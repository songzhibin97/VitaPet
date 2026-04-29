import SwiftUI

// MARK: - SoundSection

@MainActor
struct SoundSection: View {
    @Binding var soundEnabled: Bool
    @Binding var soundVolume: Double

    let onSetSoundEnabled: @MainActor (Bool) -> Void
    let onSetSoundVolume: @MainActor (Float) -> Void

    var body: some View {
        Section("音效") {
            Toggle("启用音效", isOn: $soundEnabled)
                .onChange(of: soundEnabled) { _, newValue in
                    onSetSoundEnabled(newValue)
                }

            Text("每只宠物可在「宠物管理」中单独设置音效。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if soundEnabled {
                HStack {
                    Text("音量")
                    Slider(value: $soundVolume, in: 0...1)
                        .onChange(of: soundVolume) { _, newValue in
                            onSetSoundVolume(Float(newValue))
                        }
                }
            }
        }
    }
}
