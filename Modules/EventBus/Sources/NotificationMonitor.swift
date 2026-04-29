import Foundation

@MainActor
public final class NotificationMonitor: EventSource, Sendable {
    public let sourceId = "notificationMonitor"

    private let notificationCenter: DistributedNotificationCenter
    private var observer: NSObjectProtocol?

    public init(notificationCenter: DistributedNotificationCenter = .default()) {
        self.notificationCenter = notificationCenter
    }

    public func start(publishingTo eventBus: EventBus) async {
        guard observer == nil else {
            return
        }

        observer = notificationCenter.addObserver(
            forName: nil,
            object: nil,
            queue: .main
        ) { notification in
            let event = Self.makeEvent(from: notification)
            guard let event else {
                return
            }

            Task {
                await eventBus.publish(event)
            }
        }
    }

    public func stop() async {
        if let observer {
            notificationCenter.removeObserver(observer)
            self.observer = nil
        }
    }

    nonisolated private static func makeEvent(from notification: Notification) -> AppEvent? {
        let parsed = parseNotification(
            name: notification.name.rawValue,
            userInfo: notification.userInfo
        )
        guard !parsed.source.isEmpty else {
            return nil
        }

        return .notificationReceived(
            source: parsed.source,
            title: parsed.title,
            body: parsed.body
        )
    }

    nonisolated private static func parseNotification(
        name: String,
        userInfo: [AnyHashable: Any]?
    ) -> (source: String, title: String, body: String) {
        switch name {
        case let n where n.contains("com.apple.mail"):
            return (
                "Mail",
                "New Email",
                userInfo?["subject"] as? String ?? "You have new mail"
            )
        case let n where n.contains("com.apple.iCal") || n.contains("com.apple.CalendarAgent"):
            return (
                "Calendar",
                "Calendar Event",
                userInfo?["title"] as? String ?? "Upcoming event"
            )
        case let n where n.contains("com.apple.Messages"):
            return (
                "Messages",
                "New Message",
                "You received a message"
            )
        case let n where n.contains("Slack"):
            return (
                "Slack",
                "Slack",
                userInfo?["text"] as? String ?? "New Slack message"
            )
        case let n where n.hasPrefix("com.vitapet.webhook"):
            return (
                "Webhook",
                userInfo?["title"] as? String ?? "Webhook",
                userInfo?["body"] as? String ?? ""
            )
        default:
            return ("", "", "")
        }
    }
}
