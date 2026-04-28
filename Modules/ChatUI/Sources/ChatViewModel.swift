import Foundation
import Localization
import Observation

@MainActor
@Observable
public final class ChatViewModel {
    private let defaultConversationId = "default_conversation"

    public private(set) var conversations: [ConversationThread] = []
    public var selectedConversationId: String? {
        didSet {
            if let id = selectedConversationId {
                currentMessages = messagesByConversation[id] ?? []
                onConversationChanged?(id)
            } else {
                currentMessages = []
            }
        }
    }
    public private(set) var currentMessages: [ChatMessage] = []
    public var messages: [ChatMessage] { currentMessages }
    public var inputText: String = ""
    public private(set) var aiStatus: AIEngineStatus = .notConfigured
    public private(set) var isStreaming = false
    private var messagesByConversation: [String: [ChatMessage]] = [:]
    // Per-message capture of the "show thinking" toggle at the moment the
    // message first lands in the view model. The toggle in ChatView only
    // affects messages appended *after* it changes — historical messages keep
    // whatever value was current when they were captured.
    @ObservationIgnored private var capturedShowThinking: [UUID: Bool] = [:]

    private let sendToAI: @Sendable (String, [ChatMessage]) async throws -> AsyncThrowingStream<String, Error>
    private let getAIStatus: @Sendable () async -> AIEngineStatus

    public var onUserSent: (@MainActor () -> Void)?
    public var onAssistantReplied: (@MainActor () -> Void)?
    public var onConversationChanged: ((String) -> Void)?
    public var onCreateGroup: ((String, [UUID]) -> Void)?
    public var onDeleteConversation: (@MainActor (String) -> Void)?
    /// Called when the user enters a `/command arguments` style message in the chat input.
    /// Return true to consume the message (it won't be forwarded to the AI).
    public var onSlashCommand: (@MainActor (_ name: String, _ arguments: String) async -> Bool)?

    public init(
        sendToAI: @escaping @Sendable (String, [ChatMessage]) async throws -> AsyncThrowingStream<String, Error> = { _, _ in
            AsyncThrowingStream { continuation in
                continuation.finish()
            }
        },
        getAIStatus: @escaping @Sendable () async -> AIEngineStatus = { .notConfigured }
    ) {
        self.sendToAI = sendToAI
        self.getAIStatus = getAIStatus
        // Check AI status immediately on creation
        Task { @MainActor in
            self.aiStatus = await getAIStatus()
        }
    }

    public func sendMessage() {
        let trimmedInput = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty, !isStreaming else {
            return
        }
        ensureSelectedConversation()
        inputText = ""

        if let command = Self.parseSlashCommand(from: trimmedInput), let handler = onSlashCommand {
            appendToCurrentConversation(ChatMessage(role: .user, content: trimmedInput))
            Task { @MainActor in
                _ = await handler(command.name, command.arguments)
            }
            return
        }

        let userMessage = ChatMessage(role: .user, content: trimmedInput)
        appendToCurrentConversation(userMessage)
        onUserSent?()

        Task { @MainActor in
            let aiHistory = currentMessages
            aiStatus = await getAIStatus()

            guard aiStatus == .ready else {
                appendToCurrentConversation(ChatMessage(role: .assistant, content: L10n.chatAssistantNotConfigured))
                return
            }

            isStreaming = true
            defer {
                isStreaming = false
            }

            var assistantMessage = ChatMessage(role: .assistant, content: "")
            appendToCurrentConversation(assistantMessage)

            do {
                let stream = try await sendToAI(trimmedInput, aiHistory)
                let clock = ContinuousClock()
                let streamingFlushInterval: Duration = .milliseconds(40)
                var bufferedReply = ""
                var pendingChunk = ""
                var lastFlush = clock.now

                func assistantMessageWithContent(_ content: String) -> ChatMessage {
                    ChatMessage(
                        id: assistantMessage.id,
                        role: .assistant,
                        content: content,
                        timestamp: assistantMessage.timestamp,
                        petId: assistantMessage.petId,
                        petName: assistantMessage.petName
                    )
                }

                for try await chunk in stream {
                    guard let currentAssistantMessage = currentMessages.last else {
                        break
                    }
                    assistantMessage = currentAssistantMessage
                    pendingChunk += chunk
                    let now = clock.now
                    if now - lastFlush >= streamingFlushInterval {
                        bufferedReply += pendingChunk
                        pendingChunk.removeAll(keepingCapacity: true)
                        lastFlush = now

                        replaceLastMessageInCurrentConversation(
                            with: assistantMessageWithContent(bufferedReply),
                            updatesPreview: false
                        )
                    }
                }

                if !pendingChunk.isEmpty {
                    bufferedReply += pendingChunk
                    pendingChunk.removeAll(keepingCapacity: true)
                    replaceLastMessageInCurrentConversation(
                        with: assistantMessageWithContent(bufferedReply),
                        updatesPreview: false
                    )
                }
                if let currentAssistantMessage = currentMessages.last {
                    assistantMessage = currentAssistantMessage
                    replaceLastMessageInCurrentConversation(
                        with: assistantMessageWithContent(bufferedReply),
                        updatesPreview: true
                    )
                }

                onAssistantReplied?()
            } catch {
                replaceLastMessageInCurrentConversation(with: ChatMessage(
                    id: assistantMessage.id,
                    role: .assistant,
                    content: "Error: \(error.localizedDescription)",
                    timestamp: assistantMessage.timestamp,
                    petId: assistantMessage.petId,
                    petName: assistantMessage.petName
                ))
            }
        }
    }

