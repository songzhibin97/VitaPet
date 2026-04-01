public protocol EventSource: Sendable {
    var sourceId: String { get }

    func start(publishingTo eventBus: EventBus) async
    func stop() async
}
