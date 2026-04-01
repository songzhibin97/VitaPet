public protocol CapabilityProvider: Sendable {
    var capability: Capability { get }
    var requiredPermissions: [SystemPermission] { get }
    var isEnabled: Bool { get }
    var isAvailable: Bool { get async }

    func activate() async throws
    func deactivate() async
}
