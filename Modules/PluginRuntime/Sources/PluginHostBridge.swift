import EventBus
import Foundation
import PluginProtocols

// @unchecked Sendable is required because NSObject does not conform to Sendable
// in Swift 6. All mutable state is @MainActor-isolated (pluginManager, eventBus
// are both Sendable reference types accessed only on MainActor), so the class is
// data-race-free in practice.
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
