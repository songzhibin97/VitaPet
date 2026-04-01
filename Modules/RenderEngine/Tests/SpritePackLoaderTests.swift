import Foundation
import XCTest
@testable import RenderEngine

final class SpritePackLoaderTests: XCTestCase {
    func testDefaultManifestContainsAllAnimationStates() {
        let manifest = SpritePackLoader.defaultManifest()

        XCTAssertEqual(manifest.states.count, AnimationState.allCases.count)
        XCTAssertEqual(Set(manifest.states.keys), Set(AnimationState.allCases.map(\.rawValue)))
    }

    func testDefaultManifestIdleHasTwoFrames() throws {
        let manifest = SpritePackLoader.defaultManifest()

        XCTAssertEqual(try stateAnimation(named: .idle, in: manifest).frames.count, 2)
    }

    func testDefaultManifestWalkHasFourFrames() throws {
        let manifest = SpritePackLoader.defaultManifest()

        XCTAssertEqual(try stateAnimation(named: .walk, in: manifest).frames.count, 4)
    }

    func testDefaultManifestReactLoopIsFalse() throws {
        let manifest = SpritePackLoader.defaultManifest()

        XCTAssertFalse(try stateAnimation(named: .react, in: manifest).loop)
    }

    func testDefaultManifestSleepLoopIsTrue() throws {
        let manifest = SpritePackLoader.defaultManifest()

        XCTAssertTrue(try stateAnimation(named: .sleep, in: manifest).loop)
    }

    func testDefaultManifestDragHasOneFrame() throws {
        let manifest = SpritePackLoader.defaultManifest()

        XCTAssertEqual(try stateAnimation(named: .drag, in: manifest).frames.count, 1)
    }

    func testDefaultManifestCelebrateHasThreeFrames() throws {
        let manifest = SpritePackLoader.defaultManifest()

        XCTAssertEqual(try stateAnimation(named: .celebrate, in: manifest).frames.count, 3)
    }

    func testLoadManifestFromDirectoryLoadsValidManifest() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let expectedManifest = SpriteManifest(
            name: "TempPack",
            version: "1.2.3",
            states: [
                AnimationState.idle.rawValue: .init(
                    frames: ["idle_a", "idle_b"],
                    frameInterval: 0.2,
                    loop: true
                )
            ]
        )
        let data = try JSONEncoder().encode(expectedManifest)
        try data.write(to: tempDirectory.appendingPathComponent("manifest.json"))

        let loadedManifest = try SpritePackLoader.loadManifest(from: tempDirectory)

        XCTAssertEqual(loadedManifest.name, expectedManifest.name)
        XCTAssertEqual(loadedManifest.version, expectedManifest.version)
        XCTAssertEqual(loadedManifest.states[AnimationState.idle.rawValue]?.frames, expectedManifest.states[AnimationState.idle.rawValue]?.frames)
        XCTAssertEqual(loadedManifest.states[AnimationState.idle.rawValue]?.frameInterval, expectedManifest.states[AnimationState.idle.rawValue]?.frameInterval)
        XCTAssertEqual(loadedManifest.states[AnimationState.idle.rawValue]?.loop, expectedManifest.states[AnimationState.idle.rawValue]?.loop)
    }

    func testLoadManifestFromDirectoryThrowsWhenFileDoesNotExist() {
        let missingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        XCTAssertThrowsError(try SpritePackLoader.loadManifest(from: missingDirectory))
    }

    func testLoadBundledManifestReturnsValidManifest() {
        let manifest = SpritePackLoader.loadBundledManifest()

        XCTAssertFalse(manifest.name.isEmpty)
        XCTAssertFalse(manifest.states.isEmpty)
    }

    func testDiscoverPacksIncludesDefaultAndCustomPack() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let customPackDirectory = tempDirectory.appendingPathComponent("retro", isDirectory: true)
        try FileManager.default.createDirectory(at: customPackDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let manifest = SpriteManifest(
            name: "Retro Cat",
            version: "1.0.0",
            states: [
                AnimationState.idle.rawValue: .init(
                    frames: ["idle_0"],
                    frameInterval: 0.2,
                    loop: true
                )
            ]
        )
        try JSONEncoder().encode(manifest).write(
            to: customPackDirectory.appendingPathComponent("manifest.json")
        )

        let packs = SpritePackLoader.discoverPacks(
            in: tempDirectory,
            bundledDirectory: tempDirectory
        )

        XCTAssertEqual(packs.count, 1)
        XCTAssertEqual(packs.first?.id, "retro")
        XCTAssertEqual(packs.first?.name, "Retro Cat")
        XCTAssertEqual(
            packs.last?.directory.standardizedFileURL,
            customPackDirectory.standardizedFileURL
        )
    }

    func testDiscoverPacksSkipsInvalidDirectories() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let invalidPackDirectory = tempDirectory.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: invalidPackDirectory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: invalidPackDirectory.appendingPathComponent("manifest.json"))
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let packs = SpritePackLoader.discoverPacks(
            in: tempDirectory,
            bundledDirectory: tempDirectory
        )

        XCTAssertEqual(packs.map(\.id), ["default"])
    }

    private func stateAnimation(
        named state: AnimationState,
        in manifest: SpriteManifest,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> SpriteManifest.StateAnimation {
        guard let animation = manifest.states[state.rawValue] else {
            XCTFail("Missing animation for state \(state.rawValue)", file: file, line: line)
            struct MissingStateError: Error {}
            throw MissingStateError()
        }

        return animation
    }
}