    public func addExternalMessage(_ content: String) {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else {
            return
        }

        ensureSelectedConversation()
        appendToCurrentConversation(ChatMessage(role: .user, content: trimmedContent))
    }

    public func addAssistantMessage(
        _ content: String,
        petId: UUID? = nil,
        petName: String? = nil,
        displayThinking: Bool = true
    ) {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else {
            return
        }

        ensureSelectedConversation()
        let message = ChatMessage(role: .assistant, content: trimmedContent, petId: petId, petName: petName)
        if !displayThinking {
            capturedShowThinking[message.id] = false
        }
        appendToCurrentConversation(message)
    }

    public func loadConversations(_ threads: [ConversationThread]) {
        conversations = threads
        for thread in threads where messagesByConversation[thread.id] == nil {
            messagesByConversation[thread.id] = []
        }
        if selectedConversationId == nil, let first = threads.first {
            selectedConversationId = first.id
        } else if let selectedConversationId, !threads.contains(where: { $0.id == selectedConversationId }) {
            self.selectedConversationId = threads.first?.id
        }
    }

    public func loadMessages(for conversationId: String, messages: [ChatMessage]) {
        for message in messages {
            captureShowThinkingIfNeeded(for: message.id)
        }
        messagesByConversation[conversationId] = messages
        if conversationId == selectedConversationId {
            currentMessages = messages
        }
    }

    public func selectConversation(_ id: String) {
        ensureConversationExists(id)
        selectedConversationId = id
    }

    @discardableResult
    public func createGroupChat(title: String, participantIds: [UUID]) -> ConversationThread {
        let thread = ConversationThread(
            id: "group_\(UUID().uuidString)",
            type: .group,
            participantIds: participantIds,
            title: title
        )
        conversations.append(thread)
        messagesByConversation[thread.id] = []
        selectedConversationId = thread.id
        onCreateGroup?(title, participantIds)
        return thread
    }

    public func deleteConversation(_ id: String) {
        conversations.removeAll { $0.id == id }
        messagesByConversation[id] = nil
        onDeleteConversation?(id)

        if selectedConversationId == id {
            selectedConversationId = conversations.first?.id
        } else if let selectedConversationId,
                  !conversations.contains(where: { $0.id == selectedConversationId }) {
            self.selectedConversationId = conversations.first?.id
        }
    }

    public func addConversation(_ thread: ConversationThread) {
        if !conversations.contains(where: { $0.id == thread.id }) {
            conversations.append(thread)
        }
        if messagesByConversation[thread.id] == nil {
            messagesByConversation[thread.id] = []
        }
    }

    public func updateConversationTitle(_ id: String, title: String) {
        if let index = conversations.firstIndex(where: { $0.id == id }) {
            var updated = conversations[index]
            updated = ConversationThread(
                id: updated.id,
                type: updated.type,
                participantIds: updated.participantIds,
                title: title,
                lastMessage: updated.lastMessage,
                lastTimestamp: updated.lastTimestamp,
                unreadCount: updated.unreadCount
            )
            conversations[index] = updated
        }
    }

    public func updateConversation(_ thread: ConversationThread) {
        if let index = conversations.firstIndex(where: { $0.id == thread.id }) {
            conversations[index] = thread
        } else {
            conversations.append(thread)
        }
        if messagesByConversation[thread.id] == nil {
            messagesByConversation[thread.id] = []
        }
        if selectedConversationId == thread.id {
            currentMessages = messagesByConversation[thread.id] ?? []
        }
    }

