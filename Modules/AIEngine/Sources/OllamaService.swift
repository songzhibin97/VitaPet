import Foundation
import Localization

public actor OllamaService: AIEngineProtocol {
    private static let baseSystemPrompt = "你是主人桌面上的可爱宠物。回复要简短可爱（1-2句话）。称呼用户为主人。"
    private var customSystemPrompt = ""
    private var petProfile: String = ""
    private var availableActions: [String] = []
    private var memories: [String] = []
    private var currentSessionId: String = "default"
    private var sessionHistories: [String: [ChatMessage]] = [:]
    private var activeStreams: [UUID: Task<Void, Never>] = [:]

    private var activeHistory: [ChatMessage] {
        get { sessionHistories[currentSessionId] ?? [] }
        set { sessionHistories[currentSessionId] = newValue }
    }

    /// Build full system prompt dynamically from base + available actions + custom override
    private var effectiveSystemPrompt: String {
        var prompt = customSystemPrompt.isEmpty ? Self.baseSystemPrompt : customSystemPrompt
        if !petProfile.isEmpty {
            prompt = petProfile + "\n" + prompt
        }
        if !availableActions.isEmpty {
            let actionList = availableActions.joined(separator: "、")
            prompt += "\n你可以在回复中用 [ACTION:动作名] 标签来做动作。可用动作：\(actionList)。"
            prompt += "\n每次回复最多用一个动作标签。示例：好开心！[ACTION:celebrate]"
        }
        if !memories.isEmpty {
            let memoryList = memories.map { "- \($0)" }.joined(separator: "\n")
            prompt += "\n\n你记住了以下关于用户的信息：\n\(memoryList)"
        }
        return prompt
    }

    private var endpoint: URL
    private var model: String
    private var chatOptions: ChatOptions?
    private var onConversationUpdated: (@Sendable (String, String, String, String?, String?) async -> Void)?
    private var currentStatus: AIEngineStatus = .notConfigured
    private let urlSession: URLSession

    private static func makeDefaultSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }

    public init(endpoint: URL, model: String) {
        self.endpoint = endpoint
        self.model = model
        self.urlSession = Self.makeDefaultSession()
    }

    /// Designated initialiser for testing — allows injecting a custom URLSession (e.g. with a mock URLProtocol).
    init(endpoint: URL, model: String, urlSession: URLSession) {
        self.endpoint = endpoint
        self.model = model
        self.urlSession = urlSession
    }

    public var status: AIEngineStatus {
        get async {
            currentStatus
        }
    }

    public func checkConnection() async {
        currentStatus = .connecting

        do {
            let url = endpoint.appendingPathComponent("api").appendingPathComponent("tags")
            let request = URLRequest(url: url)

            let (_, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                currentStatus = .notConfigured
                return
            }

            currentStatus = .ready
        } catch {
            currentStatus = .notConfigured
        }
    }

    public func send(message: String) async throws -> (streamID: UUID, stream: AsyncThrowingStream<String, Error>) {
        if case .ready = currentStatus {
            // no-op
        } else {
            await checkConnection()
            guard case .ready = currentStatus else {
                throw OllamaServiceError.serviceUnavailable
            }
        }

        let request = try Self.buildChatRequest(
            endpoint: endpoint,
            model: model,
            history: activeHistory,
            systemPrompt: effectiveSystemPrompt,
            userMessage: message,
            options: chatOptions
        )
        let userMessage = ChatMessage(role: .user, content: message)
        let streamID = UUID()
        let session = urlSession

        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                defer { Task { await self.removeActiveStream(streamID) } }
                do {
                    let bytes = try await session.bytes(for: request)
                    let assistantMessage = try await self.consumeStream(
                        bytes: bytes.0,
                        response: bytes.1,
                        continuation: continuation,
                        onToolCall: nil
                    )
                    self.recordConversation(
                        userMessage: userMessage,
                        assistantMessage: assistantMessage
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Register the task so it can be cancelled externally.
            // We use a detached task to hop back to the actor without blocking the stream setup.
            Task { await self.registerActiveStream(streamID, task: task) }
        }

        return (streamID: streamID, stream: stream)
    }

    public func sendWithTools(
        message: String,
        tools: [OllamaTool],
        onToolCall: @escaping @Sendable (PetToolCall) async -> Void
    ) async throws -> (streamID: UUID, stream: AsyncThrowingStream<String, Error>) {
        if case .ready = currentStatus {
            // no-op
        } else {
            await checkConnection()
            guard case .ready = currentStatus else {
                throw OllamaServiceError.serviceUnavailable
            }
        }

        let request = try Self.buildChatRequest(
            endpoint: endpoint,
            model: model,
            history: activeHistory,
            systemPrompt: effectiveSystemPrompt,
            userMessage: message,
            tools: tools,
            options: chatOptions
        )
        let userMessage = ChatMessage(role: .user, content: message)
        let streamID = UUID()
        let session = urlSession

        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                defer { Task { await self.removeActiveStream(streamID) } }
                do {
                    let bytes = try await session.bytes(for: request)
                    let assistantMessage = try await self.consumeStream(
                        bytes: bytes.0,
                        response: bytes.1,
                        continuation: continuation,
                        onToolCall: onToolCall
                    )
                    self.recordConversation(
                        userMessage: userMessage,
                        assistantMessage: assistantMessage
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            Task { await self.registerActiveStream(streamID, task: task) }
        }

        return (streamID: streamID, stream: stream)
    }

    // MARK: - Stream cancellation

    /// Cancel a specific stream by its ID. The downstream `for try await` loop will receive `CancellationError`.
    public func cancel(streamID: UUID) {
        activeStreams[streamID]?.cancel()
        activeStreams[streamID] = nil
    }

    /// Cancel all active streams (e.g. on session switch or app quit).
    public func cancelAll() {
        for task in activeStreams.values {
            task.cancel()
        }
        activeStreams.removeAll()
    }

    // Internal helpers — called from inside Task closures that cannot directly mutate actor state.
    private func registerActiveStream(_ id: UUID, task: Task<Void, Never>) {
        activeStreams[id] = task
    }

    private func removeActiveStream(_ id: UUID) {
        activeStreams[id] = nil
    }

    // MARK: - History

    public func clearHistory() {
        sessionHistories[currentSessionId]?.removeAll()
    }

    public func setOnConversationUpdated(_ handler: @escaping @Sendable (String, String, String, String?, String?) async -> Void) {
        onConversationUpdated = handler
    }

    public func switchSession(_ sessionId: String) {
        currentSessionId = sessionId
    }

    public func buildGroupChatProfile(pets: [PetProfileInfo]) -> String {
        var prompt = L10n.chatGroupChatPrompt + "\n\n"
        prompt += L10n.chatGroupChatPetsHeader + "\n"

        for pet in pets {
            var description = "- \(pet.name)"
            var details: [String] = []
            if pet.gender != "neutral" {
                details.append(localizedGender(for: pet.gender))
            }
            if !pet.age.isEmpty {
                details.append(pet.age)
            }
            if !pet.personality.isEmpty {
                details.append(pet.personality)
            }
            if !pet.hobbies.isEmpty {
                details.append(localizedHobbiesPrefix + pet.hobbies)
            }
            if !details.isEmpty {
                description += "（\(details.joined(separator: "，"))）"
            }
            prompt += description + "\n"
        }

        prompt += "\n"
        if let first = pets.first, let second = pets.dropFirst().first {
            prompt += buildLocalizedGroupChatExample(firstPetName: first.name, secondPetName: second.name)
        } else {
            prompt += L10n.chatGroupChatExample
        }

        return prompt
    }

    public func loadHistory(turns: [(role: String, content: String)], sessionId: String = "default") {
        let messages = turns.map {
            ChatMessage(
                role: ChatMessage.Role(rawValue: $0.role) ?? .user,
                content: $0.content
            )
        }
        sessionHistories[sessionId] = messages
        currentSessionId = sessionId
    }

    public func updateConfig(endpoint: URL, model: String) {
        self.endpoint = endpoint
        self.model = model
        currentStatus = .notConfigured
    }

    public func setChatOptions(temperature: Double, topP: Double, numCtx: Int) {
        chatOptions = ChatOptions(temperature: temperature, topP: topP, numCtx: numCtx)
    }

    public func updateSystemPrompt(_ prompt: String) {
        customSystemPrompt = prompt
    }

    public func updatePetProfile(_ profile: String) {
        petProfile = profile
    }

    public func updateAvailableActions(_ actions: [String]) {
        availableActions = actions
    }

    public func updateMemories(_ newMemories: [String]) {
        memories = newMemories
    }

    public func generateProactive(context: String) async throws -> String {
        guard case .ready = currentStatus else {
            throw OllamaServiceError.serviceUnavailable
        }

        let systemPrompt = effectiveSystemPrompt + "\n你现在要主动和主人说话。根据当前情境说一句话。"
        let request = try Self.buildChatRequest(
            endpoint: endpoint,
            model: model,
            history: [],
            systemPrompt: systemPrompt,
            userMessage: context,
            stream: false
        )

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw OllamaServiceError.invalidResponse
        }

        guard let parsed = try? JSONDecoder().decode(NonStreamResponse.self, from: data),
              let content = parsed.message?.content else {
            throw OllamaServiceError.invalidResponse
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func extractMemories(from recentMessages: [(role: String, content: String)]) async throws -> [String] {
        let extractionPrompt = """
        从以下对话中提取用户的关键信息（偏好、习惯、事实、名字等），每条信息用一个简短的中文句子。
        只返回 JSON 数组格式，例如：["用户喜欢猫", "用户是程序员"]
        如果没有新信息，返回空数组 []
        """

        let conversationText = recentMessages
            .map { "\($0.role): \($0.content)" }
            .joined(separator: "\n")
        let request = try Self.buildChatRequest(
            endpoint: endpoint,
            model: model,
            history: [],
            systemPrompt: extractionPrompt,
            userMessage: conversationText,
            stream: false
        )

        let (responseData, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            return []
        }

        let parsed = try? JSONDecoder().decode(NonStreamResponse.self, from: responseData)
        guard let content = parsed?.message?.content else {
            return []
        }

        return Self.parseMemoryArray(from: content)
    }

    internal static func buildChatRequest(
        endpoint: URL,
        model: String,
        history: [ChatMessage],
        systemPrompt: String,
        userMessage: String,
        tools: [OllamaTool]? = nil,
        stream: Bool = true,
        options: ChatOptions? = nil
    ) throws -> URLRequest {
        let payload = ChatPayload(
            model: model,
            messages: buildRequestMessages(
                history: history,
                userMessage: userMessage,
                systemPrompt: systemPrompt
            ),
            stream: stream,
            tools: tools,
            options: options
        )

        var request = URLRequest(url: endpoint.appendingPathComponent("api").appendingPathComponent("chat"))
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    internal static func parseChatResponse(_ line: String) throws -> ParsedChunk {
        let data = Data(line.utf8)
        let decoder = JSONDecoder()
        let response = try decoder.decode(ResponseLine.self, from: data)
        return ParsedChunk(
            content: response.message?.content ?? "",
            done: response.done
            ,
            toolCalls: response.message?.tool_calls?.compactMap { toolCall in
                guard let arguments = toolCall.function.arguments else {
                    return nil
                }
                return PetToolCall(
                    functionName: toolCall.function.name,
                    arguments: arguments
                )
            } ?? []
        )
    }

    internal func conversationHistorySnapshot() -> [ChatMessage] {
        activeHistory
    }

    internal func setConversationHistoryForTesting(_ messages: [ChatMessage]) {
        sessionHistories[currentSessionId] = messages
    }

    internal func configSnapshot() -> (endpoint: URL, model: String) {
        (endpoint, model)
    }

    internal func forceReadyStatusForTesting() {
        currentStatus = .ready
    }

    internal func isStreamRegistered(_ id: UUID) -> Bool {
        activeStreams[id] != nil
    }

    private func consumeStream(
        bytes: URLSession.AsyncBytes,
        response: URLResponse,
        continuation: AsyncThrowingStream<String, Error>.Continuation,
        onToolCall: (@Sendable (PetToolCall) async -> Void)?
    ) async throws -> String {
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            if let httpResponse = response as? HTTPURLResponse {
                throw OllamaServiceError.httpStatus(httpResponse.statusCode)
            }
            throw OllamaServiceError.invalidResponse
        }

        var assistantContent = ""
        var finished = false

        for try await line in bytes.lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLine.isEmpty {
                continue
            }

            let chunk = try Self.parseChatResponse(trimmedLine)
            if let onToolCall {
                for call in chunk.toolCalls {
                    await onToolCall(call)
                }
            }
            if let content = chunk.content, !content.isEmpty {
                assistantContent += content
                continuation.yield(content)
            }

            if chunk.done {
                finished = true
                break
            }
        }

        guard finished else {
            throw OllamaServiceError.incompleteStream
        }

        return assistantContent
    }

    private func recordConversation(userMessage: ChatMessage, assistantMessage: String) {
        var history = activeHistory
        history.append(userMessage)
        history.append(ChatMessage(role: .assistant, content: assistantMessage))

        if history.count > 100 {
            history = Array(history.suffix(50))
        }
        activeHistory = history

        if let onConversationUpdated {
            Task {
                await onConversationUpdated(userMessage.role.rawValue, userMessage.content, currentSessionId, nil, nil)
                await onConversationUpdated("assistant", assistantMessage, currentSessionId, nil, nil)
            }
        }
    }

    private var localizedHobbiesPrefix: String {
        if L10n.locale.hasPrefix("en") {
            return "hobbies: "
        }
        return "爱好"
    }

    private func localizedGender(for gender: String) -> String {
        switch gender {
        case "male":
            return L10n.locale.hasPrefix("en") ? "male" : "男"
        case "female":
            return L10n.locale.hasPrefix("en") ? "female" : "女"
        default:
            return gender
        }
    }

    private func buildLocalizedGroupChatExample(firstPetName: String, secondPetName: String) -> String {
        var example = L10n.chatGroupChatExample
        example = example.replacingOccurrences(of: "[PET:小花]", with: "[PET:\(firstPetName)]")
        example = example.replacingOccurrences(of: "[PET:小黑]", with: "[PET:\(secondPetName)]")
        example = example.replacingOccurrences(of: "[PET:Kitty]", with: "[PET:\(firstPetName)]")
        example = example.replacingOccurrences(of: "[PET:Shadow]", with: "[PET:\(secondPetName)]")
        return example
    }

    private static func buildRequestMessages(
        history: [ChatMessage],
        userMessage: String,
        systemPrompt: String
    ) -> [PayloadMessage] {
        var messages: [PayloadMessage] = []
        messages.append(PayloadMessage(role: ChatMessage.Role.system.rawValue, content: systemPrompt))

        let mappedHistory = history.map { message in
            PayloadMessage(role: message.role.rawValue, content: message.content)
        }
        messages.append(contentsOf: mappedHistory)
        messages.append(PayloadMessage(role: ChatMessage.Role.user.rawValue, content: userMessage))
        return messages
    }

    private static func parseMemoryArray(from text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            if let start = trimmed.firstIndex(of: "["),
               let end = trimmed.lastIndex(of: "]") {
                let jsonSubstring = String(trimmed[start...end])
                guard let subData = jsonSubstring.data(using: .utf8),
                      let subArray = try? JSONSerialization.jsonObject(with: subData) as? [String] else {
                    return []
                }
                return subArray
            }
            return []
        }
        return array
    }

    struct ChatOptions: Codable {
        let temperature: Double
        let topP: Double
        let numCtx: Int

        enum CodingKeys: String, CodingKey {
            case temperature
            case topP = "top_p"
            case numCtx = "num_ctx"
        }
    }

    private struct ChatPayload: Codable {
        let model: String
        let messages: [PayloadMessage]
        let stream: Bool
        let tools: [OllamaTool]?
        let options: ChatOptions?
    }

    internal struct PayloadMessage: Codable {
        let role: String
        let content: String
    }

    private struct NonStreamResponse: Decodable {
        let message: MessageContent?

        struct MessageContent: Decodable {
            let content: String?
        }
    }

    private struct ResponseLine: Decodable {
        let message: ResponseMessage?
        let done: Bool

        struct ResponseMessage: Decodable {
            let role: String
            let content: String?
            let tool_calls: [ToolCall]?

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                role = try container.decode(String.self, forKey: .role)
                content = try container.decodeIfPresent(String.self, forKey: .content)
                do {
                    tool_calls = try container.decodeIfPresent([ToolCall].self, forKey: .toolCalls)
                } catch {
                    tool_calls = nil
                }
            }

            enum CodingKeys: String, CodingKey {
                case role
                case content
                case toolCalls = "tool_calls"
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            message = try container.decodeIfPresent(ResponseMessage.self, forKey: .message)
            done = try container.decodeIfPresent(Bool.self, forKey: .done) ?? false
        }

        private enum CodingKeys: String, CodingKey {
            case message
            case done
        }

        struct ToolCall: Decodable {
            let function: ToolCallFunction
        }

        struct ToolCallFunction: Decodable {
            let name: String
            let arguments: [String: String]?

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                name = try container.decode(String.self, forKey: .name)
                if let dictionary = try? container.decode([String: String].self, forKey: .arguments) {
                    arguments = dictionary
                } else if let argumentsString = try? container.decode(String.self, forKey: .arguments) {
                    arguments = Self.decodeArguments(from: argumentsString)
                } else {
                    arguments = nil
                }
            }

            private enum CodingKeys: String, CodingKey {
                case name
                case arguments
            }

            private static func decodeArguments(from raw: String) -> [String: String]? {
                guard let data = raw.data(using: .utf8),
                      let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return nil
                }
                var output: [String: String] = [:]
                for (key, value) in decoded {
                    output[key] = String(describing: value)
                }
                return output
            }
        }
    }

    internal struct ParsedChunk {
        let content: String?
        let done: Bool
        let toolCalls: [PetToolCall]
    }
}

public enum OllamaServiceError: LocalizedError {
    case serviceUnavailable
    case httpStatus(Int)
    case invalidResponse
    case incompleteStream

    public var errorDescription: String? {
        switch self {
        case .serviceUnavailable:
            "Ollama service is not configured or unavailable"
        case .httpStatus(let status):
            "Ollama API returned HTTP status: \(status)"
        case .invalidResponse:
            "Ollama API returned invalid response"
        case .incompleteStream:
            "Ollama streaming response did not contain completion marker"
        }
    }
}
