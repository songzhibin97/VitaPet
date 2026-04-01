import Foundation
import PluginProtocols

/// 预留给未来原生 XPC 插件支持；当前插件运行时仍以声明式动作插件为主。
/// 插件开发者实现此协议
public protocol VitaPlugin: AnyObject, Sendable {
    var pluginId: String { get }

    /// 插件被激活时调用
    func activate(capabilities: [String]) async

    /// 插件被停用时调用
    func deactivate() async

    /// 收到事件时调用，返回要执行的动作
    func handle(event: XPCEventEnvelope) async -> [PluginActionResult]
}

/// 插件动作结果
public struct PluginActionResult: Sendable {
    public let kind: Kind

    public enum Kind: Sendable {
        case animation(String)
        case notification(title: String, body: String)
        case customEvent(name: String, payload: [String: String])
    }

    public init(kind: Kind) {
        self.kind = kind
    }
}
