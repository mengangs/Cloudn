// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import UIKit
import UniformTypeIdentifiers

/// 分享扩展：在 Safari、微信等应用里「分享 → Cloudn」，把链接或文案交给主应用解析。
/// 先通过 cloudn://resolve?text=… 唤起主应用；万一被系统拦下，内容也已放进剪贴板，打开 Cloudn 即会提示粘贴。
final class ShareViewController: UIViewController {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await handle() }
    }

    private func handle() async {
        let text = await sharedText()
        guard !text.isEmpty else {
            finish(message: "没有识别到可解析的链接")
            return
        }
        UIPasteboard.general.string = text
        var comps = URLComponents()
        comps.scheme = "cloudn"
        comps.host = "resolve"
        comps.queryItems = [URLQueryItem(name: "text", value: text)]
        if let url = comps.url, openHostApp(url) {
            finish(message: nil)
        } else {
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
    /// openURL:options:completionHandler: 的对象（即应用对象），按方法实现直接调用
    private func openHostApp(_ url: URL) -> Bool {
        typealias OpenURL = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.responds(to: selector), let imp = current.method(for: selector) {
                let open = unsafeBitCast(imp, to: OpenURL.self)
                open(current, selector, url as NSURL, NSDictionary(), nil)
                return true
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
