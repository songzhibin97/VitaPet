import Localization
import SwiftUI

@MainActor
public struct ChatView: View {
    @Bindable var viewModel: ChatViewModel
    @AppStorage("chat.showThinking") private var showThinking: Bool = true

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
                .padding(.top, 12)
            }

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        if viewModel.messages.isEmpty {
                            emptyState
                                .frame(maxWidth: .infinity, minHeight: 260)
                        } else {
                            let lastId = viewModel.messages.last?.id
                            let streamingId = viewModel.isStreaming ? lastId : nil
                            ForEach(viewModel.messages) { message in
                                MessageBubble(
                                    message: message,
                                    isStreaming: streamingId == message.id && message.role == .assistant,
                                    showsThinking: showThinking
                                )
                                .equatable()
                                .id(message.id)
                            }
                            Color.clear.frame(height: 4).id(bottomAnchorId)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .contentMargins(.top, 12, for: .scrollContent)
                .contentMargins(.bottom, 8, for: .scrollContent)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: viewModel.messages.count) { _, _ in
                    scrollToBottom(proxy: proxy, animated: true)
                }
                .onChange(of: viewModel.messages.last?.content) { _, _ in
                    scrollToBottom(proxy: proxy, animated: false)
                }
                .onAppear {
                    scrollToBottom(proxy: proxy, animated: false)
                }
            }

            inputBar
        }
        .frame(minWidth: 420, minHeight: 520)
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .bottom, spacing: 10) {
                Button {
                    showThinking.toggle()
                } label: {
                    Image(systemName: showThinking ? "brain" : "brain.head.profile")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(showThinking ? Color.accentColor : Color.secondary)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .help(showThinking ? "隐藏思考过程" : "显示思考过程")

                TextField(inputPlaceholderText, text: $viewModel.inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1 ... 6)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                    }
                    .disabled(sendDisabled)

                Button {
                    viewModel.sendMessage()
                } label: {
                    Image(systemName: viewModel.isStreaming ? "ellipsis" : "arrow.up.circle.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(sendButtonEnabled ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!sendButtonEnabled)
                .help(L10n.chatSend + " (⌘⏎)")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var bottomAnchorId: String { "chat-bottom-anchor" }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        let target: AnyHashable = viewModel.messages.isEmpty
            ? AnyHashable(bottomAnchorId)
            : AnyHashable(viewModel.messages.last!.id)

        if animated {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(target, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }

    private var sendDisabled: Bool { viewModel.isStreaming }

    private var sendButtonEnabled: Bool {
        !sendDisabled && !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var inputPlaceholderText: String {
        viewModel.isStreaming ? L10n.chatStreamingPlaceholder : L10n.chatInputPlaceholder
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(emptyStateText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
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
