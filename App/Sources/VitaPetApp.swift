import AppKit
import Foundation

@main
struct VitaPetApp {
    nonisolated(unsafe) private static var lockFileDescriptor: Int32 = -1

    nonisolated static func releaseAppLock() {
        guard lockFileDescriptor >= 0 else {
            return
        }

        flock(lockFileDescriptor, LOCK_UN)
        close(lockFileDescriptor)
        lockFileDescriptor = -1
    }

    @MainActor
    static func main() {
        // 单实例检测：用文件锁确保只有一个实例运行
        let lockPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VitaPet", isDirectory: true)
            .appendingPathComponent(".vitapet.lock")
            .path

        let dir = (lockPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        if fd >= 0 {
            if flock(fd, LOCK_EX | LOCK_NB) != 0 {
                close(fd)
                return
            }
            lockFileDescriptor = fd
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()

        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
