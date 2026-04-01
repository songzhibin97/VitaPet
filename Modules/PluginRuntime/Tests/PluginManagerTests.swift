import EventBus
import Foundation
import Persistence
import XCTest
@testable import PluginRuntime

final class PluginManagerTests: XCTestCase {
    var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeManager(pluginDirectories: (@Sendable () -> [URL])? = nil) async -> PluginManager {
        let tempDir = tempDir!
        return await MainActor.run {
            let configManager = ConfigManager(storageURL: tempDir)
            if let pluginDirectories {
                return PluginManager(loader: PluginLoader(developerMode: true), configManager: configManager, pluginDirectories: pluginDirectories)
            }
            return PluginManager(loader: PluginLoader(developerMode: true), configManager: configManager)
        }
    }

    func testEventMatchesTrigger_fileChanged_withPathPattern() async {
        let manager = await makeManager()
        let rule = TriggerRule(
            event: "fileChanged",
            conditions: ["pathPattern": "*/project/*.swift"],
            actions: []
        )

        let matched = await manager.eventMatchesTrigger(
            rule,
            event: AppEvent.fileChanged(path: "/tmp/project/Main.swift", flags: 1)
        )

        XCTAssertTrue(matched)
    }

    func testEventMatchesTrigger_fileChanged_noConditions_matchesAll() async {
        let manager = await makeManager()
        let rule = TriggerRule(event: "fileChanged", conditions: [:], actions: [])

        let matched = await manager.eventMatchesTrigger(
            rule,
            event: AppEvent.fileChanged(path: "/tmp/any.txt", flags: 99)
        )

        XCTAssertTrue(matched)
    }

    func testEventMatchesTrigger_wrongEventType_noMatch() async {
        let manager = await makeManager()
        let rule = TriggerRule(event: "appActivated", conditions: [:], actions: [])

        let matched = await manager.eventMatchesTrigger(
            rule,
            event: AppEvent.timerFired(id: "timer")
        )

        XCTAssertFalse(matched)
    }

    func testEventMatchesTrigger_appActivated_withBundleId() async {
        let manager = await makeManager()
        let rule = TriggerRule(
            event: "appActivated",
            conditions: ["bundleId": "com.apple.finder"],
            actions: []
        )

        let matched = await manager.eventMatchesTrigger(
            rule,
            event: AppEvent.appActivated(bundleId: "com.apple.finder", appName: "Finder")
        )

        XCTAssertTrue(matched)
    }

    func testEventMatchesTrigger_timerFired() async {
        let manager = await makeManager()
        let rule = TriggerRule(
            event: "timerFired",
            conditions: ["id": "timer"],
            actions: []
        )

        let matched = await manager.eventMatchesTrigger(
            rule,
            event: AppEvent.timerFired(id: "timer")
        )

        XCTAssertTrue(matched)
    }

    func testEventMatchesTrigger_customEvent() async {
        let manager = await makeManager()
        let rule = TriggerRule(
            event: "custom",
            conditions: ["name": "plugin.demo", "kind": "celebration"],
            actions: []
        )

        let matched = await manager.eventMatchesTrigger(
            rule,
            event: AppEvent.custom(name: "plugin.demo", payload: ["kind": "celebration"])
        )

        XCTAssertTrue(matched)
    }

