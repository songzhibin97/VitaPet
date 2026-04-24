import Foundation

@MainActor
public final class ConfigManager {
    public struct AppConfig: Codable, Sendable {
        public var windowPositionX: Double
        public var windowPositionY: Double
        public var petSize: Double
        public var selectedSpritePack: String
        public var pets: [PetIdentity]
        public var enabledCapabilities: [String: Bool]
        public var disabledPlugins: [String]
        public var locale: String
        public var ollamaEndpoint: String
        public var aiBackend: String
        public var ollamaModel: String
        public var aiSystemPrompt: String
        public var aiProactiveEnabled: Bool
        public var aiProactiveInterval: Int
        public var githubToken: String
        public var webhookEnabled: Bool
        public var webhookPort: Int
        public var webhookSecret: String
        public var spaceMode: String  // "allSpaces", "follow", "singleSpace"
        public var memoryWorkerEnabled: Bool
        public var memoryWorkerEndpoint: String
        public var memoryWorkerAuthMode: String
        public var memoryWorkerUsername: String
        public var memoryWorkerSecret: String
        public var memoryWorkerNamespace: String
        public var memoryWorkerScope: String
        public var memoryWorkerSubject: String
        public var memoryWorkerQueryLimit: Int
        public var memoryWorkerCreateHorizon: String

        public init(
            windowPositionX: Double,
            windowPositionY: Double,
            petSize: Double = 96,
            selectedSpritePack: String,
            pets: [PetIdentity]? = nil,
            enabledCapabilities: [String: Bool],
            disabledPlugins: [String] = [],
            locale: String,
            ollamaEndpoint: String = "http://localhost:11434",
            aiBackend: String = "ollama",
            ollamaModel: String = "llama3.2",
            aiSystemPrompt: String = "",
            aiProactiveEnabled: Bool = true,
            aiProactiveInterval: Int = 45,
            githubToken: String = "",
            webhookEnabled: Bool = false,
            webhookPort: Int = 19280,
            webhookSecret: String = "",
            spaceMode: String = "allSpaces",
            memoryWorkerEnabled: Bool = false,
            memoryWorkerEndpoint: String = "https://memory.example.com",
            memoryWorkerAuthMode: String = "basic",
            memoryWorkerUsername: String = "",
            memoryWorkerSecret: String = "",
            memoryWorkerNamespace: String = "default",
            memoryWorkerScope: String = "user",
            memoryWorkerSubject: String = "demo-user",
            memoryWorkerQueryLimit: Int = 5,
            memoryWorkerCreateHorizon: String = "daily"
        ) {
            let resolvedPets = Self.resolvePets(
                pets,
                legacyWindowPositionX: windowPositionX,
                legacyWindowPositionY: windowPositionY,
                legacyPetSize: petSize,
                legacySpritePack: selectedSpritePack
            )
            let primaryPet = resolvedPets[0]

            self.windowPositionX = primaryPet.positionX
            self.windowPositionY = primaryPet.positionY
            self.petSize = primaryPet.size
            self.selectedSpritePack = primaryPet.spritePack
            self.pets = resolvedPets
            self.enabledCapabilities = enabledCapabilities
            self.disabledPlugins = disabledPlugins
            self.locale = locale
            self.ollamaEndpoint = ollamaEndpoint
            self.aiBackend = aiBackend
            self.ollamaModel = ollamaModel
            self.aiSystemPrompt = aiSystemPrompt
            self.aiProactiveEnabled = aiProactiveEnabled
            self.aiProactiveInterval = aiProactiveInterval
            self.githubToken = githubToken
            self.webhookEnabled = webhookEnabled
            self.webhookPort = webhookPort
            self.webhookSecret = webhookSecret
            self.spaceMode = spaceMode
            self.memoryWorkerEnabled = memoryWorkerEnabled
            self.memoryWorkerEndpoint = memoryWorkerEndpoint
            self.memoryWorkerAuthMode = memoryWorkerAuthMode
            self.memoryWorkerUsername = memoryWorkerUsername
            self.memoryWorkerSecret = memoryWorkerSecret
            self.memoryWorkerNamespace = memoryWorkerNamespace
            self.memoryWorkerScope = memoryWorkerScope
            self.memoryWorkerSubject = memoryWorkerSubject
            self.memoryWorkerQueryLimit = Self.clampedMemoryQueryLimit(memoryWorkerQueryLimit)
            self.memoryWorkerCreateHorizon = Self.normalizedMemoryHorizon(memoryWorkerCreateHorizon)
        }

