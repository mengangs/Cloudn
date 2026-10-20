// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

@main
struct CloudnApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Typeface.applyNavigationBarFonts()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onOpenURL { model.handle(url: $0) }
                .preferredColorScheme(model.settings.appearance.colorScheme)
                .tint(model.settings.accentColor)
                .environment(\.onAccent, model.settings.onAccentColor)
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(phase)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            ResolveView()
                .tabItem { Label { Text("解析") } icon: { Image(icon: .link) } }
                .tag(AppTab.resolve)
            DownloadsView()
                .tabItem { Label { Text("下载") } icon: { Image(icon: .download) } }
                .badge(model.downloads.activeCount)
                .tag(AppTab.downloads)
            AccountsView()
                .tabItem { Label { Text("我的") } icon: { Image(icon: .user) } }
                .badge(model.announcements.unreadCount)
                .tag(AppTab.me)
        }
        .background(Color.paper)
        .background(WindowSceneReader { ToastWindowPresenter.shared.install(in: $0, model: model) })
        .sheet(isPresented: Binding(get: { !model.settings.acceptedNotice }, set: { _ in })) {
            NoticeSheet { model.settings.acceptedNotice = true }
                .interactiveDismissDisabled()
        }
        // 首次启动先看完须知，再提示更新（两个 sheet 不能同时弹）
        .sheet(item: Binding(get: { model.settings.acceptedNotice ? model.availableUpdate : nil },
                             set: { model.availableUpdate = $0 })) {
            UpdateSheet(release: $0).presentationDetents([.medium, .large])
        }
        // 公告弹窗排在须知与更新之后
        .sheet(item: Binding(get: { model.settings.acceptedNotice && model.availableUpdate == nil ? model.announcements.popup : nil },
                             set: { if $0 == nil, let shown = model.announcements.popup { model.announcements.markRead(shown.id); model.announcements.popup = nil } })) { a in
            AnnouncementPopup(announcement: a) {
                model.announcements.markRead(a.id)
                model.announcements.popup = nil
                model.selectedTab = .me
                model.openAnnouncement = a
            } onClose: {
                model.announcements.markRead(a.id)
                model.announcements.popup = nil
            }
        }
    }
}

/// 首次启动的使用须知
struct NoticeSheet: View {
    let onAccept: () -> Void

    var body: some View {
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
            Spacer()
            Button(action: onAccept) {
                Text("我已了解").frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle(kind: .primary))
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 24)
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
