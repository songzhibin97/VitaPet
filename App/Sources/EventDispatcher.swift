import AppKit
import AIEngine
import ChatUI
import EventBus
import Localization
import Persistence
import PluginRuntime
import RenderEngine
import SecurityLayer

/// Owns all monitor instances, the EventBus subscription, and event recording.
/// handleEvent logic is delegated back to AppDelegate via eventHandler closure
/// to preserve all existing callback signatures and field captures.
@MainActor
final class EventDispatcher {

    // MARK: - Monitor instances
    var timerSource: TimerSource!
    var sitReminderTimer: TimerSource!
    var workspaceMonitor: WorkspaceMonitor!
    var notificationMonitor: NotificationMonitor!
    var githubMonitor: GitHubMonitor!
    var calendarMonitor: CalendarMonitor!
    var clipboardMonitor: ClipboardMonitor!
    var fsEventsMonitor: FSEventsMonitor!
    var keyboardMonitor: KeyboardMonitor!
    var webhookServer: WebhookServer?
    var eventSubscriptionID: UUID?

    // MARK: - Stop

    func stop(eventBus: EventBus) async {
        let timerSource = timerSource
        let sitReminderTimer = sitReminderTimer
        let workspaceMonitor = workspaceMonitor
        let notificationMonitor = notificationMonitor
        let githubMonitor = githubMonitor
        let calendarMonitor = calendarMonitor
        let clipboardMonitor = clipboardMonitor
        let fsEventsMonitor = fsEventsMonitor
        let keyboardMonitor = keyboardMonitor
        let webhookServer = webhookServer
        let eventSubscriptionID = eventSubscriptionID

        await timerSource?.stop()
        await sitReminderTimer?.stop()
        await workspaceMonitor?.stop()
        await notificationMonitor?.stop()
        await githubMonitor?.stop()
        await calendarMonitor?.stop()
        await clipboardMonitor?.stop()
        await fsEventsMonitor?.stop()
        await keyboardMonitor?.stop()
        await webhookServer?.stop()

        if let eventSubscriptionID {
            await eventBus.unsubscribe(eventSubscriptionID)
        }
    }
}