        private enum CodingKeys: String, CodingKey {
            case windowPositionX
            case windowPositionY
            case petSize
            case selectedSpritePack
            case pets
            case enabledCapabilities
            case disabledPlugins
            case locale
            case ollamaEndpoint
            case aiBackend
            case ollamaModel
            case aiSystemPrompt
            case aiProactiveEnabled
            case aiProactiveInterval
            case githubToken
            case webhookEnabled
            case webhookPort
            case webhookSecret
            case spaceMode
            case memoryWorkerEnabled
            case memoryWorkerEndpoint
            case memoryWorkerAuthMode
            case memoryWorkerUsername
            case memoryWorkerSecret
            case memoryWorkerNamespace
            case memoryWorkerScope
            case memoryWorkerSubject
            case memoryWorkerQueryLimit
            case memoryWorkerCreateHorizon
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let legacyWindowPositionX = try container.decodeIfPresent(Double.self, forKey: .windowPositionX) ?? 120
            let legacyWindowPositionY = try container.decodeIfPresent(Double.self, forKey: .windowPositionY) ?? 120
            let legacyPetSize = try container.decodeIfPresent(Double.self, forKey: .petSize) ?? 96
            let legacySpritePack = try container.decodeIfPresent(String.self, forKey: .selectedSpritePack) ?? "default"
            let decodedPets = try container.decodeIfPresent([PetIdentity].self, forKey: .pets)
            let resolvedPets = Self.resolvePets(
                decodedPets,
                legacyWindowPositionX: legacyWindowPositionX,
                legacyWindowPositionY: legacyWindowPositionY,
                legacyPetSize: legacyPetSize,
                legacySpritePack: legacySpritePack
            )

            let primaryPet = resolvedPets[0]
            windowPositionX = primaryPet.positionX
            windowPositionY = primaryPet.positionY
            petSize = primaryPet.size
            selectedSpritePack = primaryPet.spritePack
            pets = resolvedPets
            enabledCapabilities = try container.decodeIfPresent([String: Bool].self, forKey: .enabledCapabilities) ?? [:]
            disabledPlugins = try container.decodeIfPresent([String].self, forKey: .disabledPlugins) ?? []
            locale = try container.decodeIfPresent(String.self, forKey: .locale) ?? ConfigManager.defaultLocaleIdentifier()
            ollamaEndpoint = try container.decodeIfPresent(String.self, forKey: .ollamaEndpoint) ?? "http://localhost:11434"
            aiBackend = try container.decodeIfPresent(String.self, forKey: .aiBackend) ?? "ollama"
            ollamaModel = try container.decodeIfPresent(String.self, forKey: .ollamaModel) ?? "llama3.2"
            aiSystemPrompt = try container.decodeIfPresent(String.self, forKey: .aiSystemPrompt) ?? ""
            aiProactiveEnabled = try container.decodeIfPresent(Bool.self, forKey: .aiProactiveEnabled) ?? true
            aiProactiveInterval = try container.decodeIfPresent(Int.self, forKey: .aiProactiveInterval) ?? 45
            githubToken = try container.decodeIfPresent(String.self, forKey: .githubToken) ?? ""
            webhookEnabled = try container.decodeIfPresent(Bool.self, forKey: .webhookEnabled) ?? false
            webhookPort = try container.decodeIfPresent(Int.self, forKey: .webhookPort) ?? 19280
            webhookSecret = try container.decodeIfPresent(String.self, forKey: .webhookSecret) ?? ""
            spaceMode = try container.decodeIfPresent(String.self, forKey: .spaceMode) ?? "allSpaces"
            memoryWorkerEnabled = try container.decodeIfPresent(Bool.self, forKey: .memoryWorkerEnabled) ?? false
            memoryWorkerEndpoint = try container.decodeIfPresent(String.self, forKey: .memoryWorkerEndpoint) ?? "https://memory.example.com"
            memoryWorkerAuthMode = try container.decodeIfPresent(String.self, forKey: .memoryWorkerAuthMode) ?? "basic"
            memoryWorkerUsername = try container.decodeIfPresent(String.self, forKey: .memoryWorkerUsername) ?? ""
            memoryWorkerSecret = try container.decodeIfPresent(String.self, forKey: .memoryWorkerSecret) ?? ""
            memoryWorkerNamespace = try container.decodeIfPresent(String.self, forKey: .memoryWorkerNamespace) ?? "default"
            memoryWorkerScope = try container.decodeIfPresent(String.self, forKey: .memoryWorkerScope) ?? "user"
            memoryWorkerSubject = try container.decodeIfPresent(String.self, forKey: .memoryWorkerSubject) ?? "demo-user"
            memoryWorkerQueryLimit = Self.clampedMemoryQueryLimit(
                try container.decodeIfPresent(Int.self, forKey: .memoryWorkerQueryLimit) ?? 5
            )
            memoryWorkerCreateHorizon = Self.normalizedMemoryHorizon(
                try container.decodeIfPresent(String.self, forKey: .memoryWorkerCreateHorizon) ?? "daily"
            )
        }

