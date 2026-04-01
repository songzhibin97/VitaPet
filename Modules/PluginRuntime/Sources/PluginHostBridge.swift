import EventBus
import Foundation
import PluginProtocols

@MainActor
final class PluginHostBridge: NSObject, VitaPluginHostProtocol, @unchecked Sendable {
    private let pluginManager: PluginManager
    private let eventBus: EventBus

    init(pluginManager: PluginManager, eventBus: EventBus) {
        self.pluginManager = pluginManager
        self.eventBus = eventBus
    }

    nonisolated func requestAnimation(_ stateName: String) {
        Task {
            await pluginManager.handleAnimationRequest(stateName)
        }
    }

    nonisolated func requestNotification(title: String, body: String) {
        Task {
            await pluginManager.handleNotificationRequest(title: title, body: body)
        }
    }

    nonisolated func publishCustomEvent(name: String, payload: [String: String]) {
        Task {
            await eventBus.publish(.custom(name: name, payload: payload))
        }
    }
}
