import AppKit
import Foundation

public enum SpritePackManagerError: Error, Sendable, Equatable, LocalizedError {
    case cannotDeleteBuiltIn
    case validationFailed([SpritePackValidationError])
    case packAlreadyExists(String)
    case fileSystemError(String)

    public var errorDescription: String? {
        switch self {
        case .cannotDeleteBuiltIn:
            return "Cannot delete built-in sprite pack"
        case .validationFailed(let errors):
            let details = errors.map(\.localizedDescription).joined(separator: "\n")
            return "Validation failed:\n\(details)"
        case .packAlreadyExists(let name):
            return "Sprite pack '\(name)' already exists"
        case .fileSystemError(let detail):
            return "File system error: \(detail)"
        }
    }
}

public actor SpritePackManager {
    private let storageURL: URL
    private let fileManager: FileManager

    public init() {
        self.storageURL = SpritePackLoader.spritePacksDirectory()
        self.fileManager = .default
    }

    public init(storageURL: URL) {
        self.storageURL = storageURL
        self.fileManager = .default
    }

    public func spritePacks() -> [SpritePackInfo] {
        if storageURL.standardizedFileURL == SpritePackLoader.spritePacksDirectory().standardizedFileURL {
            return SpritePackLoader.discoverPacks()
        }

        return SpritePackLoader.discoverPacks(
            in: storageURL,
            bundledDirectory: storageURL
        )
    }

    public func delete(packID: String) throws {
        guard !SpritePackLoader.builtInPackIDs.contains(packID) else {
            throw SpritePackManagerError.cannotDeleteBuiltIn
        }

        let directory = storageURL.appendingPathComponent(packID, isDirectory: true)

        do {
            try fileManager.removeItem(at: directory)
        } catch {
            throw SpritePackManagerError.fileSystemError(String(describing: error))
        }
    }

    public func copyFolder(_ sourceURL: URL) throws -> SpritePackInfo {
        switch SpritePackValidator.validate(directory: sourceURL) {
        case let .invalid(errors):
            throw SpritePackManagerError.validationFailed(errors)
        case let .valid(manifest):
            let destinationURL = storageURL.appendingPathComponent(
                sourceURL.lastPathComponent,
                isDirectory: true
            )

            do {
                try fileManager.createDirectory(
                    at: storageURL,
                    withIntermediateDirectories: true
                )

                guard !fileManager.fileExists(atPath: destinationURL.path) else {
                    throw SpritePackManagerError.packAlreadyExists(sourceURL.lastPathComponent)
                }

                try fileManager.copyItem(at: sourceURL, to: destinationURL)

                return SpritePackInfo(
                    id: sourceURL.lastPathComponent,
                    name: manifest.name,
                    directory: destinationURL
                )
            } catch let error as SpritePackManagerError {
                throw error
            } catch {
                throw SpritePackManagerError.fileSystemError(String(describing: error))
            }
        }
    }

    public func extractAndImportZip(_ zipURL: URL) async throws -> SpritePackInfo {
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        do {
            try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        } catch {
            throw SpritePackManagerError.fileSystemError(String(describing: error))
        }

        defer {
            try? fileManager.removeItem(at: temporaryDirectory)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", zipURL.path, "-d", temporaryDirectory.path]

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw SpritePackManagerError.fileSystemError(String(describing: error))
        }

        guard process.terminationStatus == 0 else {
            throw SpritePackManagerError.fileSystemError(
                "unzip failed with status \(process.terminationStatus)"
            )
        }

        let importSourceURL = try extractionRoot(in: temporaryDirectory)
        return try copyFolder(importSourceURL)
    }

    public func createTemplate(named name: String) throws -> URL {
        let directory = storageURL.appendingPathComponent(name, isDirectory: true)

        do {
            try fileManager.createDirectory(at: storageURL, withIntermediateDirectories: true)

            guard !fileManager.fileExists(atPath: directory.path) else {
                throw SpritePackManagerError.packAlreadyExists(name)
            }

            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

            let manifest = SpriteManifest(
                name: name,
                version: "1.0.0",
                states: Self.templateStates(named: name)
            )
            let manifestData = try JSONEncoder.prettyPrinted.encode(manifest)
            try manifestData.write(to: directory.appendingPathComponent("manifest.json"))

            let frameNames = Set(manifest.states.values.flatMap(\.frames))
            for frameName in frameNames.sorted() {
                try Self.placeholderPNGData(named: frameName).write(
                    to: directory.appendingPathComponent("\(frameName).png")
                )
            }

            try Self.readmeText(named: name).data(using: .utf8)?.write(
                to: directory.appendingPathComponent("README.txt")
            )

            return directory
        } catch let error as SpritePackManagerError {
            throw error
        } catch {
            throw SpritePackManagerError.fileSystemError(String(describing: error))
        }
    }

    public func exportAsZip(packID: String, to destinationURL: URL) throws {
        guard !SpritePackLoader.builtInPackIDs.contains(packID) else {
            throw SpritePackManagerError.fileSystemError("Exporting the built-in pack is not supported")
        }

        let packDirectory = storageURL.appendingPathComponent(packID, isDirectory: true)
        guard fileManager.fileExists(atPath: packDirectory.path) else {
            throw SpritePackManagerError.fileSystemError("Pack not found: \(packID)")
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            do {
                try fileManager.removeItem(at: destinationURL)
            } catch {
                throw SpritePackManagerError.fileSystemError(String(describing: error))
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = packDirectory.deletingLastPathComponent()
        process.arguments = ["-rq", destinationURL.path, packID]

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw SpritePackManagerError.fileSystemError(String(describing: error))
        }

        guard process.terminationStatus == 0 else {
            throw SpritePackManagerError.fileSystemError(
                "zip failed with status \(process.terminationStatus)"
            )
        }
    }

    private func extractionRoot(in temporaryDirectory: URL) throws -> URL {
        let manifestAtRoot = temporaryDirectory.appendingPathComponent("manifest.json")
        if fileManager.fileExists(atPath: manifestAtRoot.path) {
            return temporaryDirectory
        }

        do {
            let children = try fileManager.contentsOfDirectory(
                at: temporaryDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            .filter { $0.lastPathComponent != "__MACOSX" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

            if let firstDirectory = children.first(where: {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }) {
                return firstDirectory
            }

            return temporaryDirectory
        } catch {
            throw SpritePackManagerError.fileSystemError(String(describing: error))
        }
    }

    private nonisolated static func templateStates(named name: String) -> [String: SpriteManifest.StateAnimation] {
        let intervals: [AnimationState: Double] = [
            .idle: 0.5,
            .walk: 0.15,
            .run: 0.08,
            .react: 0.2,
            .sleep: 0.8,
            .drag: 0.1,
            .celebrate: 0.12,
            .stretch: 0.4,
            .yawn: 0.6,
            .lookAround: 0.35,
            .bounce: 0.15,
            .play: 0.15,
            .roll: 0.15,
            .spin: 0.15,
            .trip: 0.15,
            .dance: 0.15,
            .climb: 0.15,
            .sad: 0.2,
            .love: 0.15,
            .angry: 0.15,
            .shy: 0.2,
            .confused: 0.2,
            .scared: 0.15,
            .eat: 0.35,
            .drink: 0.35,
            .groom: 0.2,
            .sit: 0.5,
            .wave: 0.2,
            .punch: 0.14,
            .nod: 0.2,
            .headShake: 0.2,
            .sneeze: 0.15,
            .scratch: 0.2,
            .peek: 0.2,
            .gift: 0.2,
            .write: 0.2,
            .phone: 0.2,
            .read: 0.2,
            .chat: 0.2,
            .listen: 0.2,
            .alert: 0.15,
            .think: 0.3,
            .cheer: 0.15,
            .follow: 0.12,
            .hidePeek: 0.2,
            .pickup: 0.15,
            .land: 0.15,
            .type: 0.15,
            .somersault: 0.15
        ]
        let loopingStates: Set<AnimationState> = [.idle, .walk, .run, .follow, .sleep, .sit, .dance, .type, .read, .write, .phone]

        return AnimationState.allCases.reduce(into: [String: SpriteManifest.StateAnimation]()) {
            result,
            state in
            let frames = [
                "\(name)_\(state.rawValue)_0",
                "\(name)_\(state.rawValue)_1"
            ]
            result[state.rawValue] = SpriteManifest.StateAnimation(
                frames: frames,
                frameInterval: intervals[state] ?? 0.2,
                loop: loopingStates.contains(state)
            )
        }
    }

    private nonisolated static func placeholderPNGData(named name: String) throws -> Data {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 32,
            pixelsHigh: 32,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw SpritePackManagerError.fileSystemError("failed to allocate placeholder bitmap")
        }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw SpritePackManagerError.fileSystemError("failed to create graphics context")
        }

        NSGraphicsContext.current = context

        let size = NSSize(width: 32, height: 32)
        NSColor.systemRed.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

        let cross = NSBezierPath()
        cross.lineWidth = 3
        NSColor.white.setStroke()
        cross.move(to: NSPoint(x: 6, y: 6))
        cross.line(to: NSPoint(x: 26, y: 26))
        cross.move(to: NSPoint(x: 26, y: 6))
        cross.line(to: NSPoint(x: 6, y: 26))
        cross.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 5, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        NSString(string: String(name.prefix(10))).draw(
            at: NSPoint(x: 3, y: 1),
            withAttributes: attributes
        )

        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw SpritePackManagerError.fileSystemError("failed to encode placeholder PNG")
        }

        return pngData
    }

    private nonisolated static func readmeText(named name: String) -> String {
        """
        Sprite pack template: \(name)

        Files:
        - manifest.json: sprite pack metadata and animation frame mapping
        - <frame>.png: placeholder images for each referenced frame

        Replace the generated PNG files with your actual 32x32 sprite artwork while keeping the filenames unchanged.
        """
    }
}

private extension JSONEncoder {
    static var prettyPrinted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
