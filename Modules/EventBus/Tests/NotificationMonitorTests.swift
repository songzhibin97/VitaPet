import Foundation
import XCTest
@testable import EventBus

@MainActor
final class NotificationMonitorTests: XCTestCase {
    func testSourceId() {
        let monitor = NotificationMonitor()

        XCTAssertEqual(monitor.sourceId, "notificationMonitor")
    }

    func testStartStop_lifecycleDoesNotCrash() async {
        let monitor = NotificationMonitor()

        await monitor.start(publishingTo: EventBus())
        await monitor.stop()
    }

    func testStart_isIdempotent() async {
        let monitor = NotificationMonitor()
        let eventBus = EventBus()

        await monitor.start(publishingTo: eventBus)
        await monitor.start(publishingTo: eventBus)
        await monitor.stop()
    }

    func testStop_thenCanStartAgain() async {
        let monitor = NotificationMonitor()
        let eventBus = EventBus()

        await monitor.start(publishingTo: eventBus)
        await monitor.stop()
        await monitor.start(publishingTo: eventBus)
        await monitor.stop()
    }
}
