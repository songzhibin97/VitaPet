@testable import AIEngine
import Foundation
import XCTest

private final class OllamaServiceURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.requestHandler
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func install(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) {
        lock.lock()
        requestHandler = handler
        lock.unlock()
        URLProtocol.registerClass(Self.self)
    }

    static func uninstall() {
        lock.lock()
        requestHandler = nil
        lock.unlock()
        URLProtocol.unregisterClass(Self.self)
    }
}

private actor ConversationUpdateRecorder {
    private var updates: [(role: String, content: String, sessionId: String, petId: String?, petName: String?)] = []

    func record(role: String, content: String, sessionId: String, petId: String?, petName: String?) {
        updates.append((role, content, sessionId, petId, petName))
    }

    func all() -> [(role: String, content: String, sessionId: String, petId: String?, petName: String?)] {
        updates
    }
}

private actor ToolCallRecorder {
    private var calls: [PetToolCall] = []

    func record(_ call: PetToolCall) {
        calls.append(call)
    }

    func all() -> [PetToolCall] {
        calls
    }
}

private extension URLRequest {
    func bodyDataForTesting() -> Data? {
        if let httpBody {
            return httpBody
        }

        guard let stream = httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var data = Data()
        while stream.hasBytesAvailable {
            let bytesRead = stream.read(buffer, maxLength: bufferSize)
            if bytesRead < 0 {
                return nil
            }
            if bytesRead == 0 {
                break
            }
            data.append(buffer, count: bytesRead)
        }

        return data
    }
}

final class OllamaServiceTests: XCTestCase {
    override func tearDown() {
        OllamaServiceURLProtocol.uninstall()
        super.tearDown()
    }

    func testInitialStatus() async {
        let service = OllamaService(
            endpoint: URL(string: "http://localhost:11434")!,
            model: "llama3.2"
        )

        let status = await service.status

        if case .notConfigured = status {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected initial status to be .notConfigured")
        }
    }

    func testBuildChatRequest() throws {
        let endpoint = URL(string: "http://localhost:11434")!
        let history: [ChatMessage] = [
            ChatMessage(role: .user, content: "你是谁"),
            ChatMessage(role: .assistant, content: "喵~")
        ]

        let request = try OllamaService.buildChatRequest(
            endpoint: endpoint,
            model: "llama3.2",
            history: history,
            systemPrompt: "你是 VitaPet 的 AI 助手，一只可爱的桌面猫咪。",
            userMessage: "你好"
        )

        XCTAssertEqual(request.url?.absoluteString, "http://localhost:11434/api/chat")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let json = try XCTUnwrap(request.httpBody)
        let object = try JSONSerialization.jsonObject(with: json)
        guard let dict = object as? [String: Any] else {
            return XCTFail("Request body should be JSON object")
        }

        XCTAssertEqual(dict["model"] as? String, "llama3.2")
        XCTAssertEqual(dict["stream"] as? Bool, true)

        let messages = try XCTUnwrap(dict["messages"] as? [[String: String]])
        XCTAssertEqual(messages.count, 4)

        XCTAssertEqual(messages[0]["role"], "system")
        XCTAssertEqual(messages[0]["content"], "你是 VitaPet 的 AI 助手，一只可爱的桌面猫咪。")

        XCTAssertEqual(messages[1]["role"], "user")
        XCTAssertEqual(messages[1]["content"], "你是谁")

        XCTAssertEqual(messages[2]["role"], "assistant")
        XCTAssertEqual(messages[2]["content"], "喵~")

        XCTAssertEqual(messages[3]["role"], "user")
        XCTAssertEqual(messages[3]["content"], "你好")
    }

    func testBuildOpenAICompatibleChatRequestUsesCompletionsEndpoint() throws {
        let endpoint = URL(string: "http://127.0.0.1:8787")!

        let request = try OllamaService.buildOpenAICompatibleChatRequest(
            endpoint: endpoint,
            model: "auto",
            history: [],
            systemPrompt: "You are helpful.",
            userMessage: "Hello"
        )

        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8787/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
    }

