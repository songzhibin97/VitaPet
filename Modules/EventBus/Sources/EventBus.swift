import Foundation

public actor EventBus {
    public typealias EventHandler = @Sendable (AppEvent) async -> Void

    private struct Subscription: Sendable {
        let filter: @Sendable (AppEvent) -> Bool
        let handler: EventHandler
    }

    private var subscriptions: [UUID: Subscription] = [:]

    public init() {}

    public func subscribe(_ handler: @escaping EventHandler) -> UUID {
        subscribe(matching: { _ in true }, handler: handler)
    }

    public func subscribe(
        matching filter: @escaping @Sendable (AppEvent) -> Bool,
        handler: @escaping EventHandler
    ) -> UUID {
        let id = UUID()
        subscriptions[id] = Subscription(filter: filter, handler: handler)
        return id
    }

    public func unsubscribe(_ id: UUID) {
        subscriptions.removeValue(forKey: id)
    }

    public func publish(_ event: AppEvent) {
        let matchingHandlers = subscriptions.values.filter { $0.filter(event) }.map(\.handler)

        for handler in matchingHandlers {
            Task {
                await handler(event)
            }
        }
    }
}