    func testMatchingTriggerExecutesManifestActionsInProcess() async throws {
        let pluginsDir = tempDir.appendingPathComponent("Plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        try createManifestOnlyPlugin(
            in: pluginsDir,
            bundleName: "GitCelebrate.vitaplugin",
            manifest: """
            {
              "id": "com.vitapet.plugin.git-celebrate",
              "name": "Git Celebrate",
              "version": "1.0.0",
              "description": "Celebrate git commits",
              "capabilities": [],
              "triggers": [
                {
                  "event": "fileChanged",
                  "conditions": {"pathPattern": "*/.git/COMMIT_EDITMSG"},
                  "actions": [
                    {"type": "animation", "state": "celebrate"},
                    {"type": "notification", "title": "Git", "message": "Commit successful!"},
                    {"type": "event", "name": "plugin.audit", "payload": {"source": "git"}}
                  ]
                }
              ]
            }
            """
        )

        let eventBus = EventBus()
        let manager = await makeManager(pluginDirectories: { [pluginsDir] })

        let animationExpectation = expectation(description: "animation event published")
        let notificationExpectation = expectation(description: "notification event published")
        let eventExpectation = expectation(description: "custom event published")

        let subscriptionID = await eventBus.subscribe { event in
            switch event {
            case .custom(let name, _) where name == "celebrate":
                animationExpectation.fulfill()
            case .custom(let name, let payload) where name == "plugin.notification.request":
                XCTAssertEqual(payload["title"], "Git")
                XCTAssertEqual(payload["body"], "Commit successful!")
                notificationExpectation.fulfill()
            case .custom(let name, let payload) where name == "plugin.audit":
                XCTAssertEqual(payload["source"], "git")
                eventExpectation.fulfill()
            default:
                break
            }
        }

        await manager.start(publishingTo: eventBus)
        await eventBus.publish(.fileChanged(path: "/tmp/repo/.git/COMMIT_EDITMSG", flags: 0))

        await fulfillment(of: [animationExpectation, notificationExpectation, eventExpectation], timeout: 3.0)

        await eventBus.unsubscribe(subscriptionID)
        await manager.stop()
    }

