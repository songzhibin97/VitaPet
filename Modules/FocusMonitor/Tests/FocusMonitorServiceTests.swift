import EventBus
import FocusMonitor
import XCTest

@MainActor
private final class MockFullscreenDetector: FullscreenDetecting {
    var isFullscreen: Bool = false

    func isAnyAppFullscreen() -> Bool {
        isFullscreen
    }
}

@MainActor
final class FocusMonitorServiceTests: XCTestCase {
    func testToggleFocusMode_fromNotFocused_publishesFocusEntered() async {
        let eventBus = EventBus()
        let detector = MockFullscreenDetector()
        let service = FocusMonitorService(eventBus: eventBus, detector: detector)
        let received = expectation(description: "focus entered published")

        _ = await eventBus.subscribe { event in
            if case .focusEntered = event {
                received.fulfill()
            }
        }

        service.toggleFocusMode()

        let result = await XCTWaiter.fulfillment(of: [received], timeout: 1.0)
        XCTAssertEqual(result, .completed)
    }

    func testToggleFocusMode_fromFocused_publishesFocusExited() async {
        let eventBus = EventBus()
        let detector = MockFullscreenDetector()
        let service = FocusMonitorService(eventBus: eventBus, detector: detector)
        let received = expectation(description: "focus exited published")

        _ = await eventBus.subscribe { event in
            if case .focusExited = event {
                received.fulfill()
            }
        }

        service.toggleFocusMode()
        service.toggleFocusMode()

        let result = await XCTWaiter.fulfillment(of: [received], timeout: 1.0)
        XCTAssertEqual(result, .completed)
    }

    func testToggleTwice_publishesBothEvents() async {
        let eventBus = EventBus()
        let detector = MockFullscreenDetector()
        let service = FocusMonitorService(eventBus: eventBus, detector: detector)
        let received = expectation(description: "both focus events published")
        received.expectedFulfillmentCount = 2

        _ = await eventBus.subscribe { event in
            switch event {
            case .focusEntered, .focusExited:
                received.fulfill()
            default:
                break
            }
        }

        service.toggleFocusMode()
        service.toggleFocusMode()

        let result = await XCTWaiter.fulfillment(of: [received], timeout: 1.0)
        XCTAssertEqual(result, .completed)
    }

    func testStop_cancelsPolling() async {
        let eventBus = EventBus()
        let detector = MockFullscreenDetector()
        let service = FocusMonitorService(eventBus: eventBus, detector: detector)
        let notCalled = expectation(description: "polling stopped before publish")
        notCalled.isInverted = true

        _ = await eventBus.subscribe { event in
            if case .focusEntered = event {
                notCalled.fulfill()
            }
        }

        service.start()
        detector.isFullscreen = true
        service.stop()

        let result = await XCTWaiter.fulfillment(of: [notCalled], timeout: 2.3)
        XCTAssertEqual(result, .completed)
    }

    func testStart_isIdempotent() async {
        let eventBus = EventBus()
        let detector = MockFullscreenDetector()
        let service = FocusMonitorService(eventBus: eventBus, detector: detector)
        let counter = LockedCounter()

        _ = await eventBus.subscribe { event in
            if case .focusEntered = event {
                await counter.increment()
            }
        }

        service.start()
        service.start()
        detector.isFullscreen = true
        try? await Task.sleep(for: .milliseconds(2300))
        service.stop()

        let value = await counter.value()
        XCTAssertEqual(value, 1)
    }

    func testInitialState_isNotInFocusMode() async {
        let eventBus = EventBus()
        let detector = MockFullscreenDetector()
        let service = FocusMonitorService(eventBus: eventBus, detector: detector)
        let firstEvent = expectation(description: "first toggle enters focus")

        _ = await eventBus.subscribe { event in
            if case .focusEntered = event {
                firstEvent.fulfill()
            }
        }

        service.toggleFocusMode()

        let result = await XCTWaiter.fulfillment(of: [firstEvent], timeout: 1.0)
        XCTAssertEqual(result, .completed)
    }
}

private actor LockedCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}
