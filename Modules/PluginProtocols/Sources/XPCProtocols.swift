import Foundation

/// 主应用 -> 插件进程
@objc public protocol VitaPluginServiceProtocol {
    func pluginInfo(reply: @escaping @Sendable ([String: String]) -> Void)
    func activate(with capabilities: [String], reply: @escaping @Sendable (Bool) -> Void)
    func deactivate(reply: @escaping @Sendable () -> Void)
    func handleEvent(_ envelope: [String: String], reply: @escaping @Sendable () -> Void)
}

/// 插件进程 -> 主应用
@objc public protocol VitaPluginHostProtocol {
    func requestAnimation(_ stateName: String)
    func requestNotification(title: String, body: String)
    func publishCustomEvent(name: String, payload: [String: String])
}

/// NSXPCInterface 工厂
public enum XPCInterfaceFactory {
    public static func serviceInterface() -> NSXPCInterface {
        NSXPCInterface(with: VitaPluginServiceProtocol.self)
    }

    public static func hostInterface() -> NSXPCInterface {
        NSXPCInterface(with: VitaPluginHostProtocol.self)
    }
}