    func testListPlugins_returnsLoadedPlugins() async throws {
        let pluginsDir = tempDir.appendingPathComponent("Plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)

        try createManifestOnlyPlugin(
            in: pluginsDir,
            bundleName: "Alpha.vitaplugin",
            manifest: """
            {
              "id": "com.vitapet.plugin.alpha",
              "name": "Alpha Plugin",
              "version": "1.0.0",
              "description": "First test plugin",
              "capabilities": [],
              "triggers": []
            }
            """
        )
        try createManifestOnlyPlugin(
            in: pluginsDir,
            bundleName: "Beta.vitaplugin",
            manifest: """
            {
              "id": "com.vitapet.plugin.beta",
              "name": "Beta Plugin",
              "version": "2.0.0",
              "description": "Second test plugin",
              "capabilities": [],
              "triggers": []
            }
            """
        )

        let eventBus = EventBus()
        let manager = await makeManager(pluginDirectories: { [pluginsDir] })
        await manager.start(publishingTo: eventBus)

        let plugins = await manager.listPlugins()

        XCTAssertEqual(plugins.count, 2)
        XCTAssertEqual(
            Set(plugins.map { $0.id }),
            ["com.vitapet.plugin.alpha", "com.vitapet.plugin.beta"]
        )

        let alpha = try XCTUnwrap(plugins.first { $0.id == "com.vitapet.plugin.alpha" })
        XCTAssertEqual(alpha.name, "Alpha Plugin")
        XCTAssertEqual(alpha.version, "1.0.0")
        XCTAssertEqual(alpha.description, "First test plugin")
        XCTAssertTrue(alpha.isEnabled)

        let beta = try XCTUnwrap(plugins.first { $0.id == "com.vitapet.plugin.beta" })
        XCTAssertEqual(beta.name, "Beta Plugin")
        XCTAssertEqual(beta.version, "2.0.0")
        XCTAssertEqual(beta.description, "Second test plugin")
        XCTAssertTrue(beta.isEnabled)

        await manager.stop()
    }

    func testDeclarativePluginExecutesBubbleAndMoodActions() async throws {
        let pluginsDir = tempDir.appendingPathComponent("Plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        try createDeclarativePlugin(
            in: pluginsDir,
            directoryName: "HourlyChime",
            manifest: """
            {
              "id": "com.vitapet.test.declarative",
              "name": "Declarative Test",
              "version": "1.0.0",
              "description": "Bubble and mood actions",
              "capabilities": [],
              "triggers": [
                {
                  "event": "timerFired",
                  "conditions": {"id": "timer"},
                  "actions": [
                    {"type": "bubble", "message": "现在是 {hour} 点"},
                    {"type": "mood", "delta": "3"}
                  ]
                }
              ]
            }
            """
        )

        let eventBus = EventBus()
        let manager = await makeManager(pluginDirectories: { [pluginsDir] })

        let bubbleExpectation = expectation(description: "bubble callback invoked")
        let moodExpectation = expectation(description: "mood callback invoked")

        await manager.setBubbleRequestHandler { message in
            XCTAssertFalse(message.contains("{hour}"))
            bubbleExpectation.fulfill()
        }
        await manager.setMoodRequestHandler { delta in
            XCTAssertEqual(delta, 3)
            moodExpectation.fulfill()
        }

        await manager.start(publishingTo: eventBus)
        await eventBus.publish(.timerFired(id: "timer"))

        await fulfillment(of: [bubbleExpectation, moodExpectation], timeout: 1.0)
        await manager.stop()
    }

    func testListPlugins_showsEnabledStatus() async throws {
        let pluginsDir = tempDir.appendingPathComponent("Plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)

        try createManifestOnlyPlugin(
            in: pluginsDir,
            bundleName: "Alpha.vitaplugin",
            manifest: """
            {
              "id": "com.vitapet.plugin.alpha",
              "name": "Alpha Plugin",
              "version": "1.0.0",
              "description": "First test plugin",
              "capabilities": [],
              "triggers": []
            }
            """
        )
        try createManifestOnlyPlugin(
            in: pluginsDir,
            bundleName: "Beta.vitaplugin",
            manifest: """
            {
              "id": "com.vitapet.plugin.beta",
              "name": "Beta Plugin",
              "version": "2.0.0",
              "description": "Second test plugin",
              "capabilities": [],
              "triggers": []
            }
            """
        )

        let eventBus = EventBus()
        let manager = await makeManager(pluginDirectories: { [pluginsDir] })
        await manager.start(publishingTo: eventBus)
        try await manager.setPluginEnabled(id: "com.vitapet.plugin.beta", enabled: false)

        let plugins = await manager.listPlugins()

        let alpha = try XCTUnwrap(plugins.first { $0.id == "com.vitapet.plugin.alpha" })
        XCTAssertTrue(alpha.isEnabled)

        let beta = try XCTUnwrap(plugins.first { $0.id == "com.vitapet.plugin.beta" })
        XCTAssertFalse(beta.isEnabled)

        await manager.stop()
    }

    func testSetPluginEnabled_disablePlugin() async throws {
        let pluginsDir = tempDir.appendingPathComponent("Plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)

        try createManifestOnlyPlugin(
            in: pluginsDir,
            bundleName: "Toggle.vitaplugin",
            manifest: """
            {
              "id": "com.vitapet.plugin.toggle",
              "name": "Toggle Plugin",
              "version": "1.0.0",
              "description": "Plugin for enable disable tests",
              "capabilities": [],
              "triggers": []
            }
            """
        )

        let eventBus = EventBus()
        let manager = await makeManager(pluginDirectories: { [pluginsDir] })
        await manager.start(publishingTo: eventBus)

        try await manager.setPluginEnabled(id: "com.vitapet.plugin.toggle", enabled: false)

        let isEnabled = await manager.isPluginEnabled("com.vitapet.plugin.toggle")
        XCTAssertFalse(isEnabled)

        await manager.stop()
    }

    func testSetPluginEnabled_reEnablePlugin() async throws {
        let pluginsDir = tempDir.appendingPathComponent("Plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)

        try createManifestOnlyPlugin(
            in: pluginsDir,
            bundleName: "Toggle.vitaplugin",
            manifest: """
            {
              "id": "com.vitapet.plugin.toggle",
              "name": "Toggle Plugin",
              "version": "1.0.0",
              "description": "Plugin for enable disable tests",
              "capabilities": [],
              "triggers": []
            }
            """
        )

        let eventBus = EventBus()
        let manager = await makeManager(pluginDirectories: { [pluginsDir] })
        await manager.start(publishingTo: eventBus)

        try await manager.setPluginEnabled(id: "com.vitapet.plugin.toggle", enabled: false)
        try await manager.setPluginEnabled(id: "com.vitapet.plugin.toggle", enabled: true)

        let isEnabled = await manager.isPluginEnabled("com.vitapet.plugin.toggle")
        XCTAssertTrue(isEnabled)

        await manager.stop()
    }

    func testRouteEvent_skipsDisabledPlugin() async throws {
        let pluginsDir = tempDir.appendingPathComponent("Plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)

        try createManifestOnlyPlugin(
            in: pluginsDir,
            bundleName: "Silent.vitaplugin",
            manifest: """
            {
              "id": "com.vitapet.plugin.silent",
              "name": "Silent Plugin",
              "version": "1.0.0",
              "description": "Disabled plugins should not fire",
              "capabilities": [],
              "triggers": [
                {
                  "event": "custom",
                  "conditions": {"name": "input.event"},
                  "actions": [
                    {"type": "event", "name": "output.disabled", "payload": {"plugin": "silent"}}
                  ]
                }
              ]
            }
            """
        )

        let eventBus = EventBus()
        let manager = await makeManager(pluginDirectories: { [pluginsDir] })
        let outputExpectation = expectation(description: "disabled plugin should not publish action event")
        outputExpectation.isInverted = true

        let subscriptionID = await eventBus.subscribe { event in
            if case .custom(let name, _) = event, name == "output.disabled" {
                outputExpectation.fulfill()
            }
        }

        await manager.start(publishingTo: eventBus)
        try await manager.setPluginEnabled(id: "com.vitapet.plugin.silent", enabled: false)
        await eventBus.publish(.custom(name: "input.event", payload: [:]))

        await fulfillment(of: [outputExpectation], timeout: 1.0)

        await eventBus.unsubscribe(subscriptionID)
        await manager.stop()
    }

    func testRouteEvent_enabledPluginStillFires() async throws {
        let pluginsDir = tempDir.appendingPathComponent("Plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)

        try createManifestOnlyPlugin(
            in: pluginsDir,
            bundleName: "Enabled.vitaplugin",
            manifest: """
            {
              "id": "com.vitapet.plugin.enabled",
              "name": "Enabled Plugin",
              "version": "1.0.0",
              "description": "Enabled plugin should keep firing",
              "capabilities": [],
              "triggers": [
                {
                  "event": "custom",
                  "conditions": {"name": "input.event"},
                  "actions": [
                    {"type": "event", "name": "output.enabled", "payload": {"plugin": "enabled"}}
                  ]
                }
              ]
            }
            """
        )
        try createManifestOnlyPlugin(
            in: pluginsDir,
            bundleName: "Disabled.vitaplugin",
            manifest: """
            {
              "id": "com.vitapet.plugin.disabled",
              "name": "Disabled Plugin",
              "version": "1.0.0",
              "description": "Disabled plugin should be skipped",
              "capabilities": [],
              "triggers": [
                {
                  "event": "custom",
                  "conditions": {"name": "input.event"},
                  "actions": [
                    {"type": "event", "name": "output.disabled", "payload": {"plugin": "disabled"}}
                  ]
                }
              ]
            }
            """
        )

        let eventBus = EventBus()
        let manager = await makeManager(pluginDirectories: { [pluginsDir] })
        let enabledExpectation = expectation(description: "enabled plugin publishes action event")
        let disabledExpectation = expectation(description: "disabled plugin should not publish action event")
        disabledExpectation.isInverted = true

        let subscriptionID = await eventBus.subscribe { event in
            if case .custom(let name, _) = event {
                if name == "output.enabled" {
                    enabledExpectation.fulfill()
                }
                if name == "output.disabled" {
                    disabledExpectation.fulfill()
                }
            }
        }

        await manager.start(publishingTo: eventBus)
        try await manager.setPluginEnabled(id: "com.vitapet.plugin.disabled", enabled: false)
        await eventBus.publish(.custom(name: "input.event", payload: [:]))

        await fulfillment(of: [enabledExpectation, disabledExpectation], timeout: 1.0)

        await eventBus.unsubscribe(subscriptionID)
        await manager.stop()
    }

    private func createManifestOnlyPlugin(in directory: URL, bundleName: String, manifest: String) throws {
        let bundleURL = directory.appendingPathComponent(bundleName, isDirectory: true)
        let resourcesURL = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)

        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: resourcesURL.appendingPathComponent("plugin.json"))
    }

    private func createDeclarativePlugin(in directory: URL, directoryName: String, manifest: String) throws {
        let pluginURL = directory.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: pluginURL, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: pluginURL.appendingPathComponent("plugin.json"))
    }
}
