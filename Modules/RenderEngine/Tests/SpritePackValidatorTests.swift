import Foundation
import XCTest
@testable import RenderEngine

final class SpritePackValidatorTests: XCTestCase {
    func testValidateReturnsValidForWellFormedSpritePackDirectory() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifest = SpriteManifest(
            name: "Valid Pack",
            version: "1.0.0",
            states: [
                AnimationState.idle.rawValue: .init(
                    frames: ["idle_0", "idle_1"],
                    frameInterval: 0.1,
                    loop: true
                ),
                AnimationState.walk.rawValue: .init(
                    frames: ["walk_0"],
                    frameInterval: 0.1,
                    loop: true
                )
            ]
        )
        try writeManifest(manifest, to: directory)
        try createPNG(named: "idle_0", in: directory)
        try createPNG(named: "idle_1", in: directory)
        try createPNG(named: "walk_0", in: directory)

        let result = SpritePackValidator.validate(directory: directory)

        guard case let .valid(loadedManifest) = result else {
            return XCTFail("Expected validation result to be valid")
        }

        XCTAssertEqual(loadedManifest.name, manifest.name)
        XCTAssertEqual(loadedManifest.version, manifest.version)
        XCTAssertEqual(loadedManifest.states[AnimationState.idle.rawValue]?.frames, ["idle_0", "idle_1"])
        XCTAssertEqual(loadedManifest.states[AnimationState.walk.rawValue]?.frames, ["walk_0"])
    }

    func testValidateReturnsMissingManifestWhenManifestDoesNotExist() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = SpritePackValidator.validate(directory: directory)

        assertInvalid(
            result,
            equals: [.missingManifest]
        )
    }

    func testValidateReturnsInvalidManifestWhenManifestJSONIsMalformed() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data("{ invalid json".utf8).write(to: directory.appendingPathComponent("manifest.json"))

        let result = SpritePackValidator.validate(directory: directory)

        guard case let .invalid(errors) = result else {
            return XCTFail("Expected validation result to be invalid")
        }

        XCTAssertEqual(errors.count, 1)
        guard case let .invalidManifest(description) = errors[0] else {
            return XCTFail("Expected invalidManifest error")
        }
        XCTAssertFalse(description.isEmpty)
    }

    func testValidateReturnsMissingRequiredStateWhenIdleStateIsAbsent() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifest = SpriteManifest(
            name: "No Idle",
            version: "1.0.0",
            states: [
                AnimationState.walk.rawValue: .init(
                    frames: ["walk_0"],
                    frameInterval: 0.1,
                    loop: true
                )
            ]
        )
        try writeManifest(manifest, to: directory)
        try createPNG(named: "walk_0", in: directory)

        let result = SpritePackValidator.validate(directory: directory)

        assertInvalid(
            result,
            equals: [.missingRequiredState(AnimationState.idle.rawValue)]
        )
    }

    func testValidateReturnsMissingFrameWhenReferencedPNGDoesNotExist() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifest = SpriteManifest(
            name: "Missing Frame",
            version: "1.0.0",
            states: [
                AnimationState.idle.rawValue: .init(
                    frames: ["idle_0", "missing_idle"],
                    frameInterval: 0.1,
                    loop: true
                )
            ]
        )
        try writeManifest(manifest, to: directory)
        try createPNG(named: "idle_0", in: directory)

        let result = SpritePackValidator.validate(directory: directory)

        assertInvalid(
            result,
            equals: [.missingFrame("missing_idle")]
        )
    }

    func testValidateReturnsAllCollectedErrorsForManifestSemanticFailures() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifest = SpriteManifest(
            name: "Broken Pack",
            version: "1.0.0",
            states: [
                AnimationState.walk.rawValue: .init(
                    frames: ["walk_0", "missing_shared"],
                    frameInterval: 0.1,
                    loop: true
                ),
                AnimationState.react.rawValue: .init(
                    frames: ["missing_react", "missing_shared"],
                    frameInterval: 0.1,
                    loop: false
                )
            ]
        )
        try writeManifest(manifest, to: directory)
        try createPNG(named: "walk_0", in: directory)

        let result = SpritePackValidator.validate(directory: directory)

        assertInvalid(
            result,
            equals: [
                .missingRequiredState(AnimationState.idle.rawValue),
                .missingFrame("missing_react"),
                .missingFrame("missing_shared")
            ]
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeManifest(_ manifest: SpriteManifest, to directory: URL) throws {
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: directory.appendingPathComponent("manifest.json"))
    }

    private func createPNG(named name: String, in directory: URL) throws {
        try Data().write(to: directory.appendingPathComponent("\(name).png"))
    }

    private func assertInvalid(
        _ result: SpritePackValidationResult,
        equals expected: [SpritePackValidationError],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .invalid(errors) = result else {
            return XCTFail("Expected validation result to be invalid", file: file, line: line)
        }

        XCTAssertEqual(errors, expected, file: file, line: line)
    }
}
