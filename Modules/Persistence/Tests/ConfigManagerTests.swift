import Persistence
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

    private func makeStorageURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
