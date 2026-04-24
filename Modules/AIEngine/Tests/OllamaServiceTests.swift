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

        await service.updateConfig(endpoint: newEndpoint, model: "qwen2.5", backend: .openAICompatible)

        let config = await service.configSnapshot()
        XCTAssertEqual(config.endpoint, newEndpoint)
        XCTAssertEqual(config.model, "qwen2.5")
        let backend = await service.backendSnapshot()
        XCTAssertEqual(backend, .openAICompatible)
    }
}
