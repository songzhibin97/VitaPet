import EventBus
import XCTest

private actor EventCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }

    func current() -> Int {
        count
    }
}

final class TimerSourceTests: XCTestCase {
    func testSourceId_isTimer() async {
        let source = TimerSource()

        let sourceId = await source.sourceId

        XCTAssertEqual(sourceId, "timer")
    }

    func testStart_publishesTimerFiredEvent() async {
        let eventBus = EventBus()
        let source = TimerSource(interval: 0.1)
        let received = expectation(description: "timer fired event published")
        received.assertForOverFulfill = false
        let counter = EventCounter()

        _ = await eventBus.subscribe { event in
            if case let .timerFired(id) = event, id == "timer" {
                await counter.increment()
                received.fulfill()
            }
        }

        await source.start(publishingTo: eventBus)
        await fulfillment(of: [received], timeout: 0.5)
        await source.stop()

        let count = await counter.current()
        XCTAssertGreaterThanOrEqual(count, 1)
    }

    func testStop_cancelsEventDelivery() async {
        let eventBus = EventBus()
        let source = TimerSource(interval: 0.1)
        let counter = EventCounter()
        let firstEvent = expectation(description: "first timer event")
        firstEvent.assertForOverFulfill = false

        _ = await eventBus.subscribe { event in
            if case .timerFired = event {
                await counter.increment()
                firstEvent.fulfill()
            }
        }

        await source.start(publishingTo: eventBus)
        await fulfillment(of: [firstEvent], timeout: 0.2)
        try? await Task.sleep(for: .milliseconds(200))
        await source.stop()

        let countAfterStop = await counter.current()
        try? await Task.sleep(for: .milliseconds(300))

        let finalCount = await counter.current()
        // Allow at most 1 extra event due to async dispatch race
        XCTAssertLessThanOrEqual(finalCount - countAfterStop, 1, "No significant new events should arrive after stop")
    }

    func testMultipleStart_isIdempotent() async {
        let eventBus = EventBus()
        let source = TimerSource(interval: 0.05)
        let counter = EventCounter()
        let enoughEvents = expectation(description: "single timer produces events")
        enoughEvents.expectedFulfillmentCount = 3
        enoughEvents.assertForOverFulfill = false

        _ = await eventBus.subscribe { event in
            if case .timerFired = event {
                await counter.increment()
                enoughEvents.fulfill()
            }
        }

        await source.start(publishingTo: eventBus)
        await source.start(publishingTo: eventBus)
        await fulfillment(of: [enoughEvents], timeout: 0.4)
        try? await Task.sleep(for: .milliseconds(120))
        await source.stop()

        let count = await counter.current()
        XCTAssertLessThanOrEqual(count, 6)
    }
}
