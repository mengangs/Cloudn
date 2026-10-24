// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import SwiftUI
import UIKit

// MARK: - 色彩：纸与陶土

/// 浅色 / 深色两套取值的动态颜色
private func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
    Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// 正文墨色（给 UIKit 视图用，取值与 Color.ink 一致）
    static let cloudnInk = UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0xEDEAE3) : UIColor(hex: 0x1F1E1B) }
}

extension Color {
    /// 页面底色
    static let paper = dynamic(0xF7F5EF, 0x161513)
    /// 卡片
    static let surface = dynamic(0xFFFEFB, 0x23221F)
    /// 图标底、输入框底等弱填充
    static let fillMuted = dynamic(0xEFEBE2, 0x2E2C28)
    /// 1pt 细线
    static let hairline = dynamic(0xE3DED3, 0x3A3833)
    /// 卡片内分隔线（比外框更淡）
    static let divider = dynamic(0xECE8DE, 0x302E2A)
    /// 进度条 / 进度环的底轨：比细线深一级，在卡片上看得出来；强调色进度对它仍有 3:1 以上
    static let track = dynamic(0xD6CFC2, 0x4A4740)
    static let ink = dynamic(0x1F1E1B, 0xEDEAE3)
    static let ink2 = dynamic(0x66625A, 0xA8A397)
    /// 三级文字：对纸色、卡片底的对比度在两种外观下都不低于 4.5:1
    static let ink3 = dynamic(0x736E66, 0x8F8A80)
    /// 视频平台图标底（陶土浅）
    static let claySoft = dynamic(0xF2E2D7, 0x3A2A22)
    static let clayInk = dynamic(0x8E3F22, 0xF0A383)
    /// 滑动操作按钮的底色：系统在上面画白字，深浅色下都要够深（clayInk / ink2 在深色下偏浅，白字看不清）
    static let swipeDestructive = dynamic(0x8E3F22, 0x9A4A2A)
    static let swipeNeutral = dynamic(0x66625A, 0x5A554C)
    static let swipePositive = dynamic(0x3F7D52, 0x3E7350)
    static let success = dynamic(0x3F7D52, 0x7FB38E)
}

// MARK: - 字体

extension Font {
    /// 衬线标题（内置思源宋体子集，跟随动态字号）
    static func serif(_ size: CGFloat, relativeTo style: Font.TextStyle = .title2) -> Font {
        .custom(Typeface.serifName, size: size, relativeTo: style)
    }

    static let pageTitle = Font.serif(30, relativeTo: .largeTitle)
    static let cardTitle = Font.serif(19, relativeTo: .title3)
    /// 链接、提取码、直链、哈希、分支名这类「原样照抄」的字符串。数字不用它：等宽字体排中文字距很松
    static let mono = Font.system(.footnote, design: .monospaced)
    static let monoSmall = Font.system(.caption, design: .monospaced)
    /// 大小、速度、时长、计数：系统字体 + 等宽数字（变化时不跳动），和中文排在一起字距正常
    static let figures = Font.footnote.monospacedDigit()
    static let figuresSmall = Font.caption.monospacedDigit()
}

enum Typeface {
    static let serifName = "NotoSerifSC-SemiBold"

    /// 导航栏标题也用衬线
    static func applyNavigationBarFonts() {
        guard let large = UIFont(name: serifName, size: 30), let inline = UIFont(name: serifName, size: 17) else { return }
        let metrics = UIFontMetrics(forTextStyle: .largeTitle)
        let bar = UINavigationBar.appearance()
        bar.largeTitleTextAttributes = [.font: metrics.scaledFont(for: large)]
        bar.titleTextAttributes = [.font: UIFontMetrics(forTextStyle: .headline).scaledFont(for: inline)]
    }
}

// MARK: - 图标

enum Icon: String {
    case link, arrowUp = "arrow-up", plus, paste, download, folder, file, video, image, music, archive, doc, text, cloud, star
    case save, user, gear, search, clock, check, checkCircle = "check-circle", chevronRight = "chevron-right", pause, play
    case close, trash, lock, refresh, pencil, folderPlus = "folder-plus", move, share, eye, warning, filter, branch, tag, more, magnet
}

extension Image {
    /// 应用内线性图标（模板渲染，跟随前景色）
    init(icon: Icon) { self.init("i.\(icon.rawValue)") }
}

/// 统一尺寸的线性图标
struct IconView: View {
    let icon: Icon
    var size: CGFloat = 20

    init(_ icon: Icon, size: CGFloat = 20) {
        self.icon = icon
        self.size = size
    }

