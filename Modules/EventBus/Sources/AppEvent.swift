import Foundation

public enum AppEvent: Sendable {
    case appActivated(bundleId: String, appName: String)
    case appDeactivated(bundleId: String, appName: String)
    case notificationReceived(source: String, title: String, body: String)
    case timerFired(id: String)
    case fileChanged(path: String, flags: UInt32)
    case clipboardChanged(content: String)
    case hotkeyPressed(keyCode: UInt16, modifiers: UInt32)
    case focusEntered
    case focusExited
    case custom(name: String, payload: [String: String])
}
