import Foundation

public struct SpritePackInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let directory: URL

    public init(id: String, name: String, directory: URL) {
        self.id = id
        self.name = name
        self.directory = directory
    }
}

public struct SpritePackLoader: Sendable {
    /// 内置精灵包 ID 列表（不含 "default"，default 已被 PixelCat 替代）
    public static let builtInPackIDs: Set<String> = ["PixelCat", "PixelDog", "PixelFox"]

    public static func loadManifest(from directory: URL) throws -> SpriteManifest {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        return try JSONDecoder().decode(SpriteManifest.self, from: data)
    }

    public static func loadBehaviorManifest(from directory: URL) -> BehaviorManifest? {
        let manifestURL = directory.appendingPathComponent("behavior.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            return nil
        }
        return try? JSONDecoder().decode(BehaviorManifest.self, from: data)
    }

    public static func discoverPacks() -> [SpritePackInfo] {
        discoverPacks(
            in: spritePacksDirectory(),
            bundledDirectory: bundledResourcesDirectory()
        )
    }

    /// Load the bundled default manifest from SPM resources
    public static func loadBundledManifest() -> SpriteManifest {
        if let url = Bundle.module.url(forResource: "manifest", withExtension: "json", subdirectory: "Resources") ??
                      Bundle.module.url(forResource: "manifest", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let manifest = try? JSONDecoder().decode(SpriteManifest.self, from: data) {
            return manifest
        }
        return defaultManifest()
    }

    public static func loadBundledBehaviorManifest() -> BehaviorManifest {
        if let url = Bundle.module.url(forResource: "behavior", withExtension: "json", subdirectory: "Resources") ??
                      Bundle.module.url(forResource: "behavior", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let manifest = try? JSONDecoder().decode(BehaviorManifest.self, from: data) {
            return manifest
        }
        return BehaviorManifest.defaultManifest()
    }

    public static func defaultManifest() -> SpriteManifest {
        let states = AnimationState.allCases.reduce(into: [String: SpriteManifest.StateAnimation]()) {
            result,
            state in
            result[state.rawValue] = defaultAnimation(for: state)
        }

        return SpriteManifest(
            name: "DefaultSpritePack",
            version: "1.0.0",
            states: states
        )
    }

    static func discoverPacks(in spritePacksDirectory: URL, bundledDirectory: URL) -> [SpritePackInfo] {
        var discoveredPacks: [SpritePackInfo] = []

        let fileManager = FileManager.default
        if let candidateDirectories = try? fileManager.contentsOfDirectory(
            at: spritePacksDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            let packs = candidateDirectories.compactMap { directory -> SpritePackInfo? in
                guard
                    let resourceValues = try? directory.resourceValues(forKeys: [.isDirectoryKey]),
                    resourceValues.isDirectory == true,
                    let manifest = try? loadManifest(from: directory)
                else {
                    return nil
                }

                return SpritePackInfo(
                    id: directory.lastPathComponent,
                    name: manifest.name,
                    directory: directory
                )
            }

            // 内置包排前面，自定义包按名称排序
            let builtIn = packs.filter { builtInPackIDs.contains($0.id) }
                .sorted { lhs, rhs in lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
            let custom = packs.filter { !builtInPackIDs.contains($0.id) }
                .sorted { lhs, rhs in lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
            discoveredPacks = builtIn + custom
        }

        // 如果没发现任何包，fallback 到 bundled
        if discoveredPacks.isEmpty {
            discoveredPacks.append(
                SpritePackInfo(
                    id: "default",
                    name: loadBundledManifest().name,
                    directory: bundledDirectory
                )
            )
        }

        return discoveredPacks
    }

    private static func defaultAnimation(for state: AnimationState) -> SpriteManifest.StateAnimation {
        let loopingStates: Set<AnimationState> = [.idle, .walk, .run, .follow, .sleep, .sit, .dance, .type, .read, .write, .phone]

        switch state {
        case .idle:
            return .init(
                frames: ["pet_idle_0", "pet_idle_1"],
                frameInterval: 1.0 / 12.0,
                loop: true
            )
        case .walk:
            return .init(
                frames: ["pet_walk_0", "pet_walk_1", "pet_walk_2", "pet_walk_3"],
                frameInterval: 1.0 / 12.0,
                loop: true
            )
        case .react:
            return .init(
                frames: ["pet_react_0", "pet_react_1"],
                frameInterval: 1.0 / 12.0,
                loop: false
            )
        case .sleep:
            return .init(
                frames: ["pet_sleep_0", "pet_sleep_1"],
                frameInterval: 2.0 / 12.0,
                loop: true
            )
        case .drag:
            return .init(
                frames: ["pet_drag_0"],
                frameInterval: 1.0 / 12.0,
                loop: false
            )
        case .celebrate:
            return .init(
                frames: ["pet_celebrate_0", "pet_celebrate_1", "pet_celebrate_2"],
                frameInterval: 1.0 / 12.0,
                loop: false
            )
        case .stretch:
            return .init(
                frames: ["pet_react_1", "pet_react_0"],
                frameInterval: 0.4,
                loop: false
            )
        case .yawn:
            return .init(
                frames: ["pet_sleep_0", "pet_sleep_1"],
                frameInterval: 0.6,
                loop: false
            )
        case .lookAround:
            return .init(
                frames: ["pet_walk_0", "pet_walk_1"],
                frameInterval: 0.35,
                loop: false
            )
        case .bounce:
            return .init(
                frames: ["pet_celebrate_0", "pet_celebrate_1", "pet_celebrate_2"],
                frameInterval: 0.15,
                loop: false
            )
        case .punch:
            return .init(
                frames: ["pet_angry_0"],
                frameInterval: 0.14,
                loop: false
            )
        default:
            let frameCount = loopingStates.contains(state) || state == .run ? 4 : 3
            let frames = (0..<frameCount).map { "pet_\(state.rawValue)_\($0)" }
            let frameInterval: Double

            switch state {
            case .run:
                frameInterval = 0.08
            case .follow:
                frameInterval = 0.12
            case .eat, .drink:
                frameInterval = 0.35
            case .sit:
                frameInterval = 0.5
            case .think:
                frameInterval = 0.3
            case .chat, .wave, .cheer, .alert, .pickup, .land, .trip, .spin, .love, .dance, .play, .roll, .climb, .angry, .scared, .sneeze, .punch:
                frameInterval = 0.15
            case .sad, .shy, .confused, .peek, .gift, .read, .write, .phone, .listen, .hidePeek, .type, .groom, .nod, .headShake, .scratch:
                frameInterval = 0.2
            default:
                frameInterval = 1.0 / 12.0
            }

            return .init(
                frames: frames,
                frameInterval: frameInterval,
                loop: loopingStates.contains(state)
            )
        }
    }

    public static func spritePacksDirectory() -> URL {
        let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return applicationSupportURL
            .appendingPathComponent("VitaPet", isDirectory: true)
            .appendingPathComponent("SpritePacks", isDirectory: true)
    }

    public static func bundledSpritePacksDirectory() -> URL? {
        let fileManager = FileManager.default
        let directURL = Bundle.module.resourceURL?.appendingPathComponent("SpritePacks", isDirectory: true)
        if let directURL, fileManager.fileExists(atPath: directURL.path) {
            return directURL
        }

        let nestedURL = Bundle.module.resourceURL?
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("SpritePacks", isDirectory: true)
        if let nestedURL, fileManager.fileExists(atPath: nestedURL.path) {
            return nestedURL
        }

        return nil
    }

    public static func bundledSpritePackDirectory(named name: String) -> URL? {
        guard let spritePacksDirectory = bundledSpritePacksDirectory() else {
            return nil
        }

        let packDirectory = spritePacksDirectory.appendingPathComponent(name, isDirectory: true)
        guard FileManager.default.fileExists(atPath: packDirectory.path) else {
            return nil
        }

        return packDirectory
    }

    private static func bundledResourcesDirectory() -> URL {
        if let resourceURL = Bundle.module.resourceURL?.appendingPathComponent("Resources", isDirectory: true),
           FileManager.default.fileExists(atPath: resourceURL.path) {
            return resourceURL
        }

        return Bundle.module.resourceURL ?? spritePacksDirectory()
    }
}
