import Foundation
import Localization

public enum MemoryCategory: String, Sendable, CaseIterable, Codable {
    case fact
    case preference
    case event
    case todo
    case relationship

    public var displayName: String {
        switch self {
        case .fact: return "事实"
        case .preference: return "偏好"
        case .event: return "事件"
        case .todo: return "待办"
        case .relationship: return "关系"
        }
    }

    public static func from(rawValue: String?) -> MemoryCategory {
        guard let raw = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let category = MemoryCategory(rawValue: raw) else {
            return .fact
        }
        return category
    }
}

public struct ExtractedMemory: Sendable, Equatable {
    public let content: String
    public let category: MemoryCategory
    public let importance: Int

    public init(content: String, category: MemoryCategory, importance: Int) {
        self.content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        self.category = category
        self.importance = max(1, min(3, importance))
    }

    init?(fromDict dict: [String: Any]) {
        guard let rawContent = dict["content"] as? String else { return nil }
        let trimmed = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let category = MemoryCategory.from(rawValue: dict["category"] as? String)
        let importance: Int
        if let int = dict["importance"] as? Int {
            importance = int
        } else if let double = dict["importance"] as? Double {
            importance = Int(double)
        } else if let string = dict["importance"] as? String, let parsed = Int(string) {
            importance = parsed
        } else {
            importance = 1
        }

        self.init(content: trimmed, category: category, importance: importance)
    }
}

public struct MemoryContextItem: Sendable, Equatable {
    public let content: String
    public let category: MemoryCategory
    public let importance: Int

    public init(content: String, category: MemoryCategory, importance: Int) {
        self.content = content
        self.category = category
        self.importance = importance
    }
}

/// Strips reasoning/thinking content emitted by chain-of-thought models
/// (DeepSeek-R1, QwQ, etc.) before it reaches the UI or persisted history.
///
/// Handles three patterns:
/// 1. Well-formed: `<think>...</think>实际回复` — block removed.
/// 2. Tagless leak: `推理过程...</think>实际回复` — model forgot the opener
///    but emitted a closer; treat everything before the last close tag as
///    reasoning and drop it.
/// 3. Unclosed: `<think>...` (close never arrived) — drop the trailing block.
public enum ThinkingStripper {
    private static let openTags = ["<think>", "<thinking>", "<reasoning>", "<reflection>"]
    private static let closeTags = ["</think>", "</thinking>", "</reasoning>", "</reflection>"]

    public static func strip(_ text: String) -> String {
        split(text).reply
    }

