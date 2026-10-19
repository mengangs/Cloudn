// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// 主题色：预设色块 + 系统取色器（色相 / 饱和度 / 明度任选）
struct AccentPicker: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("主题色")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(AppSettings.accentPresets, id: \.hex) { preset in
                        Button { app.settings.accentHex = preset.hex } label: {
                            Circle()
                                .fill(Color(hex: preset.hex) ?? .blue)
                                .frame(width: 30, height: 30)
                                .overlay {
                                    if app.settings.accentHex == preset.hex {
                                        Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(preset.name)
                    }
                    ColorPicker("自定义", selection: Binding(
                        get: { app.settings.accentColor ?? .blue },
                        set: { app.settings.accentHex = $0.hexString }
                    ), supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 30, height: 30)
                }
                .padding(.vertical, 2)
            }
        }
    }
}
