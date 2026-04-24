@testable import AIEngine
import Foundation
import XCTest

private final class MemoryWorkerURLProtocol: URLProtocol, @unchecked Sendable {
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

    static func install(handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)) {
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

final class MemoryWorkerServiceTests: XCTestCase {
    private let placeholderMemoryWorkerEndpoint = "https://memory.example.com"

    override func tearDown() {
        MemoryWorkerURLProtocol.uninstall()
        super.tearDown()
    }

    func testQueryMemories_usesBasicAuthAndParsesItems() async throws {
        let requestObserved = expectation(description: "query request observed")

        MemoryWorkerURLProtocol.install { request in
            XCTAssertEqual(request.url?.absoluteString, "https://memory.example.com/api/memories/query")
            XCTAssertEqual(request.httpMethod, "POST")

            let expectedAuth = "Basic \(Data("tester:demo-pass".utf8).base64EncodedString())"
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), expectedAuth)

            let body = try XCTUnwrap(request.bodyDataForTesting())
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(object["scope"] as? String, "user")
            XCTAssertEqual(object["subject"] as? String, "demo-user")
            XCTAssertEqual(object["q"] as? String, "concise")
            XCTAssertEqual(object["limit"] as? Int, 5)
            requestObserved.fulfill()

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let payload = Data(
                """
                {
                  "item": null,
                  "items": [
                    { "id": 101, "content": "User prefers concise Chinese responses." }
                  ],
                  "count": 1,
                  "limit": 5,
                  "filters": {}
                }
                """.utf8
            )
            return (response, payload)
        }

        let service = MemoryWorkerService(
            config: MemoryWorkerConfig(
                enabled: true,
                endpoint: placeholderMemoryWorkerEndpoint,
                authMode: .basic,
                username: "tester",
                secret: "demo-pass",
                scope: "user",
                subject: "demo-user",
                queryLimit: 5
            )
        )

        let items = try await service.queryMemories(q: "concise")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, 101)
        XCTAssertEqual(items.first?.content, "User prefers concise Chinese responses.")

        await fulfillment(of: [requestObserved], timeout: 1.0)
    }

    func testCreateMemory_usesBearerTokenAndReturnsItem() async throws {
        let requestObserved = expectation(description: "create request observed")

        MemoryWorkerURLProtocol.install { request in
            XCTAssertEqual(request.url?.absoluteString, "https://memory.example.com/api/memories")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer demo-bearer")

            let body = try XCTUnwrap(request.bodyDataForTesting())
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(object["scope"] as? String, "user")
            XCTAssertEqual(object["subject"] as? String, "demo-user")
            XCTAssertEqual(object["content"] as? String, "User likes pomodoro mode")
            XCTAssertEqual(object["horizon"] as? String, "daily")
            requestObserved.fulfill()

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 201,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let payload = Data(
                """
                {
                  "item": {
                    "id": 202,
                    "content": "User likes pomodoro mode"
                  }
                }
                """.utf8
            )
            return (response, payload)
        }

        let service = MemoryWorkerService(
            config: MemoryWorkerConfig(
                enabled: true,
                endpoint: placeholderMemoryWorkerEndpoint,
                authMode: .bearer,
                username: "",
                secret: "demo-bearer",
                scope: "user",
                subject: "demo-user"
            )
        )

        let item = try await service.createMemory(content: "User likes pomodoro mode")
        XCTAssertEqual(item.id, 202)
        XCTAssertEqual(item.content, "User likes pomodoro mode")

        await fulfillment(of: [requestObserved], timeout: 1.0)
    }

    func testCreateMemory_acceptsFlatJSONWithStringId() async throws {
        MemoryWorkerURLProtocol.install { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let payload = Data(
                """
                {"id":"99","content":"Flat body shape"}
                """.utf8
            )
            return (response, payload)
        }

        let service = MemoryWorkerService(
            config: MemoryWorkerConfig(
                enabled: true,
                endpoint: "https://memory.example.com",
                authMode: .basic,
                username: "u",
                secret: "p",
                subject: "s"
            )
        )

        let item = try await service.createMemory(content: "Flat body shape")
        XCTAssertEqual(item.id, 99)
        XCTAssertEqual(item.content, "Flat body shape")
    }

    func testCreateMemory_acceptsDataWrappedItem() async throws {
        MemoryWorkerURLProtocol.install { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 201,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let payload = Data(
                """
                {"data":{"id":7,"content":"Wrapped"}}
                """.utf8
            )
            return (response, payload)
        }

        let service = MemoryWorkerService(
            config: MemoryWorkerConfig(
                enabled: true,
                endpoint: "https://memory.example.com",
                authMode: .bearer,
                secret: "t",
                subject: "s"
            )
        )

        let item = try await service.createMemory(content: "Wrapped")
        XCTAssertEqual(item.id, 7)
        XCTAssertEqual(item.content, "Wrapped")
    }

    func testCreateMemory_acceptsOkBooleanWithoutNestedItem() async throws {
        MemoryWorkerURLProtocol.install { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let payload = Data(#"{"ok":true,"id":42}"#.utf8)
            return (response, payload)
        }

        let service = MemoryWorkerService(
            config: MemoryWorkerConfig(
                enabled: true,
                endpoint: "https://memory.example.com",
                authMode: .basic,
                username: "u",
                secret: "p",
                subject: "s"
            )
        )

        let item = try await service.createMemory(content: "用户喜欢测试")
        XCTAssertEqual(item.id, 42)
        XCTAssertEqual(item.content, "用户喜欢测试")
    }

    func testCreateMemory_emptyBodyUsesRequestContent() async throws {
        MemoryWorkerURLProtocol.install { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 204,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        let service = MemoryWorkerService(
            config: MemoryWorkerConfig(
                enabled: true,
                endpoint: "https://memory.example.com",
                authMode: .basic,
                username: "u",
                secret: "p",
                subject: "s"
            )
        )

        let item = try await service.createMemory(content: "No JSON body")
        XCTAssertNil(item.id)
        XCTAssertEqual(item.content, "No JSON body")
    }

    func testQueryMemories_acceptsFullQueryEndpointAsBase() async throws {
        let requestObserved = expectation(description: "query request observed for full endpoint")

        MemoryWorkerURLProtocol.install { request in
            XCTAssertEqual(request.url?.absoluteString, "https://memory.example.com/api/memories/query")
            requestObserved.fulfill()

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let payload = Data(
                """
                {
                  "item": null,
                  "items": [],
                  "count": 0,
                  "limit": 5,
                  "filters": {}
                }
                """.utf8
            )
            return (response, payload)
        }

        let service = MemoryWorkerService(
            config: MemoryWorkerConfig(
                enabled: true,
                endpoint: "https://memory.example.com/api/memories/query",
                authMode: .basic,
                username: "tester",
                secret: "demo-pass",
                scope: "user",
                subject: "demo-user",
                queryLimit: 5
            )
        )

        _ = try await service.queryMemories(q: "test")
        await fulfillment(of: [requestObserved], timeout: 1.0)
    }
}
