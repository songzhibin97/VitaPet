import XCTest
@testable import EventBus

@MainActor
private final class TestPasteboard: ClipboardPasteboard {
    var changeCount: Int
    private var content: String?

    init(changeCount: Int = 0, content: String? = nil) {
        self.changeCount = changeCount
        self.content = content
    }

    func stringContent() -> String? {
        content
    }

    func update(content: String?) {
        changeCount += 1
        self.content = content
    }
}

private actor ClipboardEventRecorder {
    private var events: [String] = []

    func record(_ content: String) {
        events.append(content)
    }

    func all() -> [String] {
        events
    }
}

final class ClipboardMonitorTests: XCTestCase {
    func testSourceId_isClipboard() async {
        let pasteboard = await MainActor.run { TestPasteboard() }
        let monitor = await MainActor.run { ClipboardMonitor(pasteboard: pasteboard) }

        let sourceId = await monitor.sourceId

        XCTAssertEqual(sourceId, "clipboard")
    }

    func testStart_publishesClipboardChangedEventWhenContentChanges() async {
        let eventBus = EventBus()
        let pasteboard = await MainActor.run { TestPasteboard(content: "before") }
        let monitor = await MainActor.run {
            ClipboardMonitor(pasteboard: pasteboard, pollInterval: .milliseconds(50))
        }
        let recorder = ClipboardEventRecorder()
        let received = expectation(description: "clipboard changed event published")

        _ = await eventBus.subscribe { event in
            guard case let .clipboardChanged(content) = event else {
                return
            }

            await recorder.record(content)
            received.fulfill()
        }

        await monitor.start(publishingTo: eventBus)
        await MainActor.run {
            pasteboard.update(content: "after")
        }

        await fulfillment(of: [received], timeout: 1.0)
        await monitor.stop()

        let events = await recorder.all()
        XCTAssertEqual(events, ["after"])
    }

    func testStart_truncatesClipboardContentTo500Characters() async {
        let eventBus = EventBus()
        let pasteboard = await MainActor.run { TestPasteboard() }
        let monitor = await MainActor.run {
            ClipboardMonitor(pasteboard: pasteboard, pollInterval: .milliseconds(50))
        }
        let received = expectation(description: "truncated clipboard event published")
        let longContent = String(repeating: "a", count: 700)
        let expected = String(longContent.prefix(500))

        _ = await eventBus.subscribe { event in
            guard case let .clipboardChanged(content) = event else {
                return
            }

            XCTAssertEqual(content, expected)
            received.fulfill()
        }

        await monitor.start(publishingTo: eventBus)
        await MainActor.run {
            pasteboard.update(content: longContent)
        }

        await fulfillment(of: [received], timeout: 1.0)
        await monitor.stop()
    }

    func testStop_cancelsPollingAndMultipleStart_isIdempotent() async {
        let eventBus = EventBus()
        let pasteboard = await MainActor.run { TestPasteboard() }
        let monitor = await MainActor.run {
            ClipboardMonitor(pasteboard: pasteboard, pollInterval: .milliseconds(50))
        }
        let recorder = ClipboardEventRecorder()
        let firstEvent = expectation(description: "first clipboard event published")

        _ = await eventBus.subscribe { event in
            guard case let .clipboardChanged(content) = event else {
                return
            }

            await recorder.record(content)
            firstEvent.fulfill()
        }

        await monitor.start(publishingTo: eventBus)
        await monitor.start(publishingTo: eventBus)
        await MainActor.run {
            pasteboard.update(content: "first")
        }

        await fulfillment(of: [firstEvent], timeout: 1.0)
        await monitor.stop()

        await MainActor.run {
            pasteboard.update(content: "second")
        }
        try? await Task.sleep(for: .milliseconds(150))

        let events = await recorder.all()
        XCTAssertEqual(events, ["first"])
    }
}
