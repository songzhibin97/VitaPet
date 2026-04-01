import Foundation

public enum SpritePackBuilderError: Error, LocalizedError, Sendable, Equatable {
    case missingIdleFrames
    case fileSystemError(String)

    public var errorDescription: String? {
        switch self {
        case .missingIdleFrames:
            return "Idle frames are required to build a sprite pack."
        case let .fileSystemError(message):
            return "File system error: \(message)"
        }
    }
}

public struct SpritePackBuilder: Sendable {
    public static func build(
        named name: String,
        frames: [String: [URL]],
        outputDirectory: URL
    ) throws -> URL {
        guard let idleFrames = frames[AnimationState.idle.rawValue], idleFrames.isEmpty == false else {
            throw SpritePackBuilderError.missingIdleFrames
        }

        let fileManager = FileManager.default
        var resolvedName = name
        var destinationDirectory = outputDirectory.appendingPathComponent(resolvedName, isDirectory: true)
        var counter = 2
        while fileManager.fileExists(atPath: destinationDirectory.path) {
            resolvedName = "\(name)_\(counter)"
            destinationDirectory = outputDirectory.appendingPathComponent(resolvedName, isDirectory: true)
            counter += 1
        }

        do {
            try fileManager.createDirectory(
                at: destinationDirectory,
                withIntermediateDirectories: true
            )

            var states = [String: SpriteManifest.StateAnimation]()

            for state in AnimationState.allCases {
                let stateKey = state.rawValue
                guard let stateFrames = frames[stateKey], stateFrames.isEmpty == false else {
                    continue
                }

                let frameNames = try stateFrames.enumerated().map { index, sourceURL in
                    let frameName = "\(resolvedName)_\(stateKey)_\(index)"
                    let destinationURL = destinationDirectory.appendingPathComponent("\(frameName).png")
                    try fileManager.copyItem(at: sourceURL, to: destinationURL)
                    return frameName
                }

                states[stateKey] = SpriteManifest.StateAnimation(
                    frames: frameNames,
                    frameInterval: defaultFrameInterval(for: state),
                    loop: defaultLoop(for: state)
                )
            }

            let manifest = SpriteManifest(name: resolvedName, version: "1.0.0", states: states)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let manifestData = try encoder.encode(manifest)
            try manifestData.write(to: destinationDirectory.appendingPathComponent("manifest.json"))

            return destinationDirectory
        } catch let error as SpritePackBuilderError {
            throw error
        } catch {
            try? fileManager.removeItem(at: destinationDirectory)
            throw SpritePackBuilderError.fileSystemError(error.localizedDescription)
        }
    }

    public static func autoDetect(from directory: URL) -> [String: [URL]] {
        let fileManager = FileManager.default
        guard let fileURLs = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        let pngFiles = fileURLs.filter { $0.pathExtension.caseInsensitiveCompare("png") == .orderedSame }

        var detected = [String: [URL]]()
        for fileURL in pngFiles {
            let state = detectedState(for: fileURL.deletingPathExtension().lastPathComponent)
            detected[state.rawValue, default: []].append(fileURL)
        }

        for key in detected.keys {
            detected[key]?.sort {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
        }

        return detected
    }

    private static func detectedState(for fileName: String) -> AnimationState {
        let normalizedFileName = normalized(fileName)

        for state in AnimationState.allCases {
            if normalizedFileName.contains(normalized(state.rawValue)) {
                return state
            }
        }

        return .idle
    }

    private static func normalized(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics
        return String(value.lowercased().filter { character in
            character.unicodeScalars.allSatisfy(allowed.contains)
        })
    }

    private static func defaultFrameInterval(for state: AnimationState) -> Double {
        switch state {
        case .idle:
            return 0.5
        case .walk:
            return 0.15
        case .run:
            return 0.08
        case .sleep:
            return 0.8
        case .eat, .drink:
            return 0.35
        case .sit:
            return 0.5
        case .think:
            return 0.3
        default:
            return 0.2
        }
    }

    private static func defaultLoop(for state: AnimationState) -> Bool {
        switch state {
        case .idle, .walk, .run, .follow, .sleep, .sit, .dance, .type, .read, .write, .phone:
            return true
        default:
            return false
        }
    }
}
