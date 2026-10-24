// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

@main
struct CloudnApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Typeface.applyNavigationBarFonts()
        // 清理 MKV 转换缓存：超过 7 天没看的、总量超过 2GB 的旧文件
        Task.detached(priority: .background) { ConvertedCache.trim() }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                // 截图模式（-CloudnScreenshot，仅 Debug 构建）：直接停在指定页面，不弹须知 / 更新提示。见 ScreenshotMode.swift
                if let screen = ScreenshotMode.screen {
                    ScreenshotRootView(screen: screen)
                } else {
                    RootView()
                }
                #else
                RootView()
                #endif
            }
            .environment(model)
            .onOpenURL { model.handle(url: $0) }
            .preferredColorScheme(model.settings.appearance.colorScheme)
            .tint(model.settings.accentColor)
            .environment(\.accentTint, model.settings.accentUIColor)
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(phase)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        AppTabView { ResolveView() } me: { AccountsView() }
        .acceptsLinkDrop()
        .background(Color.paper)
        .background(WindowSceneReader { ToastWindowPresenter.shared.install(in: $0, model: model) })
        .background(WindowTint(color: model.settings.accentUIColor))
        .sheet(isPresented: Binding(get: { !model.settings.acceptedNotice }, set: { _ in })) {
            NoticeSheet { model.settings.acceptedNotice = true }
                .interactiveDismissDisabled()
        }
        // 首次启动先看完须知，再提示更新（两个 sheet 不能同时弹）
        .sheet(item: Binding(get: { model.settings.acceptedNotice ? model.availableUpdate : nil },
                             set: { model.availableUpdate = $0 })) {
            UpdateSheet(release: $0).presentationDetents([.medium, .large])
        }
    }
}

/// 三个标签页。iOS 18 起用可切换成侧栏的标签栏：iPad 上能展开成侧栏，iPhone 上和原来一样；iOS 17 保持原样
struct AppTabView<Resolve: View, Me: View>: View {
    @ViewBuilder var resolve: Resolve
    @ViewBuilder var me: Me
    @Environment(AppModel.self) private var model

    var body: some View {
        let selection = Bindable(model).selectedTab
        if #available(iOS 18.0, *) {
            TabView(selection: selection) {
                Tab(value: AppTab.resolve) { resolve } label: { resolveLabel }
                Tab(value: AppTab.downloads) { DownloadsView() } label: { downloadsLabel }
                    .badge(model.downloads.activeCount)
                Tab(value: AppTab.me) { me } label: { meLabel }
            }
            .tabViewStyle(.sidebarAdaptable)
        } else {
            TabView(selection: selection) {
                resolve
                    .tabItem { resolveLabel }
                    .tag(AppTab.resolve)
                DownloadsView()
                    .tabItem { downloadsLabel }
                    .badge(model.downloads.activeCount)
                    .tag(AppTab.downloads)
                me
                    .tabItem { meLabel }
                    .tag(AppTab.me)
            }
        }
    }

    private var resolveLabel: some View { Label { Text("解析") } icon: { Image(icon: .link) } }
    private var downloadsLabel: some View { Label { Text("下载") } icon: { Image(icon: .download) } }
    private var meLabel: some View { Label { Text("我的") } icon: { Image(icon: .user) } }
}

/// 首次启动的使用须知
struct NoticeSheet: View {
    let onAccept: () -> Void

    var body: some View {
        // 内容放进滚动视图：大字号、横屏或小屏上也能滚到底；「我已了解」固定在底部，始终点得到
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Image("Logo")
                    .resizable()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(Color.hairline, lineWidth: 1) }
                    .padding(.top, 48)
                Text("使用前请了解")
                    .font(.pageTitle)
                    .foregroundStyle(Color.ink)
                VStack(alignment: .leading, spacing: 0) {
                    NoticeRow(icon: .link, title: "能做什么", text: "粘贴网盘分享、短视频或 GitHub 链接，浏览内容并直接下载。")
                    RowDivider(leading: 50)
                    NoticeRow(icon: .lock, title: "凭据在哪", text: "登录凭据只保存在本机钥匙串，只发给对应平台，不经过任何第三方服务器。")
                    RowDivider(leading: 50)
                    NoticeRow(icon: .warning, title: "使用边界", text: "仅供个人学习与技术交流。请只解析你有权访问的内容，遵守各平台服务条款与当地法律。")
                }
                .card()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .readableWidth()
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: onAccept) {
                Text("我已了解").frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle(kind: .primary))
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 16)
            .readableWidth()
            .background(Color.paper)
        }
        .background(Color.paper)
        .presentationDetents([.large])
    }
}

private struct NoticeRow: View {
    let icon: Icon
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            IconView(icon, size: 20)
                .foregroundStyle(Color.clayInk)
                .frame(width: 22)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(Color.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
    }
}