    var body: some View {
        Image(icon: icon).resizable().scaledToFit().frame(width: size, height: size)
    }
}

// MARK: - 平台标识

/// 平台图标资源名与类别（网盘暖灰底 / 视频平台陶土浅底）
struct PlatformMark: Equatable {
    let name: String
    let isVideo: Bool

    static func share(_ p: SharePlatform) -> PlatformMark { PlatformMark(name: p.rawValue, isVideo: false) }
    static func video(_ p: VideoPlatform) -> PlatformMark { PlatformMark(name: p.rawValue, isVideo: true) }
    static let github = PlatformMark(name: "github", isVideo: false)
    static let magnet = PlatformMark(name: "magnet", isVideo: false)

    static func account(_ kind: AccountKind) -> PlatformMark {
        PlatformMark(name: kind.rawValue, isVideo: !kind.isDrive)
    }

    /// 线性在 Platforms/p.*，实心在 PlatformsSolid/ps.*
    func asset(_ style: PlatformIconStyle) -> String { (style == .solid ? "ps." : "p.") + name }
}

/// 平台图标方块
struct PlatformTile: View {
    let mark: PlatformMark
    var size: CGFloat = 36
    var dimmed = false
    var badge = false
    @AppStorage(PlatformIconStyle.key) private var style: PlatformIconStyle = .line

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
            .fill(mark.isVideo ? Color.claySoft : Color.fillMuted)
            .frame(width: size, height: size)
            .overlay {
                // 实心图形视觉上更重，略缩一点与线性对齐
                Image(mark.asset(style))
                    .resizable()
                    .scaledToFit()
                    .frame(width: size * (style == .solid ? 0.54 : 0.58), height: size * (style == .solid ? 0.54 : 0.58))
                    .foregroundStyle(mark.isVideo ? Color.clayInk : (dimmed ? Color.ink3 : Color.ink))
            }
            .overlay(alignment: .bottomTrailing) {
                if badge {
                    Circle()
                        .fill(Color.success)
                        .frame(width: size * 0.34, height: size * 0.34)
                        .overlay { Image(icon: .check).resizable().scaledToFit().padding(size * 0.08).foregroundStyle(Color.surface) }
                        .overlay { Circle().stroke(Color.surface, lineWidth: 2) }
                        .offset(x: size * 0.08, y: size * 0.08)
                }
            }
            .accessibilityHidden(true)
    }
}

/// 行内小图标（标签、说明文字里）
struct PlatformGlyph: View {
    let mark: PlatformMark
    var size: CGFloat = 14
    @AppStorage(PlatformIconStyle.key) private var style: PlatformIconStyle = .line

    var body: some View {
        Image(mark.asset(style)).resizable().scaledToFit().frame(width: size, height: size).accessibilityHidden(true)
    }
}

typealias Glyph = Icon

extension Label where Title == Text, Icon == Image {
    /// 用线性图标集的 Label（菜单、按钮）
    init(_ title: String, glyph: Glyph) {
        self.init { Text(title) } icon: { Image(icon: glyph) }
    }
}

// MARK: - 卡片与列表

extension View {
    /// 卡片：暖白底 + 1pt 细线
    func card(radius: CGFloat = 16, padding: CGFloat? = nil) -> some View {
        self
            .padding(padding ?? 0)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.hairline, lineWidth: 1) }
    }

    /// List / Form 放到纸色底上
    func paperList() -> some View {
        self.scrollContentBackground(.hidden).background(Color.paper)
    }

    /// 列表分组行：卡片底色 + 淡分隔线
    func paperRow() -> some View {
        self.listRowBackground(Color.surface).listRowSeparatorTint(Color.divider)
    }

    /// iPad 等宽屏上把主内容收窄并居中，避免一行拉得过长；iPhone 宽度不到上限，不受影响
    func readableWidth(_ maxWidth: CGFloat = 700) -> some View {
        self.frame(maxWidth: maxWidth).frame(maxWidth: .infinity)
    }

    /// 点按区域上下（左右）各扩出一截、外观与布局不变：小胶囊、文字按钮也有 44pt 高的点按区域
    func expandedHitArea(_ vertical: CGFloat, horizontal: CGFloat = 0) -> some View {
        self
            .padding(.vertical, vertical)
            .padding(.horizontal, horizontal)
            .contentShape(Rectangle())
            .padding(.vertical, -vertical)
            .padding(.horizontal, -horizontal)
    }

    /// 浮层阴影（菜单、操作栏、Toast）：浅色是淡淡的暖棕，深色底上暖棕看不出来，改用更深的黑影把浮层托起来
    func floatingShadow() -> some View {
        self.shadow(color: Color.floatingShadow, radius: 12, y: 6)
    }
}

