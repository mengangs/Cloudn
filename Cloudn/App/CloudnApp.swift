// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

@main
struct CloudnApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onOpenURL { model.handle(url: $0) }
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(active: phase == .active)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            ResolveView()
                .tabItem { Label("解析", systemImage: "link") }
                .tag(AppTab.resolve)
            AccountsView()
                .tabItem { Label("账号", systemImage: "person.crop.circle") }
                .tag(AppTab.accounts)
            DownloadsView()
                .tabItem { Label("下载", systemImage: "arrow.down.circle") }
                .badge(model.downloads.activeCount)
                .tag(AppTab.downloads)
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .toastOverlay($model.toast)
        .sheet(isPresented: Binding(get: { !model.settings.acceptedNotice }, set: { _ in })) {
            NoticeSheet { model.settings.acceptedNotice = true }
                .interactiveDismissDisabled()
        }
    }
}

/// 首次启动的使用须知
struct NoticeSheet: View {
    let onAccept: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image("Logo")
                .resizable()
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(.top, 40)
            Text("欢迎使用 Cloudn")
                .font(.title2.bold())
            VStack(alignment: .leading, spacing: 14) {
                NoticeRow(symbol: "link", text: "粘贴网盘分享链接或短视频链接，浏览内容并直接下载。")
                NoticeRow(symbol: "lock.shield", text: "登录凭证只保存在本机钥匙串，不会上传到任何服务器。")
                NoticeRow(symbol: "hand.raised", text: "仅供个人学习与技术交流，请只解析你有权访问的内容，遵守各平台服务条款与当地法律。")
            }
            .padding(.horizontal, 28)
            Spacer()
            Button(action: onAccept) {
                Text("我已了解").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
        .presentationDetents([.large])
    }
}

private struct NoticeRow: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(.tint)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
