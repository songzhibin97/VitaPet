import Foundation
import XCTest
@testable import RenderEngine

final class SpritePackBuilderTests: XCTestCase {
    func testAutoDetectClassifiesFilesByAnimationState() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try createPNG(named: "idle_0", in: directory)
        try createPNG(named: "pet_walk_1", in: directory)
        try createPNG(named: "my_sleep", in: directory)
        try createPNG(named: "react_2", in: directory)

        let detected = SpritePackBuilder.autoDetect(from: directory)

        XCTAssertEqual(detected[AnimationState.idle.rawValue]?.map(\.lastPathComponent), ["idle_0.png"])
        XCTAssertEqual(detected[AnimationState.walk.rawValue]?.map(\.lastPathComponent), ["pet_walk_1.png"])
        XCTAssertEqual(detected[AnimationState.sleep.rawValue]?.map(\.lastPathComponent), ["my_sleep.png"])
        XCTAssertEqual(detected[AnimationState.react.rawValue]?.map(\.lastPathComponent), ["react_2.png"])
    }

    func testAutoDetectFallsBackToIdleForUnknownFiles() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try createPNG(named: "mystery_pose", in: directory)

        let detected = SpritePackBuilder.autoDetect(from: directory)

        XCTAssertEqual(detected[AnimationState.idle.rawValue]?.map(\.lastPathComponent), ["mystery_pose.png"])
    }

    func testAutoDetectMatchesLookAroundCamelCaseAndUnderscore() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try createPNG(named: "lookaround_0", in: directory)
        try createPNG(named: "look_around_1", in: directory)

        let detected = SpritePackBuilder.autoDetect(from: directory)

        XCTAssertEqual(
            detected[AnimationState.lookAround.rawValue]?.map(\.lastPathComponent),
            ["look_around_1.png", "lookaround_0.png"]
        )
    }

    func testBuildCreatesSpritePackDirectoryManifestAndImages() throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sources = workspace.appendingPathComponent("sources", isDirectory: true)
        let output = workspace.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)

        let idle0 = try createPNG(named: "idle_source_0", in: sources)
        let idle1 = try createPNG(named: "idle_source_1", in: sources)
        let walk0 = try createPNG(named: "walk_source_0", in: sources)

        let packURL = try SpritePackBuilder.build(
            named: "cat",
            frames: [
                AnimationState.idle.rawValue: [idle0, idle1],
                AnimationState.walk.rawValue: [walk0]
            ],
            outputDirectory: output
        )

        XCTAssertEqual(packURL.lastPathComponent, "cat")
        XCTAssertTrue(FileManager.default.fileExists(atPath: packURL.appendingPathComponent("cat_idle_0.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: packURL.appendingPathComponent("cat_idle_1.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: packURL.appendingPathComponent("cat_walk_0.png").path))

        let manifest = try SpritePackLoader.loadManifest(from: packURL)
        XCTAssertEqual(manifest.name, "cat")
        XCTAssertEqual(manifest.version, "1.0.0")
        XCTAssertEqual(manifest.states.keys.sorted(), [AnimationState.idle.rawValue, AnimationState.walk.rawValue])
        XCTAssertEqual(manifest.states[AnimationState.idle.rawValue]?.frames, ["cat_idle_0", "cat_idle_1"])
        XCTAssertEqual(manifest.states[AnimationState.idle.rawValue]?.frameInterval, 0.5)
        XCTAssertEqual(manifest.states[AnimationState.idle.rawValue]?.loop, true)
        XCTAssertEqual(manifest.states[AnimationState.walk.rawValue]?.frames, ["cat_walk_0"])
        XCTAssertEqual(manifest.states[AnimationState.walk.rawValue]?.frameInterval, 0.15)
        XCTAssertEqual(manifest.states[AnimationState.walk.rawValue]?.loop, true)
    }

    func testBuildThrowsWhenIdleFramesMissing() throws {
        let output = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: output) }

        XCTAssertThrowsError(
            try SpritePackBuilder.build(
                named: "cat",
                frames: [AnimationState.walk.rawValue: []],
                outputDirectory: output
            )
        ) { error in
            XCTAssertEqual(error as? SpritePackBuilderError, .missingIdleFrames)
        }
    }

    func testBuildAutoRenamesWhenTargetDirectoryAlreadyExists() throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sources = workspace.appendingPathComponent("sources", isDirectory: true)
        let output = workspace.appendingPathComponent("output", isDirectory: true)
        let existing = output.appendingPathComponent("cat", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)

        let idle = try createPNG(named: "idle_source", in: sources)

        let packURL = try SpritePackBuilder.build(
            named: "cat",
            frames: [AnimationState.idle.rawValue: [idle]],
            outputDirectory: output
        )

        XCTAssertEqual(packURL.lastPathComponent, "cat_2")
        XCTAssertTrue(FileManager.default.fileExists(atPath: existing.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: packURL.path))

        let manifest = try SpritePackLoader.loadManifest(from: packURL)
        XCTAssertEqual(manifest.name, "cat_2")
        XCTAssertEqual(manifest.states[AnimationState.idle.rawValue]?.frames, ["cat_2_idle_0"])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    private func createPNG(named name: String, in directory: URL) throws -> URL {
        let fileURL = directory.appendingPathComponent("\(name).png")
        try Data("png".utf8).write(to: fileURL)
        return fileURL
    }
}
