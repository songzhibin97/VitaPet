@testable import AIEngine
import Foundation
import XCTest

// MARK: - Mock URLProtocol (synchronous response)

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
    }

    static func uninstall() {
        lock.lock()
        requestHandler = nil
        lock.unlock()
    }
}

// MARK: - Hanging URLProtocol (never responds — used for cancel/timeout tests)

private final class HangingURLProtocol: URLProtocol, @unchecked Sendable {
    // stopLoading is called when the task is cancelled; we signal that via this nonisolated-unsafe flag.
    nonisolated(unsafe) static var didStop = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // Intentionally do nothing — the request hangs forever until cancelled.
    }

    override func stopLoading() {
        Self.didStop = true
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }
}

// MARK: - Test helpers

private func makeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [OllamaServiceURLProtocol.self]
    return URLSession(configuration: config)
}

private func makeHangingSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [HangingURLProtocol.self]
    return URLSession(configuration: config)
}

// MARK: - Helpers

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

// MARK: - Tests

final class OllamaServiceTests: XCTestCase {
    override func tearDown() {
        OllamaServiceURLProtocol.uninstall()
        HangingURLProtocol.didStop = false
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
        let session = makeMockSession()
        let service = OllamaService(
            endpoint: URL(string: "http://unit.test")!,
            model: "llama3.2",
            urlSession: session
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
        let (_, stream) = try await service.send(message: "记住我了吗")
        for try await _ in stream {}

        await fulfillment(of: [chatRequestObserved], timeout: 1.0)
    }

    func testSetOnConversationUpdated_recordsCallbackWhenConversationIsRecorded() async throws {
        let session = makeMockSession()
        let service = OllamaService(
            endpoint: URL(string: "http://unit.test")!,
            model: "llama3.2",
            urlSession: session
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

        let (_, stream) = try await service.send(message: "你好")
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

    func testUpdateConfig() async {
        let service = OllamaService(
            endpoint: URL(string: "http://localhost:11434")!,
            model: "llama3.2"
        )
        let newEndpoint = URL(string: "http://127.0.0.1:11435")!

        await service.updateConfig(endpoint: newEndpoint, model: "qwen2.5")

        let config = await service.configSnapshot()
        XCTAssertEqual(config.endpoint, newEndpoint)
        XCTAssertEqual(config.model, "qwen2.5")
    }

    // MARK: - New cancel / timeout tests

    /// send() returns a streamID; the activeStreams dictionary should contain it while streaming.
    func testSendReturnsStreamID_activeStreamIsRegistered() async throws {
        // Use a hanging session so the stream stays open long enough to inspect.
        let session = makeHangingSession()
        let service = OllamaService(
            endpoint: URL(string: "http://unit.test")!,
            model: "llama3.2",
            urlSession: session
        )
        // Force status to ready so send() doesn't call checkConnection (which would also hang).
        await service.forceReadyStatusForTesting()

        let streamID = try await { () async throws -> UUID in
            let (id, _) = try await service.send(message: "hello")
            return id
        }()

        // Give the internal Task a moment to register itself.
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        let isRegistered = await service.isStreamRegistered(streamID)
        XCTAssertTrue(isRegistered, "Active stream should be registered with the returned streamID")

        // Cleanup
        await service.cancel(streamID: streamID)
    }

    /// cancel(streamID:) causes the downstream async-for loop to throw CancellationError or finish.
    func testCancelStopsStream() async throws {
        let session = makeHangingSession()
        let service = OllamaService(
            endpoint: URL(string: "http://unit.test")!,
            model: "llama3.2",
            urlSession: session
        )
        await service.forceReadyStatusForTesting()

        let (streamID, stream) = try await service.send(message: "hello")
        // Give the internal Task time to register.
        try await Task.sleep(nanoseconds: 50_000_000)

        // Cancel in the background while iterating.
        Task {
            try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
            await service.cancel(streamID: streamID)
        }

        var didTerminate = false
        do {
            for try await _ in stream {
                // no chunks expected from a hanging protocol
            }
            didTerminate = true
        } catch {
            // CancellationError or URLError.cancelled — both are acceptable.
            didTerminate = true
        }

        XCTAssertTrue(didTerminate, "Stream should terminate after cancel(streamID:) is called")
        let isStillRegistered = await service.isStreamRegistered(streamID)
        XCTAssertFalse(isStillRegistered, "Cancelled stream should be removed from activeStreams")
    }

    /// cancelAll() terminates all active streams simultaneously.
    func testCancelAll_terminatesBothStreams() async throws {
        let session = makeHangingSession()
        let service = OllamaService(
            endpoint: URL(string: "http://unit.test")!,
            model: "llama3.2",
            urlSession: session
        )
        await service.forceReadyStatusForTesting()

        let (id1, stream1) = try await service.send(message: "msg1")
        let (id2, stream2) = try await service.send(message: "msg2")
        try await Task.sleep(nanoseconds: 50_000_000)

        let reg1Before = await service.isStreamRegistered(id1)
        let reg2Before = await service.isStreamRegistered(id2)
        XCTAssertTrue(reg1Before)
        XCTAssertTrue(reg2Before)

        await service.cancelAll()

        // Both streams should terminate.
        let terminated1 = await drainStream(stream1)
        let terminated2 = await drainStream(stream2)
        XCTAssertTrue(terminated1, "Stream 1 should terminate after cancelAll()")
        XCTAssertTrue(terminated2, "Stream 2 should terminate after cancelAll()")

        let reg1After = await service.isStreamRegistered(id1)
        let reg2After = await service.isStreamRegistered(id2)
        XCTAssertFalse(reg1After)
        XCTAssertFalse(reg2After)
    }

    /// When the URLSession times out, the stream propagates the error to consumers.
    func testTimeoutError_propagatesToStream() async throws {
        // Use a very short request timeout so the test finishes quickly.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HangingURLProtocol.self]
        config.timeoutIntervalForRequest = 0.1 // 100ms
        let shortTimeoutSession = URLSession(configuration: config)

        let service = OllamaService(
            endpoint: URL(string: "http://unit.test")!,
            model: "llama3.2",
            urlSession: shortTimeoutSession
        )
        await service.forceReadyStatusForTesting()

        let (_, stream) = try await service.send(message: "timeout test")

        var caughtError: Error?
        do {
            for try await _ in stream {}
        } catch {
            caughtError = error
        }

        XCTAssertNotNil(caughtError, "Stream should throw an error on timeout")
        // URLError.timedOut or URLError.cancelled both indicate the stream ended due to timeout/cancel.
        if let urlError = caughtError as? URLError {
            XCTAssertTrue(
                urlError.code == .timedOut || urlError.code == .cancelled,
                "Expected timedOut or cancelled, got \(urlError.code)"
            )
        }
        // If it's another error type, we just verify it's non-nil — timeout manifested.
    }
}

// MARK: - Test-only drain helper

private func drainStream(_ stream: AsyncThrowingStream<String, Error>) async -> Bool {
    do {
        for try await _ in stream {}
        return true
    } catch {
        return true // terminated via error — still counts as terminated
    }
}
