import AppKit
import CoreGraphics
import Foundation

@MainActor
public final class FullscreenDetector: FullscreenDetecting {
    public init() {}

    /// 检测当前是否有全屏应用
    public func isAnyAppFullscreen() -> Bool {
        guard
            let mainScreenBounds = NSScreen.main?.frame,
            let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
            let windowInfoList = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]]
        else {
            return false
        }

        let normalizedMainBounds = CGRect(
            x: mainScreenBounds.origin.x,
            y: mainScreenBounds.origin.y,
            width: mainScreenBounds.width,
            height: mainScreenBounds.height
        ).integral

        for windowInfo in windowInfoList {
            guard
                let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                ownerPID == frontmostPID,
                let layer = windowInfo[kCGWindowLayer as String] as? Int,
                layer == 0,
                let boundsDictionary = windowInfo[kCGWindowBounds as String] as? NSDictionary,
                let windowBounds = CGRect(dictionaryRepresentation: boundsDictionary)
            else {
                continue
            }

            return windowBounds.integral.equalTo(normalizedMainBounds)
        }

        return false
    }
}
