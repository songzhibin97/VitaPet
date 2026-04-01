import AppKit
import XCTest
@testable import EventBus

@MainActor
private final class MonitorToken {}

@MainActor
private final class KeyboardMonitorHarness {
    var globalRegistrationCount = 0
    var localRegistrationCount = 0
    var removedMonitors: [ObjectIdentifier] = []
    var globalHandler: ((NSEvent) -> Void)?
    var localHandler: ((NSEvent) -> NSEvent?)?

    func makeMonitor() -> KeyboardMonitor {
        KeyboardMonitor(
            addGlobalMonitor: { [weak self] handler in
                self?.globalRegistrationCount += 1
                self?.globalHandler = handler
                return MonitorToken()
            },
            addLocalMonitor: { [weak self] handler in
                self?.localRegistrationCount += 1
                self?.localHandler = handler
                return MonitorToken()
            },
            removeMonitor: { [weak self] monitor in
                guard let token = monitor as? MonitorToken else {
                    return
                }

                self?.removedMonitors.append(ObjectIdentifier(token))
            }
        )
    }
}

private actor HotkeyRecorder {
    private var events: [(UInt16, UInt32)] = []

    func record(keyCode: UInt16, modifiers: UInt32) {
        events.append((keyCode, modifiers))
    }

    func all() -> [(UInt16, UInt32)] {
        events
    }
}

@MainActor
final class KeyboardMonitorTests: XCTestCase {
    func testSourceId_isKeyboard() async {
        let monitor = KeyboardMonitor()

        let sourceId = monitor.sourceId

        XCTAssertEqual(sourceId, "keyboard")
    }

    func testStartAndStop_registersMonitorsPublishesEventsAndIsIdempotent() async throws {
        let eventBus = EventBus()
        let harness = KeyboardMonitorHarness()
        let monitor = harness.makeMonitor()
        let recorder = HotkeyRecorder()
        let received = expectation(description: "hotkey events published")
        received.expectedFulfillmentCount = 2
        received.assertForOverFulfill = false

        _ = await eventBus.subscribe { event in
            guard case let .hotkeyPressed(keyCode, modifiers) = event else {
                return
            }

            await recorder.record(keyCode: keyCode, modifiers: modifiers)
            received.fulfill()
        }

        await monitor.start(publishingTo: eventBus)
        await monitor.start(publishingTo: eventBus)

        let registrationCounts = (harness.globalRegistrationCount, harness.localRegistrationCount)
        XCTAssertEqual(registrationCounts.0, 1)
        XCTAssertEqual(registrationCounts.1, 1)

        let globalEvent = try XCTUnwrap(makeKeyDownEvent(keyCode: 9, modifiers: [.command, .shift]))
        let localEvent = try XCTUnwrap(makeKeyDownEvent(keyCode: 1, modifiers: [.option]))

        harness.globalHandler?(globalEvent)
        let localResult = harness.localHandler?(localEvent)

        XCTAssertNotNil(localResult)
        await fulfillment(of: [received], timeout: 1.0)

        let recordedEvents = await recorder.all()
        XCTAssertEqual(recordedEvents.count, 2)
        XCTAssertTrue(
            recordedEvents.contains { keyCode, modifiers in
                keyCode == 9 &&
                    NSEvent.ModifierFlags(rawValue: UInt(modifiers))
                    .intersection(.deviceIndependentFlagsMask)
                    .isSuperset(of: [.command, .shift])
            }
        )
        XCTAssertTrue(
            recordedEvents.contains { keyCode, modifiers in
                keyCode == 1 &&
                    NSEvent.ModifierFlags(rawValue: UInt(modifiers))
                    .intersection(.deviceIndependentFlagsMask)
                    .contains(.option)
            }
        )

        let consumedResult = harness.localHandler?(globalEvent)
        XCTAssertNil(consumedResult)

        await monitor.stop()
        let removedCountAfterStop = harness.removedMonitors.count
        XCTAssertEqual(removedCountAfterStop, 2)

        await monitor.stop()
        let removedCountAfterSecondStop = harness.removedMonitors.count
        XCTAssertEqual(removedCountAfterSecondStop, 2)
    }

    private func makeKeyDownEvent(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "v",
            charactersIgnoringModifiers: "v",
            isARepeat: false,
            keyCode: keyCode
        )
    }
}
