import ChatUI
import Foundation
import XCTest

@MainActor
final class StatisticsViewModelTests: XCTestCase {
    func testIsPersistenceAvailable_defaultsTrue() {
        let viewModel = StatisticsViewModel()
        XCTAssertTrue(viewModel.isPersistenceAvailable)
    }

    func testIsPersistenceAvailable_falseWhenPassedFalse() {
        let viewModel = StatisticsViewModel(isPersistenceAvailable: false)
        XCTAssertFalse(viewModel.isPersistenceAvailable)
    }

    func testRefresh_populatesData() async {
        let viewModel = StatisticsViewModel(
            loadMoodHistory: { _, _ in [(timestamp: Date(), happiness: 80, petName: "Mochi")] },
            loadBehaviorCounts: { _ in [(state: "idle", count: 5, petName: "Mochi")] },
            loadDailyInteractions: { _ in [(date: "2026-04-29", clicks: 3, interactions: 2, games: 1)] }
        )

        await viewModel.refresh()

        XCTAssertEqual(viewModel.moodHistory.count, 1)
        XCTAssertEqual(viewModel.moodHistory[0].happiness, 80)
        XCTAssertEqual(viewModel.behaviorCounts.count, 1)
        XCTAssertEqual(viewModel.behaviorCounts[0].state, "idle")
        XCTAssertEqual(viewModel.dailyInteractions.count, 1)
        XCTAssertEqual(viewModel.dailyInteractions[0].clicks, 3)
    }

    func testRefresh_clearsDataOnError() async {
        let viewModel = StatisticsViewModel(
            loadMoodHistory: { _, _ in throw URLError(.badServerResponse) },
            loadBehaviorCounts: { _ in [] },
            loadDailyInteractions: { _ in [] }
        )

        await viewModel.refresh()

        XCTAssertTrue(viewModel.moodHistory.isEmpty)
        XCTAssertTrue(viewModel.behaviorCounts.isEmpty)
        XCTAssertTrue(viewModel.dailyInteractions.isEmpty)
    }
}
