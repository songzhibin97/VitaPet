import Foundation
import SecurityLayer

// MARK: - KeychainStoring protocol (enables test injection of failing mocks)

/// Minimal async interface consumed by ConfigManager. `KeychainManager` conforms below.
protocol KeychainStoring: Actor {
    func setString(_ value: String, forKey key: String) async throws
    func getString(forKey key: String) async throws -> String?
}

extension KeychainManager: KeychainStoring {}

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
        public var ollamaModel: String
        public var aiSystemPrompt: String
        public var aiProactiveEnabled: Bool
        public var aiProactiveInterval: Int
        /// Legacy field — retained for decoding old plist only.
        /// Authoritative value lives in Keychain. Always written as "" on save.
        public var githubToken: String
        public var webhookEnabled: Bool
        public var webhookPort: Int
        /// Legacy field — retained for decoding old plist only.
        /// Authoritative value lives in Keychain. Always written as "" on save.
        public var webhookSecret: String
        public var spaceMode: String  // "allSpaces", "follow", "singleSpace"
        public var aiTemperature: Double
        public var aiTopP: Double
        public var aiNumCtx: Int

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
            ollamaModel: String = "llama3.2",
            aiSystemPrompt: String = "",
            aiProactiveEnabled: Bool = true,
            aiProactiveInterval: Int = 45,
            githubToken: String = "",
            webhookEnabled: Bool = false,
            webhookPort: Int = 19280,
            webhookSecret: String = "",
            spaceMode: String = "allSpaces",
            aiTemperature: Double = 0.7,
            aiTopP: Double = 0.9,
            aiNumCtx: Int = 4096
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
            self.ollamaModel = ollamaModel
            self.aiSystemPrompt = aiSystemPrompt
            self.aiProactiveEnabled = aiProactiveEnabled
            self.aiProactiveInterval = aiProactiveInterval
            self.githubToken = githubToken
            self.webhookEnabled = webhookEnabled
            self.webhookPort = webhookPort
            self.webhookSecret = webhookSecret
            self.spaceMode = spaceMode
            self.aiTemperature = aiTemperature
            self.aiTopP = aiTopP
            self.aiNumCtx = aiNumCtx
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
            case ollamaModel
            case aiSystemPrompt
            case aiProactiveEnabled
            case aiProactiveInterval
            case githubToken
            case webhookEnabled
            case webhookPort
            case webhookSecret
            case spaceMode
            case aiTemperature
            case aiTopP
            case aiNumCtx
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
            ollamaModel = try container.decodeIfPresent(String.self, forKey: .ollamaModel) ?? "llama3.2"
            aiSystemPrompt = try container.decodeIfPresent(String.self, forKey: .aiSystemPrompt) ?? ""
            aiProactiveEnabled = try container.decodeIfPresent(Bool.self, forKey: .aiProactiveEnabled) ?? true
            aiProactiveInterval = try container.decodeIfPresent(Int.self, forKey: .aiProactiveInterval) ?? 45
            githubToken = try container.decodeIfPresent(String.self, forKey: .githubToken) ?? ""
            webhookEnabled = try container.decodeIfPresent(Bool.self, forKey: .webhookEnabled) ?? false
            webhookPort = try container.decodeIfPresent(Int.self, forKey: .webhookPort) ?? 19280
            webhookSecret = try container.decodeIfPresent(String.self, forKey: .webhookSecret) ?? ""
            spaceMode = try container.decodeIfPresent(String.self, forKey: .spaceMode) ?? "allSpaces"
            aiTemperature = try container.decodeIfPresent(Double.self, forKey: .aiTemperature) ?? 0.7
            aiTopP = try container.decodeIfPresent(Double.self, forKey: .aiTopP) ?? 0.9
            aiNumCtx = try container.decodeIfPresent(Int.self, forKey: .aiNumCtx) ?? 4096
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
    }

    // MARK: - Keychain keys
    private enum KeychainKey {
        static let githubToken = "githubToken"
        static let webhookSecret = "webhookSecret"
    }

    public private(set) var config: AppConfig
    private let applicationSupportDirectoryURL: URL
    private let configFileURL: URL
    private let keychain: any KeychainStoring

    /// In-memory cache for the github token (populated by `create` or explicit `setGithubToken`).
    /// Allows sync read from @MainActor context without async hop.
    private var cachedGithubToken: String = ""
    /// In-memory cache for the webhook secret.
    private var cachedWebhookSecret: String = ""

    // MARK: - Designated initializer (internal use + test injection)
    init(initialConfig: AppConfig, storageURL: URL, keychain: any KeychainStoring) {
        self.config = initialConfig
        self.applicationSupportDirectoryURL = storageURL
        self.configFileURL = storageURL.appendingPathComponent("config.plist")
        self.keychain = keychain
    }

    // MARK: - Legacy sync initializers (preserved for existing test compatibility)

    public init() {
        let storageURL = Self.defaultStorageURL()
        self.applicationSupportDirectoryURL = storageURL
        self.configFileURL = storageURL.appendingPathComponent("config.plist")
        self.keychain = KeychainManager()
        self.config = Self.load(storageURL: storageURL)
    }

    public init(config: AppConfig) {
        let storageURL = Self.defaultStorageURL()
        self.applicationSupportDirectoryURL = storageURL
        self.configFileURL = storageURL.appendingPathComponent("config.plist")
        self.keychain = KeychainManager()
        self.config = config
    }

    public init(storageURL: URL) {
        self.applicationSupportDirectoryURL = storageURL
        self.configFileURL = storageURL.appendingPathComponent("config.plist")
        self.keychain = KeychainManager()
        self.config = Self.load(storageURL: storageURL)
    }

    // MARK: - Async factory (preferred for production bootstrap)

    /// Creates a ConfigManager, migrating any legacy plist credentials to Keychain,
    /// and warming the in-memory cache from Keychain.
    public static func create(
        storageURL: URL = defaultStorageURL(),
        keychain: KeychainManager = KeychainManager()
    ) async -> ConfigManager {
        await create(storageURL: storageURL, keychainStoring: keychain)
    }

    /// Internal overload that accepts any `KeychainStoring` implementation.
    /// Used by tests to inject a failing or mock keychain.
    static func create(
        storageURL: URL = defaultStorageURL(),
        keychainStoring keychain: any KeychainStoring
    ) async -> ConfigManager {
        let (loadedConfig, pendingMigration) = await loadWithMigrationData(storageURL: storageURL)
        let manager = ConfigManager(initialConfig: loadedConfig, storageURL: storageURL, keychain: keychain)
        await manager.performMigrationIfNeeded(pendingMigration)
        // Warm the cache after potential migration
        await manager.warmCache()
        return manager
    }

    // MARK: - Keychain accessors (async — authoritative source)

    public func githubToken() async -> String {
        let value = (try? await keychain.getString(forKey: KeychainKey.githubToken)) ?? ""
        cachedGithubToken = value
        return value
    }

    public func setGithubToken(_ value: String) async throws {
        try await keychain.setString(value, forKey: KeychainKey.githubToken)
        cachedGithubToken = value
    }

    public func webhookSecret() async -> String {
        let value = (try? await keychain.getString(forKey: KeychainKey.webhookSecret)) ?? ""
        cachedWebhookSecret = value
        return value
    }

    public func setWebhookSecret(_ value: String) async throws {
        try await keychain.setString(value, forKey: KeychainKey.webhookSecret)
        cachedWebhookSecret = value
    }

    // MARK: - Sync cache reads (for use in @MainActor sync closures)

    /// Synchronous read of github token from in-memory cache.
    /// Always call `githubToken()` at least once after init, or use `create()`, to ensure this is populated.
    public var cachedGithubTokenValue: String { cachedGithubToken }

    /// Synchronous read of webhook secret from in-memory cache.
    public var cachedWebhookSecretValue: String { cachedWebhookSecret }

    // MARK: - Persist

    public func save() throws {
        try ensureApplicationSupportDirectoryExists()

        // Sanitize: never write sensitive fields to plist
        var sanitized = config
        sanitized.githubToken = ""
        sanitized.webhookSecret = ""

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data = try encoder.encode(sanitized)
        try data.write(to: configFileURL, options: .atomic)
    }

    public func update(_ transform: (inout AppConfig) -> Void) throws {
        let originalConfig = config
        transform(&config)
        config.reconcileLegacyFields(afterUpdatingFrom: originalConfig)
        try save()
    }

    // MARK: - Load (sync, for legacy inits)

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

    // MARK: - Private helpers

    /// Returns the loaded config along with any credentials that need migrating to Keychain.
    /// Migration candidates: non-empty plist fields that haven't already been saved to Keychain.
    private static func loadWithMigrationData(storageURL: URL) async -> (AppConfig, [String: String]) {
        let cfg = load(storageURL: storageURL)
        var pending: [String: String] = [:]
        if !cfg.githubToken.isEmpty {
            pending[KeychainKey.githubToken] = cfg.githubToken
        }
        if !cfg.webhookSecret.isEmpty {
            pending[KeychainKey.webhookSecret] = cfg.webhookSecret
        }
        return (cfg, pending)
    }

    /// Writes pending credentials to Keychain (only if Keychain doesn't already have a value),
    /// then rewrites plist with those fields blanked out. Idempotent.
    ///
    /// Safety invariants:
    /// - A plist field is cleared **only** when Keychain is confirmed to hold a value for that key
    ///   (either pre-existing or just written successfully). This prevents both:
    ///   P0: plist plaintext residue when Keychain already had a value and didMigrate stayed false.
    ///   P1: credential loss when a Keychain write fails silently.
    private func performMigrationIfNeeded(_ pending: [String: String]) async {
        guard !pending.isEmpty else { return }

        // Track which keys are confirmed safe in Keychain (pre-existing OR freshly written).
        var keysConfirmedInKeychain: Set<String> = []

        for (key, value) in pending {
            let existing = try? await keychain.getString(forKey: key)
            if let existing, !existing.isEmpty {
                // Keychain already holds a value — do not overwrite; still safe to clear plist.
                keysConfirmedInKeychain.insert(key)
            } else {
                // Keychain is empty — attempt to migrate plist value.
                do {
                    try await keychain.setString(value, forKey: key)
                    keysConfirmedInKeychain.insert(key)
                } catch {
                    // Write failed: keep plist value intact to avoid credential loss.
                    AppLogger.error("Keychain migration failed for key '\(key)': \(error.localizedDescription)")
                }
            }
        }

        // Clear only the plist fields that are confirmed safe in Keychain.
        if keysConfirmedInKeychain.contains(KeychainKey.githubToken) {
            config.githubToken = ""
        }
        if keysConfirmedInKeychain.contains(KeychainKey.webhookSecret) {
            config.webhookSecret = ""
        }

        // Persist if at least one field was sanitized.
        if !keysConfirmedInKeychain.isEmpty {
            try? save()
        }
    }

    /// Populates the in-memory cache from Keychain.
    private func warmCache() async {
        cachedGithubToken = (try? await keychain.getString(forKey: KeychainKey.githubToken)) ?? ""
        cachedWebhookSecret = (try? await keychain.getString(forKey: KeychainKey.webhookSecret)) ?? ""
    }
}

extension ConfigManager {
    nonisolated public static func defaultStorageURL() -> URL {
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
