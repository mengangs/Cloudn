// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 系统文件选择器（UIDocumentPickerViewController）。
/// SwiftUI 的 .fileImporter 在同一条导航栈里挂了多个时只有一个生效（「我的」页已有导入备份），
/// 选完点「打开」没反应；这里每次单独弹出，互不干扰
struct DocumentPicker: UIViewControllerRepresentable {
    let types: [UTType]
    var multiple = false
    let onPick: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // asCopy: false —— 拿到原文件（安全作用域），大文件不必先复制一份
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.allowsMultipleSelection = multiple
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onPick(urls) }
    }
}

extension View {
    /// 用系统文件选择器选文件（sheet 方式弹出）
    func documentPicker(isPresented: Binding<Bool>, types: [UTType], multiple: Bool = false, onPick: @escaping ([URL]) -> Void) -> some View {
        sheet(isPresented: isPresented) {
            DocumentPicker(types: types, multiple: multiple, onPick: onPick).ignoresSafeArea()
        }
    }
}
