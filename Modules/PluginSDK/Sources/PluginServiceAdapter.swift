import Foundation
import PluginProtocols

/// 将 VitaPluginServiceProtocol 的 @objc 调用桥接到 VitaPlugin
// @unchecked Sendable is required because NSObject does not conform to Sendable in
// Swift 6, and VitaPluginServiceProtocol is an @objc protocol (ObjC bridge).
// This adapter is created per-connection inside NSXPCListenerDelegate and accessed
// only through XPC infrastructure, so concurrent access to its state cannot occur.
final class PluginServiceAdapter: NSObject, VitaPluginServiceProtocol, @unchecked Sendable {
    private let plugin: any VitaPlugin
    private weak var hostProxy: VitaPluginHostProtocol?

    init(plugin: any VitaPlugin, hostProxy: VitaPluginHostProtocol?) {
        self.plugin = plugin
        self.hostProxy = hostProxy
        super.init()
    }

    func pluginInfo(reply: @escaping @Sendable ([String: String]) -> Void) {
        reply(["id": plugin.pluginId])
    }

    func activate(with capabilities: [String], reply: @escaping @Sendable (Bool) -> Void) {
        Task {
            await plugin.activate(capabilities: capabilities)
            reply(true)
        }
    }

    func deactivate(reply: @escaping @Sendable () -> Void) {
        Task {
            await plugin.deactivate()
            reply()
        }
    }

    func handleEvent(_ envelope: [String: String], reply: @escaping @Sendable () -> Void) {
        Task {
            guard let decoded = XPCEventEnvelope(dictionary: envelope) else {
                reply()
                return
            }

            let results = await plugin.handle(event: decoded)
            for result in results {
                switch result.kind {
                case .animation(let state):
                    hostProxy?.requestAnimation(state)
                case .notification(let title, let body):
                    hostProxy?.requestNotification(title: title, body: body)
                case .customEvent(let name, let payload):
                    hostProxy?.publishCustomEvent(name: name, payload: payload)
                }
            }

            reply()
        }
    }
}
