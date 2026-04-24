import Foundation

/// Publishes `timerFired` at each local-time hour boundary (`:00:00`), independent of a fixed tick interval.
/// This fixes “整点报时” when the app uses coarse `TimerSource` ticks or misses a minute during sleep.
public actor HourBoundaryTimerSource: EventSource {
    public let sourceId: String
    private var loopTask: Task<Void, Never>?

    public init(sourceId: String = "hour-boundary") {
        self.sourceId = sourceId
    }

    public func start(publishingTo eventBus: EventBus) async {
        guard loopTask == nil else {
            return
        }

        let sourceId = self.sourceId
        loopTask = Task {
            let calendar = Calendar.autoupdatingCurrent
            var boundary = DateComponents()
            boundary.minute = 0
            boundary.second = 0
            boundary.nanosecond = 0

            while !Task.isCancelled {
                let now = Date()
                guard let nextBoundary = calendar.nextDate(
                    after: now,
                    matching: boundary,
                    matchingPolicy: .nextTime,
                    direction: .forward
                ) else {
                    try? await Task.sleep(for: .seconds(30))
                    continue
                }

                let delay = nextBoundary.timeIntervalSinceNow
                if delay > 0 {
                    do {
                        try await Task.sleep(for: .seconds(delay))
                    } catch {
                        break
                    }
                }

                guard !Task.isCancelled else {
                    break
                }

                await eventBus.publish(.timerFired(id: sourceId))
            }
        }
    }

    public func stop() async {
        loopTask?.cancel()
        loopTask = nil
    }
}
