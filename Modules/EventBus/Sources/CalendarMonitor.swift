@preconcurrency import EventKit
import Foundation

@MainActor
public final class CalendarMonitor: EventSource, @unchecked Sendable {
    public nonisolated let sourceId = "calendarMonitor"

    private var eventBus: EventBus?
    private var isRunning = false
    private var checkTimer: Timer?
    private let eventStore = EKEventStore()
    private let requestAccessHandler: @MainActor @Sendable (EKEventStore) async throws -> Bool
    private var remindedEventIDs: Set<String> = []
    private let lookAheadMinutes: Int
    private let checkIntervalSeconds: TimeInterval

    public init(
        lookAheadMinutes: Int = 15,
        checkIntervalSeconds: TimeInterval = 300
    ) {
        self.requestAccessHandler = Self.defaultRequestAccess
        self.lookAheadMinutes = lookAheadMinutes
        self.checkIntervalSeconds = checkIntervalSeconds
    }

    init(
        lookAheadMinutes: Int = 15,
        checkIntervalSeconds: TimeInterval = 300,
        requestAccessHandler: @escaping @MainActor @Sendable (EKEventStore) async throws -> Bool
    ) {
        self.requestAccessHandler = requestAccessHandler
        self.lookAheadMinutes = lookAheadMinutes
        self.checkIntervalSeconds = checkIntervalSeconds
    }

    public func start(publishingTo eventBus: EventBus) async {
        guard !isRunning else {
            return
        }

        isRunning = true
        self.eventBus = eventBus

        do {
            let granted = try await requestCalendarAccess()
            guard granted else {
                resetStateAfterStartFailure()
                return
            }
        } catch {
            resetStateAfterStartFailure()
            return
        }

        await checkUpcomingEvents()

        checkTimer = Timer.scheduledTimer(withTimeInterval: checkIntervalSeconds, repeats: true) { [weak self] _ in
            guard let self else {
                return
            }

            Task { @MainActor in
                await self.checkUpcomingEvents()
            }
        }
    }

    public func stop() async {
        isRunning = false
        checkTimer?.invalidate()
        checkTimer = nil
        eventBus = nil
    }

    private func requestCalendarAccess() async throws -> Bool {
        try await requestAccessHandler(eventStore)
    }

    private static func defaultRequestAccess(_ eventStore: EKEventStore) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            eventStore.requestFullAccessToEvents { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume(returning: granted)
            }
        }
    }

    private func resetStateAfterStartFailure() {
        isRunning = false
        eventBus = nil
    }

    private func checkUpcomingEvents() async {
        guard isRunning, let eventBus else {
            return
        }

        let now = Date()
        let endDate = now.addingTimeInterval(TimeInterval(lookAheadMinutes * 60))
        let predicate = eventStore.predicateForEvents(
            withStart: now,
            end: endDate,
            calendars: nil
        )
        let events = eventStore.events(matching: predicate)

        for event in events {
            let eventID = identifier(for: event)
            guard !remindedEventIDs.contains(eventID) else {
                continue
            }

            remindedEventIDs.insert(eventID)

            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            let timeString = formatter.string(from: event.startDate)
            let title = event.title ?? "Event"

            await eventBus.publish(
                .notificationReceived(
                    source: "Calendar",
                    title: title,
                    body: "Starts at \(timeString)"
                )
            )
        }

        let oneHourAgo = now.addingTimeInterval(-3600)
        let activeEvents = eventStore.events(
            matching: eventStore.predicateForEvents(
                withStart: oneHourAgo,
                end: now.addingTimeInterval(86400),
                calendars: nil
            )
        )
        let activeIDs = Set(activeEvents.map(identifier(for:)))
        remindedEventIDs = remindedEventIDs.intersection(activeIDs)
    }

    private func identifier(for event: EKEvent) -> String {
        event.eventIdentifier ?? event.calendarItemIdentifier
    }
}
