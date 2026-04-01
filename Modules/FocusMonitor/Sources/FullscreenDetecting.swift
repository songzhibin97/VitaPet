@MainActor
public protocol FullscreenDetecting: Sendable {
    func isAnyAppFullscreen() -> Bool
}