    public var currentParticipantIds: [UUID] {
        conversations.first(where: { $0.id == selectedConversationId })?.participantIds ?? []
    }

    public var currentConversationType: ConversationType? {
        conversations.first(where: { $0.id == selectedConversationId })?.type
    }

    public func refreshStatus() {
        Task { @MainActor in
            aiStatus = await getAIStatus()
        }
    }

    private func appendToCurrentConversation(_ message: ChatMessage) {
        guard let id = selectedConversationId else {
            return
        }
        captureShowThinkingIfNeeded(for: message.id)
        // Single write to currentMessages (the @Observable source of truth);
        // sync the dict afterward without triggering another view-tree update.
        currentMessages.append(message)
        messagesByConversation[id] = currentMessages
        updateConversationPreview(for: id, using: message)
    }

    /// Returns the captured "show thinking" value for a given message. Falls
    /// back to the current global toggle if a capture is missing (which only
    /// happens for messages that pre-date this mechanism).
    public func showsThinking(for messageId: UUID) -> Bool {
        if let captured = capturedShowThinking[messageId] {
            return captured
        }
        return currentGlobalShowThinking()
    }

    private func captureShowThinkingIfNeeded(for messageId: UUID) {
        guard capturedShowThinking[messageId] == nil else { return }
        capturedShowThinking[messageId] = currentGlobalShowThinking()
    }

    private func currentGlobalShowThinking() -> Bool {
        // Mirror @AppStorage("chat.showThinking") default = true
        UserDefaults.standard.object(forKey: "chat.showThinking") as? Bool ?? true
    }

    private func replaceLastMessageInCurrentConversation(with message: ChatMessage, updatesPreview: Bool = true) {
        guard let id = selectedConversationId,
              !currentMessages.isEmpty else {
            return
        }
        let lastIndex = currentMessages.count - 1
        if currentMessages[lastIndex] == message {
            if updatesPreview {
                updateConversationPreview(for: id, using: message)
            }
            return
        }
        currentMessages[lastIndex] = message
        messagesByConversation[id] = currentMessages
        if updatesPreview {
            updateConversationPreview(for: id, using: message)
        }
    }

    private func updateConversationPreview(for conversationId: String, using message: ChatMessage) {
        // Skip the empty placeholder assistant bubble — otherwise every send
        // wipes the visible last-message preview in the sidebar and forces
        // ConversationListView (and the parent split view) to re-render twice
        // for nothing.
        guard !message.content.isEmpty,
              let index = conversations.firstIndex(where: { $0.id == conversationId }) else {
            return
        }
        let newPreview = String(message.content.prefix(50))
        // Avoid spurious @Observable notifications when nothing actually changed.
        if conversations[index].lastMessage == newPreview,
           conversations[index].lastTimestamp == message.timestamp {
            return
        }
        conversations[index].lastMessage = newPreview
        conversations[index].lastTimestamp = message.timestamp
    }

    private func ensureSelectedConversation() {
        if let selectedConversationId {
            ensureConversationExists(selectedConversationId)
            return
        }
        if let firstConversationId = conversations.first?.id {
            selectedConversationId = firstConversationId
            return
        }

        let thread = ConversationThread(
            id: defaultConversationId,
            type: .single,
            participantIds: [],
            title: ""
        )
        conversations.append(thread)
        messagesByConversation[thread.id] = []
        selectedConversationId = thread.id
    }

    private func ensureConversationExists(_ id: String) {
        if !conversations.contains(where: { $0.id == id }) {
            conversations.append(
                ConversationThread(
                    id: id,
                    type: .single,
                    participantIds: [],
                    title: ""
                )
            )
        }
        if messagesByConversation[id] == nil {
            messagesByConversation[id] = []
        }
    }

    struct SlashCommand {
        let name: String
        let arguments: String
    }

    static func parseSlashCommand(from text: String) -> SlashCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }

        let body = String(trimmed.dropFirst())
        guard !body.isEmpty else { return nil }

        if let spaceIndex = body.firstIndex(where: { $0.isWhitespace }) {
            let name = String(body[..<spaceIndex])
            let arguments = String(body[body.index(after: spaceIndex)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return SlashCommand(name: name, arguments: arguments)
        }

        return SlashCommand(name: body, arguments: "")
    }
}
