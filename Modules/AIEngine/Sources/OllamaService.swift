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
    private var backend: AIBackend
    private var model: String
    private var onConversationUpdated: (@Sendable (String, String, String, String?, String?) async -> Void)?
    private var currentStatus: AIEngineStatus = .notConfigured

    public init(endpoint: URL, model: String, backend: AIBackend = .ollama) {
        self.endpoint = endpoint
        self.model = model
        self.backend = backend
    }

    public var status: AIEngineStatus {
        get async {
            currentStatus
        }
    }

    public func checkConnection() async {
        currentStatus = .connecting

        switch backend {
        case .ollama:
            await checkOllamaConnection()
        case .openAICompatible:
            await checkOpenAICompatibleConnection()
        }
    }

    private func checkOllamaConnection() async {
        do {
            let url = Self.resolveOllamaTagsURL(from: endpoint)
            var request = URLRequest(url: url)
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                currentStatus = .error("HTTP \(statusCode)")
                return
            }

            currentStatus = .ready
        } catch {
            currentStatus = .error(error.localizedDescription)
        }
    }

    private func checkOpenAICompatibleConnection() async {
        do {
            var request = URLRequest(url: Self.resolveOpenAIModelsURL(from: endpoint))
            request.timeoutInterval = 8
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw OllamaServiceError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
            }

            currentStatus = .ready
            return
        } catch {
            do {
                var request = try Self.buildOpenAICompatibleChatRequest(
                    endpoint: endpoint,
                    model: resolvedModelName(),
                    history: [],
                    systemPrompt: "You are a connection health check. Reply with ok.",
                    userMessage: "ping",
                    stream: false,
                    maxTokens: 1
                )
                request.timeoutInterval = 120

                let (_, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                    currentStatus = .error("HTTP \(statusCode)")
                    return
                }

                currentStatus = .ready
            } catch {
                currentStatus = .error(error.localizedDescription)
            }
        }
    }

    public func send(message: String) async throws -> AsyncThrowingStream<String, Error> {
        if case .ready = currentStatus {
            // no-op
        } else {
            await checkConnection()
            guard case .ready = currentStatus else {
                throw OllamaServiceError.serviceUnavailable
            }
        }

        let userMessage = ChatMessage(role: .user, content: message)

        switch backend {
        case .ollama:
            let request = try Self.buildChatRequest(
                endpoint: endpoint,
                model: model,
                history: activeHistory,
                systemPrompt: effectiveSystemPrompt,
                userMessage: message
            )

            return AsyncThrowingStream<String, Error> { continuation in
                Task {
                    do {
                        let stream = try await URLSession.shared.bytes(for: request)
                        let assistantMessage = try await self.consumeStream(
                            bytes: stream.0,
                            response: stream.1,
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
            }
        case .openAICompatible:
            let request = try Self.buildOpenAICompatibleChatRequest(
                endpoint: endpoint,
                model: resolvedModelName(),
                history: activeHistory,
                systemPrompt: effectiveSystemPrompt,
                userMessage: message,
                stream: false
            )

            return AsyncThrowingStream<String, Error> { continuation in
                Task {
                    do {
                        let (data, response) = try await URLSession.shared.data(for: request)
                        let assistantMessage = try await self.consumeOpenAIResponse(
                            data: data,
                            response: response,
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
            }
        }
    }

    public func sendWithTools(
        message: String,
        tools: [OllamaTool],
        onToolCall: @escaping @Sendable (PetToolCall) async -> Void
    ) async throws -> AsyncThrowingStream<String, Error> {
        if case .ready = currentStatus {
            // no-op
        } else {
            await checkConnection()
            guard case .ready = currentStatus else {
                throw OllamaServiceError.serviceUnavailable
            }
        }

        let userMessage = ChatMessage(role: .user, content: message)

        switch backend {
        case .ollama:
            let request = try Self.buildChatRequest(
                endpoint: endpoint,
                model: model,
                history: activeHistory,
                systemPrompt: effectiveSystemPrompt,
                userMessage: message,
                tools: tools
            )

            return AsyncThrowingStream<String, Error> { continuation in
                Task {
                    do {
                        let stream = try await URLSession.shared.bytes(for: request)
                        let assistantMessage = try await self.consumeStream(
                            bytes: stream.0,
                            response: stream.1,
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
            }
        case .openAICompatible:
            let request = try Self.buildOpenAICompatibleChatRequest(
                endpoint: endpoint,
                model: resolvedModelName(),
                history: activeHistory,
                systemPrompt: effectiveSystemPrompt,
                userMessage: message,
                tools: tools,
                stream: false
            )

            return AsyncThrowingStream<String, Error> { continuation in
                Task {
                    do {
                        let (data, response) = try await URLSession.shared.data(for: request)
                        let assistantMessage = try await self.consumeOpenAIResponse(
                            data: data,
                            response: response,
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
            }
        }
    }

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

    public func updateConfig(endpoint: URL, model: String, backend: AIBackend) {
        self.endpoint = endpoint
        self.model = model
        self.backend = backend
        currentStatus = .notConfigured
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

        switch backend {
        case .ollama:
            let request = try Self.buildChatRequest(
                endpoint: endpoint,
                model: model,
                history: [],
                systemPrompt: systemPrompt,
                userMessage: context,
                stream: false
            )

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw OllamaServiceError.invalidResponse
            }

            guard let parsed = try? JSONDecoder().decode(NonStreamResponse.self, from: data),
                  let content = parsed.message?.content else {
                throw OllamaServiceError.invalidResponse
            }

            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        case .openAICompatible:
            let request = try Self.buildOpenAICompatibleChatRequest(
                endpoint: endpoint,
                model: resolvedModelName(),
                history: [],
                systemPrompt: systemPrompt,
                userMessage: context,
                stream: false
            )

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw OllamaServiceError.invalidResponse
            }

            let chunk = try Self.parseOpenAIChatResponse(data)
            guard let content = chunk.content else {
                throw OllamaServiceError.invalidResponse
            }

            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
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
        switch backend {
        case .ollama:
            let request = try Self.buildChatRequest(
                endpoint: endpoint,
                model: model,
                history: [],
                systemPrompt: extractionPrompt,
                userMessage: conversationText,
                stream: false
            )

            let (responseData, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return []
            }

            let parsed = try? JSONDecoder().decode(NonStreamResponse.self, from: responseData)
            guard let content = parsed?.message?.content else {
                return []
            }

            return Self.parseMemoryArray(from: content)
        case .openAICompatible:
            let request = try Self.buildOpenAICompatibleChatRequest(
                endpoint: endpoint,
                model: resolvedModelName(),
                history: [],
                systemPrompt: extractionPrompt,
                userMessage: conversationText,
                stream: false
            )

            let (responseData, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return []
            }

            let parsed = try? Self.parseOpenAIChatResponse(responseData)
            guard let content = parsed?.content else {
                return []
            }

            return Self.parseMemoryArray(from: content)
        }
    }

    internal static func buildChatRequest(
        endpoint: URL,
        model: String,
        history: [ChatMessage],
        systemPrompt: String,
        userMessage: String,
        tools: [OllamaTool]? = nil,
        stream: Bool = true
    ) throws -> URLRequest {
        let payload = ChatPayload(
            model: model,
            messages: buildRequestMessages(
                history: history,
                userMessage: userMessage,
                systemPrompt: systemPrompt
            ),
            stream: stream,
            tools: tools
        )

        var request = URLRequest(url: resolveOllamaChatURL(from: endpoint))
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }

    internal static func buildOpenAICompatibleChatRequest(
        endpoint: URL,
        model: String,
        history: [ChatMessage],
        systemPrompt: String,
        userMessage: String,
        tools: [OllamaTool]? = nil,
        stream: Bool = false,
        maxTokens: Int? = nil
    ) throws -> URLRequest {
        let payload = OpenAIChatPayload(
            model: model,
            messages: buildRequestMessages(
                history: history,
                userMessage: userMessage,
                systemPrompt: systemPrompt
            ),
            stream: stream,
            tools: tools,
            maxTokens: maxTokens
        )

        var request = URLRequest(url: resolveOpenAIChatURL(from: endpoint))
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
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

    internal func backendSnapshot() -> AIBackend {
        backend
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

    private func consumeOpenAIResponse(
        data: Data,
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

        let chunk = try Self.parseOpenAIChatResponse(data)
        if let onToolCall {
            for call in chunk.toolCalls {
                await onToolCall(call)
            }
        }
        if let content = chunk.content, !content.isEmpty {
            continuation.yield(content)
            return content
        }
        return ""
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

    private func resolvedModelName() -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return backend.defaultModel
        }
        return trimmed
    }

    internal nonisolated static func resolveOllamaTagsURL(from endpoint: URL) -> URL {
        let normalizedPath = endpoint.path.lowercased()
        if normalizedPath.hasSuffix("/api/tags") {
            return endpoint
        }
        if normalizedPath.hasSuffix("/api/chat") {
            return endpoint.deletingLastPathComponent().appendingPathComponent("tags")
        }
        return endpoint.appendingPathComponent("api").appendingPathComponent("tags")
    }

    internal nonisolated static func resolveOllamaChatURL(from endpoint: URL) -> URL {
        let normalizedPath = endpoint.path.lowercased()
        if normalizedPath.hasSuffix("/api/chat") {
            return endpoint
        }
        if normalizedPath.hasSuffix("/api/tags") {
            return endpoint.deletingLastPathComponent().appendingPathComponent("chat")
        }
        return endpoint.appendingPathComponent("api").appendingPathComponent("chat")
    }

    internal nonisolated static func resolveOpenAIModelsURL(from endpoint: URL) -> URL {
        let normalizedPath = Self.trimmedLowercasedPath(endpoint)
        if normalizedPath.hasSuffix("/v1/models") || normalizedPath.hasSuffix("/models") {
            return endpoint
        }
        if normalizedPath.hasSuffix("/v1/chat/completions") {
            return endpoint
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("models")
        }
        if normalizedPath.hasSuffix("/v1/chat") {
            return endpoint
                .deletingLastPathComponent()
                .appendingPathComponent("models")
        }
        if normalizedPath.hasSuffix("/v1") {
            return endpoint.appendingPathComponent("models")
        }
        return endpoint.appendingPathComponent("v1").appendingPathComponent("models")
    }

    internal nonisolated static func resolveOpenAIChatURL(from endpoint: URL) -> URL {
        let normalizedPath = Self.trimmedLowercasedPath(endpoint)
        if normalizedPath.hasSuffix("/v1/chat/completions") || normalizedPath.hasSuffix("/chat/completions") {
            return endpoint
        }
        if normalizedPath.hasSuffix("/v1/chat") || normalizedPath.hasSuffix("/chat") {
            return endpoint.appendingPathComponent("completions")
        }
        if normalizedPath.hasSuffix("/v1") {
            return endpoint
                .appendingPathComponent("chat")
                .appendingPathComponent("completions")
        }
        if normalizedPath.hasSuffix("/v1/models") {
            return endpoint
                .deletingLastPathComponent()
                .appendingPathComponent("chat")
                .appendingPathComponent("completions")
        }
        return endpoint
            .appendingPathComponent("v1")
            .appendingPathComponent("chat")
            .appendingPathComponent("completions")
    }

    private nonisolated static func trimmedLowercasedPath(_ url: URL) -> String {
        let path = url.path.lowercased()
        if path.count > 1, path.hasSuffix("/") {
            return String(path.dropLast())
        }
        return path
    }

    internal nonisolated static func parseOpenAIChatResponse(_ data: Data) throws -> ParsedChunk {
        let decoder = JSONDecoder()
        let response = try decoder.decode(OpenAIResponse.self, from: data)
        guard let choice = response.choices.first else {
            throw OllamaServiceError.invalidResponse
        }

        return ParsedChunk(
            content: choice.message.content,
            done: true,
            toolCalls: choice.message.toolCalls?.compactMap { toolCall in
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

    private struct ChatPayload: Codable {
        let model: String
        let messages: [PayloadMessage]
        let stream: Bool
        let tools: [OllamaTool]?
    }

    private struct OpenAIChatPayload: Codable {
        let model: String
        let messages: [PayloadMessage]
        let stream: Bool
        let tools: [OllamaTool]?
        let maxTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case model
            case messages
            case stream
            case tools
            case maxTokens = "max_tokens"
        }
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

    private struct OpenAIResponse: Decodable {
        let choices: [Choice]

        struct Choice: Decodable {
            let message: Message
        }

        struct Message: Decodable {
            let role: String
            let content: String?
            let toolCalls: [ToolCall]?

            private enum CodingKeys: String, CodingKey {
                case role
                case content
                case toolCalls = "tool_calls"
            }
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
