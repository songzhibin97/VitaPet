import EventBus
import XCTest

final class EventBusTests: XCTestCase {
    func testSubscribe_returnsUUID() async {
        let eventBus = EventBus()

        let subscriptionId = await eventBus.subscribe { _ in }

        XCTAssertNotEqual(subscriptionId, UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
    }

    func testPublish_dispatchesToSubscriber() async {
        let eventBus = EventBus()
        let received = expectation(description: "subscriber receives event")

        _ = await eventBus.subscribe { event in
            if case let .timerFired(id) = event, id == "timer" {
                received.fulfill()
            }
        }

        await eventBus.publish(.timerFired(id: "timer"))
        await fulfillment(of: [received], timeout: 1.0)
    }

    func testPublish_dispatchesToMultipleSubscribers() async {
        let eventBus = EventBus()
        let allReceived = expectation(description: "all subscribers receive event")
        allReceived.expectedFulfillmentCount = 3

        for _ in 0..<3 {
            _ = await eventBus.subscribe { event in
                if case .focusEntered = event {
                    allReceived.fulfill()
                }
            }
        }

        await eventBus.publish(.focusEntered)
        await fulfillment(of: [allReceived], timeout: 1.0)
    }

    func testFilteredSubscribe_onlyMatchingEventsDispatched() async {
        let eventBus = EventBus()
        let matched = expectation(description: "matching event received")

        _ = await eventBus.subscribe(
            matching: {
                if case .focusEntered = $0 { return true }
                return false
            }
        ) { event in
            if case .focusEntered = event {
                matched.fulfill()
            }
        }

        await eventBus.publish(.focusEntered)
        await fulfillment(of: [matched], timeout: 1.0)
    }

    func testFilteredSubscribe_nonMatchingEventsIgnored() async {
        let eventBus = EventBus()
        let notCalled = expectation(description: "non-matching event ignored")
        notCalled.isInverted = true

        _ = await eventBus.subscribe(
            matching: {
                if case .focusEntered = $0 { return true }
                return false
            }
        ) { _ in
            notCalled.fulfill()
        }

        await eventBus.publish(.focusExited)
        await fulfillment(of: [notCalled], timeout: 0.2)
    }

    func testUnsubscribe_removesHandler() async {
        let eventBus = EventBus()
        let notCalled = expectation(description: "unsubscribed handler not called")
        notCalled.isInverted = true

        let subscriptionId = await eventBus.subscribe { _ in
            notCalled.fulfill()
        }

        await eventBus.unsubscribe(subscriptionId)
        await eventBus.publish(.focusEntered)
        await fulfillment(of: [notCalled], timeout: 0.2)
    }

    func testPublishToEmptyBus_doesNotCrash() async {
        let eventBus = EventBus()

        await eventBus.publish(.focusEntered)
    }

    func testMultipleSubscriptions_independentUUIDs() async {
        let eventBus = EventBus()

        let first = await eventBus.subscribe { _ in }
        let second = await eventBus.subscribe { _ in }

        XCTAssertNotEqual(first, second)
    }
}
