public enum Capability: String, Sendable, CaseIterable {
    case basePet
    case systemAwareness
    case fileAwareness
    case aiChat
    case butlerMode
    case plugins
}

public enum SystemPermission: String, Sendable {
    case accessibility
    case fullDiskAccess
    case screenRecording
}
