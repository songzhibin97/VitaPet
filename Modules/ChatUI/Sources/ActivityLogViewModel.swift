import Foundation
import Localization
import Observation

@MainActor
@Observable
public final class ActivityLogViewModel {
    public struct EventEntry: Identifiable, Sendable {
        public let id: Int64
        public let timestamp: Date
        public let source: String
        public let payload: String

        public init(id: Int64, timestamp: Date, source: String, payload: String) {
            self.id = id
            self.timestamp = timestamp
            self.source = source
            self.payload = payload
        }

        public var summary: String {
            guard
                let data = payload.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data),
                let dictionary = object as? [String: String],
                !dictionary.isEmpty
            else {
                return payload.isEmpty ? L10n.activityLogNoInfo : payload
            }

            return dictionary
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)" }
                .joined(separator: " · ")
        }
    }

    public private(set) var events: [EventEntry] = []
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    public private(set) var canLoadMore = true
    public private(set) var isPersistenceAvailable: Bool

    private let loadEvents: @Sendable (Int, Int) async throws -> [EventEntry]
    private let pageSize: Int

    public init(
        isPersistenceAvailable: Bool = true,
        pageSize: Int = 50,
        loadEvents: @escaping @Sendable (Int, Int) async throws -> [EventEntry]
    ) {
        self.isPersistenceAvailable = isPersistenceAvailable
        self.pageSize = pageSize
        self.loadEvents = loadEvents
    }

    public func refresh() async {
        await load(reset: true)
    }

    public func loadMore() async {
        guard canLoadMore else {
            return
        }

        await load(reset: false)
    }

    private func load(reset: Bool) async {
        guard !isLoading else {
            return
        }

        isLoading = true
        errorMessage = nil

        let offset = reset ? 0 : events.count

        do {
            let fetchedEvents = try await loadEvents(pageSize, offset)
            if reset {
                events = fetchedEvents
            } else {
                events.append(contentsOf: fetchedEvents)
            }
            canLoadMore = fetchedEvents.count == pageSize
        } catch {
            if reset {
                events = []
                canLoadMore = false
            }
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}
