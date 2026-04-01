import Foundation

/// XPC 事件线传格式
public struct XPCEventEnvelope: Codable, Sendable {
    public let eventType: String
    public let payload: [String: String]

    public init(eventType: String, payload: [String: String] = [:]) {
        self.eventType = eventType
        self.payload = payload
    }

    /// 转换为 [String: String] 用于 XPC 传输
    public func asDictionary() -> [String: String] {
        var dict = payload
        dict["__eventType"] = eventType
        return dict
    }

    /// 从 XPC 传输的 [String: String] 还原
    public init?(dictionary: [String: String]) {
        guard let eventType = dictionary["__eventType"] else { return nil }
        self.eventType = eventType
        var payload = dictionary
        payload.removeValue(forKey: "__eventType")
        self.payload = payload
    }
}