        mutating func synchronizeLegacyFields() {
            guard let primaryPet = pets.first else {
                pets = [PetIdentity.defaultPet()]
                synchronizeLegacyFields()
                return
            }

            windowPositionX = primaryPet.positionX
            windowPositionY = primaryPet.positionY
            petSize = primaryPet.size
            selectedSpritePack = primaryPet.spritePack
        }

        mutating func reconcileLegacyFields(afterUpdatingFrom original: AppConfig) {
            if pets.isEmpty {
                pets = [PetIdentity.defaultPet()]
            }

            let petsChanged = pets != original.pets
            let legacyFieldsChanged =
                windowPositionX != original.windowPositionX ||
                windowPositionY != original.windowPositionY ||
                petSize != original.petSize ||
                selectedSpritePack != original.selectedSpritePack

            if !petsChanged && legacyFieldsChanged {
                pets[0].positionX = windowPositionX
                pets[0].positionY = windowPositionY
                pets[0].size = petSize
                pets[0].spritePack = selectedSpritePack
                return
            }

            synchronizeLegacyFields()
        }

        private static func resolvePets(
            _ pets: [PetIdentity]?,
            legacyWindowPositionX: Double,
            legacyWindowPositionY: Double,
            legacyPetSize: Double,
            legacySpritePack: String
        ) -> [PetIdentity] {
            if let pets, !pets.isEmpty {
                return pets
            }

            return [
                PetIdentity(
                    id: UUID(),
                    name: "Cat",
                    spritePack: legacySpritePack,
                    size: legacyPetSize,
                    positionX: legacyWindowPositionX,
                    positionY: legacyWindowPositionY
                )
            ]
        }

        private static func clampedMemoryQueryLimit(_ value: Int) -> Int {
            max(1, min(100, value))
        }

        private static func normalizedMemoryHorizon(_ value: String) -> String {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch normalized {
            case "daily", "weekly", "monthly", "permanent":
                return normalized
            default:
                return "daily"
            }
        }
    }

    public private(set) var config: AppConfig
    private let applicationSupportDirectoryURL: URL
    private let configFileURL: URL

    public init() {
        let storageURL = Self.defaultStorageURL()
        self.applicationSupportDirectoryURL = storageURL
        self.configFileURL = storageURL.appendingPathComponent("config.plist")
        self.config = Self.load(storageURL: storageURL)
    }

    public init(config: AppConfig) {
        let storageURL = Self.defaultStorageURL()
        self.applicationSupportDirectoryURL = storageURL
        self.configFileURL = storageURL.appendingPathComponent("config.plist")
        self.config = config
    }

    public init(storageURL: URL) {
        self.applicationSupportDirectoryURL = storageURL
        self.configFileURL = storageURL.appendingPathComponent("config.plist")
        self.config = Self.load(storageURL: storageURL)
    }

    public func save() throws {
        try ensureApplicationSupportDirectoryExists()

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data = try encoder.encode(config)
        try data.write(to: configFileURL, options: .atomic)
    }

    public func update(_ transform: (inout AppConfig) -> Void) throws {
        let originalConfig = config
        transform(&config)
        config.reconcileLegacyFields(afterUpdatingFrom: originalConfig)
        try save()
    }

    public static func load() -> AppConfig {
        load(storageURL: defaultStorageURL())
    }

    public static func load(storageURL: URL) -> AppConfig {
        do {
            try ensureApplicationSupportDirectoryExists(at: storageURL)

            let data = try Data(contentsOf: storageURL.appendingPathComponent("config.plist"))
            let decoder = PropertyListDecoder()
            return try decoder.decode(AppConfig.self, from: data)
        } catch {
            return defaultConfig()
        }
    }
}

extension ConfigManager {
    nonisolated private static func defaultStorageURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return baseURL.appendingPathComponent("VitaPet", isDirectory: true)
    }

    private func ensureApplicationSupportDirectoryExists() throws {
        try Self.ensureApplicationSupportDirectoryExists(at: applicationSupportDirectoryURL)
    }

    nonisolated private static func ensureApplicationSupportDirectoryExists(at storageURL: URL) throws {
        try FileManager.default.createDirectory(
            at: storageURL,
            withIntermediateDirectories: true
        )
    }

    nonisolated private static func defaultConfig() -> AppConfig {
        AppConfig(
            windowPositionX: 120,
            windowPositionY: 120,
            petSize: 96,
            selectedSpritePack: "default",
            enabledCapabilities: [:],
            disabledPlugins: [],
            locale: defaultLocaleIdentifier()
        )
    }

    nonisolated private static func defaultLocaleIdentifier() -> String {
        let preferredIdentifier = Locale.preferredLanguages.first ?? Locale.current.identifier
        return preferredIdentifier.hasPrefix("zh") ? "zh-Hans" : "en"
    }
}
