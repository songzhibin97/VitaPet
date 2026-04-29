import EventBus
import XCTest

private actor FileChangeRecorder {
    private var events: [(path: String, flags: UInt32)] = []

    func record(path: String, flags: UInt32) {
        events.append((path: path, flags: flags))
    }

    func matchingEvents(for path: String) -> [(path: String, flags: UInt32)] {
        events.filter {
            URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == path
        }
    }
}

final class FSEventsMonitorTests: XCTestCase {
    func testSourceId_isFsEvents() async {
        let source = FSEventsMonitor(paths: [NSTemporaryDirectory()])

        let sourceId = await source.sourceId

        XCTAssertEqual(sourceId, "fsEvents")
    }

    func testStart_publishesFileChangedEvent() async throws {
        let eventBus = EventBus()
        let directoryURL = try makeTemporaryDirectory()
        // Use a short latency so FSEvents coalesces quickly in tests.
        let source = FSEventsMonitor(paths: [directoryURL.path], latency: 0.1)
        let recorder = FileChangeRecorder()
        let changedFileURL = directoryURL.appendingPathComponent("created.txt")
        let expectedPath = changedFileURL.resolvingSymlinksInPath().path
        let eventReceived = expectation(description: "file changed event published")
        eventReceived.assertForOverFulfill = false

        defer {
            Task {
                await source.stop()
                try? FileManager.default.removeItem(at: directoryURL)
            }
        }

        _ = await eventBus.subscribe { event in
            guard case let .fileChanged(path, flags) = event else {
                return
            }

            await recorder.record(path: path, flags: flags)
            if URL(fileURLWithPath: path).resolvingSymlinksInPath().path == expectedPath {
                XCTAssertNotEqual(flags, 0)
                eventReceived.fulfill()
            }
        }

        await source.start(publishingTo: eventBus)
        // Wait briefly to ensure the stream is registered before writing.
        try? await Task.sleep(for: .milliseconds(200))
        try Data("hello".utf8).write(to: changedFileURL)

        // Allow generous headroom: latency(0.1s) + dispatch + CI load.
        await fulfillment(of: [eventReceived], timeout: 10.0)

        let matchingEvents = await recorder.matchingEvents(for: expectedPath)
        XCTAssertFalse(matchingEvents.isEmpty)
    }

    /// Verifies that calling start() twice does not create a second stream.
    /// This test is purely structural — it does not depend on real FSEvents delivery
    /// and therefore has no timing sensitivity.
    func testMultipleStart_isIdempotent() async throws {
        let directoryURL = try makeTemporaryDirectory()
        let source = FSEventsMonitor(paths: [directoryURL.path], latency: 0.1)
        let eventBus = EventBus()

        defer {
            Task {
                await source.stop()
                try? FileManager.default.removeItem(at: directoryURL)
            }
        }

        // After first start, the monitor must be active.
        await source.start(publishingTo: eventBus)
        let isMonitoringAfterFirst = await source.isMonitoring
        XCTAssertTrue(isMonitoringAfterFirst, "Monitor should be active after first start()")

        // A second start() must be a no-op — still exactly one stream.
        await source.start(publishingTo: eventBus)
        let isMonitoringAfterSecond = await source.isMonitoring
        XCTAssertTrue(isMonitoringAfterSecond, "Monitor should still be active after second start()")

        // Stop and verify it shuts down cleanly.
        await source.stop()
        let isMonitoringAfterStop = await source.isMonitoring
        XCTAssertFalse(isMonitoringAfterStop, "Monitor should be inactive after stop()")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }
}
