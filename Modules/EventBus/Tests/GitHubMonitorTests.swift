import Foundation
import XCTest
@testable import EventBus

private final class GitHubMonitorURLProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.invalid")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("[]".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset() {
        lock.lock()
        requests = []
        lock.unlock()
    }

    static func recordedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

final class GitHubMonitorTests: XCTestCase {
    override func setUp() {
        super.setUp()
        GitHubMonitorURLProtocol.reset()
    }

    func testSourceId() async {
        let monitor = GitHubMonitor(tokenProvider: { "" })

        let sourceId = monitor.sourceId

        XCTAssertEqual(sourceId, "githubMonitor")
    }

    func testStart_withoutToken_doesNotIssueRequests() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubMonitorURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let monitor = GitHubMonitor(session: session, tokenProvider: { "" })

        await monitor.start(publishingTo: EventBus())
        try? await Task.sleep(for: .milliseconds(150))
        await monitor.stop()

        XCTAssertTrue(GitHubMonitorURLProtocol.recordedRequests().isEmpty)
    }

    func testStartStop_lifecycleDoesNotCrash() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubMonitorURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let monitor = GitHubMonitor(session: session, tokenProvider: { "  " })

        await monitor.start(publishingTo: EventBus())
        await monitor.stop()
    }
}
