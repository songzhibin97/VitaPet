import EventBus
import PluginProtocols
import XCTest
@testable import PluginRuntime

final class AppEventBridgeTests: XCTestCase {
    func testAppActivatedRoundtrip() async {
        let event = AppEvent.appActivated(bundleId: "com.apple.finder", appName: "Finder")
        let result = roundtrip(event)

        guard case let .appActivated(bundleId, appName)? = result else {
            return XCTFail("Unexpected event: \(String(describing: result))")
        }
        XCTAssertEqual(bundleId, "com.apple.finder")
        XCTAssertEqual(appName, "Finder")
    }

    func testAppDeactivatedRoundtrip() async {
        let event = AppEvent.appDeactivated(bundleId: "com.apple.dt.Xcode", appName: "Xcode")
        let result = roundtrip(event)

        guard case let .appDeactivated(bundleId, appName)? = result else {
            return XCTFail("Unexpected event: \(String(describing: result))")
        }
        XCTAssertEqual(bundleId, "com.apple.dt.Xcode")
        XCTAssertEqual(appName, "Xcode")
    }

    func testTimerFiredRoundtrip() async {
        let event = AppEvent.timerFired(id: "timer")
        let result = roundtrip(event)

        guard case let .timerFired(id)? = result else {
            return XCTFail("Unexpected event: \(String(describing: result))")
        }
        XCTAssertEqual(id, "timer")
    }

    func testFileChangedRoundtrip() async {
        let event = AppEvent.fileChanged(path: "/tmp/test.txt", flags: 42)
        let result = roundtrip(event)

        guard case let .fileChanged(path, flags)? = result else {
            return XCTFail("Unexpected event: \(String(describing: result))")
        }
        XCTAssertEqual(path, "/tmp/test.txt")
        XCTAssertEqual(flags, 42)
    }

    func testClipboardChangedRoundtrip() async {
        let event = AppEvent.clipboardChanged(content: "copied text")
        let result = roundtrip(event)

        guard case let .clipboardChanged(content)? = result else {
            return XCTFail("Unexpected event: \(String(describing: result))")
        }
        XCTAssertEqual(content, "copied text")
    }

    func testHotkeyPressedRoundtrip() async {
        let event = AppEvent.hotkeyPressed(keyCode: 36, modifiers: 1179648)
        let result = roundtrip(event)

        guard case let .hotkeyPressed(keyCode, modifiers)? = result else {
            return XCTFail("Unexpected event: \(String(describing: result))")
        }
        XCTAssertEqual(keyCode, 36)
        XCTAssertEqual(modifiers, 1179648)
    }

    func testFocusEnteredRoundtrip() async {
        let result = roundtrip(.focusEntered)

        guard case .focusEntered? = result else {
            return XCTFail("Unexpected event: \(String(describing: result))")
        }
    }

    func testFocusExitedRoundtrip() async {
        let result = roundtrip(.focusExited)

        guard case .focusExited? = result else {
            return XCTFail("Unexpected event: \(String(describing: result))")
        }
    }

    func testCustomEventRoundtrip() async {
        let event = AppEvent.custom(name: "plugin.demo", payload: ["answer": "42"])
        let result = roundtrip(event)

        guard case let .custom(name, payload)? = result else {
            return XCTFail("Unexpected event: \(String(describing: result))")
        }
        XCTAssertEqual(name, "plugin.demo")
        XCTAssertEqual(payload, ["answer": "42"])
    }

    func testInvalidEnvelopeReturnsNil() async {
        let envelope = XPCEventEnvelope(eventType: "appActivated", payload: ["bundleId": "com.apple.finder"])

        XCTAssertNil(AppEventBridge.fromEnvelope(envelope))
        XCTAssertNil(XPCEventEnvelope(dictionary: ["bundleId": "com.apple.finder"]))
    }

    private func roundtrip(_ event: AppEvent) -> AppEvent? {
        let envelope = AppEventBridge.toEnvelope(event)
        let dictionary = envelope.asDictionary()
        guard let rebuiltEnvelope = XPCEventEnvelope(dictionary: dictionary) else {
            XCTFail("Envelope dictionary roundtrip failed")
            return nil
        }
        return AppEventBridge.fromEnvelope(rebuiltEnvelope)
    }
}
