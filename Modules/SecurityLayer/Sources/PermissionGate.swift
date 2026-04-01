import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public struct PermissionGate: Sendable {
    public static func checkPermission(_ permission: SystemPermission) -> Bool {
        switch permission {
        case .accessibility:
            return AXIsProcessTrusted()
        case .fullDiskAccess:
            return canReadProtectedDirectory()
        case .screenRecording:
            return CGPreflightScreenCaptureAccess()
        }
    }

    @MainActor
    public static func requestPermission(_ permission: SystemPermission) {
        switch permission {
        case .accessibility:
            let promptKey = "AXTrustedCheckOptionPrompt" as CFString
            let options = [promptKey: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .fullDiskAccess:
            openSystemSettingsPane("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        case .screenRecording:
            openSystemSettingsPane("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        }
    }

    private static func canReadProtectedDirectory() -> Bool {
        let fileManager = FileManager.default
        let homeDirectory = fileManager.homeDirectoryForCurrentUser
        let safariDirectory = homeDirectory.appendingPathComponent("Library/Safari", isDirectory: true)

        guard fileManager.fileExists(atPath: safariDirectory.path) else {
            return false
        }

        do {
            _ = try fileManager.contentsOfDirectory(atPath: safariDirectory.path)
            return true
        } catch {
            return false
        }
    }

    @MainActor
    private static func openSystemSettingsPane(_ urlString: String) {
        guard let url = URL(string: urlString) else {
            return
        }

        NSWorkspace.shared.open(url)
    }
}
