import SecurityLayer

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
