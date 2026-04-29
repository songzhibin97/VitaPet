import Foundation
import Observation

@MainActor
@Observable
public final class StatisticsViewModel {
    public struct MoodPoint: Identifiable {
        public let id = UUID()
        public let timestamp: Date
        public let happiness: Int
        public let petName: String

        public init(timestamp: Date, happiness: Int, petName: String) {
            self.timestamp = timestamp
            self.happiness = happiness
            self.petName = petName
        }
    }

    public struct BehaviorCount: Identifiable {
        public let id = UUID()
        public let state: String
        public let count: Int
        public let petName: String

        public init(state: String, count: Int, petName: String) {
            self.state = state
            self.count = count
            self.petName = petName
        }
    }

    public struct DailyInteraction: Identifiable {
        public let id = UUID()
        public let date: String
        public let clicks: Int
        public let interactions: Int
        public let games: Int

        public init(date: String, clicks: Int, interactions: Int, games: Int) {
            self.date = date
            self.clicks = clicks
            self.interactions = interactions
            self.games = games
        }
    }

    public private(set) var moodHistory: [MoodPoint] = []
    public private(set) var behaviorCounts: [BehaviorCount] = []
    public private(set) var dailyInteractions: [DailyInteraction] = []
    public private(set) var isLoading = false
    public var selectedDays: Int = 7
    public private(set) var isPersistenceAvailable: Bool

    private var loadMoodHistory: @Sendable (String?, Int) async throws -> [(timestamp: Date, happiness: Int, petName: String)]
    private var loadBehaviorCounts: @Sendable (Int) async throws -> [(state: String, count: Int, petName: String)]
    private var loadDailyInteractions: @Sendable (Int) async throws -> [(date: String, clicks: Int, interactions: Int, games: Int)]

    public init(
        isPersistenceAvailable: Bool = true,
        selectedDays: Int = 7,
        loadMoodHistory: @escaping @Sendable (String?, Int) async throws -> [(timestamp: Date, happiness: Int, petName: String)] = { _, _ in [] },
        loadBehaviorCounts: @escaping @Sendable (Int) async throws -> [(state: String, count: Int, petName: String)] = { _ in [] },
        loadDailyInteractions: @escaping @Sendable (Int) async throws -> [(date: String, clicks: Int, interactions: Int, games: Int)] = { _ in [] }
    ) {
        self.isPersistenceAvailable = isPersistenceAvailable
        self.selectedDays = selectedDays
        self.loadMoodHistory = loadMoodHistory
        self.loadBehaviorCounts = loadBehaviorCounts
        self.loadDailyInteractions = loadDailyInteractions
    }

    public func configure(
        loadMoodHistory: @escaping @Sendable (String?, Int) async throws -> [(timestamp: Date, happiness: Int, petName: String)],
        loadBehaviorCounts: @escaping @Sendable (Int) async throws -> [(state: String, count: Int, petName: String)],
        loadDailyInteractions: @escaping @Sendable (Int) async throws -> [(date: String, clicks: Int, interactions: Int, games: Int)]
    ) {
        self.loadMoodHistory = loadMoodHistory
        self.loadBehaviorCounts = loadBehaviorCounts
        self.loadDailyInteractions = loadDailyInteractions
    }

    public func refresh() async {
        guard !isLoading else {
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            async let moodRows = loadMoodHistory(nil, selectedDays)
            async let behaviorRows = loadBehaviorCounts(selectedDays)
            async let interactionRows = loadDailyInteractions(selectedDays)

            moodHistory = try await moodRows.map {
                MoodPoint(timestamp: $0.timestamp, happiness: $0.happiness, petName: $0.petName)
            }
            behaviorCounts = try await behaviorRows.map {
                BehaviorCount(state: $0.state, count: $0.count, petName: $0.petName)
            }
            dailyInteractions = try await interactionRows.map {
                DailyInteraction(
                    date: $0.date,
                    clicks: $0.clicks,
                    interactions: $0.interactions,
                    games: $0.games
                )
            }
        } catch {
            moodHistory = []
            behaviorCounts = []
            dailyInteractions = []
        }
    }
}
