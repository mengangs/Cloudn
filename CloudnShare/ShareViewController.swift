// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import UIKit
import UniformTypeIdentifiers

/// 分享扩展：在 Safari、微信、抖音等应用里「分享 → Cloudn」，把链接或文案交给主应用解析。
/// 先通过 cloudn://resolve?text=… 唤起主应用，并确认它真的到了前台（分享来源的应用随之进入后台）才收起；
/// 系统说打开了、其实没跳过去（新系统上会这样）时，把内容放进剪贴板，给「打开 Cloudn」重试和「完成」，不再一闪就消失。
/// 唤起成功就不动用户的剪贴板。
final class ShareViewController: UIViewController {
    /// viewDidAppear 可能不止一次（弹出的提示框收起后等）：只处理一次，免得重复唤起主应用
    private var handled = false
    private var sharedURL: URL?
    /// 分享来源的应用进入了后台：说明主应用真的到了前台
    private var hostLeft = false
    private var observers: [NSObjectProtocol] = []

    private let card = UIStackView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let openButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        buildCard()
        for name in [NSNotification.Name.NSExtensionHostWillResignActive, .NSExtensionHostDidEnterBackground] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.hostLeft = true
            })
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !handled else { return }
        handled = true
        Task { await handle() }
    }

    private func handle() async {
        let text = await sharedText()
        guard !text.isEmpty else {
            show(title: "没有识别到链接", detail: "这条分享里没有可解析的链接或口令。", canRetry: false)
            return
        }
        var comps = URLComponents()
        comps.scheme = "cloudn"
        comps.host = "resolve"
        comps.queryItems = [URLQueryItem(name: "text", value: text)]
        sharedURL = comps.url
        if await open() { return }
        // 没能跳过去才借用剪贴板兜底：手动打开 Cloudn 也会提示粘贴
        UIPasteboard.general.string = text
        show(title: "链接已复制", detail: "点「打开 Cloudn」继续；如果仍没有跳转，手动打开 Cloudn 即可粘贴解析。", canRetry: true)
    }

    /// 唤起主应用，并等它真的到前台（最多 2 秒）；到了就收起扩展，返回 true
    private func open() async -> Bool {
        guard let url = sharedURL else { return false }
        setOpening()
        hostLeft = false
        let accepted = await openHostApp(url)
        if accepted {
            for _ in 0..<20 where !hostLeft { try? await Task.sleep(nanoseconds: 100_000_000) }
        }
        guard accepted, hostLeft else { return false }
        extensionContext?.completeRequest(returningItems: nil)
        return true
    }

    // MARK: 界面

    /// 与主应用「纸与陶土」一致的几种颜色（扩展拿不到主应用的设计令牌，这里各写一份）
    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? Self.hex(dark) : Self.hex(light) }
    }

    private static func hex(_ v: UInt32) -> UIColor {
        UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    private static let paper = dynamic(0xF7F5EF, 0x161513)
    private static let ink = dynamic(0x1F1E1B, 0xEDEAE3)
    private static let ink2 = dynamic(0x66625A, 0xA8A397)
    private static let clay = dynamic(0xB4532F, 0xE08A66)
    /// 陶土底上的字：浅色白字，深色（提亮的陶土）用深墨字
    private static let onClay = dynamic(0xFFFFFF, 0x161513)

    private func buildCard() {
        view.backgroundColor = Self.paper
        titleLabel.font = UIFontMetrics(forTextStyle: .headline).scaledFont(for: .systemFont(ofSize: 17, weight: .semibold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Self.ink
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        detailLabel.font = .preferredFont(forTextStyle: .subheadline)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = Self.ink2
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 0
        spinner.color = Self.clay

        var primary = UIButton.Configuration.filled()
        primary.title = "打开 Cloudn"
        primary.baseBackgroundColor = Self.clay
        primary.baseForegroundColor = Self.onClay
        primary.cornerStyle = .capsule
        primary.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 24, bottom: 12, trailing: 24)
        openButton.configuration = primary
        openButton.addAction(UIAction { [weak self] _ in self?.retryOpen() }, for: .primaryActionTriggered)

        var plain = UIButton.Configuration.plain()
        plain.title = "完成"
        plain.baseForegroundColor = Self.ink2
        doneButton.configuration = plain
        doneButton.addAction(UIAction { [weak self] _ in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }, for: .primaryActionTriggered)

        card.axis = .vertical
        card.alignment = .center
        card.spacing = 12
        for item in [spinner, titleLabel, detailLabel, openButton, doneButton] as [UIView] { card.addArrangedSubview(item) }
        card.setCustomSpacing(20, after: detailLabel)
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)
        NSLayoutConstraint.activate([
            card.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor, constant: 8),
            card.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor, constant: -8),
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
        setOpening()
    }

    /// 正在唤起：只有转圈和一句话
    private func setOpening() {
        spinner.startAnimating()
        spinner.isHidden = false
        titleLabel.text = "正在打开 Cloudn…"
        detailLabel.isHidden = true
        openButton.isHidden = true
        doneButton.isHidden = true
    }

    /// 没跳过去 / 没有内容：说明情况，给下一步
    private func show(title: String, detail: String, canRetry: Bool) {
        spinner.stopAnimating()
        spinner.isHidden = true
        titleLabel.text = title
        detailLabel.text = detail
        detailLabel.isHidden = false
        openButton.isHidden = !canRetry
        doneButton.isHidden = false
        UIAccessibility.post(notification: .screenChanged, argument: titleLabel)
    }

    /// 用户点了「打开 Cloudn」：在点按里再唤起一次（新系统可能只允许由用户操作触发）
    private func retryOpen() {
        Task {
            if await open() { return }
            show(title: "没能自动跳转", detail: "链接已在剪贴板里，手动打开 Cloudn 即可粘贴解析。", canRetry: true)
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
}

/// 续体只能恢复一次：系统回调和超时谁先到用谁
private final class ResumeOnce {
    var done = false
}
