import AppKit
import Foundation

@MainActor
public final class WorkspaceMonitor: EventSource, Sendable {
    public let sourceId: String = "workspace"

    private let notificationCenter: NotificationCenter
    private var activateObserver: NSObjectProtocol?
    private var deactivateObserver: NSObjectProtocol?

    public init(notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.notificationCenter = notificationCenter
    }

    public func start(publishingTo eventBus: EventBus) async {
        guard activateObserver == nil, deactivateObserver == nil else {
            return
        }

        activateObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard
                let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                let bundleId = application.bundleIdentifier,
                let appName = application.localizedName
            else {
                return
            }

            Task {
                await eventBus.publish(.appActivated(bundleId: bundleId, appName: appName))
            }
        }

        deactivateObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard
                let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                let bundleId = application.bundleIdentifier,
                let appName = application.localizedName
            else {
                return
            }

            Task {
                await eventBus.publish(.appDeactivated(bundleId: bundleId, appName: appName))
            }
        }
    }

    public func stop() async {
        if let activateObserver {
            notificationCenter.removeObserver(activateObserver)
            self.activateObserver = nil
        }

        if let deactivateObserver {
            notificationCenter.removeObserver(deactivateObserver)
            self.deactivateObserver = nil
        }
    }
}