    func testBuildOpenAICompatibleChatRequestKeepsExplicitCompletionsPath() throws {
        let endpoint = URL(string: "http://127.0.0.1:8787/v1/chat/completions")!

        let request = try OllamaService.buildOpenAICompatibleChatRequest(
            endpoint: endpoint,
            model: "auto",
            history: [],
            systemPrompt: "You are helpful.",
            userMessage: "Hello"
        )

        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8787/v1/chat/completions")
    }

    func testBuildOpenAICompatibleChatRequest_setsBearerWhenAuthorizationProvided() throws {
        let endpoint = URL(string: "https://api.openai.com/v1")!

        let withAuth = try OllamaService.buildOpenAICompatibleChatRequest(
            endpoint: endpoint,
            model: "gpt-4o-mini",
            history: [],
            systemPrompt: "x",
            userMessage: "y",
            authorizationBearer: " sk-secret "
        )
        XCTAssertEqual(withAuth.value(forHTTPHeaderField: "Authorization"), "Bearer sk-secret")

        let noAuth = try OllamaService.buildOpenAICompatibleChatRequest(
            endpoint: endpoint,
            model: "gpt-4o-mini",
            history: [],
            systemPrompt: "x",
            userMessage: "y",
            authorizationBearer: "   "
        )
        XCTAssertNil(noAuth.value(forHTTPHeaderField: "Authorization"))
    }

    func testParseChatResponse() throws {
        let line = #"{"model":"llama3.2","message":{"role":"assistant","content":"你"},"done":false}"#

        let chunk = try OllamaService.parseChatResponse(line)

        XCTAssertEqual(chunk.content, "你")
        XCTAssertFalse(chunk.done)
    }

    func testParseDoneResponse() throws {
        let line = #"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true}"#

        let chunk = try OllamaService.parseChatResponse(line)

        XCTAssertEqual(chunk.content, "")
        XCTAssertTrue(chunk.done)
    }

    func testThinkingStripper_removesWellFormedBlock() {
        let input = "<think>主人想知道我有什么记忆，让我组织一下回答</think>小喵记得主人喜欢数数～"
        XCTAssertEqual(ThinkingStripper.strip(input), "小喵记得主人喜欢数数～")
    }

    func testThinkingStripper_handlesTaglessLeak() {
        // DeepSeek-R1 / QwQ sometimes emit reasoning without an opener,
        // closed only by a stray </think> before the real reply.
        let input = """
        Here's a thinking process:
        1. Analyze user input...
        2. Draft response...
        Output Generation.
        </think>

        小喵牢牢记得主人喜欢数数～[ACTION:lookAtCursor]
        """
        XCTAssertEqual(
            ThinkingStripper.strip(input),
            "小喵牢牢记得主人喜欢数数～[ACTION:lookAtCursor]"
        )
    }

    func testThinkingStripper_dropsUnclosedTrailingThink() {
        let input = "你好主人～<think>但其实我还在想"
        XCTAssertEqual(ThinkingStripper.strip(input), "你好主人～")
    }

    func testThinkingStripper_passesThroughCleanContent() {
        let input = "好开心！[ACTION:celebrate]"
        XCTAssertEqual(ThinkingStripper.strip(input), "好开心！[ACTION:celebrate]")
    }

    func testThinkingStripper_stripsMultipleBlocks() {
        let input = "<think>第一段思考</think>开头<thinking>中间又想了想</thinking>结尾"
        XCTAssertEqual(ThinkingStripper.strip(input), "开头结尾")
    }

    func testThinkingStripper_splitReturnsBothParts() {
        let input = "<think>主人在问记忆</think>小喵记得呀～"
        let parts = ThinkingStripper.split(input)
        XCTAssertEqual(parts.thinking, "主人在问记忆")
        XCTAssertEqual(parts.reply, "小喵记得呀～")
    }

