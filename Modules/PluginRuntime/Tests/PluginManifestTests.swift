import XCTest
@testable import PluginRuntime

final class PluginManifestTests: XCTestCase {
    func testDecodeValidManifest() throws {
        let data = Data(
            """
            {
              "id": "com.vitapet.gitcelebrate",
              "name": "Git Celebrate",
              "version": "1.0.0",
              "description": "Celebrate commits",
              "capabilities": ["animation", "notifications"],
              "triggers": [
                {
                  "event": "fileChanged",
                  "conditions": {
                    "pathPattern": "*/.git/*"
                  },
                  "actions": [
                    {
                      "type": "animate",
                      "state": "celebrate"
                    }
                  ]
                }
              ]
            }
            """.utf8
        )

        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)

        XCTAssertEqual(manifest.id, "com.vitapet.gitcelebrate")
        XCTAssertEqual(manifest.name, "Git Celebrate")
        XCTAssertEqual(manifest.version, "1.0.0")
        XCTAssertEqual(manifest.description, "Celebrate commits")
        XCTAssertEqual(manifest.capabilities, ["animation", "notifications"])
        XCTAssertEqual(manifest.triggers.count, 1)
        XCTAssertEqual(manifest.triggers[0].event, "fileChanged")
    }

    func testDecodeMinimalManifest() throws {
        let data = Data(
            """
            {
              "id": "com.vitapet.minimal",
              "name": "Minimal",
              "version": "0.1.0",
              "description": "Minimal plugin",
              "capabilities": [],
              "triggers": []
            }
            """.utf8
        )

        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)

        XCTAssertEqual(manifest.id, "com.vitapet.minimal")
        XCTAssertTrue(manifest.capabilities.isEmpty)
        XCTAssertTrue(manifest.triggers.isEmpty)
    }

    func testDecodeMissingRequiredField() {
        let data = Data(
            """
            {
              "name": "Broken",
              "version": "0.1.0",
              "description": "Missing id",
              "capabilities": [],
              "triggers": []
            }
            """.utf8
        )

        XCTAssertThrowsError(try JSONDecoder().decode(PluginManifest.self, from: data))
    }

    func testTriggerRuleDecoding() throws {
        let data = Data(
            """
            {
              "id": "com.vitapet.triggers",
              "name": "Trigger Test",
              "version": "1.0.0",
              "description": "Trigger decode",
              "capabilities": ["animation"],
              "triggers": [
                {
                  "event": "appActivated",
                  "conditions": {
                    "bundleId": "com.apple.finder",
                    "appName": "Finder"
                  },
                  "actions": []
                }
              ]
            }
            """.utf8
        )

        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        let rule = try XCTUnwrap(manifest.triggers.first)

        XCTAssertEqual(rule.event, "appActivated")
        XCTAssertEqual(rule.conditions["bundleId"], "com.apple.finder")
        XCTAssertEqual(rule.conditions["appName"], "Finder")
        XCTAssertTrue(rule.actions.isEmpty)
    }

    func testPluginActionDecoding() throws {
        let data = Data(
            """
            {
              "id": "com.vitapet.actions",
              "name": "Action Test",
              "version": "1.0.0",
              "description": "Action decode",
              "capabilities": ["animation", "notifications"],
              "triggers": [
                {
                  "event": "custom",
                  "conditions": {},
                  "actions": [
                    {
                      "type": "animate",
                      "state": "wave"
                    },
                    {
                      "type": "notify",
                      "title": "Hello",
                      "message": "World"
                    },
                    {
                      "type": "publish",
                      "name": "plugin.event",
                      "payload": {
                        "key": "value"
                      }
                    }
                  ]
                }
              ]
            }
            """.utf8
        )

        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        let actions = try XCTUnwrap(manifest.triggers.first?.actions)

        XCTAssertEqual(actions.count, 3)
        XCTAssertEqual(actions[0].type, "animate")
        XCTAssertEqual(actions[0].state, "wave")
        XCTAssertEqual(actions[1].type, "notify")
        XCTAssertEqual(actions[1].title, "Hello")
        XCTAssertEqual(actions[1].message, "World")
        XCTAssertEqual(actions[2].type, "publish")
        XCTAssertEqual(actions[2].name, "plugin.event")
        XCTAssertEqual(actions[2].payload?["key"], "value")
    }

    func testEncodeRoundtrip() throws {
        let manifest = PluginManifest(
            id: "com.vitapet.roundtrip",
            name: "Roundtrip",
            version: "2.0.0",
            description: "Encode decode",
            capabilities: ["animation"],
            triggers: [
                TriggerRule(
                    event: "timerFired",
                    conditions: ["id": "timer"],
                    actions: [
                        PluginAction(type: "animate", state: "idle"),
                        PluginAction(type: "notify", message: "Tick", title: "Timer")
                    ]
                )
            ]
        )

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(PluginManifest.self, from: data)

        XCTAssertEqual(decoded.id, manifest.id)
        XCTAssertEqual(decoded.name, manifest.name)
        XCTAssertEqual(decoded.version, manifest.version)
        XCTAssertEqual(decoded.description, manifest.description)
        XCTAssertEqual(decoded.capabilities, manifest.capabilities)
        XCTAssertEqual(decoded.triggers.count, manifest.triggers.count)
        XCTAssertEqual(decoded.triggers[0].event, manifest.triggers[0].event)
        XCTAssertEqual(decoded.triggers[0].conditions, manifest.triggers[0].conditions)
        XCTAssertEqual(decoded.triggers[0].actions[0].type, manifest.triggers[0].actions[0].type)
        XCTAssertEqual(decoded.triggers[0].actions[0].state, manifest.triggers[0].actions[0].state)
        XCTAssertEqual(decoded.triggers[0].actions[1].title, manifest.triggers[0].actions[1].title)
        XCTAssertEqual(decoded.triggers[0].actions[1].message, manifest.triggers[0].actions[1].message)
    }

    func testEmptyTriggersArray() throws {
        let data = Data(
            """
            {
              "id": "com.vitapet.emptytriggers",
              "name": "Empty Triggers",
              "version": "1.0.0",
              "description": "No triggers",
              "capabilities": ["animation"],
              "triggers": []
            }
            """.utf8
        )

        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)

        XCTAssertTrue(manifest.triggers.isEmpty)
    }

    func testEmptyCapabilities() throws {
        let data = Data(
            """
            {
              "id": "com.vitapet.emptycaps",
              "name": "Empty Caps",
              "version": "1.0.0",
              "description": "No capabilities",
              "capabilities": [],
              "triggers": [
                {
                  "event": "focusEntered",
                  "conditions": {},
                  "actions": []
                }
              ]
            }
            """.utf8
        )

        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)

        XCTAssertTrue(manifest.capabilities.isEmpty)
        XCTAssertEqual(manifest.triggers.count, 1)
    }
}
