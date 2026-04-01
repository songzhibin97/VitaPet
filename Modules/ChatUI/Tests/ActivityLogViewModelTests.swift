import ChatUI
import Foundation
import XCTest

private actor EventLoaderStub {
    enum Response {
        case success([ActivityLogViewModel.EventEntry])
        case failure(Error)
    }

    private var responses: [Response]
    private var calls: [(limit: Int, offset: Int)] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    func load(limit: Int, offset: Int) throws -> [ActivityLogViewModel.EventEntry] {
        calls.append((limit: limit, offset: offset))

        guard !responses.isEmpty else {
            return []
        }

        let response = responses.removeFirst()
        switch response {
        case .success(let events):
            return events
        case .failure(let error):
            throw error
        }
    }

    func callCount() -> Int {
        calls.count
    }

    func recordedCalls() -> [(limit: Int, offset: Int)] {
        calls
    }
}

private struct TestError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

@MainActor
final class ActivityLogViewModelTests: XCTestCase {
    func testRefresh_loadsEvents() async {
        let loader = EventLoaderStub(responses: [
            .success(makeEvents(count: 3))
        ])
        let viewModel = makeViewModel(pageSize: 2, loader: loader)

        await viewModel.refresh()

        XCTAssertEqual(viewModel.events.count, 3)
    }

    func testRefresh_replacesExistingEvents() async {
        let loader = EventLoaderStub(responses: [
            .success(makeEvents(count: 3, sourcePrefix: "old")),
            .success(makeEvents(count: 2, sourcePrefix: "new"))
        ])
        let viewModel = makeViewModel(pageSize: 2, loader: loader)

        await viewModel.refresh()
        await viewModel.refresh()

        XCTAssertEqual(viewModel.events.count, 2)
        XCTAssertEqual(viewModel.events.map(\.source), ["new-0", "new-1"])
    }

    func testLoadMore_appendsEvents() async {
        let loader = EventLoaderStub(responses: [
            .success(makeEvents(count: 2, sourcePrefix: "page1")),
            .success(makeEvents(count: 2, sourcePrefix: "page2", startingID: 100))
        ])
        let viewModel = makeViewModel(pageSize: 2, loader: loader)

        await viewModel.refresh()
        await viewModel.loadMore()

        XCTAssertEqual(viewModel.events.count, 4)
        XCTAssertEqual(viewModel.events.map(\.source), ["page1-0", "page1-1", "page2-0", "page2-1"])
    }

    func testLoadMore_setsCanLoadMoreFalse() async {
        let loader = EventLoaderStub(responses: [
            .success(makeEvents(count: 1))
        ])
        let viewModel = makeViewModel(pageSize: 2, loader: loader)

        await viewModel.loadMore()

        XCTAssertFalse(viewModel.canLoadMore)
    }

    func testLoadMore_doesNothingWhenCanLoadMoreFalse() async {
        let loader = EventLoaderStub(responses: [
            .success(makeEvents(count: 1))
        ])
        let viewModel = makeViewModel(pageSize: 2, loader: loader)

        await viewModel.refresh()
        XCTAssertFalse(viewModel.canLoadMore)

        await viewModel.loadMore()

        let calls = await loader.recordedCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].limit, 2)
        XCTAssertEqual(calls[0].offset, 0)
    }

    func testRefresh_onError_clearsEventsAndSetsErrorMessage() async {
        let loader = EventLoaderStub(responses: [
            .success(makeEvents(count: 2)),
            .failure(TestError(message: "load failed"))
        ])
        let viewModel = makeViewModel(pageSize: 2, loader: loader)

        await viewModel.refresh()
        XCTAssertEqual(viewModel.events.count, 2)

        await viewModel.refresh()

        XCTAssertTrue(viewModel.events.isEmpty)
        XCTAssertEqual(viewModel.errorMessage, "load failed")
    }

    func testEventEntry_summary_parsesJSON() {
        let entry = ActivityLogViewModel.EventEntry(
            id: 1,
            timestamp: Date(timeIntervalSince1970: 0),
            source: "test",
            payload: #"{"z":"last","a":"first"}"#
        )

        XCTAssertEqual(entry.summary, "a: first · z: last")
    }

    func testEventEntry_summary_emptyPayload() {
        let entry = ActivityLogViewModel.EventEntry(
            id: 1,
            timestamp: Date(timeIntervalSince1970: 0),
            source: "test",
            payload: ""
        )

        XCTAssertEqual(entry.summary, "无附加信息")
    }

    private func makeViewModel(
        pageSize: Int,
        loader: EventLoaderStub
    ) -> ActivityLogViewModel {
        ActivityLogViewModel(pageSize: pageSize) { limit, offset in
            try await loader.load(limit: limit, offset: offset)
        }
    }

    private func makeEvents(
        count: Int,
        sourcePrefix: String = "event",
        startingID: Int64 = 0
    ) -> [ActivityLogViewModel.EventEntry] {
        (0..<count).map { index in
            ActivityLogViewModel.EventEntry(
                id: startingID + Int64(index),
                timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                source: "\(sourcePrefix)-\(index)",
                payload: #"{"index":"\#(index)"}"#
            )
        }
    }
}
