import Foundation
import Localization
import SwiftUI

@MainActor
public struct ChatView: View {
    @Bindable var viewModel: ChatViewModel
    @AppStorage("chat.showThinking") private var showThinking: Bool = true
    @State private var lastStreamingScrollAt: Date = .distantPast

    public init(viewModel: ChatViewModel = ChatViewModel()) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .underPageBackgroundColor).opacity(0.95)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 14) {
                headerCard

                if case .notConfigured = viewModel.aiStatus {
                    statusBanner(
                        text: L10n.chatStatusNotConfigured,
                        color: Color.orange.opacity(0.18),
                        borderColor: Color.orange.opacity(0.4)
                    )
                }

                messageSurface

                inputBar
            }
            .padding(16)
        }
        .frame(minWidth: 420, minHeight: 520)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Button {
                showThinking.toggle()
            } label: {
                Image(systemName: showThinking ? "brain" : "brain.head.profile")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(showThinking ? Color.accentColor : Color.secondary)
                    .frame(width: 38, height: 38)
                    .background(Color.black.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(showThinking ? "隐藏思考过程" : "显示思考过程")

            TextField(inputPlaceholderText, text: $viewModel.inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(1 ... 8)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                        .shadow(color: Color.black.opacity(0.03), radius: 3, x: 0, y: 1)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
                }
                .disabled(sendDisabled)

            Button {
                viewModel.sendMessage()
            } label: {
                Image(systemName: viewModel.isStreaming ? "ellipsis" : "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(sendButtonEnabled ? Color.white : Color.secondary)
                    .frame(width: 40, height: 40)
                    .background(
                        Circle()
                            .fill(
                                sendButtonEnabled
                                    ? AnyShapeStyle(
                                        LinearGradient(
                                            colors: [Color.accentColor, Color.accentColor.opacity(0.72)],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                                    : AnyShapeStyle(Color.black.opacity(0.06))
                            )
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!sendButtonEnabled)
            .help(L10n.chatSend + " (⌘⏎)")
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.24), lineWidth: 1)
        }
    }

    private var headerCard: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: currentConversationType == .group
                                ? [Color.orange.opacity(0.85), Color.red.opacity(0.7)]
                                : [Color.blue.opacity(0.85), Color.cyan.opacity(0.65)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: currentConversationType == .group ? Color.red.opacity(0.3) : Color.blue.opacity(0.3), radius: 6, x: 0, y: 3)

                Image(systemName: currentConversationType == .group ? "person.3.fill" : "pawprint.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 6) {
                Text(currentConversationTitle)
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                Text(currentConversationSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            aiStatusBadge
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 4)
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.35), lineWidth: 1)
        }
    }

    private var messageSurface: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if viewModel.messages.isEmpty {
                        emptyState
                            .frame(maxWidth: .infinity, minHeight: 320)
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
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            .contentMargins(.top, 12, for: .scrollContent)
            .contentMargins(.bottom, 8, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.88))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.black.opacity(0.05), lineWidth: 1)
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                scrollToBottom(proxy: proxy, animated: !viewModel.isStreaming)
            }
            .onChange(of: viewModel.messages.last?.content) { _, _ in
                scrollToBottomForStreamingIfNeeded(proxy: proxy)
            }
            .onChange(of: viewModel.isStreaming) { _, isStreaming in
                if isStreaming {
                    lastStreamingScrollAt = .distantPast
                } else {
                    scrollToBottom(proxy: proxy, animated: false)
                }
            }
            .onAppear {
                scrollToBottom(proxy: proxy, animated: false)
            }
        }
    }

    @ViewBuilder
    private var aiStatusBadge: some View {
        let config = aiStatusVisual
        HStack(spacing: 8) {
            Circle()
                .fill(config.tint)
                .frame(width: 8, height: 8)
            Text(config.title)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(config.tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(config.background, in: Capsule())
    }

    private var aiStatusVisual: (title: String, tint: Color, background: Color) {
        switch viewModel.aiStatus {
        case .ready:
            return ("已连接", .green, Color.green.opacity(0.12))
        case .connecting:
            return ("连接中", .orange, Color.orange.opacity(0.12))
        case .error:
            return ("错误", .red, Color.red.opacity(0.12))
        case .notConfigured:
            return ("未配置", .orange, Color.orange.opacity(0.12))
        }
    }

    private var currentThread: ConversationThread? {
        viewModel.conversations.first { $0.id == viewModel.selectedConversationId }
    }

    private var currentConversationType: ConversationType {
        currentThread?.type ?? .single
    }

    private var currentConversationTitle: String {
        guard let currentThread else {
            return "VitaPet"
        }
        if currentThread.title.isEmpty {
            return currentThread.type == .group ? L10n.chatGroupChat : L10n.chatSingleChat
        }
        return currentThread.title
    }

    private var currentConversationSubtitle: String {
        let messageCount = viewModel.messages.count
        let prefix = currentConversationType == .group ? "多宠会话" : "单宠会话"
        if viewModel.isStreaming {
            return "\(prefix) · 正在回复…"
        }
        return "\(prefix) · \(messageCount) 条消息"
    }

    private var bottomAnchorId: String { "chat-bottom-anchor" }
    private var minStreamingScrollInterval: TimeInterval { 0.08 }

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

    private func scrollToBottomForStreamingIfNeeded(proxy: ScrollViewProxy) {
        guard viewModel.isStreaming else {
            return
        }
        let now = Date()
        guard now.timeIntervalSince(lastStreamingScrollAt) >= minStreamingScrollInterval else {
            return
        }
        lastStreamingScrollAt = now
        scrollToBottom(proxy: proxy, animated: false)
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
        VStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.14, green: 0.16, blue: 0.21),
                            Color(red: 0.24, green: 0.27, blue: 0.34)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 82, height: 82)
                .overlay {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                }

            VStack(spacing: 6) {
                Text("开始一段对话")
                    .font(.title3.weight(.semibold))
                Text(emptyStateText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 10) {
                emptyStateChip(title: "总结日程", symbolName: "calendar")
                emptyStateChip(title: "写一句状态", symbolName: "sparkles")
                emptyStateChip(title: "陪宠物聊天", symbolName: "pawprint.fill")
            }
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

    private func emptyStateChip(title: String, symbolName: String) -> some View {
        Label(title, systemImage: symbolName)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.05), in: Capsule())
    }
}
