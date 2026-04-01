import XCTest
@testable import RenderEngine

final class SpriteManifestTests: XCTestCase {
    func testManifestCodableRoundTrip() throws {
        let manifest = SpriteManifest(
            name: "TestPack",
            version: "2.1.0",
            states: [
                AnimationState.idle.rawValue: .init(
                    frames: ["idle_0", "idle_1"],
                    frameInterval: 0.25,
                    loop: true
                ),
                AnimationState.react.rawValue: .init(
                    frames: ["react_0"],
                    frameInterval: 0.5,
                    loop: false
                )
            ]
        )

        let encoded = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(SpriteManifest.self, from: encoded)

        XCTAssertEqual(decoded.name, manifest.name)
        XCTAssertEqual(decoded.version, manifest.version)
        XCTAssertEqual(decoded.states.count, manifest.states.count)
        XCTAssertEqual(decoded.states[AnimationState.idle.rawValue]?.frames, manifest.states[AnimationState.idle.rawValue]?.frames)
        XCTAssertEqual(decoded.states[AnimationState.idle.rawValue]?.frameInterval, manifest.states[AnimationState.idle.rawValue]?.frameInterval)
        XCTAssertEqual(decoded.states[AnimationState.idle.rawValue]?.loop, manifest.states[AnimationState.idle.rawValue]?.loop)
        XCTAssertEqual(decoded.states[AnimationState.react.rawValue]?.frames, manifest.states[AnimationState.react.rawValue]?.frames)
        XCTAssertEqual(decoded.states[AnimationState.react.rawValue]?.frameInterval, manifest.states[AnimationState.react.rawValue]?.frameInterval)
        XCTAssertEqual(decoded.states[AnimationState.react.rawValue]?.loop, manifest.states[AnimationState.react.rawValue]?.loop)
    }

    func testStateAnimationCodableRoundTrip() throws {
        let animation = SpriteManifest.StateAnimation(
            frames: ["frame_0", "frame_1", "frame_2"],
            frameInterval: 0.125,
            loop: false
        )

        let encoded = try JSONEncoder().encode(animation)
        let decoded = try JSONDecoder().decode(SpriteManifest.StateAnimation.self, from: encoded)

        XCTAssertEqual(decoded.frames, animation.frames)
        XCTAssertEqual(decoded.frameInterval, animation.frameInterval)
        XCTAssertEqual(decoded.loop, animation.loop)
    }
}
