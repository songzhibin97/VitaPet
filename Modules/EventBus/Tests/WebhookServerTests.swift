import Foundation
import XCTest
@testable import EventBus

private actor WebhookEventRecorder {
    private var notifications: [(source: String, title: String, body: String)] = []
    private var customActions: [String] = []

    func recordNotification(source: String, title: String, body: String) {
        notifications.append((source, title, body))
    }

    func recordCustomAction(_ name: String) {
        customActions.append(name)
    }

    func recordedNotifications() -> [(source: String, title: String, body: String)] {
        notifications
    }

    func recordedActions() -> [String] {
        customActions
    }
}

final class WebhookServerTests: XCTestCase {
    func testStart_receivesWebhookAndPublishesEvents() async throws {
        let eventBus = EventBus()
        let port = UInt16(Int.random(in: 20000...40000))
        let server = WebhookServer(port: port)
        let recorder = WebhookEventRecorder()
        let notificationReceived = expectation(description: "notification event published")
        let customReceived = expectation(description: "custom action published")

        _ = await eventBus.subscribe { event in
            switch event {
            case let .notificationReceived(source, title, body):
                await recorder.recordNotification(source: source, title: title, body: body)
                notificationReceived.fulfill()
            case let .custom(name, _):
                await recorder.recordCustomAction(name)
                customReceived.fulfill()
            default:
                break
            }
        }

        await server.start(publishingTo: eventBus)
        try? await Task.sleep(for: .milliseconds(150))

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/webhook")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = #"{"title":"Build Complete","body":"Webhook payload","action":"celebrate"}"#.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"status":"ok"}"#)

        await fulfillment(of: [notificationReceived, customReceived], timeout: 2.0)
        await server.stop()

        let notifications = await recorder.recordedNotifications()
        let actions = await recorder.recordedActions()
        XCTAssertEqual(notifications.count, 1)
        XCTAssertEqual(notifications.first?.source, "Webhook")
        XCTAssertEqual(notifications.first?.title, "Build Complete")
        XCTAssertEqual(notifications.first?.body, "Webhook payload")
        XCTAssertEqual(actions, ["celebrate"])
    }

    func testCorrectSecretAllowsRequest() async throws {
        let eventBus = EventBus()
        let port = UInt16(Int.random(in: 20000...40000))
        let server = WebhookServer(port: port, secret: "test-secret-123")
        let recorder = WebhookEventRecorder()
        let received = expectation(description: "event received")

        _ = await eventBus.subscribe { event in
            if case .notificationReceived = event {
                await recorder.recordNotification(source: "Webhook", title: "", body: "")
                received.fulfill()
            }
        }

        await server.start(publishingTo: eventBus)
        try? await Task.sleep(for: .milliseconds(150))

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/webhook")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("test-secret-123", forHTTPHeaderField: "X-Webhook-Secret")
        request.httpBody = #"{"title":"OK","body":"with secret"}"#.data(using: .utf8)

        let (_, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 200)

        await fulfillment(of: [received], timeout: 2.0)
        await server.stop()

        let notifications = await recorder.recordedNotifications()
        XCTAssertEqual(notifications.count, 1)
    }

    func testWrongSecretRejectsRequest() async throws {
        let eventBus = EventBus()
        let port = UInt16(Int.random(in: 20000...40000))
        let server = WebhookServer(port: port, secret: "correct-secret")

        await server.start(publishingTo: eventBus)
        try? await Task.sleep(for: .milliseconds(150))

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/webhook")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("wrong-secret", forHTTPHeaderField: "X-Webhook-Secret")
        request.httpBody = #"{"title":"Blocked","body":"should fail"}"#.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 401)
        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"error":"invalid secret"}"#)

        await server.stop()
    }

    func testMissingSecretRejectsRequest() async throws {
        let eventBus = EventBus()
        let port = UInt16(Int.random(in: 20000...40000))
        let server = WebhookServer(port: port, secret: "my-secret")

        await server.start(publishingTo: eventBus)
        try? await Task.sleep(for: .milliseconds(150))

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/webhook")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // No X-Webhook-Secret header
        request.httpBody = #"{"title":"NoSecret","body":"missing"}"#.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 401)
        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"error":"invalid secret"}"#)

        await server.stop()
    }

    func testWrongPathReturns404() async throws {
        let eventBus = EventBus()
        let port = UInt16(Int.random(in: 20000...40000))
        let server = WebhookServer(port: port)

        await server.start(publishingTo: eventBus)
        try? await Task.sleep(for: .milliseconds(150))

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/wrong")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = #"{"title":"test"}"#.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 404)
        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"error":"not found"}"#)

        await server.stop()
    }

    func testInvalidJSONReturns400() async throws {
        let eventBus = EventBus()
        let port = UInt16(Int.random(in: 20000...40000))
        let server = WebhookServer(port: port)

        await server.start(publishingTo: eventBus)
        try? await Task.sleep(for: .milliseconds(150))

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/webhook")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = "not json at all".data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 400)
        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"error":"invalid json"}"#)

        await server.stop()
    }

    func testStop_isSafeBeforeStart() async {
        let server = WebhookServer(port: UInt16(Int.random(in: 20000...40000)))
        await server.stop()
    }
}
