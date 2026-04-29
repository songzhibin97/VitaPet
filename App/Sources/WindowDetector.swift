import AppKit
import CoreGraphics
import EventBus
import SecurityLayer

struct DetectedWindow {
    let frame: CGRect
    let ownerName: String
    let windowNumber: Int

    var appKitFrame: CGRect {
        let screenHeight = NSScreen.main?.frame.height ?? 0
        return CGRect(
            x: frame.origin.x,
            y: screenHeight - frame.origin.y - frame.height,
            width: frame.width,
            height: frame.height
        )
    }
}

@MainActor
final class WindowDetector {
    /// EventBus to publish permission-missing events (injected from AppDelegate).
    var eventBus: EventBus?
    /// Ensures the permission-missing event is only published once per launch.
    private var permissionEventPublished = false

    /// 检测当前屏幕上可见的窗口
    /// excludingWindowNumbers: 要排除的窗口号（VitaPet 自己的窗口）
    func detectWindows(excludingWindowNumbers: Set<Int> = []) -> [DetectedWindow] {
        guard
            let windowInfoList = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]]
        else {
            // Publish permission-missing event once if screen recording is not granted.
            if !permissionEventPublished,
               !PermissionGate.checkPermission(.screenRecording),
               let bus = eventBus {
                permissionEventPublished = true
                Task {
                    await bus.publish(.custom(name: "permissionMissing", payload: ["capability": "screenRecording"]))
                }
            }
            return []
        }

        var detectedWindows: [DetectedWindow] = []
        detectedWindows.reserveCapacity(windowInfoList.count)

        for windowInfo in windowInfoList {
            guard
                let boundsDictionary = windowInfo[kCGWindowBounds as String] as? NSDictionary,
                let ownerName = windowInfo[kCGWindowOwnerName as String] as? String,
                let windowNumber = windowInfo[kCGWindowNumber as String] as? Int,
                let windowLayer = windowInfo[kCGWindowLayer as String] as? Int
            else {
                continue
            }

            guard windowLayer == 0 else { continue }
            guard !ownerName.contains("VitaPet") else { continue }
            guard !excludingWindowNumbers.contains(windowNumber) else { continue }

            var bounds = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDictionary, &bounds) else {
                continue
            }

            guard bounds.width >= 100, bounds.height >= 100 else { continue }

            detectedWindows.append(
                DetectedWindow(
                    frame: bounds,
                    ownerName: ownerName,
                    windowNumber: windowNumber
                )
            )
        }

        return detectedWindows
    }
}
