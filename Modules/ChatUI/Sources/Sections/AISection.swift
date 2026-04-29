import Localization
import SwiftUI

// MARK: - AISection

@MainActor
struct AISection: View {
    @Binding var ollamaEndpoint: String
    @Binding var ollamaModel: String
    @Binding var aiSystemPrompt: String
    @Binding var aiProactiveEnabled: Bool
    @Binding var aiProactiveInterval: Int
    @Binding var aiTemperature: Double
    @Binding var aiTopP: Double
    @Binding var aiNumCtx: Int

    let aiStatus: AIEngineStatus
    let onTestConnection: @MainActor () -> Void
    let onSaveAIConfig: @MainActor (String, String, String) -> Void
    let onSaveAIProactiveConfig: @MainActor (Bool, Int) -> Void
    let onSaveAIChatOptions: @MainActor (Double, Double, Int) -> Void

    var body: some View {
        Section(L10n.settingsAI) {
            HStack(alignment: .center, spacing: 12) {
                Circle()
                    .fill(statusColor(for: aiStatus))
                    .frame(width: 10, height: 10)

                Text(aiStatusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 2)

            TextField(L10n.settingsAIEndpoint, text: $ollamaEndpoint)
                .textFieldStyle(.roundedBorder)
                .onChange(of: ollamaEndpoint) { _, newValue in
                    onSaveAIConfig(newValue, ollamaModel, aiSystemPrompt)
                }

            TextField(L10n.settingsAIModel, text: $ollamaModel)
                .textFieldStyle(.roundedBorder)
                .onChange(of: ollamaModel) { _, newValue in
                    onSaveAIConfig(ollamaEndpoint, newValue, aiSystemPrompt)
                }

            Toggle(L10n.settingsAIProactiveEnabled, isOn: $aiProactiveEnabled)
                .onChange(of: aiProactiveEnabled) { _, newValue in
                    onSaveAIProactiveConfig(newValue, aiProactiveInterval)
                }

            if aiProactiveEnabled {
                Stepper(
                    "\(L10n.settingsAIProactiveInterval): \(aiProactiveInterval)",
                    value: $aiProactiveInterval,
                    in: 5...240,
                    step: 5
                )
                .onChange(of: aiProactiveInterval) { _, newValue in
                    onSaveAIProactiveConfig(aiProactiveEnabled, newValue)
                }
            }

            Text(L10n.settingsAISystemPrompt)
                .font(.headline)

            ZStack(alignment: .topLeading) {
                if aiSystemPrompt.isEmpty {
                    Text(L10n.settingsAISystemPromptPlaceholder)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                        .padding(.leading, 6)
                        .padding(.trailing, 6)
                }

                TextEditor(text: $aiSystemPrompt)
                    .font(.body)
                    .frame(minHeight: 96)
                    .onChange(of: aiSystemPrompt) { _, newValue in
                        onSaveAIConfig(ollamaEndpoint, ollamaModel, newValue)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.35))
                    )
            }

            Button(L10n.settingsAITestConnection) {
                onTestConnection()
            }

            HStack {
                Text("温度: \(String(format: "%.1f", aiTemperature))")
                    .frame(width: 80, alignment: .leading)
                Slider(value: $aiTemperature, in: 0...2, step: 0.1)
                    .onChange(of: aiTemperature) { _, newValue in
                        onSaveAIChatOptions(newValue, aiTopP, aiNumCtx)
                    }
            }

            HStack {
                Text("Top-P: \(String(format: "%.2f", aiTopP))")
                    .frame(width: 80, alignment: .leading)
                Slider(value: $aiTopP, in: 0...1, step: 0.05)
                    .onChange(of: aiTopP) { _, newValue in
                        onSaveAIChatOptions(aiTemperature, newValue, aiNumCtx)
                    }
            }

            Stepper("上下文长度: \(aiNumCtx)", value: $aiNumCtx, in: 512...32768, step: 512)
                .onChange(of: aiNumCtx) { _, newValue in
                    onSaveAIChatOptions(aiTemperature, aiTopP, newValue)
                }
        }
    }

    private var aiStatusText: String {
        switch aiStatus {
        case .ready:
            return L10n.settingsAIStatusReady
        case .notConfigured:
            return L10n.settingsAIStatusNotConfigured
        case .connecting:
            return L10n.settingsAIStatusConnecting
        case .error:
            return L10n.settingsAIStatusError
        }
    }

    private func statusColor(for status: AIEngineStatus) -> Color {
        switch status {
        case .ready:
            return .green
        case .connecting:
            return .orange
        case .notConfigured:
            return .red
        case .error:
            return .red
        }
    }
}