private extension Color {
    static let floatingShadow = Color(UIColor {
        $0.userInterfaceStyle == .dark
            ? UIColor(white: 0, alpha: 0.45)
            : UIColor(red: 0.24, green: 0.18, blue: 0.12, alpha: 0.10)
    })
}

extension View {
    /// 确认框挂在触发它的那一行 / 那张卡片上：iOS 26 起确认框是指向来源视图的气泡，挂在整页上会跑到屏幕顶部
    func rowDialog<A: View>(_ title: String, isPresented: Binding<Bool>, message: String? = nil,
                            @ViewBuilder actions: () -> A) -> some View {
        let content = actions()
        return confirmationDialog(title, isPresented: isPresented, titleVisibility: .visible) {
            content
        } message: {
            if let message { Text(message) }
        }
    }
}

/// 可选状态「正好是这一项」时为 true；关闭时清空
func presenting<T>(_ value: Binding<T?>, _ matches: @escaping (T) -> Bool) -> Binding<Bool> {
    Binding(get: { value.wrappedValue.map(matches) ?? false }, set: { if !$0 { value.wrappedValue = nil } })
}

/// 平时横排、辅助字号（AX1 以上）下改为竖排：免得按钮和文字被挤成一字一行
struct AdaptiveStack<Content: View>: View {
    var spacing: CGFloat?
    var rowAlignment: VerticalAlignment
    var columnAlignment: HorizontalAlignment
    let content: Content
    @Environment(\.dynamicTypeSize) private var typeSize

    init(spacing: CGFloat? = nil, rowAlignment: VerticalAlignment = .center, columnAlignment: HorizontalAlignment = .leading,
         @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.rowAlignment = rowAlignment
        self.columnAlignment = columnAlignment
        self.content = content()
    }

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: columnAlignment, spacing: spacing))
            : AnyLayout(HStackLayout(alignment: rowAlignment, spacing: spacing))
        layout { content }
    }
}

/// 卡片内行与行之间的分隔线（从图标右侧开始）
struct RowDivider: View {
    var leading: CGFloat = 62

    var body: some View {
        Rectangle().fill(Color.divider).frame(height: 1).padding(.leading, leading)
    }
}

/// 分组标题（小号次要色）
struct SectionLabel: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
            Spacer()
            if let trailing { Text(trailing).font(.caption).foregroundStyle(Color.ink2) }
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - 按钮

/// 主按钮（实心胶囊）/ 次按钮（细线胶囊）
struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, dark }
    var kind: Kind = .primary
    var height: CGFloat = 48

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(kind == .secondary ? .medium : .semibold))
            .padding(.horizontal, 20)
            .frame(minHeight: height)
            .modifier(OnAccentForeground(fallback: kind == .secondary ? Color.ink : (kind == .dark ? Color.paper : nil)))
            .background(background, in: Capsule())
            .overlay { if kind == .secondary { Capsule().strokeBorder(Color.hairline, lineWidth: 1) } }
            // 矮胶囊（30pt 的「登录」等）点按区域补到 44pt
            .expandedHitArea(max(0, (44 - height) / 2))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .modifier(DimWhenDisabled())
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }

    private var background: AnyShapeStyle {
        switch kind {
        case .primary: return AnyShapeStyle(.tint)
        case .secondary: return AnyShapeStyle(Color.surface)
        case .dark: return AnyShapeStyle(Color.ink)
        }
    }
}

/// 当前强调色（浅色 / 深色各一份的动态 UIColor，由根视图注入）
private struct AccentTintKey: EnvironmentKey {
    static let defaultValue = UIColor(named: "AccentColor") ?? .systemOrange
}

extension EnvironmentValues {
    var accentTint: UIColor {
        get { self[AccentTintKey.self] }
        set { self[AccentTintKey.self] = newValue }
    }
}

/// fallback 为 nil 时用强调色底上的前景色（按对比度选白色或深墨色），否则用 fallback
struct OnAccentForeground: ViewModifier {
    let fallback: Color?
    @Environment(\.accentTint) private var accentTint
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.foregroundStyle(fallback ?? Self.readable(on: accentTint, dark: colorScheme == .dark))
    }

    /// 按当前浅色 / 深色显式取出强调色再按对比度选字色。
    /// 不能交给动态颜色自己解析：Color(uiColor:) 的动态回调拿到的常是浅色特征，
    /// 深色模式提亮的陶土色上就成了看不清的白字
    static func readable(on accent: UIColor, dark: Bool) -> Color {
        let resolved = accent.resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        func lin(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let l = 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        let onWhite = 1.05 / (l + 0.05), onDark = (l + 0.05) / 0.0575
        return onWhite >= onDark ? .white : Color(red: 0x16 / 255, green: 0x15 / 255, blue: 0x13 / 255)
    }
}

