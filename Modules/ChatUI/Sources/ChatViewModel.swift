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

    private let sendToAI: @Sendable (String, [ChatMessage]) async throws -> AsyncThrowingStream<String, Error>
    private let getAIStatus: @Sendable () async -> AIEngineStatus

    public var onUserSent: (@MainActor () -> Void)?
    public var onAssistantReplied: (@MainActor () -> Void)?
    public var onConversationChanged: ((String) -> Void)?
    public var onCreateGroup: ((String, [UUID]) -> Void)?
    public var onDeleteConversation: (@MainActor (String) -> Void)?

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

                for try await chunk in stream {
                    guard let currentAssistantMessage = currentMessages.last else {
                        break
                    }
                    assistantMessage = currentAssistantMessage
                    replaceLastMessageInCurrentConversation(with: ChatMessage(
                        id: assistantMessage.id,
                        role: .assistant,
                        content: assistantMessage.content + chunk,
                        timestamp: assistantMessage.timestamp,
                        petId: assistantMessage.petId,
                        petName: assistantMessage.petName
                    ))
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

    public func addAssistantMessage(_ content: String, petId: UUID? = nil, petName: String? = nil) {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else {
            return
        }

        ensureSelectedConversation()
        appendToCurrentConversation(ChatMessage(role: .assistant, content: trimmedContent, petId: petId, petName: petName))
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
        messagesByConversation[id, default: []].append(message)
        currentMessages = messagesByConversation[id] ?? []
        updateConversationPreview(for: id, using: message)
    }

    private func replaceLastMessageInCurrentConversation(with message: ChatMessage) {
        guard let id = selectedConversationId else {
            return
        }
        guard var messages = messagesByConversation[id], !messages.isEmpty else {
            return
        }
        messages[messages.count - 1] = message
        messagesByConversation[id] = messages
        currentMessages = messages
        updateConversationPreview(for: id, using: message)
    }

    private func updateConversationPreview(for conversationId: String, using message: ChatMessage) {
        if let index = conversations.firstIndex(where: { $0.id == conversationId }) {
            conversations[index].lastMessage = String(message.content.prefix(50))
            conversations[index].lastTimestamp = message.timestamp
        }
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
}