    /// Separate reasoning from reply. Handles well-formed `<think>...</think>`,
    /// tagless leak (close tag with no opener), and unclosed open tag.
    public static func split(_ text: String) -> (thinking: String?, reply: String) {
        guard !text.isEmpty else { return (nil, text) }
        var thinkingChunks: [String] = []
        var result = text

        for (open, close) in zip(openTags, closeTags) {
            while let openRange = result.range(of: open, options: .caseInsensitive) {
                let searchRange = openRange.upperBound..<result.endIndex
                guard let closeRange = result.range(of: close, options: .caseInsensitive, range: searchRange) else {
                    break
                }
                let inner = String(result[openRange.upperBound..<closeRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !inner.isEmpty { thinkingChunks.append(inner) }
                result.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
            }
        }

        for close in closeTags {
            if let range = result.range(of: close, options: [.caseInsensitive, .backwards]) {
                let leak = String(result[result.startIndex..<range.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !leak.isEmpty { thinkingChunks.insert(leak, at: 0) }
                result.removeSubrange(result.startIndex..<range.upperBound)
            }
        }

        for open in openTags {
            if let range = result.range(of: open, options: .caseInsensitive) {
                let trailing = String(result[range.upperBound..<result.endIndex])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !trailing.isEmpty { thinkingChunks.append(trailing) }
                result.removeSubrange(range.lowerBound..<result.endIndex)
            }
        }

        let reply = result.trimmingCharacters(in: .whitespacesAndNewlines)
        let thinking = thinkingChunks.isEmpty ? nil : thinkingChunks.joined(separator: "\n\n")
        return (thinking, reply)
    }

    /// Canonical form for UI: `<think>...</think>{reply}` so MessageBubble can
    /// render reasoning in a disclosure. Returns just the reply if no thinking.
    public static func combine(_ text: String) -> String {
        let parts = split(text)
        guard let thinking = parts.thinking, !thinking.isEmpty else { return parts.reply }
        return "<think>\n\(thinking)\n</think>\n\(parts.reply)"
    }
}

public actor OllamaService: AIEngineProtocol {
    private static let baseSystemPrompt = "你是主人桌面上的可爱宠物。回复要简短可爱（1-2句话）。称呼用户为主人。直接给出回复，不要展示推理过程；如确需思考，请放在 <think>...</think> 标签内。"
    private var customSystemPrompt = ""
    private var petProfile: String = ""
    private var availableActions: [String] = []
    private var memories: [String] = []
    private var structuredMemories: [MemoryContextItem] = []
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
        let structuredBlock = buildStructuredMemoryBlock()
        if !structuredBlock.isEmpty {
            prompt += "\n\n" + structuredBlock
        } else if !memories.isEmpty {
            let memoryList = memories.map { "- \($0)" }.joined(separator: "\n")
            prompt += "\n\n你记住了以下关于用户的信息：\n\(memoryList)"
        }
        return prompt
    }

    private func buildStructuredMemoryBlock() -> String {
        guard !structuredMemories.isEmpty else { return "" }

        let sorted = structuredMemories.sorted { lhs, rhs in
            if lhs.importance != rhs.importance { return lhs.importance > rhs.importance }
            return lhs.category.rawValue < rhs.category.rawValue
        }

        var grouped: [MemoryCategory: [MemoryContextItem]] = [:]
        for item in sorted {
            grouped[item.category, default: []].append(item)
        }

        let order: [MemoryCategory] = [.fact, .relationship, .preference, .todo, .event]
        var sections: [String] = []
        for category in order {
            guard let items = grouped[category], !items.isEmpty else { continue }
            let bullets = items.map { item -> String in
                let marker = item.importance >= 3 ? "⭐ " : "- "
                return marker + item.content
            }.joined(separator: "\n")
            sections.append("[\(category.displayName)]\n\(bullets)")
        }

        guard !sections.isEmpty else { return "" }
        return "关于主人的已知信息（请在合适的时候自然地运用，不要生硬地重复）：\n" + sections.joined(separator: "\n\n")
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
        structuredMemories = []
    }

    public func updateStructuredMemories(_ items: [MemoryContextItem]) {
        structuredMemories = items
        memories = items.map(\.content)
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

            return ThinkingStripper.strip(content)
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

            return ThinkingStripper.strip(content)
        }
    }

    public func extractMemories(from recentMessages: [(role: String, content: String)]) async throws -> [String] {
        let structured = try await extractStructuredMemories(from: recentMessages)
        return structured.map(\.content)
    }

    public func extractStructuredMemories(
        from recentMessages: [(role: String, content: String)]
    ) async throws -> [ExtractedMemory] {
        let extractionPrompt = """
        你是一个记忆提取助手。从以下对话中提取对用户有长期价值的信息。

        只提取：
        - fact：客观事实（姓名、生日、工作、家庭成员、地点、设备等）
        - preference：主观偏好（喜欢 / 不喜欢、口味、风格等）
        - event：已发生的具体事件（有时间点或场景）
        - todo：用户明确提到的待办或承诺（"我下周要去..."）
        - relationship：与他人的关系或联系方式

        不要提取：寒暄、临时话题、情绪波动、宠物自己的动作/心情、AI 的回答本身。

        每条记忆写成一句自成独立上下文的中文陈述（不要"他"/"她"之类指代，需补全主语），并评估重要性：
        - 1：一般（偶然提到的偏好）
        - 2：重要（生日、工作、家人）
        - 3：关键（用户明确说"请记住..."）

        若对话里有多条互不重复的长期信息，请拆成多条记忆分别输出，不要合并成一条笼统摘要；只要符合条件，通常可提取 2～8 条（视对话信息量而定）。

        严格返回 JSON 数组，每项结构：
        {"content": "用户生日是 6 月 3 日", "category": "fact", "importance": 2}

        没有可提取的信息时返回空数组 []。不要解释、不要 Markdown 代码块，只输出 JSON。
        """

        let conversationText = recentMessages
            .map { "\($0.role): \($0.content)" }
            .joined(separator: "\n")

        let responseText: String?
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
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return []
            }
            responseText = (try? JSONDecoder().decode(NonStreamResponse.self, from: data))?.message?.content
        case .openAICompatible:
            let request = try Self.buildOpenAICompatibleChatRequest(
                endpoint: endpoint,
                model: resolvedModelName(),
                history: [],
                systemPrompt: extractionPrompt,
                userMessage: conversationText,
                stream: false
            )
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return []
            }
            responseText = try? Self.parseOpenAIChatResponse(data).content
        }

        guard let responseText else { return [] }
        let cleanedText = ThinkingStripper.strip(responseText)
        return Self.parseStructuredMemories(from: cleanedText)
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

        var rawContent = ""
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
                rawContent += content
                // Yield raw token incrementally so the bubble can render the
                // reasoning live. MessageBubble's parser handles partial states
                // (open `<think>` without a close yet) and tagless leaks.
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

        // Return the canonical `<think>...</think>{reply}` form for history /
        // DB persistence so reloads parse cleanly even if the live stream had
        // a tagless leak. The live bubble keeps the raw token stream — both
        // forms parse to the same (thinking, reply) tuple.
        return ThinkingStripper.combine(rawContent)
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
            let combined = ThinkingStripper.combine(content)
            if !combined.isEmpty {
                continuation.yield(combined)
            }
            return combined
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
            // Strip <think>...</think> from prior assistant turns so the model
            // doesn't see (and try to imitate or get confused by) its own
            // earlier reasoning. UI keeps the tagged version for display.
            let content = message.role == .assistant
                ? ThinkingStripper.strip(message.content)
                : message.content
            return PayloadMessage(role: message.role.rawValue, content: content)
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

    static func parseStructuredMemories(from text: String) -> [ExtractedMemory] {
        guard let jsonText = extractFirstJSONArray(from: text),
              let data = jsonText.data(using: .utf8) else {
            return []
        }

        // Primary path: objects with fields.
        if let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return raw.compactMap { ExtractedMemory(fromDict: $0) }
        }

        // Fallback: plain string array — upgrade with default category/importance so older prompts keep working.
        if let strings = try? JSONSerialization.jsonObject(with: data) as? [String] {
            return strings
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { ExtractedMemory(content: $0, category: .fact, importance: 1) }
        }

        return []
    }

    private static func extractFirstJSONArray(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") { return trimmed }
        guard let start = trimmed.firstIndex(of: "["),
              let end = trimmed.lastIndex(of: "]"), start < end else {
            return nil
        }
        return String(trimmed[start...end])
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