/// 文字按钮（分组标题旁的「全部」「清空」「多选」等）：强调色文字。
/// 强调色和正文墨色几乎一样时（墨黑主题）加粗，免得和普通文字分不开
struct TextLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TextLinkLabel(configuration: configuration)
    }
}

private struct TextLinkLabel: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.accentTint) private var accentTint
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .foregroundStyle(.tint)
            .bold(Self.looksLikeInk(accentTint, dark: colorScheme == .dark))
            .expandedHitArea(12, horizontal: 8)
            .opacity(configuration.isPressed ? 0.5 : (isEnabled ? 1 : 0.45))
    }

    /// 强调色与正文墨色对比不到 1.6:1
    static func looksLikeInk(_ accent: UIColor, dark: Bool) -> Bool {
        let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        func luminance(_ color: UIColor) -> CGFloat {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
            func lin(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        }
        let a = luminance(accent), b = luminance(.cloudnInk)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05) < 1.6
    }
}

/// 圆形图标按钮（细线）
struct CircleIconButtonStyle: ButtonStyle {
    var size: CGFloat = 36
    var filled = false
    /// 细线样式的图标颜色（默认墨色）
    var foreground: Color?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: size, height: size)
            .modifier(OnAccentForeground(fallback: filled ? nil : (foreground ?? Color.ink)))
            .background(filled ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.clear), in: Circle())
            .overlay { if !filled { Circle().strokeBorder(Color.hairline, lineWidth: 1) } }
            // 视觉上小一些，点按区域不小于 44pt
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .modifier(DimWhenDisabled())
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// 按钮不可用时统一变淡（各按钮样式共用，调用处不用再各自写透明度）
private struct DimWhenDisabled: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.opacity(isEnabled ? 1 : 0.45)
    }
}

/// 筛选胶囊
struct FilterChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.footnote)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .frame(minHeight: 32)
                .foregroundStyle(selected ? Color.paper : Color.ink)
                .background(selected ? Color.ink : Color.clear, in: Capsule())
                .overlay { if !selected { Capsule().strokeBorder(Color.hairline, lineWidth: 1) } }
                .expandedHitArea(6)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: selected)
    }
}

// MARK: - 进度

/// 3pt 进度细线
struct ProgressLine: View {
    let value: Double?
    var tint: Color?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.track)
                if let value {
                    Capsule()
                        .fill(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.tint))
                        .frame(width: max(3, geo.size.width * min(1, max(0, value))))
                        .animation(.easeOut(duration: 0.4), value: value)
                } else {
                    IndeterminateBar(tint: tint)
                }
            }
        }
        .frame(height: 3)
        .accessibilityElement()
        .accessibilityValue(value.map { "\(Int($0 * 100))%" } ?? "进行中")
    }
}

private struct IndeterminateBar: View {
    var tint: Color?

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { context in
                // 1.1 秒从左滑到右，用缓动曲线算位置
                let p = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1
                let eased = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2
                Capsule()
                    .fill(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.tint))
                    .frame(width: geo.size.width * 0.3)
                    .offset(x: geo.size.width * (-0.3 + 1.3 * eased))
            }
        }
        .clipShape(Capsule())
    }
}

/// 圆环进度（下载按钮原地变成它）
struct ProgressRing: View {
    let value: Double?
    var size: CGFloat = 26
    var lineWidth: CGFloat = 2.4
    var paused = false
    /// 中间是否画暂停 / 继续符号（只表示「正在处理」时关掉）
    var glyph = true

    var body: some View {
        ZStack {
            Circle().stroke(Color.track, lineWidth: lineWidth)
            if let value {
                Circle()
                    .trim(from: 0, to: max(0.04, min(1, value)))
                    .stroke(.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: value)
            } else {
                // 进度未知：按时间转，不用 repeatForever（放在列表里会带着整行漂移）
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    Circle()
                        .trim(from: 0, to: 0.25)
                        .stroke(.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 1) * 360))
                }
            }
            if glyph {
                Image(icon: paused ? .play : .pause)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size * 0.36, height: size * 0.36)
                    .foregroundStyle(.tint)
            }
        }
        .frame(width: size, height: size)
    }
}
