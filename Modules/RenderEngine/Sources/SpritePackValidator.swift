import Foundation

public enum SpritePackValidationError: Error, Equatable, Sendable, LocalizedError {
    case missingManifest
    case invalidManifest(String)
    case missingRequiredState(String)
    case missingFrame(String)

    public var errorDescription: String? {
        switch self {
        case .missingManifest:
            return "manifest.json not found"
        case .invalidManifest(let detail):
            return "Invalid manifest.json: \(detail)"
        case .missingRequiredState(let state):
            return "Missing required state: \(state)"
        case .missingFrame(let frame):
            return "Missing frame: \(frame).png"
        }
    }
}

public enum SpritePackValidationResult: Sendable {
    case valid(SpriteManifest)
    case invalid([SpritePackValidationError])
}

public struct SpritePackValidator: Sendable {
    public nonisolated static func validate(directory: URL) -> SpritePackValidationResult {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return .invalid([.missingManifest])
        }

        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            return .invalid([.invalidManifest(String(describing: error))])
        }

        let manifest: SpriteManifest
        do {
            manifest = try JSONDecoder().decode(SpriteManifest.self, from: data)
        } catch {
            return .invalid([.invalidManifest(String(describing: error))])
        }

        var errors = [SpritePackValidationError]()

        if manifest.states[AnimationState.idle.rawValue] == nil {
            errors.append(.missingRequiredState(AnimationState.idle.rawValue))
        }

        var reportedMissingFrames = Set<String>()
        for stateName in manifest.states.keys.sorted() {
            guard let animation = manifest.states[stateName] else {
                continue
            }

            for frameName in animation.frames {
                guard reportedMissingFrames.insert(frameName).inserted else {
                    continue
                }

                let frameURL = directory.appendingPathComponent("\(frameName).png")
                if !fileManager.fileExists(atPath: frameURL.path) {
                    errors.append(.missingFrame(frameName))
                }
            }
        }

        if errors.isEmpty {
            return .valid(manifest)
        }

        return .invalid(errors)
    }
}
