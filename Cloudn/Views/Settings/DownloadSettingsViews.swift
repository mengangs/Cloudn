// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import SwiftUI
import UniformTypeIdentifiers

/// 限速档位（KB/s，0 为不限）
enum SpeedLimitOption: Int, CaseIterable, Identifiable {
    case unlimited = 0, k512 = 512, m1 = 1024, m2 = 2048, m5 = 5120, m10 = 10240, m20 = 20480

    var id: Int { rawValue }
    var title: String { rawValue == 0 ? "不限速" : ByteFormat.speed(Double(rawValue) * 1024) }
}

/// 按平台覆盖单任务连接数（键是下载来源，即平台显示名）
struct PlatformConnectionsView: View {
    @Environment(AppModel.self) private var app

    private var sources: [String] {
        SharePlatform.allCases.map(\.displayName) + VideoPlatform.allCases.map(\.displayName) + ["直链"]
    }

    var body: some View {
        Form {
            Group {
                Section {
                    ForEach(sources, id: \.self) { source in
                        Picker(source, selection: binding(source)) {
                            Text("跟随全局（\(app.settings.connectionsPerTask)）").tag(0)
                            ForEach(1...16, id: \.self) { Text("\($0)").tag($0) }
                        }
                    }
                } footer: {
                    Text("部分网盘对并发连接数敏感（如百度、115），遇到 403 或频繁失败时可单独调低。")
                }
            }
            .listRowBackground(Color.surface)
        }
        .paperList()
        .navigationTitle("按平台设置连接数")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func binding(_ source: String) -> Binding<Int> {
        Binding(
            get: { app.settings.connectionsBySource[source] ?? 0 },
            set: { value in
                if value == 0 { app.settings.connectionsBySource[source] = nil } else { app.settings.connectionsBySource[source] = value }
            }
        )
    }
}

/// 选择文件夹（「文件」App 里的任意位置，如 iCloud 云盘）
struct FolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }
    }
}
