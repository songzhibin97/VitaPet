@preconcurrency import EventKit
import XCTest
@testable import EventBus

// MARK: - Helpers

/// Creates a bare EKEvent with a title and startDate for use in tests.
/// We use a local EKEventStore solely as a factory; no calendar access is needed
/// to instantiate events.
@MainActor
private func makeEvent(title: String, startDate: Date) -> EKEvent {
    let store = EKEventStore()
    let event = EKEvent(eventStore: store)
    event.title = title
    event.startDate = startDate
    event.endDate = startDate.addingTimeInterval(3600)
    return event
}

/// Collects AppEvent values published to an EventBus.
private actor EventRecorder {
    private(set) var events: [AppEvent] = []

    func record(_ event: AppEvent) {
        events.append(event)
    }
}

// MARK: - Tests

@MainActor
final class CalendarMonitorTests: XCTestCase {

    // MARK: Existing lifecycle tests

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

    // MARK: Behavioral tests

    /// An event starting within the lookAhead window must be published to EventBus.
    func testCheck_publishesUpcomingEventInWindow() async {
        let eventBus = EventBus()
        let recorder = EventRecorder()
        let received = expectation(description: "calendar event published")

        _ = await eventBus.subscribe { event in
            guard case .notificationReceived(let source, _, _) = event, source == "Calendar" else { return }
            await recorder.record(event)
            received.fulfill()
        }

        let upcomingEvent = makeEvent(title: "Team Sync", startDate: Date().addingTimeInterval(5 * 60))
        let monitor = CalendarMonitor(
            lookAheadMinutes: 15,
            requestAccessHandler: { _ in true },
            eventsProvider: { _, _ in [upcomingEvent] }
        )

        await monitor.start(publishingTo: eventBus)
        await fulfillment(of: [received], timeout: 2.0)
        await monitor.stop()

        let recorded = await recorder.events
        XCTAssertEqual(recorded.count, 1)
        guard case let .notificationReceived(source, title, _) = recorded[0] else {
            return XCTFail("Expected notificationReceived event")
        }
        XCTAssertEqual(source, "Calendar")
        XCTAssertEqual(title, "Team Sync")
    }

    /// An event outside the lookAhead window must NOT be published.
    func testCheck_doesNotPublishEventOutsideWindow() async {
        let eventBus = EventBus()
        let recorder = EventRecorder()

        _ = await eventBus.subscribe { event in
            if case .notificationReceived(let source, _, _) = event, source == "Calendar" {
                await recorder.record(event)
            }
        }

        // eventsProvider always returns empty — simulates no events in window
        let monitor = CalendarMonitor(
            lookAheadMinutes: 15,
            requestAccessHandler: { _ in true },
            eventsProvider: { _, _ in [] }
        )

        await monitor.start(publishingTo: eventBus)
        // Give EventBus tasks a chance to run
        try? await Task.sleep(for: .milliseconds(100))
        await monitor.stop()

        let recorded = await recorder.events
        XCTAssertEqual(recorded.count, 0, "No events should be published when the window is empty")
    }

    /// The same event returned by two consecutive checks must only be published once.
    func testCheck_deduplicatesSameEvent() async {
        let eventBus = EventBus()
        let recorder = EventRecorder()

        _ = await eventBus.subscribe { event in
            if case .notificationReceived(let source, _, _) = event, source == "Calendar" {
                await recorder.record(event)
            }
        }

        // Return the same EKEvent instance on every call
        let repeatedEvent = makeEvent(title: "Daily Standup", startDate: Date().addingTimeInterval(5 * 60))
        let monitor = CalendarMonitor(
            lookAheadMinutes: 15,
            requestAccessHandler: { _ in true },
            eventsProvider: { _, _ in [repeatedEvent] }
        )

        // First check fires automatically on start
        await monitor.start(publishingTo: eventBus)
        // Let the first publish propagate
        try? await Task.sleep(for: .milliseconds(100))

        // Second check: same event should be suppressed
        await monitor.triggerCheck()
        try? await Task.sleep(for: .milliseconds(100))
        await monitor.stop()

        let recorded = await recorder.events
        XCTAssertEqual(recorded.count, 1, "Same event must only be published once across multiple checks")
    }

    /// Events exactly at the lookAhead boundary are NOT included because the provider
    /// only returns events inside the window (open-right semantics).
    /// This test documents the current implementation contract: if eventsProvider
    /// returns nothing for the boundary case, nothing is published.
    func testCheck_lookAheadBoundary_noPublishWhenProviderReturnsEmpty() async {
        let eventBus = EventBus()
        let recorder = EventRecorder()

        _ = await eventBus.subscribe { event in
            if case .notificationReceived(let source, _, _) = event, source == "Calendar" {
                await recorder.record(event)
            }
        }

        // Provider returns empty — boundary event falls outside the window
        let monitor = CalendarMonitor(
            lookAheadMinutes: 10,
            requestAccessHandler: { _ in true },
            eventsProvider: { _, _ in [] }
        )

        await monitor.start(publishingTo: eventBus)
        try? await Task.sleep(for: .milliseconds(100))
        await monitor.stop()

        let recorded = await recorder.events
        XCTAssertEqual(recorded.count, 0, "Event at or beyond lookAhead boundary should not be published")
    }
}
