import Foundation
import XCTest
@testable import RenderEngine

final class BehaviorManifestTests: XCTestCase {
    func testDecodeFromJSON() throws {
        guard let url = Bundle.module.url(
            forResource: "behavior",
            withExtension: "json",
            subdirectory: "Resources"
        ) ?? Bundle.module.url(forResource: "behavior", withExtension: "json") else {
            return XCTFail("behavior.json not found in bundle resources")
        }

        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(BehaviorManifest.self, from: data)

        XCTAssertEqual(manifest.version, "1.0.0")
        XCTAssertEqual(manifest.behaviors.count, 51)
        XCTAssertEqual(manifest.idleBehaviors.count, 3)
        XCTAssertEqual(manifest.behaviors["walk"]?.type, .move)
        XCTAssertEqual(manifest.behaviors["edgeBounce"]?.type, .edgeReaction)
        XCTAssertEqual(manifest.behaviors["lookAtCursor"]?.type, .track)
        XCTAssertEqual(manifest.behaviors["sitOnWindow"]?.type, .windowSit)
        XCTAssertEqual(manifest.behaviors["climb"]?.type, .windowClimb)
    }

    func testDefaultManifest() {
        let manifest = BehaviorManifest.defaultManifest()

        XCTAssertEqual(manifest.version, "1.0.0")
        XCTAssertFalse(manifest.behaviors.isEmpty)
        XCTAssertFalse(manifest.idleBehaviors.isEmpty)
        XCTAssertEqual(manifest.behaviors.count, 51)
        XCTAssertEqual(manifest.idleBehaviors.count, 3)
    }

    func testBehaviorLookup() {
        let manifest = BehaviorManifest.defaultManifest()

        let walk = manifest.behaviors["walk"]
        XCTAssertEqual(walk?.type, .move)
        XCTAssertEqual(walk?.speed, 60)
        XCTAssertEqual(walk?.targetMode, "random")
        XCTAssertEqual(walk?.maxDistance, 200)
        XCTAssertEqual(walk?.minDistance, 50)
        XCTAssertEqual(walk?.animation, "walk")
        XCTAssertEqual(walk?.flipToDirection, true)
    }

    func testIdleBehaviors() {
        let manifest = BehaviorManifest.defaultManifest()

        let happyTotal = manifest.idleBehaviors["happy"]?.values.reduce(0, +) ?? 0
        let normalTotal = manifest.idleBehaviors["normal"]?.values.reduce(0, +) ?? 0
        let sadTotal = manifest.idleBehaviors["sad"]?.values.reduce(0, +) ?? 0

        XCTAssertEqual(happyTotal, 103)
        XCTAssertEqual(normalTotal, 102)
        XCTAssertEqual(sadTotal, 94)
    }

    func testLoadBundledManifest() {
        let manifest = SpritePackLoader.loadBundledBehaviorManifest()

        XCTAssertEqual(manifest.version, "1.0.0")
        XCTAssertFalse(manifest.behaviors.isEmpty)
        XCTAssertFalse(manifest.idleBehaviors.isEmpty)
    }
}
