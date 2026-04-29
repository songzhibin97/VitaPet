@testable import Persistence
import SecurityLayer
import XCTest

@MainActor
final class ConfigManagerTests: XCTestCase {
    func testInitWithConfig_storesConfig() {
        let pet = PetIdentity(
            id: UUID(),
            name: "Retro Cat",
            spritePack: "retro",
            size: 320,
            positionX: 10,
            positionY: 20
        )
        let config = ConfigManager.AppConfig(
            windowPositionX: 10,
            windowPositionY: 20,
            petSize: 320,
            selectedSpritePack: "retro",
            pets: [pet],
            enabledCapabilities: ["aiChat": true],
            locale: "en"
        )

        let manager = ConfigManager(config: config)

        XCTAssertEqual(manager.config.windowPositionX, 10)
        XCTAssertEqual(manager.config.windowPositionY, 20)
        XCTAssertEqual(manager.config.petSize, 320)
        XCTAssertEqual(manager.config.selectedSpritePack, "retro")
        XCTAssertEqual(manager.config.pets, [pet])
        XCTAssertEqual(manager.config.enabledCapabilities, ["aiChat": true])
        XCTAssertEqual(manager.config.locale, "en")
    }

    func testDefaultConfig_hasExpectedDefaults() {
        let storageURL = makeStorageURL()
        defer { try? FileManager.default.removeItem(at: storageURL) }
        let manager = ConfigManager(storageURL: storageURL)

        XCTAssertEqual(manager.config.windowPositionX, 120)
        XCTAssertEqual(manager.config.windowPositionY, 120)
        XCTAssertEqual(manager.config.petSize, 96)
        XCTAssertEqual(manager.config.selectedSpritePack, "default")
        XCTAssertEqual(manager.config.pets.count, 1)
        XCTAssertEqual(manager.config.pets[0].name, "Cat")
        XCTAssertEqual(manager.config.pets[0].spritePack, "default")
        XCTAssertTrue(manager.config.enabledCapabilities.isEmpty)
        XCTAssertEqual(
            manager.config.locale,
            (Locale.preferredLanguages.first ?? Locale.current.identifier).hasPrefix("zh") ? "zh-Hans" : "en"
        )
    }

    func testDefaultConfig_hasAIProactiveDefaults() {
        let storageURL = makeStorageURL()
        defer { try? FileManager.default.removeItem(at: storageURL) }
        let manager = ConfigManager(storageURL: storageURL)

        XCTAssertTrue(manager.config.aiProactiveEnabled)
        XCTAssertEqual(manager.config.aiProactiveInterval, 45)
    }

    func testDefaultConfig_hasAIChatOptionDefaults() {
        let storageURL = makeStorageURL()
        defer { try? FileManager.default.removeItem(at: storageURL) }
        let manager = ConfigManager(storageURL: storageURL)

        XCTAssertEqual(manager.config.aiTemperature, 0.7, accuracy: 0.001)
        XCTAssertEqual(manager.config.aiTopP, 0.9, accuracy: 0.001)
        XCTAssertEqual(manager.config.aiNumCtx, 4096)
    }

