// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import UIKit
import UniformTypeIdentifiers

/// 分享扩展：在 Safari、微信等应用里「分享 → Cloudn」，把链接或文案交给主应用解析。
/// 先通过 cloudn://resolve?text=… 唤起主应用；只有唤起失败时才把内容放进剪贴板（打开 Cloudn 即会提示粘贴），
/// 唤起成功就不动用户的剪贴板。
final class ShareViewController: UIViewController {
    /// viewDidAppear 可能不止一次（弹出的提示框收起后等）：只处理一次，免得重复唤起主应用
    private var handled = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !handled else { return }
        handled = true
        Task { await handle() }
    }

    private func handle() async {
        let text = await sharedText()
        guard !text.isEmpty else {
            finish(message: "没有识别到可解析的链接")
            return
        }
        var comps = URLComponents()
        comps.scheme = "cloudn"
        comps.host = "resolve"
        comps.queryItems = [URLQueryItem(name: "text", value: text)]
        if let url = comps.url, await openHostApp(url) {
            finish(message: nil)
        } else {
            // 唤起失败才借用剪贴板兜底
            UIPasteboard.general.string = text
            finish(message: "已复制到剪贴板，打开 Cloudn 即可解析")
        }
    }

    /// 拼出分享内容：网页链接优先，其次文本（分享文案里常带提取码，一并保留）
    private func sharedText() async -> String {
        var parts: [String] = []
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL, !url.isFileURL {
                parts.append(url.absoluteString)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                parts.append(text)
            }
        }
        // 文案里已经含有链接时不重复拼接
        var seen = Set<String>()
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .reduce(into: [String]()) { acc, part in
                if !acc.contains(where: { $0.contains(part) }) { acc.append(part) }
            }
            .joined(separator: " ")
    }

    /// 扩展里 UIApplication 的打开接口在编译期不可用：沿响应链找到能响应
    /// openURL:options:completionHandler: 的对象（即应用对象），按方法实现直接调用。
    /// 等系统回报是否真的打开了；3 秒没有回音按失败处理（走剪贴板兜底）
    @MainActor
    private func openHostApp(_ url: URL) async -> Bool {
        typealias Completion = @convention(block) (Bool) -> Void
        typealias OpenURL = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, Completion?) -> Void
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.responds(to: selector), let imp = current.method(for: selector) {
                let open = unsafeBitCast(imp, to: OpenURL.self)
                return await withCheckedContinuation { continuation in
                    // 回调与超时只有先到的那个生效（都在主线程上）
                    let once = ResumeOnce()
                    let finish: (Bool) -> Void = { ok in
                        guard !once.done else { return }
                        once.done = true
                        continuation.resume(returning: ok)
                    }
                    open(current, selector, url as NSURL, NSDictionary(), { ok in
                        DispatchQueue.main.async { finish(ok) }
                    })
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { finish(false) }
                }
            }
            responder = current.next
        }
        return false
    }

    private func finish(message: String?) {
        guard let message else {
            extensionContext?.completeRequest(returningItems: nil)
            return
        }
        let alert = UIAlertController(title: "Cloudn", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { [weak self] _ in
            self?.extensionContext?.completeRequest(returningItems: nil)
        })
        present(alert, animated: true)
    }
}

/// 续体只能恢复一次：系统回调和超时谁先到用谁
private final class ResumeOnce {
    var done = false
}
