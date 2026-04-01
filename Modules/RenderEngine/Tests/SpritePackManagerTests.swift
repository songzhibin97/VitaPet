import Foundation
import XCTest
@testable import RenderEngine

final class SpritePackManagerTests: XCTestCase {
    private var storageURL: URL!
    private var manager: SpritePackManager!

    override func setUpWithError() throws {
        storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
        manager = SpritePackManager(storageURL: storageURL)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: storageURL.path) {
            try FileManager.default.removeItem(at: storageURL)
        }
        storageURL = nil
        manager = nil
    }

    func testDeleteDefaultThrowsCannotDeleteBuiltIn() async {
        do {
            try await manager.delete(packID: "PixelCat")
            XCTFail("Expected delete to throw")
        } catch let error as SpritePackManagerError {
            XCTAssertEqual(error, .cannotDeleteBuiltIn)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCopyFolderValidDirectoryReturnsSpritePackInfo() async throws {
        let sourceDirectory = try makeValidPackDirectory(named: "retro-pack")

        let info = try await manager.copyFolder(sourceDirectory)

        XCTAssertEqual(info.id, "retro-pack")
        XCTAssertEqual(info.name, "retro-pack")
        XCTAssertEqual(
            info.directory.standardizedFileURL,
            storageURL.appendingPathComponent("retro-pack", isDirectory: true).standardizedFileURL
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: info.directory.path))
    }

    func testCopyFolderMissingManifestThrowsValidationFailed() async throws {
        let sourceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }

        do {
            _ = try await manager.copyFolder(sourceDirectory)
            XCTFail("Expected copyFolder to throw")
        } catch let error as SpritePackManagerError {
            XCTAssertEqual(error, .validationFailed([.missingManifest]))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCopyFolderWhenDestinationExistsThrowsPackAlreadyExists() async throws {
        let sourceDirectory = try makeValidPackDirectory(named: "existing-pack")
        try FileManager.default.createDirectory(
            at: storageURL.appendingPathComponent("existing-pack", isDirectory: true),
            withIntermediateDirectories: true
        )

        do {
            _ = try await manager.copyFolder(sourceDirectory)
            XCTFail("Expected copyFolder to throw")
        } catch let error as SpritePackManagerError {
            XCTAssertEqual(error, .packAlreadyExists("existing-pack"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCreateTemplateGeneratesManifestAndAllFrames() async throws {
        let templateURL = try await manager.createTemplate(named: "template-pack")
        let manifest = try SpritePackLoader.loadManifest(from: templateURL)

        XCTAssertEqual(manifest.name, "template-pack")
        XCTAssertEqual(manifest.version, "1.0.0")
        XCTAssertEqual(Set(manifest.states.keys), Set(AnimationState.allCases.map(\.rawValue)))

        let frameNames = Set(manifest.states.values.flatMap(\.frames))
        XCTAssertEqual(frameNames.count, AnimationState.allCases.count * 2)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: templateURL.appendingPathComponent("manifest.json").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: templateURL.appendingPathComponent("README.txt").path
            )
        )

        for frameName in frameNames {
            let frameURL = templateURL.appendingPathComponent("\(frameName).png")
            XCTAssertTrue(FileManager.default.fileExists(atPath: frameURL.path))
            let attributes = try FileManager.default.attributesOfItem(atPath: frameURL.path)
            XCTAssertGreaterThan((attributes[.size] as? NSNumber)?.intValue ?? 0, 0)
        }
    }

    func testExtractAndImportZipImportsPackSuccessfully() async throws {
        let sourceDirectory = try makeValidPackDirectory(named: "zip-pack")
        let zipURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).zip")
        defer {
            try? FileManager.default.removeItem(at: sourceDirectory)
            try? FileManager.default.removeItem(at: zipURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = sourceDirectory.deletingLastPathComponent()
        process.arguments = ["-rq", zipURL.path, sourceDirectory.lastPathComponent]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let info = try await manager.extractAndImportZip(zipURL)

        XCTAssertEqual(info.id, "zip-pack")
        XCTAssertEqual(info.name, "zip-pack")
        XCTAssertTrue(FileManager.default.fileExists(atPath: info.directory.path))
    }

    func testExportAsZipCreatesValidArchive() async throws {
        let sourceDirectory = try makeValidPackDirectory(named: "export-pack")
        let imported = try await manager.copyFolder(sourceDirectory)
        let zipURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).zip")
        defer {
            try? FileManager.default.removeItem(at: sourceDirectory.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: zipURL)
        }

        try await manager.exportAsZip(packID: imported.id, to: zipURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: zipURL.path))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-t", zipURL.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func makeValidPackDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let manifest = SpriteManifest(
            name: name,
            version: "1.0.0",
            states: [
                AnimationState.idle.rawValue: .init(
                    frames: ["\(name)_idle_0", "\(name)_idle_1"],
                    frameInterval: 0.5,
                    loop: true
                )
            ]
        )
        try JSONEncoder().encode(manifest).write(
            to: directory.appendingPathComponent("manifest.json")
        )
        try Data([0x89, 0x50, 0x4E, 0x47]).write(
            to: directory.appendingPathComponent("\(name)_idle_0.png")
        )
        try Data([0x89, 0x50, 0x4E, 0x47]).write(
            to: directory.appendingPathComponent("\(name)_idle_1.png")
        )

        return directory
    }
}