    func testThinkingStripper_splitCapturesTaglessLeak() {
        let input = "Here's a thinking process:\nstep 1\nstep 2\n</think>\n\n小喵记得！"
        let parts = ThinkingStripper.split(input)
        XCTAssertEqual(parts.thinking, "Here's a thinking process:\nstep 1\nstep 2")
        XCTAssertEqual(parts.reply, "小喵记得！")
    }

    func testThinkingStripper_combineProducesCanonicalForm() {
        let input = "Reasoning text...\n</think>\n实际回复"
        let combined = ThinkingStripper.combine(input)
        XCTAssertEqual(combined, "<think>\nReasoning text...\n</think>\n实际回复")
    }

    func testThinkingStripper_combinePassesThroughCleanReply() {
        XCTAssertEqual(ThinkingStripper.combine("好开心！"), "好开心！")
    }

    func testClearHistory() async {
        let service = OllamaService(
            endpoint: URL(string: "http://localhost:11434")!,
            model: "llama3.2"
        )

        await service.setConversationHistoryForTesting([
            ChatMessage(role: .user, content: "你好"),
            ChatMessage(role: .assistant, content: "喵~")
        ])

        await service.clearHistory()

        let history = await service.conversationHistorySnapshot()
        XCTAssertTrue(history.isEmpty)
    }

