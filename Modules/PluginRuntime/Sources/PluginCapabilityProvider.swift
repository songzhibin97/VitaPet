import SecurityLayer

// @unchecked Sendable is required because CapabilityProvider (Sendable) has a
// nonisolated `isEnabled` getter that is incompatible with @MainActor isolation.
// isEnabled is only mutated inside async activate()/deactivate(), which are always
// called serially through CapabilityManager (an actor). The let fields (capability,
// requiredPermissions, pluginManager) are immutable after init. So there is no
// data race in practice.
public final class PluginCapabilityProvider: CapabilityProvider, @unchecked Sendable {
    public let capability: Capability = .plugins
    public let requiredPermissions: [SystemPermission] = []
    public private(set) var isEnabled: Bool
    private let pluginManager: PluginManager

    public init(pluginManager: PluginManager, isEnabled: Bool = true) {
        self.pluginManager = pluginManager
        self.isEnabled = isEnabled
    }

    public var isAvailable: Bool {
        get async {
            true
        }
    }

    public func activate() async throws {
        isEnabled = true
    }

    public func deactivate() async {
        isEnabled = false
        await pluginManager.stop()
    }
}
