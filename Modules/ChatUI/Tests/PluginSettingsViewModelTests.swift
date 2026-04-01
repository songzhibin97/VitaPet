import ChatUI
import XCTest

private actor CallRecorder<Value: Sendable> {
    private var values: [Value] = []

    func record(_ value: Value) {
        values.append(value)
    }

    func allValues() -> [Value] {
        values
    }

    func count() -> Int {
        values.count
    }
}

private final class ExpectationBox: @unchecked Sendable {
    private let wrapped: XCTestExpectation

    init(_ wrapped: XCTestExpectation) {
        self.wrapped = wrapped
    }

    @MainActor
    func fulfill() {
        wrapped.fulfill()
    }
}

@MainActor
final class PluginSettingsViewModelTests: XCTestCase {
    func testRefresh_loadsPlugins() async {
        let viewModel = PluginSettingsViewModel(
            loadPlugins: {
                [
                    (
                        id: "plugin.a",
                        name: "Plugin A",
                        version: "1.0.0",
                        description: "First plugin",
                        directory: nil,
                        isDeclarative: false,
                        isBuiltIn: false,
                        isEnabled: true
                    ),
                    (
                        id: "plugin.b",
                        name: "Plugin B",
                        version: "2.1.0",
                        description: "Second plugin",
                        directory: nil,
                        isDeclarative: false,
                        isBuiltIn: false,
                        isEnabled: false
                    )
                ]
            },
            setEnabled: { _, _ in }
        )

        await viewModel.refresh()

        XCTAssertEqual(viewModel.plugins.count, 2)
        XCTAssertEqual(viewModel.plugins[0].id, "plugin.a")
        XCTAssertEqual(viewModel.plugins[0].name, "Plugin A")
        XCTAssertEqual(viewModel.plugins[0].version, "1.0.0")
        XCTAssertEqual(viewModel.plugins[0].description, "First plugin")
        XCTAssertEqual(viewModel.plugins[0].isEnabled, true)
        XCTAssertEqual(viewModel.plugins[1].id, "plugin.b")
        XCTAssertEqual(viewModel.plugins[1].name, "Plugin B")
        XCTAssertEqual(viewModel.plugins[1].version, "2.1.0")
        XCTAssertEqual(viewModel.plugins[1].description, "Second plugin")
        XCTAssertEqual(viewModel.plugins[1].isEnabled, false)
    }

    func testRefresh_emptyList() async {
        let viewModel = PluginSettingsViewModel(
            loadPlugins: { [] },
            setEnabled: { _, _ in }
        )

        await viewModel.refresh()

        XCTAssertTrue(viewModel.plugins.isEmpty)
    }

    func testTogglePlugin_updatesLocalState() async {
        let viewModel = PluginSettingsViewModel(
            loadPlugins: {
                return [
                    (
                        id: "plugin.a",
                        name: "Plugin A",
                        version: "1.0.0",
                        description: "First plugin",
                        directory: nil,
                        isDeclarative: false,
                        isBuiltIn: false,
                        isEnabled: false
                    )
                ]
            },
            setEnabled: { _, _ in
                try? await Task.sleep(for: .milliseconds(50))
            }
        )

        await viewModel.refresh()
        viewModel.togglePlugin("plugin.a", enabled: false)

        XCTAssertEqual(viewModel.plugins.map(\.isEnabled), [false])
        try? await Task.sleep(for: .milliseconds(100))
    }

    func testTogglePlugin_callsSetEnabled() async {
        let called = expectation(description: "setEnabled called")
        let calledBox = ExpectationBox(called)
        let recorder = CallRecorder<(String, Bool)>()

        let viewModel = PluginSettingsViewModel(
            loadPlugins: {
                [
                    (
                        id: "plugin.a",
                        name: "Plugin A",
                        version: "1.0.0",
                        description: "First plugin",
                        directory: nil,
                        isDeclarative: false,
                        isBuiltIn: false,
                        isEnabled: true
                    )
                ]
            },
            setEnabled: { id, enabled in
                await recorder.record((id, enabled))
                await calledBox.fulfill()
            }
        )

        await viewModel.refresh()
        viewModel.togglePlugin("plugin.a", enabled: false)

        await fulfillment(of: [called], timeout: 1.0)

        let calls = await recorder.allValues()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].0, "plugin.a")
        XCTAssertEqual(calls[0].1, false)
    }

    func testTogglePlugin_rollsBackOnError() async {
        enum TestError: Error {
            case setEnabledFailed
        }

        let called = expectation(description: "setEnabled attempted")
        let calledBox = ExpectationBox(called)

        let viewModel = PluginSettingsViewModel(
            loadPlugins: {
                [
                    (
                        id: "plugin.a",
                        name: "Plugin A",
                        version: "1.0.0",
                        description: "First plugin",
                        directory: nil,
                        isDeclarative: false,
                        isBuiltIn: false,
                        isEnabled: true
                    )
                ]
            },
            setEnabled: { _, _ in
                await calledBox.fulfill()
                throw TestError.setEnabledFailed
            }
        )

        await viewModel.refresh()
        viewModel.togglePlugin("plugin.a", enabled: false)

        XCTAssertEqual(viewModel.plugins.first?.isEnabled, false)

        await fulfillment(of: [called], timeout: 1.0)
        await assertEventuallyTrue { viewModel.plugins.first?.isEnabled == true }
    }

    func testTogglePlugin_invalidId_noEffect() async {
        let recorder = CallRecorder<(String, Bool)>()

        let viewModel = PluginSettingsViewModel(
            loadPlugins: {
                [
                    (
                        id: "plugin.a",
                        name: "Plugin A",
                        version: "1.0.0",
                        description: "First plugin",
                        directory: nil,
                        isDeclarative: false,
                        isBuiltIn: false,
                        isEnabled: true
                    )
                ]
            },
            setEnabled: { id, enabled in
                await recorder.record((id, enabled))
            }
        )

        await viewModel.refresh()
        viewModel.togglePlugin("missing.plugin", enabled: false)

        XCTAssertEqual(viewModel.plugins.count, 1)
        XCTAssertEqual(viewModel.plugins.first?.id, "plugin.a")
        XCTAssertEqual(viewModel.plugins.first?.isEnabled, true)

        try? await Task.sleep(for: .milliseconds(100))
        let callCount = await recorder.count()
        XCTAssertEqual(callCount, 0)
    }

    private func assertEventuallyTrue(
        _ predicate: @escaping @MainActor () -> Bool,
        timeout: Duration = .seconds(1)
    ) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if predicate() {
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }

        XCTFail("Timed out waiting for predicate to become true")
    }
}