    func testLoadHistory_populatesConversationSnapshot() async {
        let service = OllamaService(
            endpoint: URL(string: "http://localhost:11434")!,
            model: "llama3.2"
        )

        await service.loadHistory(turns: [
            (role: "user", content: "你好"),
            (role: "assistant", content: "喵~")
        ])

        let history = await service.conversationHistorySnapshot()
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history[0].role, .user)
        XCTAssertEqual(history[0].content, "你好")
        XCTAssertEqual(history[1].role, .assistant)
        XCTAssertEqual(history[1].content, "喵~")
    }

    func testSwitchSession_isolatesConversationHistory() async {
        let service = OllamaService(
            endpoint: URL(string: "http://localhost:11434")!,
            model: "llama3.2"
        )

        await service.setConversationHistoryForTesting([
            ChatMessage(role: .user, content: "default")
        ])
        await service.switchSession("session-b")

        let sessionBHistory = await service.conversationHistorySnapshot()
        XCTAssertTrue(sessionBHistory.isEmpty)

        await service.setConversationHistoryForTesting([
            ChatMessage(role: .user, content: "session-b")
        ])

        await service.switchSession("default")
        let defaultHistory = await service.conversationHistorySnapshot()
        XCTAssertEqual(defaultHistory.map(\.content), ["default"])

        await service.switchSession("session-b")
        let updatedSessionBHistory = await service.conversationHistorySnapshot()
        XCTAssertEqual(updatedSessionBHistory.map(\.content), ["session-b"])
    }

    func testLoadHistory_withSessionId_setsActiveSessionHistory() async {
        let service = OllamaService(
            endpoint: URL(string: "http://localhost:11434")!,
            model: "llama3.2"
        )

        await service.loadHistory(
            turns: [
                (role: "user", content: "你好，群聊"),
                (role: "assistant", content: "大家好")
            ],
            sessionId: "group-chat"
        )

        let activeHistory = await service.conversationHistorySnapshot()
        XCTAssertEqual(activeHistory.map(\.content), ["你好，群聊", "大家好"])

        await service.switchSession("default")
        let defaultHistory = await service.conversationHistorySnapshot()
        XCTAssertTrue(defaultHistory.isEmpty)
    }

    func testBuildGroupChatProfile_rendersPetsAndExample() async {
        let service = OllamaService(
            endpoint: URL(string: "http://localhost:11434")!,
            model: "llama3.2"
        )
        let pets = [
            PetProfileInfo(
                id: UUID(),
                name: "小花",
                gender: "female",
                age: "3岁",
                personality: "活泼",
                hobbies: "追蝴蝶"
            ),
            PetProfileInfo(
                id: UUID(),
                name: "小黑",
                gender: "male",
                age: "",
                personality: "高冷",
                hobbies: ""
            )
        ]

        let profile = await service.buildGroupChatProfile(pets: pets)

        XCTAssertTrue(profile.contains("你现在同时扮演以下宠物参与群聊"))
        XCTAssertTrue(profile.contains("宠物："))
        XCTAssertTrue(profile.contains("- 小花（女，3岁，活泼，爱好追蝴蝶）"))
        XCTAssertTrue(profile.contains("- 小黑（男，高冷）"))
        XCTAssertTrue(profile.contains("[PET:小花]"))
        XCTAssertTrue(profile.contains("[PET:小黑]"))
    }

    func testUpdateMemories_includesMemoriesInChatRequest() async throws {
        let service = OllamaService(
            endpoint: URL(string: "http://unit.test")!,
            model: "llama3.2"
        )
        let chatRequestObserved = expectation(description: "chat request observed")
        chatRequestObserved.assertForOverFulfill = true

        OllamaServiceURLProtocol.install { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!

            if request.url?.path == "/api/chat" {
                let body = try XCTUnwrap(request.bodyDataForTesting())
                let object = try XCTUnwrap(
                    try JSONSerialization.jsonObject(with: body) as? [String: Any]
                )
                let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
                let systemPrompt = try XCTUnwrap(messages.first?["content"] as? String)
                XCTAssertTrue(systemPrompt.contains("你记住了以下关于用户的信息"))
                XCTAssertTrue(systemPrompt.contains("- 用户喜欢冻干"))
                XCTAssertTrue(systemPrompt.contains("- 用户叫小宋"))
                chatRequestObserved.fulfill()

                let payload = Data(
                    """
                    {"model":"llama3.2","message":{"role":"assistant","content":"喵"},"done":false}
                    {"model":"llama3.2","message":{"role":"assistant","content":""},"done":true}
                    """.utf8
                )
                return (response, payload)
            }

            return (response, Data("{}".utf8))
        }

        await service.updateMemories(["用户喜欢冻干", "用户叫小宋"])
        let stream = try await service.send(message: "记住我了吗")
        for try await _ in stream {}

        await fulfillment(of: [chatRequestObserved], timeout: 1.0)
    }

    func testSetOnConversationUpdated_recordsCallbackWhenConversationIsRecorded() async throws {
        let service = OllamaService(
            endpoint: URL(string: "http://unit.test")!,
            model: "llama3.2"
        )
        let recorder = ConversationUpdateRecorder()
        let callbackReceived = expectation(description: "conversation update callback fired twice")
        callbackReceived.expectedFulfillmentCount = 2

        OllamaServiceURLProtocol.install { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!

            if request.url?.path == "/api/chat" {
                let payload = Data(
                    """
                    {"model":"llama3.2","message":{"role":"assistant","content":"喵~你好"},"done":false}
                    {"model":"llama3.2","message":{"role":"assistant","content":""},"done":true}
                    """.utf8
                )
                return (response, payload)
            }

            return (response, Data("{}".utf8))
        }

        await service.setOnConversationUpdated { role, content, sessionId, petId, petName in
            await recorder.record(role: role, content: content, sessionId: sessionId, petId: petId, petName: petName)
            callbackReceived.fulfill()
        }

        let stream = try await service.send(message: "你好")
        for try await _ in stream {}

        await fulfillment(of: [callbackReceived], timeout: 1.0)

        let updates = await recorder.all()
        XCTAssertEqual(updates.count, 2)
        XCTAssertEqual(updates[0].role, "user")
        XCTAssertEqual(updates[0].content, "你好")
        XCTAssertEqual(updates[0].sessionId, "default")
        XCTAssertNil(updates[0].petId)
        XCTAssertNil(updates[0].petName)
        XCTAssertEqual(updates[1].role, "assistant")
        XCTAssertEqual(updates[1].content, "喵~你好")
        XCTAssertEqual(updates[1].sessionId, "default")
        XCTAssertNil(updates[1].petId)
        XCTAssertNil(updates[1].petName)
    }

    func testSend_openAICompatibleBackendYieldsAssistantContent() async throws {
        let service = OllamaService(
            endpoint: URL(string: "http://unit.test")!,
            model: "auto",
            backend: .openAICompatible
        )
        let modelsObserved = expectation(description: "models endpoint observed")
        let completionsObserved = expectation(description: "chat completions observed")

        OllamaServiceURLProtocol.install { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!

            if request.url?.path == "/v1/models" {
                modelsObserved.fulfill()
                return (response, Data(#"{"data":[]}"#.utf8))
            }

            if request.url?.path == "/v1/chat/completions" {
                completionsObserved.fulfill()
                let body = try XCTUnwrap(request.bodyDataForTesting())
                let object = try XCTUnwrap(
                    try JSONSerialization.jsonObject(with: body) as? [String: Any]
                )
                XCTAssertEqual(object["model"] as? String, "auto")
                XCTAssertEqual(object["stream"] as? Bool, false)

                let payload = Data(
                    #"{"choices":[{"finish_reason":"stop","index":0,"message":{"role":"assistant","content":"你好呀"}}]}"#.utf8
                )
                return (response, payload)
            }

            return (response, Data("{}".utf8))
        }

        let stream = try await service.send(message: "你好")
        var collected = ""
        for try await chunk in stream {
            collected += chunk
        }

        XCTAssertEqual(collected, "你好呀")
        await fulfillment(of: [modelsObserved, completionsObserved], timeout: 1.0)
    }

    func testUpdateConfig() async {
        let service = OllamaService(
            endpoint: URL(string: "http://localhost:11434")!,
            model: "llama3.2"
        )
        let newEndpoint = URL(string: "http://127.0.0.1:11435")!

        await service.updateConfig(endpoint: newEndpoint, model: "qwen2.5", backend: .openAICompatible, openAIApiKey: "")

        let config = await service.configSnapshot()
        XCTAssertEqual(config.endpoint, newEndpoint)
        XCTAssertEqual(config.model, "qwen2.5")
        let backend = await service.backendSnapshot()
        XCTAssertEqual(backend, .openAICompatible)
    }

    func testSendWithTools_replaysToolResultsForOpenAICompatible() async throws {
        let service = OllamaService(
            endpoint: URL(string: "http://unit.test")!,
            model: "auto",
            backend: .openAICompatible
        )
        let toolRecorder = ToolCallRecorder()
        let completionRequestsObserved = expectation(description: "tool loop requests observed")
        completionRequestsObserved.expectedFulfillmentCount = 2
        let lock = NSLock()
        var completionRequestCount = 0

        OllamaServiceURLProtocol.install { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!

            if request.url?.path == "/v1/models" {
                return (response, Data(#"{"data":[]}"#.utf8))
            }

            if request.url?.path == "/v1/chat/completions" {
                completionRequestsObserved.fulfill()

                let body = try XCTUnwrap(request.bodyDataForTesting())
                let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
                let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])

                lock.lock()
                completionRequestCount += 1
                let currentRequest = completionRequestCount
                lock.unlock()

                if currentRequest == 1 {
                    XCTAssertEqual(messages.count, 2)
                    XCTAssertEqual(messages[0]["role"] as? String, "system")
                    XCTAssertEqual(messages[1]["role"] as? String, "user")

                    let payload = Data(
                        #"{"choices":[{"message":{"role":"assistant","content":"","tool_calls":[{"id":"call_1","type":"function","function":{"name":"pet_action","arguments":"{\"action\":\"wave\",\"count\":2}"}}]}}]}"#.utf8
                    )
                    return (response, payload)
                }

                XCTAssertEqual(messages.count, 4)
                XCTAssertEqual(messages[2]["role"] as? String, "assistant")
                let assistantToolCalls = try XCTUnwrap(messages[2]["tool_calls"] as? [[String: Any]])
                let assistantFunction = try XCTUnwrap(assistantToolCalls.first?["function"] as? [String: Any])
                XCTAssertEqual(assistantFunction["name"] as? String, "pet_action")
                let argumentsString = try XCTUnwrap(assistantFunction["arguments"] as? String)
                let argumentsData = Data(argumentsString.utf8)
                let argumentsObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: argumentsData) as? [String: Any])
                XCTAssertEqual(argumentsObject["action"] as? String, "wave")
                XCTAssertEqual(argumentsObject["count"] as? Int, 2)
                XCTAssertEqual(messages[3]["role"] as? String, "tool")
                XCTAssertEqual(messages[3]["tool_call_id"] as? String, "call_1")
                XCTAssertEqual(messages[3]["content"] as? String, "pet_action_done")

                let payload = Data(
                    #"{"choices":[{"message":{"role":"assistant","content":"已经挥手啦"}}]}"#.utf8
                )
                return (response, payload)
            }

            return (response, Data("{}".utf8))
        }

        let stream = try await service.sendWithTools(
            message: "挥挥手",
            tools: [OllamaTool.petActionTool(availableActions: ["wave"])],
            onToolCall: { toolCall in
                await toolRecorder.record(toolCall)
                return "pet_action_done"
            }
        )

        var collected = ""
        for try await chunk in stream {
            collected += chunk
        }

        let recordedCalls = await toolRecorder.all()
        XCTAssertEqual(recordedCalls.count, 1)
        XCTAssertEqual(recordedCalls.first?.functionName, "pet_action")
        XCTAssertEqual(recordedCalls.first?.id, "call_1")
        XCTAssertEqual(recordedCalls.first?.arguments["action"]?.stringValue, "wave")
        XCTAssertEqual(recordedCalls.first?.arguments["count"]?.intValue, 2)
        XCTAssertEqual(collected, "已经挥手啦")
        await fulfillment(of: [completionRequestsObserved], timeout: 1.0)
    }

    func testSendWithTools_forcesFinalReplyAfterRepeatedIdenticalToolCall() async throws {
        let service = OllamaService(
            endpoint: URL(string: "http://unit.test")!,
            model: "auto",
            backend: .openAICompatible
        )
        let toolRecorder = ToolCallRecorder()
        let completionRequestsObserved = expectation(description: "tool loop fallback requests observed")
        completionRequestsObserved.expectedFulfillmentCount = 3
        let lock = NSLock()
        var completionRequestCount = 0

        let mealTool = OllamaTool.mcpTool(
            name: "recommend_meal",
            description: "Recommend a meal for the user.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "day": .object([
                        "type": .string("string")
                    ])
                ])
            ])
        )

        OllamaServiceURLProtocol.install { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!

            if request.url?.path == "/v1/models" {
                return (response, Data(#"{"data":[]}"#.utf8))
            }

            if request.url?.path == "/v1/chat/completions" {
                completionRequestsObserved.fulfill()

                let body = try XCTUnwrap(request.bodyDataForTesting())
                let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
                let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])

                lock.lock()
                completionRequestCount += 1
                let currentRequest = completionRequestCount
                lock.unlock()

                if currentRequest == 1 {
                    XCTAssertEqual(messages.count, 2)
                    XCTAssertNotNil(object["tools"])

                    let payload = Data(
                        #"{"choices":[{"message":{"role":"assistant","content":"","tool_calls":[{"id":"call_1","type":"function","function":{"name":"recommend_meal","arguments":"{\"day\":\"tomorrow\"}"}}]}}]}"#.utf8
                    )
                    return (response, payload)
                }

                if currentRequest == 2 {
                    XCTAssertEqual(messages.count, 4)
                    XCTAssertNotNil(object["tools"])
                    XCTAssertEqual(messages[3]["role"] as? String, "tool")
                    XCTAssertEqual(messages[3]["tool_call_id"] as? String, "call_1")
                    XCTAssertEqual(messages[3]["content"] as? String, "推荐明天吃冬瓜酿肉")

                    let payload = Data(
                        #"{"choices":[{"message":{"role":"assistant","content":"","tool_calls":[{"id":"call_2","type":"function","function":{"name":"recommend_meal","arguments":"{\"day\":\"tomorrow\"}"}}]}}]}"#.utf8
                    )
                    return (response, payload)
                }

                XCTAssertEqual(messages.count, 5)
                XCTAssertNil(object["tools"])
                XCTAssertEqual(messages[4]["role"] as? String, "system")
                let reminder = try XCTUnwrap(messages[4]["content"] as? String)
                XCTAssertTrue(reminder.contains("Do not call any more tools"))

                let payload = Data(
                    #"{"choices":[{"message":{"role":"assistant","content":"明天吃冬瓜酿肉吧，适合两个人。"}}]}"#.utf8
                )
                return (response, payload)
            }

            return (response, Data("{}".utf8))
        }

        let stream = try await service.sendWithTools(
            message: "明天吃什么",
            tools: [mealTool],
            onToolCall: { toolCall in
                await toolRecorder.record(toolCall)
                return "推荐明天吃冬瓜酿肉"
            }
        )

        var collected = ""
        for try await chunk in stream {
            collected += chunk
        }

        let recordedCalls = await toolRecorder.all()
        XCTAssertEqual(recordedCalls.count, 1)
        XCTAssertEqual(recordedCalls.first?.functionName, "recommend_meal")
        XCTAssertEqual(recordedCalls.first?.arguments["day"]?.stringValue, "tomorrow")
        XCTAssertEqual(collected, "明天吃冬瓜酿肉吧，适合两个人。")
        await fulfillment(of: [completionRequestsObserved], timeout: 1.0)
    }

    func testMCPServerConfigurationDecodeList_acceptsNamedStreamableHTTPServers() throws {
        let json = #"""
        {
          "mcpServers": {
            "mcp-chinese-fortune": {
              "type": "streamable_http",
              "url": "https://example.com/fortune/mcp",
              "headers": {
                "Authorization": "Bearer fortune-token"
              }
            },
            "howtocook-mcp": {
              "type": "streamable_http",
              "url": "https://example.com/howtocook/mcp",
              "headers": {
                "Authorization": "Bearer cook-token"
              }
            }
          }
        }
        """#

        let configurations = try MCPServerConfiguration.decodeList(from: json)
        XCTAssertEqual(configurations.count, 2)

        let byName = Dictionary(uniqueKeysWithValues: configurations.map { ($0.name, $0) })
        XCTAssertEqual(byName["mcp-chinese-fortune"]?.transport, .streamableHTTP)
        XCTAssertEqual(byName["mcp-chinese-fortune"]?.url, "https://example.com/fortune/mcp")
        XCTAssertEqual(byName["mcp-chinese-fortune"]?.headers["Authorization"], "Bearer fortune-token")
        XCTAssertEqual(byName["howtocook-mcp"]?.transport, .streamableHTTP)
        XCTAssertEqual(byName["howtocook-mcp"]?.url, "https://example.com/howtocook/mcp")
        XCTAssertEqual(byName["howtocook-mcp"]?.headers["Authorization"], "Bearer cook-token")
    }

    func testMCPClient_supportsStreamableHTTPTransport() async throws {
        let configuration = MCPServerConfiguration(
            name: "howtocook-mcp",
            transport: .streamableHTTP,
            url: "https://unit.test/mcp",
            headers: ["Authorization": "Bearer unit-token"]
        )
        let client = MCPClient(configuration: configuration)
        let requestOrderLock = NSLock()
        var requestMethods: [String] = []

        OllamaServiceURLProtocol.install { request in
            let responseURL = try XCTUnwrap(request.url)
            let body = try XCTUnwrap(request.bodyDataForTesting())
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            let method = try XCTUnwrap(object["method"] as? String)
            let headers = request.allHTTPHeaderFields ?? [:]

            requestOrderLock.lock()
            requestMethods.append(method)
            requestOrderLock.unlock()

            XCTAssertEqual(headers["Authorization"], "Bearer unit-token")
            XCTAssertEqual(headers["Accept"], "application/json, text/event-stream")

            switch method {
            case "initialize":
                XCTAssertNil(headers["Mcp-Session-Id"])
                XCTAssertEqual(object["id"] as? Int, 1)
                let params = try XCTUnwrap(object["params"] as? [String: Any])
                XCTAssertEqual(params["protocolVersion"] as? String, "2025-03-26")

                let response = HTTPURLResponse(
                    url: responseURL,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": "application/json",
                        "Mcp-Session-Id": "session-1"
                    ]
                )!
                let payload = Data(
                    #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26","capabilities":{"tools":{"listChanged":false}},"serverInfo":{"name":"howtocook-mcp","version":"1.0.0"}}}"#.utf8
                )
                return (response, payload)

            case "notifications/initialized":
                XCTAssertEqual(headers["Mcp-Session-Id"], "session-1")
                XCTAssertNil(object["id"])

                let response = HTTPURLResponse(
                    url: responseURL,
                    statusCode: 202,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": "application/json",
                        "Mcp-Session-Id": "session-1"
                    ]
                )!
                return (response, Data())

            case "tools/list":
                XCTAssertEqual(headers["Mcp-Session-Id"], "session-1")
                XCTAssertEqual(object["id"] as? Int, 2)
                let params = try XCTUnwrap(object["params"] as? [String: Any])
                XCTAssertTrue(params.isEmpty)

                let response = HTTPURLResponse(
                    url: responseURL,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": "application/json",
                        "Mcp-Session-Id": "session-1"
                    ]
                )!
                let payload = Data(
                    #"{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"lookup-recipe","description":"Find a recipe","inputSchema":{"type":"object","properties":{"dish":{"type":"string"}},"required":["dish"]}}]}}"#.utf8
                )
                return (response, payload)

            case "tools/call":
                XCTAssertEqual(headers["Mcp-Session-Id"], "session-1")
                XCTAssertEqual(object["id"] as? Int, 3)
                let params = try XCTUnwrap(object["params"] as? [String: Any])
                XCTAssertEqual(params["name"] as? String, "lookup-recipe")
                let arguments = try XCTUnwrap(params["arguments"] as? [String: Any])
                XCTAssertEqual(arguments["dish"] as? String, "番茄炒蛋")

                let response = HTTPURLResponse(
                    url: responseURL,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": "application/json",
                        "Mcp-Session-Id": "session-1"
                    ]
                )!
                let payload = Data(
                    #"{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"番茄炒蛋做法"}]}}"#.utf8
                )
                return (response, payload)

            default:
                XCTFail("Unexpected MCP method: \(method)")
                let response = HTTPURLResponse(
                    url: responseURL,
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data())
            }
        }

        let tools = try await client.listTools()
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools.first?.exposedName, "mcp_howtocook_mcp_lookup_recipe")
        XCTAssertEqual(tools.first?.description, "[MCP:howtocook-mcp] Find a recipe")

        let result = try await client.callExposedTool(
            "mcp_howtocook_mcp_lookup_recipe",
            arguments: ["dish": .string("番茄炒蛋")]
        )
        XCTAssertEqual(result, "番茄炒蛋做法")
        await client.close()

        requestOrderLock.lock()
        let recordedMethods = requestMethods
        requestOrderLock.unlock()
        XCTAssertEqual(recordedMethods, ["initialize", "notifications/initialized", "tools/list", "tools/call"])
    }
}
