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
                        let selected = app.settings.accentHex == preset.hex
                        Button { app.settings.accentHex = preset.hex } label: {
                            Circle()
                                .fill(Color(uiColor: UIColor(hexString: preset.hex).map { light in
                                    let dark = UIColor(hexString: preset.dark) ?? light
                                    return UIColor { $0.userInterfaceStyle == .dark ? dark : light }
                                } ?? UIColor(named: "AccentColor")!))
                                .frame(width: 30, height: 30)
                                .overlay {
                                    Circle().strokeBorder(Color.ink, lineWidth: selected ? 2 : 0).padding(-4)
                                }
                                .frame(width: 44, height: 44)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(preset.name)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                    ColorPicker("自定义", selection: Binding(
                        get: { app.settings.accentColor },
                        set: { app.settings.accentHex = $0.hexString }
                    ), supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 30, height: 30)
                }
                .padding(.vertical, 2)
            }
            .sensoryFeedback(.selection, trigger: app.settings.accentHex)
        }
    }
}
