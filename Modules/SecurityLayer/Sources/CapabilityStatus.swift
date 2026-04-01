public enum CapabilityStatus: Sendable {
    case active
    case inactive
    case permissionNeeded([SystemPermission])
    case unavailable
}
