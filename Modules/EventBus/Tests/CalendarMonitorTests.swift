import XCTest
@testable import EventBus

@MainActor
final class CalendarMonitorTests: XCTestCase {
    func testSourceId() {
        let monitor = CalendarMonitor()

        XCTAssertEqual(monitor.sourceId, "calendarMonitor")
    }

    func testStartStop_lifecycleDoesNotCrashWithoutPermissions() async {
        let monitor = CalendarMonitor()

        await monitor.start(publishingTo: EventBus())
        await monitor.stop()
    }

    func testStop_isIdempotent() async {
        let monitor = CalendarMonitor()

        await monitor.stop()
        await monitor.stop()
    }
}
