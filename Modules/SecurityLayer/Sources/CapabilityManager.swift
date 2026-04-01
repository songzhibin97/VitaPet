public enum CapabilityManagerError: Error, Sendable {
    case unavailable(Capability)
    case permissionDenied(Capability, missing: [SystemPermission])
    case disabled(Capability)
}

public actor CapabilityManager {
    private var providers: [Capability: any CapabilityProvider] = [:]
    private var activeCapabilities: Set<Capability> = []
    private let permissionChecker: @Sendable (SystemPermission) -> Bool

    public init(
        permissionChecker: @escaping @Sendable (SystemPermission) -> Bool = PermissionGate.checkPermission
    ) {
        self.permissionChecker = permissionChecker
    }

    public func register(_ provider: any CapabilityProvider) {
        providers[provider.capability] = provider
        if !provider.isEnabled {
            activeCapabilities.remove(provider.capability)
        }
    }

    public func activate(_ capability: Capability) async throws {
        guard let provider = providers[capability] else {
            throw CapabilityManagerError.unavailable(capability)
        }

        guard provider.isEnabled else {
            throw CapabilityManagerError.disabled(capability)
        }

        let missingPermissions = provider.requiredPermissions.filter { !permissionChecker($0) }
        guard missingPermissions.isEmpty else {
            throw CapabilityManagerError.permissionDenied(capability, missing: missingPermissions)
        }

        guard await provider.isAvailable else {
            throw CapabilityManagerError.permissionDenied(capability, missing: provider.requiredPermissions)
        }

        try await provider.activate()
        activeCapabilities.insert(capability)
    }

    public func deactivate(_ capability: Capability) async {
        guard let provider = providers[capability] else {
            return
        }

        await provider.deactivate()
        activeCapabilities.remove(capability)
    }

    public func status(of capability: Capability) async -> CapabilityStatus {
        guard let provider = providers[capability] else {
            return .unavailable
        }

        if activeCapabilities.contains(capability) {
            return .active
        }

        guard provider.isEnabled else {
            return .inactive
        }

        let missingPermissions = provider.requiredPermissions.filter { !permissionChecker($0) }
        if !missingPermissions.isEmpty {
            return .permissionNeeded(missingPermissions)
        }

        guard await provider.isAvailable else {
            return .permissionNeeded(provider.requiredPermissions)
        }

        return .inactive
    }

    public func allStatuses() async -> [Capability: CapabilityStatus] {
        var statuses: [Capability: CapabilityStatus] = [:]

        for capability in providers.keys {
            statuses[capability] = await status(of: capability)
        }

        return statuses
    }
}
