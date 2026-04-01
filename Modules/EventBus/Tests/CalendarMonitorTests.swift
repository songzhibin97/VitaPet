import XCTest
@testable import EventBus

@MainActor
final class CalendarMonitorTests: XCTestCase {
    func testSourceId() {
        let monitor = CalendarMonitor(requestAccessHandler: { _ in false })

        XCTAssertEqual(monitor.sourceId, "calendarMonitor")
    }

    func testStartStop_lifecycleDoesNotCrashWithoutPermissions() async {
        let monitor = CalendarMonitor(requestAccessHandler: { _ in false })

        await monitor.start(publishingTo: EventBus())
        await monitor.stop()
    }

    func testStop_isIdempotent() async {
        let monitor = CalendarMonitor(requestAccessHandler: { _ in false })

        await monitor.stop()
        await monitor.stop()
    }
}
