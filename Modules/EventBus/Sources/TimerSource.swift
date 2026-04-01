import Foundation

public actor TimerSource: EventSource {
    public let sourceId: String

    private let interval: TimeInterval
    private var timerTask: Task<Void, Never>?

    public init(interval: TimeInterval = 10.0, sourceId: String = "timer") {
        self.interval = interval
        self.sourceId = sourceId
    }

    public func start(publishingTo eventBus: EventBus) async {
        guard timerTask == nil else {
            return
        }

        let interval = self.interval
        let sourceId = self.sourceId

        timerTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    break
                }

                guard !Task.isCancelled else {
                    break
                }

                await eventBus.publish(.timerFired(id: sourceId))
            }
        }
    }

    public func stop() async {
        timerTask?.cancel()
        timerTask = nil
    }
}
