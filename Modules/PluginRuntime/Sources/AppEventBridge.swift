import EventBus
import PluginProtocols

public enum AppEventBridge {
    public static func toEnvelope(_ event: AppEvent) -> XPCEventEnvelope {
        switch event {
        case .appActivated(let bundleId, let appName):
            return XPCEventEnvelope(
                eventType: "appActivated",
                payload: [
                    "bundleId": bundleId,
                    "appName": appName
                ]
            )
        case .appDeactivated(let bundleId, let appName):
            return XPCEventEnvelope(
                eventType: "appDeactivated",
                payload: [
                    "bundleId": bundleId,
                    "appName": appName
                ]
            )
        case .notificationReceived(let source, let title, let body):
            return XPCEventEnvelope(
                eventType: "notificationReceived",
                payload: [
                    "source": source,
                    "title": title,
                    "body": body
                ]
            )
        case .timerFired(let id):
            return XPCEventEnvelope(
                eventType: "timerFired",
                payload: ["id": id]
            )
        case .fileChanged(let path, let flags):
            return XPCEventEnvelope(
                eventType: "fileChanged",
                payload: [
                    "path": path,
                    "flags": String(flags)
                ]
            )
        case .clipboardChanged(let content):
            return XPCEventEnvelope(
                eventType: "clipboardChanged",
                payload: ["content": content]
            )
        case .hotkeyPressed(let keyCode, let modifiers):
            return XPCEventEnvelope(
                eventType: "hotkeyPressed",
                payload: [
                    "keyCode": String(keyCode),
                    "modifiers": String(modifiers)
                ]
            )
        case .focusEntered:
            return XPCEventEnvelope(eventType: "focusEntered")
        case .focusExited:
            return XPCEventEnvelope(eventType: "focusExited")
        case .custom(let name, let payload):
            var payload = payload
            payload["name"] = name
            return XPCEventEnvelope(eventType: "custom", payload: payload)
        }
    }

    public static func fromEnvelope(_ envelope: XPCEventEnvelope) -> AppEvent? {
        switch envelope.eventType {
        case "appActivated":
            guard
                let bundleId = envelope.payload["bundleId"],
                let appName = envelope.payload["appName"]
            else {
                return nil
            }
            return .appActivated(bundleId: bundleId, appName: appName)
        case "appDeactivated":
            guard
                let bundleId = envelope.payload["bundleId"],
                let appName = envelope.payload["appName"]
            else {
                return nil
            }
            return .appDeactivated(bundleId: bundleId, appName: appName)
        case "notificationReceived":
            guard
                let source = envelope.payload["source"],
                let title = envelope.payload["title"],
                let body = envelope.payload["body"]
            else {
                return nil
            }
            return .notificationReceived(source: source, title: title, body: body)
        case "timerFired":
            guard let id = envelope.payload["id"] else {
                return nil
            }
            return .timerFired(id: id)
        case "fileChanged":
            guard
                let path = envelope.payload["path"],
                let rawFlags = envelope.payload["flags"],
                let flags = UInt32(rawFlags)
            else {
                return nil
            }
            return .fileChanged(path: path, flags: flags)
        case "clipboardChanged":
            guard let content = envelope.payload["content"] else {
                return nil
            }
            return .clipboardChanged(content: content)
        case "hotkeyPressed":
            guard
                let rawKeyCode = envelope.payload["keyCode"],
                let rawModifiers = envelope.payload["modifiers"],
                let keyCode = UInt16(rawKeyCode),
                let modifiers = UInt32(rawModifiers)
            else {
                return nil
            }
            return .hotkeyPressed(keyCode: keyCode, modifiers: modifiers)
        case "focusEntered":
            return .focusEntered
        case "focusExited":
            return .focusExited
        case "custom":
            guard let name = envelope.payload["name"] else {
                return nil
            }
            var payload = envelope.payload
            payload.removeValue(forKey: "name")
            return .custom(name: name, payload: payload)
        default:
            return nil
        }
    }
}
