// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 系统文件选择器（UIDocumentPickerViewController），由 UIKit 直接弹出。
/// - SwiftUI 的 .fileImporter 在同一条导航栈里挂了多个时只有一个生效（「我的」页已有导入备份）；
/// - 把选择器包进 SwiftUI 的 sheet 里，选完点「打开」也可能没反应（选择器要自己收起，却不是被直接弹出的）。
/// 所以这里从最上层的界面直接 present，选完 / 取消后由系统收起，再回调
private struct DocumentPickerPresenter: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let types: [UTType]
    let multiple: Bool
    let asCopy: Bool
    let onPick: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard isPresented, coordinator.picker == nil else { return }
        // asCopy: true —— 系统先复制一份到本应用的临时目录再交回（就地打开在部分系统版本上点「打开」会没反应）；
        // 选文件夹只能就地打开（asCopy: false，拿到安全作用域地址）
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: asCopy)
        picker.allowsMultipleSelection = multiple
        picker.delegate = coordinator
        coordinator.picker = picker
        // 等这一轮界面更新结束再弹，避免与 SwiftUI 的转场冲突
        DispatchQueue.main.async {
            guard let top = Self.topController(from: host) else { return coordinator.finish(nil) }
            Log.info("文件选择器：弹出（\(asCopy ? "复制" : "就地打开")，类型 \(types.map(\.identifier).joined(separator: ","))）")
            top.present(picker, animated: true)
            picker.presentationController?.delegate = coordinator
        }
    }

    static func topController(from host: UIViewController) -> UIViewController? {
        var top = host.view.window?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
        var parent: DocumentPickerPresenter
        var picker: UIDocumentPickerViewController?

        init(_ parent: DocumentPickerPresenter) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            Log.info("文件选择器：选中 \(urls.count) 项 \(urls.map(\.lastPathComponent).joined(separator: "、"))")
            finish(urls)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            Log.info("文件选择器：取消")
            finish(nil)
        }
        /// 下滑收起
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            Log.info("文件选择器：下滑收起")
            finish(nil)
        }

        func finish(_ urls: [URL]?) {
            guard picker != nil else { return }
            picker = nil
            parent.isPresented = false
            if let urls, !urls.isEmpty { parent.onPick(urls) }
        }
    }
}

extension View {
    /// 用系统文件选择器选文件 / 文件夹
    /// asCopy 为 true 时交回的是临时副本（用完由调用方删除）；为 false 时是原文件的安全作用域地址
    func documentPicker(isPresented: Binding<Bool>, types: [UTType], multiple: Bool = false, asCopy: Bool = true,
                        onPick: @escaping ([URL]) -> Void) -> some View {
        background(
            DocumentPickerPresenter(isPresented: isPresented, types: types, multiple: multiple, asCopy: asCopy, onPick: onPick)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
    }
}

/// 把文件导出（复制）到「文件」App 里用户选的位置。导出由系统完成，不需要 App 自己拿到目标文件夹的访问权限——
/// 有的签名安装方式下系统不给「就地打开」的权限（选文件夹点「打开」没反应），这条路仍然可用
private struct ExportPickerPresenter: UIViewControllerRepresentable {
    @Binding var urls: [URL]
    let onDone: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard !urls.isEmpty, coordinator.picker == nil else { return }
        let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        picker.delegate = coordinator
        coordinator.picker = picker
        let count = urls.count
        DispatchQueue.main.async {
            guard let top = DocumentPickerPresenter.topController(from: host) else { return coordinator.finish(false) }
            Log.info("文件选择器：导出 \(count) 个文件")
            top.present(picker, animated: true)
            picker.presentationController?.delegate = coordinator
        }
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
        var parent: ExportPickerPresenter
        var picker: UIDocumentPickerViewController?
        init(_ parent: ExportPickerPresenter) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            Log.info("文件选择器：已导出 \(urls.count) 个文件")
            finish(true)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(false) }
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { finish(false) }

        func finish(_ done: Bool) {
            guard picker != nil else { return }
            picker = nil
            parent.urls = []
            parent.onDone(done)
        }
    }
}

extension View {
    /// urls 非空时弹出系统导出界面，把这些文件复制到「文件」App 里选的位置；结束后 urls 清空
    func exportPicker(urls: Binding<[URL]>, onDone: @escaping (Bool) -> Void) -> some View {
        background(ExportPickerPresenter(urls: urls, onDone: onDone).frame(width: 0, height: 0).accessibilityHidden(true))
    }
}
