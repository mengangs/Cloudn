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
    static let ink = dynamic(0x1F1E1B, 0xEDEAE3)
    static let ink2 = dynamic(0x66625A, 0xA8A397)
    static let ink3 = dynamic(0x8A857B, 0x7C786F)
    /// 视频平台图标底（陶土浅）
    static let claySoft = dynamic(0xF2E2D7, 0x3A2A22)
    static let clayInk = dynamic(0x8E3F22, 0xF0A383)
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
    /// 大小、速度、链接、提取码
    static let mono = Font.system(.footnote, design: .monospaced)
    static let monoSmall = Font.system(.caption, design: .monospaced)
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
    case close, trash, lock, refresh, pencil, folderPlus = "folder-plus", move, share, eye, warning, filter, branch, tag
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
                        .overlay { Image(icon: .check).resizable().scaledToFit().padding(size * 0.08).foregroundStyle(.white) }
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

    /// 浮层阴影（菜单、操作栏、Toast）
    func floatingShadow() -> some View {
        self.shadow(color: Color(red: 0.24, green: 0.18, blue: 0.12).opacity(0.10), radius: 12, y: 6)
    }
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
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
            .overlay { if kind == .secondary { Capsule().strokeBorder(Color.hairline, lineWidth: 1) } }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }

    private var foreground: AnyShapeStyle {
        switch kind {
        case .primary: return AnyShapeStyle(Color.white)
        case .secondary: return AnyShapeStyle(Color.ink)
        case .dark: return AnyShapeStyle(Color.paper)
        }
    }

    private var background: AnyShapeStyle {
        switch kind {
        case .primary: return AnyShapeStyle(.tint)
        case .secondary: return AnyShapeStyle(Color.surface)
        case .dark: return AnyShapeStyle(Color.ink)
        }
    }
}

/// 圆形图标按钮（细线）
struct CircleIconButtonStyle: ButtonStyle {
    var size: CGFloat = 36
    var filled = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: size, height: size)
            .foregroundStyle(filled ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.ink))
            .background(filled ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.clear), in: Circle())
            .overlay { if !filled { Circle().strokeBorder(Color.hairline, lineWidth: 1) } }
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
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
                .padding(.horizontal, 14)
                .frame(height: 32)
                .foregroundStyle(selected ? Color.paper : Color.ink)
                .background(selected ? Color.ink : Color.clear, in: Capsule())
                .overlay { if !selected { Capsule().strokeBorder(Color.hairline, lineWidth: 1) } }
        }
        .buttonStyle(.plain)
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
                Capsule().fill(Color.hairline)
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
    @State private var phase: CGFloat = -0.3

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.tint))
                .frame(width: geo.size.width * 0.3)
                .offset(x: geo.size.width * phase)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) { phase = 1 }
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

    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().stroke(Color.hairline, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: value.map { max(0.04, min(1, $0)) } ?? 0.25)
                .stroke(.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .rotationEffect(.degrees(value == nil && spin ? 360 : 0))
                .animation(.easeOut(duration: 0.4), value: value)
            if glyph {
                Image(icon: paused ? .play : .pause)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size * 0.36, height: size * 0.36)
                    .foregroundStyle(.tint)
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            guard value == nil else { return }
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { spin = true }
        }
    }
}
