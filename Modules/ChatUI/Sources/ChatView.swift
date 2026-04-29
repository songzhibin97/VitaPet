import Localization
import SwiftUI

@MainActor
public struct ChatView: View {
    @Bindable var viewModel: ChatViewModel

    public init(viewModel: ChatViewModel = ChatViewModel()) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            if case .notConfigured = viewModel.aiStatus {
                statusBanner(
                    text: L10n.chatStatusNotConfigured,
                    color: Color.orange.opacity(0.18),
                    borderColor: Color.orange.opacity(0.4)
                )
                .padding(.horizontal, 16)
                .padding(.top, 16)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if viewModel.messages.isEmpty {
                            Text(emptyStateText)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 220, alignment: .center)
                        } else {
                            ForEach(viewModel.messages) { message in
                                MessageBubble(message: messageForDisplay(message))
                                    .id(message.id)
                            }
                        }
                    }
                    .padding(16)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: viewModel.messages.count) { _, _ in
                    guard let lastID = viewModel.messages.last?.id else {
                        return
                    }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }

            Divider()

            HStack(alignment: .bottom, spacing: 12) {
                TextField(inputPlaceholderText, text: $viewModel.inputText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1 ... 5)
                    .disabled(sendDisabled)

                if viewModel.isStreaming {
                    Button(L10n.chatStopGeneration) {
                        viewModel.stopGeneration()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button(L10n.chatSend) {
                        viewModel.sendMessage()
                    }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(16)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 420, minHeight: 520)
    }

    private var sendDisabled: Bool {
        viewModel.isStreaming
    }

    private var inputPlaceholderText: String {
        viewModel.isStreaming ? L10n.chatStreamingPlaceholder : L10n.chatInputPlaceholder
    }

    private func messageForDisplay(_ message: ChatMessage) -> ChatMessage {
        guard viewModel.isStreaming,
              message.id == viewModel.messages.last?.id,
              message.role == .assistant else {
            return message
        }

        return ChatMessage(
            id: message.id,
            role: message.role,
            content: message.content + "▌",
            timestamp: message.timestamp,
            petId: message.petId,
            petName: message.petName
        )
    }

    private var emptyStateText: String {
        if case .notConfigured = viewModel.aiStatus {
            return L10n.chatEmptyNotConfigured
        }
        return L10n.chatEmptyNewConversation
    }

    @ViewBuilder
    private func statusBanner(text: String, color: Color, borderColor: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        }
    }
}
