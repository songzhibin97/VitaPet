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
        let source = FSEventsMonitor(paths: [directoryURL.path])
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
        try? await Task.sleep(for: .milliseconds(300))
        try Data("hello".utf8).write(to: changedFileURL)

        await fulfillment(of: [eventReceived], timeout: 5.0)

        let matchingEvents = await recorder.matchingEvents(for: expectedPath)
        XCTAssertFalse(matchingEvents.isEmpty)
    }

    func testMultipleStart_isIdempotent() async throws {
        let eventBus = EventBus()
        let directoryURL = try makeTemporaryDirectory()
        let source = FSEventsMonitor(paths: [directoryURL.path])
        let recorder = FileChangeRecorder()
        let changedFileURL = directoryURL.appendingPathComponent("duplicate-check.txt")
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
                eventReceived.fulfill()
            }
        }

        await source.start(publishingTo: eventBus)
        await source.start(publishingTo: eventBus)
        try? await Task.sleep(for: .milliseconds(300))
        try Data("hello".utf8).write(to: changedFileURL)

        await fulfillment(of: [eventReceived], timeout: 5.0)
        try? await Task.sleep(for: .milliseconds(500))
        await source.stop()

        let matchingEvents = await recorder.matchingEvents(for: expectedPath)
        XCTAssertLessThanOrEqual(matchingEvents.count, 3)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }
}
