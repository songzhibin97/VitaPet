import Foundation
import PluginProtocols

/// 预留给未来原生 XPC 插件支持；当前宿主暂未接入原生插件事件路由。
/// 插件开发者在 main.swift 调用: PluginEntryPoint(plugin: MyPlugin()).run()
public final class PluginEntryPoint: NSObject, @unchecked Sendable {
    private let plugin: any VitaPlugin
    private let listener: NSXPCListener

    public init(plugin: any VitaPlugin) {
        self.plugin = plugin
        self.listener = NSXPCListener.service()
        super.init()
    }

    /// 启动 XPC listener，永不返回
    public func run() -> Never {
        listener.delegate = self
        listener.resume()
        RunLoop.current.run()
        fatalError("RunLoop exited unexpectedly")
    }
}

extension PluginEntryPoint: NSXPCListenerDelegate {
    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = XPCInterfaceFactory.serviceInterface()
        connection.remoteObjectInterface = XPCInterfaceFactory.hostInterface()

        let hostProxy = connection.remoteObjectProxy as? VitaPluginHostProtocol
        let adapter = PluginServiceAdapter(plugin: plugin, hostProxy: hostProxy)
        connection.exportedObject = adapter

        connection.resume()
        return true
    }
}
