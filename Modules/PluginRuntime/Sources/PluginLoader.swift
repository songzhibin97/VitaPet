import Foundation
import OSLog
import Security

public struct PluginLoader: Sendable {
    public struct PluginBundle: Sendable {
        public let bundleURL: URL
        public let manifest: PluginManifest
        public let executableURL: URL?

        public init(bundleURL: URL, manifest: PluginManifest, executableURL: URL?) {
            self.bundleURL = bundleURL
            self.manifest = manifest
            self.executableURL = executableURL
        }
    }

    public enum LoadError: Error, Sendable {
        case missingManifest(URL)
        case malformedManifest(URL, underlying: any Error)
        case signatureInvalid(URL, OSStatus)
        case signatureVerificationFailed(URL)
    }

    private static let logger = Logger(subsystem: "VitaPet", category: "PluginLoader")

    public let developerMode: Bool

    public init(developerMode: Bool = false) {
        self.developerMode = developerMode
    }

    public func discover(in directory: URL) throws -> [PluginBundle] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else {
            return []
        }

        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter { candidate in
            guard (try? candidate.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return false
            }

            return candidate.pathExtension == "vitaplugin" || hasDeclarativeManifest(at: candidate)
        }
        .compactMap { candidate in
            do {
                return try load(bundleAt: candidate)
            } catch {
                // Never fail the whole directory: one bad/corrupt bundle should not unload
                // every other plugin (e.g. built-in SitReminder / HourlyChime).
                Self.logger.warning("Skipping plugin at \(candidate.path, privacy: .public): \(String(describing: error), privacy: .public)")
                return nil
            }
        }
    }

    public func load(bundleAt url: URL) throws -> PluginBundle {
        guard let manifestURL = resolveManifestURL(in: url) else {
            throw LoadError.missingManifest(url)
        }

        let manifest: PluginManifest
        do {
            let data = try Data(contentsOf: manifestURL)
            manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        } catch {
            throw LoadError.malformedManifest(url, underlying: error)
        }

        let executableURL = try resolveExecutable(in: url)
        if url.pathExtension == "vitaplugin" {
            try verifySignature(for: url)
        }

        return PluginBundle(bundleURL: url, manifest: manifest, executableURL: executableURL)
    }

    public static func pluginDirectories() -> [URL] {
        let baseURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("VitaPet", isDirectory: true)
            .appendingPathComponent("Plugins", isDirectory: true)

        return [baseURL]
    }

    private func resolveExecutable(in bundleURL: URL) throws -> URL? {
        let executableDirectory = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)

        guard FileManager.default.fileExists(atPath: executableDirectory.path) else {
            return nil
        }

        let candidates = try FileManager.default.contentsOfDirectory(
            at: executableDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    }

    private func resolveManifestURL(in bundleURL: URL) -> URL? {
        let declarativeManifestURL = bundleURL.appendingPathComponent("plugin.json", isDirectory: false)
        if FileManager.default.fileExists(atPath: declarativeManifestURL.path) {
            return declarativeManifestURL
        }

        let bundleManifestURL = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("plugin.json", isDirectory: false)

        guard FileManager.default.fileExists(atPath: bundleManifestURL.path) else {
            return nil
        }

        return bundleManifestURL
    }

    private func hasDeclarativeManifest(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("plugin.json", isDirectory: false).path)
    }

    private func verifySignature(for bundleURL: URL) throws {
        var staticCode: SecStaticCode?
        let creationStatus = SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode)
        guard creationStatus == errSecSuccess else {
            if developerMode {
                Self.logger.warning("Skipping signature creation failure for \(bundleURL.path, privacy: .public): \(creationStatus, privacy: .public)")
                return
            }

            throw LoadError.signatureInvalid(bundleURL, creationStatus)
        }

        guard let staticCode else {
            if developerMode {
                Self.logger.warning("Skipping missing static code reference for \(bundleURL.path, privacy: .public)")
                return
            }

            throw LoadError.signatureVerificationFailed(bundleURL)
        }

        let validationStatus = SecStaticCodeCheckValidity(staticCode, [], nil)
        guard validationStatus == errSecSuccess else {
            if developerMode {
                Self.logger.warning("Skipping signature validation failure for \(bundleURL.path, privacy: .public): \(validationStatus, privacy: .public)")
                return
            }

            throw LoadError.signatureVerificationFailed(bundleURL)
        }
    }
}
