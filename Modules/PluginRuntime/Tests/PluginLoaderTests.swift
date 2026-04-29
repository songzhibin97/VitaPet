import Foundation
import XCTest
@testable import PluginRuntime

final class PluginLoaderTests: XCTestCase {
    var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testDiscoverFindsVitapluginBundles() throws {
        let loader = PluginLoader(developerMode: true, developerWhitelistDirectory: tempDir)
        try createPluginBundle(named: "First.vitaplugin", manifestId: "com.vitapet.first")
        try createPluginBundle(named: "Second.vitaplugin", manifestId: "com.vitapet.second")

        let bundles = try loader.discover(in: tempDir)

        XCTAssertEqual(Set(bundles.map(\.manifest.id)), ["com.vitapet.first", "com.vitapet.second"])
    }

    func testDiscoverIgnoresNonPluginDirectories() throws {
        let loader = PluginLoader(developerMode: true, developerWhitelistDirectory: tempDir)
        try createPluginBundle(named: "Valid.vitaplugin", manifestId: "com.vitapet.valid")
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("NotAPlugin", isDirectory: true),
            withIntermediateDirectories: true
        )

        let bundles = try loader.discover(in: tempDir)

        XCTAssertEqual(bundles.count, 1)
        XCTAssertEqual(bundles.first?.manifest.id, "com.vitapet.valid")
    }

    func testDiscoverFindsDeclarativePluginDirectories() throws {
        let loader = PluginLoader(developerMode: true, developerWhitelistDirectory: tempDir)
        try createPluginBundle(named: "Valid.vitaplugin", manifestId: "com.vitapet.valid")
        try createDeclarativePluginDirectory(named: "JSONOnly", manifestId: "com.vitapet.json-only")

        let bundles = try loader.discover(in: tempDir)

        XCTAssertEqual(Set(bundles.map(\.manifest.id)), ["com.vitapet.valid", "com.vitapet.json-only"])
    }

    func testLoadReturnsPluginBundle() throws {
        let loader = PluginLoader(developerMode: true, developerWhitelistDirectory: tempDir)
        let bundleURL = try createPluginBundle(named: "Loadable.vitaplugin", manifestId: "com.vitapet.loadable")

        let bundle = try loader.load(bundleAt: bundleURL)

        XCTAssertEqual(bundle.bundleURL, bundleURL)
        XCTAssertEqual(bundle.manifest.id, "com.vitapet.loadable")
        XCTAssertEqual(bundle.executableURL?.lastPathComponent, "FakeExec")
    }

    func testLoadAllowsManifestOnlyBundle() throws {
        let loader = PluginLoader(developerMode: true, developerWhitelistDirectory: tempDir)
        let bundleURL = tempDir.appendingPathComponent("ManifestOnly.vitaplugin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true),
            withIntermediateDirectories: true
        )
        try writeManifest(at: bundleURL, id: "com.vitapet.manifestonly")

        let bundle = try loader.load(bundleAt: bundleURL)

        XCTAssertEqual(bundle.bundleURL, bundleURL)
        XCTAssertEqual(bundle.manifest.id, "com.vitapet.manifestonly")
        XCTAssertNil(bundle.executableURL)
    }

    func testLoadAllowsDeclarativePluginDirectory() throws {
        let loader = PluginLoader(developerMode: true, developerWhitelistDirectory: tempDir)
        let bundleURL = try createDeclarativePluginDirectory(named: "Declarative", manifestId: "com.vitapet.declarative")

        let bundle = try loader.load(bundleAt: bundleURL)

        XCTAssertEqual(bundle.bundleURL, bundleURL)
        XCTAssertEqual(bundle.manifest.id, "com.vitapet.declarative")
        XCTAssertNil(bundle.executableURL)
    }

    func testLoadThrowsMissingManifest() throws {
        let loader = PluginLoader(developerMode: false)
        let bundleURL = tempDir.appendingPathComponent("MissingManifest.vitaplugin", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("Contents/MacOS", isDirectory: true),
            withIntermediateDirectories: true
        )
        let executableURL = bundleURL.appendingPathComponent("Contents/MacOS/FakeExec")
        FileManager.default.createFile(atPath: executableURL.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        XCTAssertThrowsError(try loader.load(bundleAt: bundleURL)) { error in
            guard case PluginLoader.LoadError.missingManifest(let failingURL) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(failingURL, bundleURL)
        }
    }

    func testLoadThrowsMalformedManifest() throws {
        let loader = PluginLoader(developerMode: false)
        let bundleURL = tempDir.appendingPathComponent("Malformed.vitaplugin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("Contents/MacOS", isDirectory: true),
            withIntermediateDirectories: true
        )
        let manifestURL = bundleURL.appendingPathComponent("Contents/Resources/plugin.json")
        try Data("{ invalid json }".utf8).write(to: manifestURL)
        let executableURL = bundleURL.appendingPathComponent("Contents/MacOS/FakeExec")
        FileManager.default.createFile(atPath: executableURL.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        XCTAssertThrowsError(try loader.load(bundleAt: bundleURL)) { error in
            guard case PluginLoader.LoadError.malformedManifest(let failingURL, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(failingURL, bundleURL)
        }
    }

    // MARK: - Release path (strict signature enforcement)

    func testReleasePathRejectsUnsignedPlugin() throws {
        // developerMode=false means no whitelist bypass; unsigned .vitaplugin must be rejected.
        let loader = PluginLoader(developerMode: false)
        let bundleURL = try createPluginBundle(named: "Unsigned.vitaplugin", manifestId: "com.vitapet.unsigned")

        XCTAssertThrowsError(try loader.load(bundleAt: bundleURL)) { error in
            switch error {
            case PluginLoader.LoadError.signatureInvalid, PluginLoader.LoadError.signatureVerificationFailed:
                break  // expected
            default:
                XCTFail("Expected signature error, got: \(error)")
            }
        }
    }

    // MARK: - DEBUG path with whitelist

    func testDebugPathAllowsUnsignedPluginInsideWhitelist() throws {
        // developerMode=true + plugin inside whitelist directory → signature skipped.
        let devDir = tempDir.appendingPathComponent("dev", isDirectory: true)
        try FileManager.default.createDirectory(at: devDir, withIntermediateDirectories: true)
        let loader = PluginLoader(developerMode: true, developerWhitelistDirectory: devDir)
        let bundleURL = try createPluginBundle(named: "DevPlugin.vitaplugin", manifestId: "com.vitapet.dev", inDirectory: devDir)

        XCTAssertNoThrow(try loader.load(bundleAt: bundleURL))
    }

    func testDebugPathRejectsUnsignedPluginOutsideWhitelist() throws {
        // developerMode=true but plugin is in a different directory → strict validation applies.
        let devDir = tempDir.appendingPathComponent("dev", isDirectory: true)
        try FileManager.default.createDirectory(at: devDir, withIntermediateDirectories: true)
        let otherDir = tempDir.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)

        let loader = PluginLoader(developerMode: true, developerWhitelistDirectory: devDir)
        let bundleURL = try createPluginBundle(named: "Outside.vitaplugin", manifestId: "com.vitapet.outside", inDirectory: otherDir)

        XCTAssertThrowsError(try loader.load(bundleAt: bundleURL)) { error in
            switch error {
            case PluginLoader.LoadError.signatureInvalid, PluginLoader.LoadError.signatureVerificationFailed:
                break  // expected
            default:
                XCTFail("Expected signature error, got: \(error)")
            }
        }
    }

    func testDebugPathRejectsSymlinkBypassOutsideWhitelist() throws {
        // A symlink inside the whitelist directory pointing to a bundle outside it must
        // not bypass signature verification (resolvingSymlinksInPath defeats this).
        let devDir = tempDir.appendingPathComponent("dev", isDirectory: true)
        try FileManager.default.createDirectory(at: devDir, withIntermediateDirectories: true)
        let outsideDir = tempDir.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)

        // The real (unsigned) plugin lives outside the whitelist.
        let realBundle = try createPluginBundle(
            named: "Real.vitaplugin",
            manifestId: "com.vitapet.symlink-target",
            inDirectory: outsideDir
        )

        // Place a symlink to it inside the whitelist directory.
        let symlinkURL = devDir.appendingPathComponent("SymlinkedPlugin.vitaplugin", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: realBundle)

        let loader = PluginLoader(developerMode: true, developerWhitelistDirectory: devDir)

        // Loading via the symlink must fail because the resolved path is outside the whitelist.
        XCTAssertThrowsError(try loader.load(bundleAt: symlinkURL)) { error in
            switch error {
            case PluginLoader.LoadError.signatureInvalid, PluginLoader.LoadError.signatureVerificationFailed:
                break  // expected – symlink was resolved before whitelist check
            default:
                XCTFail("Expected signature error (symlink bypass prevented), got: \(error)")
            }
        }
    }

    func testDebugPathDoesNotMatchPrefixBoundaryMismatch() throws {
        // Whitelist=/foo/dev must NOT match a plugin at /foo/devil (prefix boundary).
        let devDir = tempDir.appendingPathComponent("dev", isDirectory: true)
        try FileManager.default.createDirectory(at: devDir, withIntermediateDirectories: true)
        // "devil" shares the same prefix as "dev" but is a sibling, not a child.
        let devilDir = tempDir.appendingPathComponent("devil", isDirectory: true)
        try FileManager.default.createDirectory(at: devilDir, withIntermediateDirectories: true)

        let loader = PluginLoader(developerMode: true, developerWhitelistDirectory: devDir)
        let bundleURL = try createPluginBundle(
            named: "Trickster.vitaplugin",
            manifestId: "com.vitapet.trickster",
            inDirectory: devilDir
        )

        XCTAssertThrowsError(try loader.load(bundleAt: bundleURL)) { error in
            switch error {
            case PluginLoader.LoadError.signatureInvalid, PluginLoader.LoadError.signatureVerificationFailed:
                break  // expected
            default:
                XCTFail("Expected signature error (prefix boundary), got: \(error)")
            }
        }
    }

    // MARK: - Private helpers

    @discardableResult
    private func createPluginBundle(named bundleName: String, manifestId: String) throws -> URL {
        try createPluginBundle(named: bundleName, manifestId: manifestId, inDirectory: tempDir)
    }

    @discardableResult
    private func createPluginBundle(named bundleName: String, manifestId: String, inDirectory directory: URL) throws -> URL {
        let bundleURL = directory.appendingPathComponent(bundleName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("Contents/MacOS", isDirectory: true),
            withIntermediateDirectories: true
        )
        try writeManifest(at: bundleURL, id: manifestId)

        let executableURL = bundleURL.appendingPathComponent("Contents/MacOS/FakeExec")
        FileManager.default.createFile(atPath: executableURL.path, contents: Data("#!/bin/sh\nexit 0\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        return bundleURL
    }

    private func writeManifest(at bundleURL: URL, id: String) throws {
        let data = Data(
            """
            {
              "id": "\(id)",
              "name": "Test Plugin",
              "version": "1.0.0",
              "description": "Loader test",
              "capabilities": ["animation"],
              "triggers": []
            }
            """.utf8
        )
        try data.write(to: bundleURL.appendingPathComponent("Contents/Resources/plugin.json"))
    }

    @discardableResult
    private func createDeclarativePluginDirectory(named name: String, manifestId: String) throws -> URL {
        let pluginURL = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: pluginURL, withIntermediateDirectories: true)
        let data = Data(
            """
            {
              "id": "\(manifestId)",
              "name": "Declarative Plugin",
              "version": "1.0.0",
              "description": "Loader test",
              "capabilities": [],
              "triggers": []
            }
            """.utf8
        )
        try data.write(to: pluginURL.appendingPathComponent("plugin.json"))
        return pluginURL
    }
}