    func testAIChatOptions_decodeCompatibility_missingFieldsFallbackToDefaults() throws {
        // Simulate an old plist that does NOT contain aiTemperature/aiTopP/aiNumCtx.
        let legacyPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>windowPositionX</key><real>100</real>
            <key>windowPositionY</key><real>200</real>
            <key>ollamaEndpoint</key><string>http://localhost:11434</string>
            <key>ollamaModel</key><string>llama3.2</string>
        </dict>
        </plist>
        """
        let data = Data(legacyPlist.utf8)
        let decoder = PropertyListDecoder()
        let config = try decoder.decode(ConfigManager.AppConfig.self, from: data)

        XCTAssertEqual(config.aiTemperature, 0.7, accuracy: 0.001)
        XCTAssertEqual(config.aiTopP, 0.9, accuracy: 0.001)
        XCTAssertEqual(config.aiNumCtx, 4096)
    }

    func testDefaultConfig_hasNotificationDefaults() {
        let storageURL = makeStorageURL()
        defer { try? FileManager.default.removeItem(at: storageURL) }
        let manager = ConfigManager(storageURL: storageURL)

        XCTAssertEqual(manager.config.githubToken, "")
        XCTAssertFalse(manager.config.webhookEnabled)
        XCTAssertEqual(manager.config.webhookPort, 19280)
    }

    func testUpdate_modifiesConfig() throws {
        let storageURL = makeStorageURL()
        defer { try? FileManager.default.removeItem(at: storageURL) }
        let manager = ConfigManager(storageURL: storageURL)

        try manager.update {
            $0.windowPositionX = 320
            $0.selectedSpritePack = "pixel"
        }

        XCTAssertEqual(manager.config.windowPositionX, 320)
        XCTAssertEqual(manager.config.selectedSpritePack, "pixel")
    }

    func testAppConfig_codableRoundtrip() throws {
        let pets = [
            PetIdentity(
                id: UUID(),
                name: "Classic Cat",
                spritePack: "classic",
                size: 200,
                positionX: 1,
                positionY: 2
            ),
            PetIdentity(
                id: UUID(),
                name: "Pixel Cat",
                spritePack: "pixel",
                size: 120,
                positionX: 40,
                positionY: 50
            )
        ]
        let config = ConfigManager.AppConfig(
            windowPositionX: 1,
            windowPositionY: 2,
            petSize: 200,
            selectedSpritePack: "classic",
            pets: pets,
            enabledCapabilities: ["basePet": true],
            locale: "zh-Hans"
        )

        let data = try PropertyListEncoder().encode(config)
        let decoded = try PropertyListDecoder().decode(ConfigManager.AppConfig.self, from: data)

        XCTAssertEqual(decoded.windowPositionX, config.windowPositionX)
        XCTAssertEqual(decoded.windowPositionY, config.windowPositionY)
        XCTAssertEqual(decoded.petSize, config.petSize)
        XCTAssertEqual(decoded.selectedSpritePack, config.selectedSpritePack)
        XCTAssertEqual(decoded.pets, pets)
        XCTAssertEqual(decoded.enabledCapabilities, config.enabledCapabilities)
        XCTAssertEqual(decoded.locale, config.locale)
    }

    func testAppConfig_codableRoundtrip_withNewFields() throws {
        let config = ConfigManager.AppConfig(
            windowPositionX: 1,
            windowPositionY: 2,
            petSize: 144,
            selectedSpritePack: "retro",
            pets: [
                PetIdentity(
                    id: UUID(),
                    name: "Retro Cat",
                    spritePack: "retro",
                    size: 144,
                    gender: "female",
                    age: "2岁",
                    personality: "活泼",
                    hobbies: "晒太阳",
                    positionX: 1,
                    positionY: 2
                )
            ],
            enabledCapabilities: ["aiChat": true],
            disabledPlugins: ["demo.plugin"],
            locale: "en",
            ollamaEndpoint: "http://127.0.0.1:11435",
            ollamaModel: "qwen2.5",
            aiSystemPrompt: "Be concise",
            aiProactiveEnabled: false,
            aiProactiveInterval: 90,
            githubToken: "ghp_test_token",
            webhookEnabled: true,
            webhookPort: 18080,
            spaceMode: "singleSpace"
        )

        let data = try PropertyListEncoder().encode(config)
        let decoded = try PropertyListDecoder().decode(ConfigManager.AppConfig.self, from: data)

        XCTAssertEqual(decoded.aiProactiveEnabled, false)
        XCTAssertEqual(decoded.aiProactiveInterval, 90)
        XCTAssertEqual(decoded.githubToken, "ghp_test_token")
        XCTAssertEqual(decoded.webhookEnabled, true)
        XCTAssertEqual(decoded.webhookPort, 18080)
        XCTAssertEqual(decoded.ollamaEndpoint, "http://127.0.0.1:11435")
        XCTAssertEqual(decoded.ollamaModel, "qwen2.5")
        XCTAssertEqual(decoded.aiSystemPrompt, "Be concise")
        XCTAssertEqual(decoded.spaceMode, "singleSpace")
        XCTAssertEqual(decoded.pets[0].gender, "female")
        XCTAssertEqual(decoded.pets[0].age, "2岁")
        XCTAssertEqual(decoded.pets[0].personality, "活泼")
        XCTAssertEqual(decoded.pets[0].hobbies, "晒太阳")
    }

    func testPetIdentity_decodesMissingProfileFieldsWithDefaults() throws {
        let legacyPet: [String: Any] = [
            "id": UUID().uuidString,
            "name": "Legacy Cat",
            "spritePack": "legacy-pack",
            "size": 96.0,
            "positionX": 120.0,
            "positionY": 140.0,
            "happiness": 60
        ]

        let data = try PropertyListSerialization.data(
            fromPropertyList: legacyPet,
            format: .xml,
            options: 0
        )

        let decoded = try PropertyListDecoder().decode(PetIdentity.self, from: data)

        XCTAssertEqual(decoded.gender, "neutral")
        XCTAssertEqual(decoded.age, "")
        XCTAssertEqual(decoded.personality, "")
        XCTAssertEqual(decoded.hobbies, "")
    }

    func testSave_writesFile() throws {
        let storageURL = makeStorageURL()
        defer { try? FileManager.default.removeItem(at: storageURL) }
        let manager = ConfigManager(storageURL: storageURL)

        try manager.save()

        let configFileURL = storageURL.appendingPathComponent("config.plist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: configFileURL.path))
    }

    func testLoad_readsFromDisk() throws {
        let storageURL = makeStorageURL()
        defer { try? FileManager.default.removeItem(at: storageURL) }
        let manager = ConfigManager(storageURL: storageURL)
        try manager.update {
            $0.windowPositionY = 450
            $0.locale = "en"
        }

        let reloaded = ConfigManager(storageURL: storageURL)

        XCTAssertEqual(reloaded.config.windowPositionY, 450)
        XCTAssertEqual(reloaded.config.locale, "en")
    }

    func testLoad_returnsDefaultsWhenNoFile() {
        let storageURL = makeStorageURL()
        defer { try? FileManager.default.removeItem(at: storageURL) }
        let loaded = ConfigManager.load(storageURL: storageURL)

        XCTAssertEqual(loaded.windowPositionX, 120)
        XCTAssertEqual(loaded.windowPositionY, 120)
        XCTAssertEqual(loaded.petSize, 96)
        XCTAssertEqual(loaded.selectedSpritePack, "default")
        XCTAssertEqual(loaded.pets.count, 1)
        XCTAssertTrue(loaded.enabledCapabilities.isEmpty)
    }

    func testUpdate_persistsChange() throws {
        let storageURL = makeStorageURL()
        defer { try? FileManager.default.removeItem(at: storageURL) }
        let manager = ConfigManager(storageURL: storageURL)

        try manager.update {
            $0.enabledCapabilities["systemAwareness"] = true
        }

        let reloaded = ConfigManager(storageURL: storageURL)
        XCTAssertEqual(reloaded.config.enabledCapabilities["systemAwareness"], true)
    }

    func testLegacyConfigDecodesIntoSinglePet() throws {
        let legacyConfig: [String: Any] = [
            "windowPositionX": 210.0,
            "windowPositionY": 240.0,
            "petSize": 144.0,
            "selectedSpritePack": "legacy-pack",
            "enabledCapabilities": ["basePet": true],
            "disabledPlugins": ["demo.plugin"],
            "locale": "en"
        ]

        let data = try PropertyListSerialization.data(
            fromPropertyList: legacyConfig,
            format: .xml,
            options: 0
        )

        let decoded = try PropertyListDecoder().decode(ConfigManager.AppConfig.self, from: data)

        XCTAssertEqual(decoded.pets.count, 1)
        XCTAssertEqual(decoded.pets[0].spritePack, "legacy-pack")
        XCTAssertEqual(decoded.pets[0].size, 144)
        XCTAssertEqual(decoded.pets[0].positionX, 210)
        XCTAssertEqual(decoded.pets[0].positionY, 240)
        XCTAssertEqual(decoded.selectedSpritePack, "legacy-pack")
    }

    func testUpdate_persistsMultiplePets() throws {
        let storageURL = makeStorageURL()
        defer { try? FileManager.default.removeItem(at: storageURL) }
        let manager = ConfigManager(storageURL: storageURL)
        let secondPet = PetIdentity(
            id: UUID(),
            name: "Second Cat",
            spritePack: "default",
            size: 96,
            positionX: 180,
            positionY: 200
        )

        try manager.update {
            $0.pets.append(secondPet)
        }

        let reloaded = ConfigManager(storageURL: storageURL)
        XCTAssertEqual(reloaded.config.pets.count, 2)
        XCTAssertEqual(reloaded.config.pets[1], secondPet)
    }

    // MARK: - Save sanitizes sensitive fields

    func testSave_doesNotWriteGithubTokenOrWebhookSecretToPlist() throws {
        let storageURL = makeStorageURL()
        defer { try? FileManager.default.removeItem(at: storageURL) }
        let manager = ConfigManager(storageURL: storageURL)

        // Manually set in-memory (legacy path, not Keychain)
        try manager.update {
            $0.githubToken = "should-not-be-saved"
            $0.webhookSecret = "secret-should-not-be-saved"
        }

        let configFileURL = storageURL.appendingPathComponent("config.plist")
        let data = try Data(contentsOf: configFileURL)
        let decoded = try PropertyListDecoder().decode(ConfigManager.AppConfig.self, from: data)

        XCTAssertEqual(decoded.githubToken, "", "githubToken must be blank in plist")
        XCTAssertEqual(decoded.webhookSecret, "", "webhookSecret must be blank in plist")
    }

    // MARK: - Keychain migration tests (use isolated keychain service)

    func testCreate_migratesLegacyPlistTokenToKeychain() async throws {
        let storageURL = makeStorageURL()
        let keychainService = makeKeychainService()
        defer {
            try? FileManager.default.removeItem(at: storageURL)
            Task { try? await KeychainManager(service: keychainService).delete(forKey: "githubToken") }
        }

        // Write a legacy plist that contains a plaintext githubToken
        try writeLegacyPlist(
            at: storageURL,
            githubToken: "ghp_legacy_token",
            webhookSecret: "legacy_secret"
        )

        let keychain = KeychainManager(service: keychainService)
        let manager = await ConfigManager.create(storageURL: storageURL, keychain: keychain)

        // Token is accessible via async accessor
        let token = await manager.githubToken()
        XCTAssertEqual(token, "ghp_legacy_token", "Token must be migrated to Keychain")

        let secret = await manager.webhookSecret()
        XCTAssertEqual(secret, "legacy_secret", "Secret must be migrated to Keychain")

        // plist must have been rewritten with blank fields
        let plistData = try Data(contentsOf: storageURL.appendingPathComponent("config.plist"))
        let decodedPlist = try PropertyListDecoder().decode(ConfigManager.AppConfig.self, from: plistData)
        XCTAssertEqual(decodedPlist.githubToken, "", "plist githubToken must be blank after migration")
        XCTAssertEqual(decodedPlist.webhookSecret, "", "plist webhookSecret must be blank after migration")
    }

    func testCreate_keychainAlreadyHasValue_doesNotOverwrite() async throws {
        let storageURL = makeStorageURL()
        let keychainService = makeKeychainService()
        defer {
            try? FileManager.default.removeItem(at: storageURL)
            Task {
                let kc = KeychainManager(service: keychainService)
                try? await kc.delete(forKey: "githubToken")
                try? await kc.delete(forKey: "webhookSecret")
            }
        }

        // Pre-populate Keychain with a value
        let keychain = KeychainManager(service: keychainService)
        try await keychain.setString("existing_keychain_token", forKey: "githubToken")
        try await keychain.setString("existing_keychain_secret", forKey: "webhookSecret")

        // Write a legacy plist with a different token
        try writeLegacyPlist(at: storageURL, githubToken: "old_plist_token", webhookSecret: "old_plist_secret")

        let manager = await ConfigManager.create(storageURL: storageURL, keychain: keychain)

        // Keychain value must NOT be overwritten by plist value
        let token = await manager.githubToken()
        XCTAssertEqual(token, "existing_keychain_token", "Existing Keychain value must not be overwritten")

        let secret = await manager.webhookSecret()
        XCTAssertEqual(secret, "existing_keychain_secret", "Existing Keychain secret must not be overwritten")
    }

    func testCreate_noLegacyPlist_readsExistingKeychainValue() async throws {
        let storageURL = makeStorageURL()
        let keychainService = makeKeychainService()
        defer {
            try? FileManager.default.removeItem(at: storageURL)
            Task {
                let kc = KeychainManager(service: keychainService)
                try? await kc.delete(forKey: "githubToken")
                try? await kc.delete(forKey: "webhookSecret")
            }
        }

        let keychain = KeychainManager(service: keychainService)
        try await keychain.setString("kc_token_only", forKey: "githubToken")

        // No legacy plist — fresh start
        let manager = await ConfigManager.create(storageURL: storageURL, keychain: keychain)

        let token = await manager.githubToken()
        XCTAssertEqual(token, "kc_token_only")
    }

    func testCreate_migrationIsIdempotent() async throws {
        let storageURL = makeStorageURL()
        let keychainService = makeKeychainService()
        defer {
            try? FileManager.default.removeItem(at: storageURL)
            Task {
                let kc = KeychainManager(service: keychainService)
                try? await kc.delete(forKey: "githubToken")
            }
        }

        try writeLegacyPlist(at: storageURL, githubToken: "ghp_idempotent", webhookSecret: "")

        let keychain = KeychainManager(service: keychainService)

        // First create — migrates
        let manager1 = await ConfigManager.create(storageURL: storageURL, keychain: keychain)
        let token1 = await manager1.githubToken()
        XCTAssertEqual(token1, "ghp_idempotent")

        // Second create — plist now has blank token, Keychain already has value → should not overwrite with ""
        let manager2 = await ConfigManager.create(storageURL: storageURL, keychain: keychain)
        let token2 = await manager2.githubToken()
        XCTAssertEqual(token2, "ghp_idempotent", "Second startup must not overwrite Keychain with empty plist value")
    }

    func testSetGithubToken_persistsToKeychain() async throws {
        let storageURL = makeStorageURL()
        let keychainService = makeKeychainService()
        defer {
            try? FileManager.default.removeItem(at: storageURL)
            Task { try? await KeychainManager(service: keychainService).delete(forKey: "githubToken") }
        }

        let keychain = KeychainManager(service: keychainService)
        let manager = await ConfigManager.create(storageURL: storageURL, keychain: keychain)

        try await manager.setGithubToken("new_ghp_token")

        // Re-read from same manager
        let token = await manager.githubToken()
        XCTAssertEqual(token, "new_ghp_token")

        // Verify via a fresh Keychain read
        let raw = try await keychain.getString(forKey: "githubToken")
        XCTAssertEqual(raw, "new_ghp_token")
    }

    func testSetGithubToken_cachedValueIsUpdatedSynchronously() async throws {
        let storageURL = makeStorageURL()
        let keychainService = makeKeychainService()
        defer {
            try? FileManager.default.removeItem(at: storageURL)
            Task { try? await KeychainManager(service: keychainService).delete(forKey: "githubToken") }
        }

        let keychain = KeychainManager(service: keychainService)
        let manager = await ConfigManager.create(storageURL: storageURL, keychain: keychain)

        try await manager.setGithubToken("sync_cached_token")

        // cachedGithubTokenValue must reflect the new value without an additional async round-trip
        XCTAssertEqual(manager.cachedGithubTokenValue, "sync_cached_token")
    }

    // MARK: - P0: plist cleared even when Keychain already has a value

    /// P0 fix: when both plist and Keychain already hold a value, the plist plaintext must still
    /// be cleared (the old code left it because didMigrate stayed false).
    func testCreate_legacyPlistAndKeychainBothHaveValues_clearsPlistKeepsKeychain() async throws {
        let storageURL = makeStorageURL()
        let keychainService = makeKeychainService()
        defer {
            try? FileManager.default.removeItem(at: storageURL)
            Task {
                let kc = KeychainManager(service: keychainService)
                try? await kc.delete(forKey: "githubToken")
                try? await kc.delete(forKey: "webhookSecret")
            }
        }

        // Pre-populate Keychain with existing values.
        let keychain = KeychainManager(service: keychainService)
        try await keychain.setString("keychain_token_value", forKey: "githubToken")
        try await keychain.setString("keychain_secret_value", forKey: "webhookSecret")

        // Write a legacy plist that also contains plaintext credentials.
        try writeLegacyPlist(
            at: storageURL,
            githubToken: "plist_token_value",
            webhookSecret: "plist_secret_value"
        )

        let manager = await ConfigManager.create(storageURL: storageURL, keychain: keychain)

        // Keychain values must NOT be overwritten by plist values.
        let token = await manager.githubToken()
        XCTAssertEqual(token, "keychain_token_value", "Keychain value must not be overwritten by plist value")

        let secret = await manager.webhookSecret()
        XCTAssertEqual(secret, "keychain_secret_value", "Keychain secret must not be overwritten by plist value")

        // Plist must have been rewritten with blank sensitive fields (P0 fix: was not happening before).
        let plistData = try Data(contentsOf: storageURL.appendingPathComponent("config.plist"))
        let decodedPlist = try PropertyListDecoder().decode(ConfigManager.AppConfig.self, from: plistData)
        XCTAssertEqual(decodedPlist.githubToken, "", "plist githubToken must be blank even when Keychain already had a value")
        XCTAssertEqual(decodedPlist.webhookSecret, "", "plist webhookSecret must be blank even when Keychain already had a value")
    }

    // MARK: - P1: Keychain write failure must not clear plist (no credential loss)

    /// P1 fix: when Keychain write fails, the plist must retain the original value so credentials
    /// are not silently lost. We simulate failure by using an injected FailingKeychainManager.
    func testCreate_keychainWriteFailure_doesNotClearPlist() async throws {
        let storageURL = makeStorageURL()
        defer { try? FileManager.default.removeItem(at: storageURL) }

        // Write a legacy plist with a token — Keychain starts empty.
        try writeLegacyPlist(
            at: storageURL,
            githubToken: "token_to_preserve",
            webhookSecret: "secret_to_preserve"
        )

        // Use an always-failing KeychainStoring to simulate write failure.
        let failingKeychain = FailingKeychainManager()
        let manager = await ConfigManager.create(storageURL: storageURL, keychainStoring: failingKeychain)

        // The plist must still contain the original plaintext (not cleared) because the Keychain
        // write failed and we have no safe place to store the credentials.
        let plistData = try Data(contentsOf: storageURL.appendingPathComponent("config.plist"))
        let decodedPlist = try PropertyListDecoder().decode(ConfigManager.AppConfig.self, from: plistData)
        XCTAssertEqual(
            decodedPlist.githubToken, "token_to_preserve",
            "plist githubToken must NOT be cleared when Keychain write fails"
        )
        XCTAssertEqual(
            decodedPlist.webhookSecret, "secret_to_preserve",
            "plist webhookSecret must NOT be cleared when Keychain write fails"
        )

        // The in-memory manager should also return empty (Keychain unavailable, plist not used).
        let token = await manager.githubToken()
        XCTAssertEqual(token, "", "githubToken must return empty when Keychain is unavailable")
    }

    // MARK: - Helpers

    private func makeStorageURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func makeKeychainService() -> String {
        "app.vitapet.secrets.configmgrtest.\(UUID().uuidString)"
    }

    /// Writes a minimal config plist to `storageURL/config.plist` containing the given credentials.
    private func writeLegacyPlist(at storageURL: URL, githubToken: String, webhookSecret: String) throws {
        try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
        let config = ConfigManager.AppConfig(
            windowPositionX: 100,
            windowPositionY: 100,
            selectedSpritePack: "default",
            enabledCapabilities: [:],
            locale: "en",
            githubToken: githubToken,
            webhookSecret: webhookSecret
        )
        let data = try PropertyListEncoder().encode(config)
        try data.write(to: storageURL.appendingPathComponent("config.plist"), options: .atomic)
    }
}

// MARK: - FailingKeychainManager (P1 test helper)

/// An actor that conforms to `KeychainStoring` and always fails on writes.
/// Used to verify that a Keychain write failure does not clear plist credentials.
private actor FailingKeychainManager: KeychainStoring {
    enum FailError: Error { case alwaysFails }

    func setString(_ value: String, forKey key: String) async throws {
        throw FailError.alwaysFails
    }

    func getString(forKey key: String) async throws -> String? {
        return nil
    }
}
