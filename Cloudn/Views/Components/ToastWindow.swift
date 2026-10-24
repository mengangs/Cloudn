// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import UIKit

/// Toast 放在单独一层窗口里，弹出的 sheet 也盖不住它。这层窗口不接收触摸，下面的界面照常可点
@MainActor
final class ToastWindowPresenter {
    static let shared = ToastWindowPresenter()
    private var window: UIWindow?

    func install(in scene: UIWindowScene, model: AppModel) {
        guard window == nil else { return }
        let host = UIHostingController(rootView: ToastHost().environment(model))
        host.view.backgroundColor = .clear
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.windowLevel = .alert + 1
        window.isUserInteractionEnabled = false
        window.isHidden = false
        self.window = window
    }
}

private struct ToastHost: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Color.clear
            .toastOverlay($model.toast, lift: model.toastLifts.values.max() ?? 0)
            .preferredColorScheme(model.settings.appearance.colorScheme)
            .tint(model.settings.accentColor)
    }
}

/// 拿到所在窗口的 scene，用来挂 Toast 窗口
struct WindowSceneReader: UIViewRepresentable {
    let onScene: (UIWindowScene) -> Void

    func makeUIView(context: Context) -> SceneProbeView {
        let view = SceneProbeView()
        view.onScene = onScene
        return view
    }

    func updateUIView(_ uiView: SceneProbeView, context: Context) {}

    final class SceneProbeView: UIView {
        var onScene: ((UIWindowScene) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let scene = window?.windowScene { onScene?(scene) }
        }
    }
}

/// 把主题色设到所在窗口的 tintColor：系统弹窗（alert、确认框）的按钮只认窗口的 tintColor，不跟 SwiftUI 的 .tint
struct WindowTint: UIViewRepresentable {
    let color: UIColor

    func makeUIView(context: Context) -> TintProbeView {
        let view = TintProbeView()
        view.color = color
        return view
    }

    func updateUIView(_ uiView: TintProbeView, context: Context) {
        uiView.color = color
    }

    final class TintProbeView: UIView {
        var color: UIColor? {
            didSet { window?.tintColor = color }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            window?.tintColor = color
        }
    }
}
