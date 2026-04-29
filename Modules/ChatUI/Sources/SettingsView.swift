import EventBus
import Foundation
import Localization
import RenderEngine
import SwiftUI

public struct SpritePackOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct SpritePackDisplayItem: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let directory: URL
    public let stateCount: Int
    public let totalFrameCount: Int
    public let isBuiltIn: Bool

    public init(id: String, name: String, directory: URL, stateCount: Int, totalFrameCount: Int, isBuiltIn: Bool) {
        self.id = id
        self.name = name
        self.directory = directory
        self.stateCount = stateCount
        self.totalFrameCount = totalFrameCount
        self.isBuiltIn = isBuiltIn
    }
}

public struct PetProfileItem: Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var spritePack: String
    public var size: Double
    public var gender: String
    public var age: String
    public var personality: String
    public var hobbies: String
    public var customLanguage: [String: [String]]?
    public var soundEnabled: Bool?
    public var soundVolume: Float?

    public init(
        id: UUID,
        name: String,
        spritePack: String,
        size: Double,
        gender: String,
        age: String,
        personality: String,
        hobbies: String,
        customLanguage: [String: [String]]? = nil,
        soundEnabled: Bool? = nil,
        soundVolume: Float? = nil
    ) {
        self.id = id
        self.name = name
        self.spritePack = spritePack
        self.size = size
        self.gender = gender
        self.age = age
        self.personality = personality
        self.hobbies = hobbies
        self.customLanguage = customLanguage
        self.soundEnabled = soundEnabled
        self.soundVolume = soundVolume
    }
}

public enum CapabilityItemStatus: Sendable {
    case active
    case needsPermission
    case inactive
}

public struct CapabilityItem: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public var status: CapabilityItemStatus
    public var isEnabled: Bool

    public init(
        id: String,
        name: String,
        description: String,
        status: CapabilityItemStatus,
        isEnabled: Bool
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.status = status
        self.isEnabled = isEnabled
    }
}

@MainActor
public struct SettingsView: View {
    // ── shared state ──
    @State private var capabilityItems: [CapabilityItem]
    @State private var pluginSettingsViewModel: PluginSettingsViewModel
    @State private var petProfiles: [PetProfileItem]
    @State private var errorMessage: String?
    @State private var showError: Bool

    // ── desktop awareness state (passed as Binding to section) ──
    @State private var desktopAwarenessEnabled: Bool
    @State private var desktopAwarenessRules: [EditableDesktopAwarenessRule]
    @State private var expandedDesktopRuleIDs: Set<UUID>
    @State private var desktopAwarenessStatusMessage: String?

    // ── sound state (passed as Binding to section) ──
    @State private var soundEnabled: Bool
    @State private var soundVolume: Double

    // ── weather state (passed as Binding to section) ──
    @State private var weatherAwarenessEnabled: Bool
    @State private var weatherLatitude: String
    @State private var weatherLongitude: String
    @State private var weatherRefreshMinutes: Int

    // ── AI state (passed as Binding to section) ──
    @State private var ollamaEndpoint: String
    @State private var ollamaModel: String
    @State private var aiSystemPrompt: String
    @State private var aiProactiveEnabled: Bool
    @State private var aiProactiveInterval: Int
    @State private var aiTemperature: Double
    @State private var aiTopP: Double
    @State private var aiNumCtx: Int

    // ── notification state (passed as Binding to section) ──
    @State private var githubToken: String
    @State private var webhookEnabled: Bool
    @State private var webhookPort: Int
    @State private var webhookSecret: String

    // ── plugin management state ──
    @State private var editingPluginID: String?

    // ── callbacks / props ──
    private let onSaveWeatherLocation: @MainActor (Double?, Double?) -> Void
    private let onSetWeatherRefreshInterval: @MainActor (Double) -> Void
    private let spritePackItems: [SpritePackDisplayItem]
    private let onSelectSpritePack: @MainActor (String) -> Void
    private let onImportPack: @MainActor () async -> String?
    private let onExportPack: @MainActor (String) async -> String?
    private let onDeletePack: @MainActor (String) async -> String?
    private let onRevealInFinder: @MainActor (String) -> Void
    private let onCreateTemplate: @MainActor () async -> String?
    private let loadPetProfiles: @MainActor () -> [PetProfileItem]
    private let aiStatus: AIEngineStatus
    private let onTestConnection: @MainActor () -> Void
    private let onSaveAIConfig: @MainActor (String, String, String) -> Void
    private let onSaveAIProactiveConfig: @MainActor (Bool, Int) -> Void
    private let onSaveAIChatOptions: @MainActor (Double, Double, Int) -> Void
    private let onSaveNotificationConfig: @MainActor (String, Bool, Int, String) -> Void
    private let onUpdatePet: @MainActor (UUID, String, String, Double, String, String, String, String) -> Void
    private let onUpdatePetSound: @MainActor (UUID, Bool?, Float?) -> Void
    private let onUpdatePetLanguage: @MainActor (UUID, [String: [String]]?) -> String?
    private let onRemovePet: @MainActor (UUID) -> Void
    private let onAddPet: @MainActor () -> Void
    private let canAddMorePets: Bool
    private let onSetDesktopAwarenessEnabled: @MainActor (Bool) -> Void
    private let onSaveDesktopAwarenessRules: @MainActor ([AppBehaviorRule]) -> String?
    private let onSetSoundEnabled: @MainActor (Bool) -> Void
    private let onSetSoundVolume: @MainActor (Float) -> Void
    private let currentWeatherSummary: String?
    private let onSetWeatherAwarenessEnabled: @MainActor (Bool) -> Void
    private let onCreatePlugin: @MainActor (String, String, String) async -> String?
    private let onDeletePlugin: @MainActor (String) async -> String?
    private let onRevealPluginInFinder: @MainActor (String) -> Void
    private let onReloadPlugins: @MainActor () async -> String?
    private let onResetLanguage: (@MainActor (UUID) -> Void)?
    private let onResetAttributes: (@MainActor (UUID) -> Void)?
    private let onResetAll: (@MainActor (UUID) -> Void)?

    public init(
        pluginSettingsViewModel: PluginSettingsViewModel = PluginSettingsViewModel(loadPlugins: { [] }, setEnabled: { _, _ in }),
        petProfiles: [PetProfileItem] = [],
        loadPetProfiles: @escaping @MainActor () -> [PetProfileItem] = { [] },
        spritePackItems: [SpritePackDisplayItem] = [],
        selectedSpritePackID: String = "default",
        onSelectSpritePack: @escaping @MainActor (String) -> Void = { _ in },
        onImportPack: @escaping @MainActor () async -> String? = { nil },
        onExportPack: @escaping @MainActor (String) async -> String? = { _ in nil },
        onDeletePack: @escaping @MainActor (String) async -> String? = { _ in nil },
        onRevealInFinder: @escaping @MainActor (String) -> Void = { _ in },
        onCreateTemplate: @escaping @MainActor () async -> String? = { nil },
        ollamaEndpoint: String = "http://localhost:11434",
        ollamaModel: String = "llama3.2",
        aiSystemPrompt: String = "",
        aiProactiveEnabled: Bool = true,
        aiProactiveInterval: Int = 45,
        aiTemperature: Double = 0.7,
        aiTopP: Double = 0.9,
        aiNumCtx: Int = 4096,
        githubToken: String = "",
        webhookEnabled: Bool = false,
        webhookPort: Int = 19280,
        webhookSecret: String = "",
        aiStatus: AIEngineStatus = .notConfigured,
        onTestConnection: @escaping @MainActor () -> Void = {},
        onSaveAIConfig: @escaping @MainActor (String, String, String) -> Void = { _, _, _ in },
        onSaveAIProactiveConfig: @escaping @MainActor (Bool, Int) -> Void = { _, _ in },
        onSaveAIChatOptions: @escaping @MainActor (Double, Double, Int) -> Void = { _, _, _ in },
        onSaveNotificationConfig: @escaping @MainActor (String, Bool, Int, String) -> Void = { _, _, _, _ in },
        onUpdatePet: @escaping @MainActor (UUID, String, String, Double, String, String, String, String) -> Void = { _, _, _, _, _, _, _, _ in },
        onUpdatePetSound: @escaping @MainActor (UUID, Bool?, Float?) -> Void = { _, _, _ in },
        onUpdatePetLanguage: @escaping @MainActor (UUID, [String: [String]]?) -> String? = { _, _ in nil },
        onRemovePet: @escaping @MainActor (UUID) -> Void = { _ in },
        onAddPet: @escaping @MainActor () -> Void = {},
        canAddMorePets: Bool = true,
        desktopAwarenessEnabled: Bool = true,
        desktopAwarenessRules: [AppBehaviorRule] = [],
        onSetDesktopAwarenessEnabled: @escaping @MainActor (Bool) -> Void = { _ in },
        onSaveDesktopAwarenessRules: @escaping @MainActor ([AppBehaviorRule]) -> String? = { _ in nil },
        soundEnabled: Bool = false,
        soundVolume: Double = 0.5,
        onSetSoundEnabled: @escaping @MainActor (Bool) -> Void = { _ in },
        onSetSoundVolume: @escaping @MainActor (Float) -> Void = { _ in },
        weatherAwarenessEnabled: Bool = true,
        currentWeatherSummary: String? = nil,
        onSetWeatherAwarenessEnabled: @escaping @MainActor (Bool) -> Void = { _ in },
        weatherLatitude: Double? = nil,
        weatherLongitude: Double? = nil,
        onSaveWeatherLocation: @escaping @MainActor (Double?, Double?) -> Void = { _, _ in },
        weatherRefreshMinutes: Int = 120,
        onSetWeatherRefreshInterval: @escaping @MainActor (Double) -> Void = { _ in },
        onCreatePlugin: @escaping @MainActor (String, String, String) async -> String? = { _, _, _ in nil },
        onDeletePlugin: @escaping @MainActor (String) async -> String? = { _ in nil },
        onRevealPluginInFinder: @escaping @MainActor (String) -> Void = { _ in },
        onReloadPlugins: @escaping @MainActor () async -> String? = { nil },
        onResetLanguage: (@MainActor (UUID) -> Void)? = nil,
        onResetAttributes: (@MainActor (UUID) -> Void)? = nil,
        onResetAll: (@MainActor (UUID) -> Void)? = nil
    ) {
        _capabilityItems = State(initialValue: Self.defaultCapabilityItems)
        _pluginSettingsViewModel = State(initialValue: pluginSettingsViewModel)
        _petProfiles = State(initialValue: petProfiles)
        _ollamaEndpoint = State(initialValue: ollamaEndpoint)
        _ollamaModel = State(initialValue: ollamaModel)
        _aiSystemPrompt = State(initialValue: aiSystemPrompt)
        _aiProactiveEnabled = State(initialValue: aiProactiveEnabled)
        _aiProactiveInterval = State(initialValue: aiProactiveInterval)
        _aiTemperature = State(initialValue: aiTemperature)
        _aiTopP = State(initialValue: aiTopP)
        _aiNumCtx = State(initialValue: aiNumCtx)
        _githubToken = State(initialValue: githubToken)
        _webhookEnabled = State(initialValue: webhookEnabled)
        _webhookPort = State(initialValue: webhookPort)
        _webhookSecret = State(initialValue: webhookSecret)
        _errorMessage = State(initialValue: nil)
        _showError = State(initialValue: false)
        let editableRules = desktopAwarenessRules.map(EditableDesktopAwarenessRule.init(rule:))
        _desktopAwarenessEnabled = State(initialValue: desktopAwarenessEnabled)
        _desktopAwarenessRules = State(initialValue: editableRules)
        _expandedDesktopRuleIDs = State(initialValue: [])
        _desktopAwarenessStatusMessage = State(initialValue: nil)
        _soundEnabled = State(initialValue: soundEnabled)
        _soundVolume = State(initialValue: soundVolume)
        _weatherAwarenessEnabled = State(initialValue: weatherAwarenessEnabled)
        _weatherLatitude = State(initialValue: weatherLatitude.map { String($0) } ?? "")
        _weatherLongitude = State(initialValue: weatherLongitude.map { String($0) } ?? "")
        _editingPluginID = State(initialValue: nil)
        self.onSaveWeatherLocation = onSaveWeatherLocation
        _weatherRefreshMinutes = State(initialValue: weatherRefreshMinutes)
        self.onSetWeatherRefreshInterval = onSetWeatherRefreshInterval
        self.spritePackItems = spritePackItems
        self.onSelectSpritePack = onSelectSpritePack
        self.onImportPack = onImportPack
        self.onExportPack = onExportPack
        self.onDeletePack = onDeletePack
        self.onRevealInFinder = onRevealInFinder
        self.onCreateTemplate = onCreateTemplate
        self.loadPetProfiles = loadPetProfiles
        self.aiStatus = aiStatus
        self.onTestConnection = onTestConnection
        self.onSaveAIConfig = onSaveAIConfig
        self.onSaveAIProactiveConfig = onSaveAIProactiveConfig
        self.onSaveAIChatOptions = onSaveAIChatOptions
        self.onSaveNotificationConfig = onSaveNotificationConfig
        self.onUpdatePet = onUpdatePet
        self.onUpdatePetSound = onUpdatePetSound
        self.onUpdatePetLanguage = onUpdatePetLanguage
        self.onRemovePet = onRemovePet
        self.onAddPet = onAddPet
        self.canAddMorePets = canAddMorePets
        self.onSetDesktopAwarenessEnabled = onSetDesktopAwarenessEnabled
        self.onSaveDesktopAwarenessRules = onSaveDesktopAwarenessRules
        self.onSetSoundEnabled = onSetSoundEnabled
        self.onSetSoundVolume = onSetSoundVolume
        self.currentWeatherSummary = currentWeatherSummary
        self.onSetWeatherAwarenessEnabled = onSetWeatherAwarenessEnabled
        self.onCreatePlugin = onCreatePlugin
        self.onDeletePlugin = onDeletePlugin
        self.onRevealPluginInFinder = onRevealPluginInFinder
        self.onReloadPlugins = onReloadPlugins
        self.onResetLanguage = onResetLanguage
        self.onResetAttributes = onResetAttributes
        self.onResetAll = onResetAll
    }

    public var body: some View {
        List {
            // ─── 宠物核心 ───
            PetManagementSection(
                petProfiles: $petProfiles,
                spritePackItems: spritePackItems,
                soundEnabled: soundEnabled,
                soundVolume: soundVolume,
                canAddMorePets: canAddMorePets,
                loadPetProfiles: loadPetProfiles,
                onUpdatePet: onUpdatePet,
                onUpdatePetSound: onUpdatePetSound,
                onUpdatePetLanguage: onUpdatePetLanguage,
                onRemovePet: onRemovePet,
                onAddPet: onAddPet,
                onResetLanguage: onResetLanguage,
                onResetAttributes: onResetAttributes,
                onResetAll: onResetAll,
                onError: { message in
                    errorMessage = message
                    showError = true
                }
            )

            SpritePackSection(
                spritePackItems: spritePackItems,
                onImportPack: onImportPack,
                onExportPack: onExportPack,
                onDeletePack: onDeletePack,
                onRevealInFinder: onRevealInFinder,
                onCreateTemplate: onCreateTemplate,
                onError: { message in
                    errorMessage = message
                    showError = true
                }
            )

            // ─── 环境感知 ───
            DesktopAwarenessSection(
                desktopAwarenessEnabled: $desktopAwarenessEnabled,
                desktopAwarenessRules: $desktopAwarenessRules,
                expandedDesktopRuleIDs: $expandedDesktopRuleIDs,
                desktopAwarenessStatusMessage: $desktopAwarenessStatusMessage,
                availableAnimations: Self.availableDesktopAnimations,
                onSetDesktopAwarenessEnabled: onSetDesktopAwarenessEnabled,
                onSaveDesktopAwarenessRules: onSaveDesktopAwarenessRules
            )

            WeatherSection(
                weatherAwarenessEnabled: $weatherAwarenessEnabled,
                weatherLatitude: $weatherLatitude,
                weatherLongitude: $weatherLongitude,
                weatherRefreshMinutes: $weatherRefreshMinutes,
                currentWeatherSummary: currentWeatherSummary,
                onSetWeatherAwarenessEnabled: onSetWeatherAwarenessEnabled,
                onSaveWeatherLocation: onSaveWeatherLocation,
                onSetWeatherRefreshInterval: onSetWeatherRefreshInterval
            )

            SoundSection(
                soundEnabled: $soundEnabled,
                soundVolume: $soundVolume,
                onSetSoundEnabled: onSetSoundEnabled,
                onSetSoundVolume: onSetSoundVolume
            )

            // ─── AI & 通信 ───
            AISection(
                ollamaEndpoint: $ollamaEndpoint,
                ollamaModel: $ollamaModel,
                aiSystemPrompt: $aiSystemPrompt,
                aiProactiveEnabled: $aiProactiveEnabled,
                aiProactiveInterval: $aiProactiveInterval,
                aiTemperature: $aiTemperature,
                aiTopP: $aiTopP,
                aiNumCtx: $aiNumCtx,
                aiStatus: aiStatus,
                onTestConnection: onTestConnection,
                onSaveAIConfig: onSaveAIConfig,
                onSaveAIProactiveConfig: onSaveAIProactiveConfig,
                onSaveAIChatOptions: onSaveAIChatOptions
            )

            NotificationSection(
                githubToken: $githubToken,
                webhookEnabled: $webhookEnabled,
                webhookPort: $webhookPort,
                webhookSecret: $webhookSecret,
                onSaveNotificationConfig: onSaveNotificationConfig
            )

            // ─── 扩展 ───
            PluginManagementSection(
                editingPluginID: $editingPluginID,
                pluginSettingsViewModel: $pluginSettingsViewModel,
                onCreatePlugin: onCreatePlugin,
                onDeletePlugin: onDeletePlugin,
                onRevealPluginInFinder: onRevealPluginInFinder,
                onReloadPlugins: onReloadPlugins,
                onError: { message in
                    errorMessage = message
                    showError = true
                }
            )

            CapabilitiesSection(capabilityItems: $capabilityItems)
        }
        .listStyle(.inset)
        .navigationTitle(L10n.settingsTitle)
        .frame(minWidth: 420, minHeight: 360)
        .alert(L10n.settingsSpritePacksImportError, isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
        .task {
            await pluginSettingsViewModel.refresh()
        }
    }

    private static let defaultCapabilityItems: [CapabilityItem] = [
        CapabilityItem(
            id: "screen-awareness",
            name: L10n.capabilityScreenAwarenessName,
            description: L10n.capabilityScreenAwarenessDescription,
            status: .needsPermission,
            isEnabled: false
        ),
        CapabilityItem(
            id: "calendar-access",
            name: L10n.capabilityCalendarAccessName,
            description: L10n.capabilityCalendarAccessDescription,
            status: .inactive,
            isEnabled: false
        ),
        CapabilityItem(
            id: "focus-monitoring",
            name: L10n.capabilityFocusMonitoringName,
            description: L10n.capabilityFocusMonitoringDescription,
            status: .active,
            isEnabled: true
        )
    ]

    private static let availableDesktopAnimations = AnimationState.allCases
        .filter { $0 != .drag }
        .map(\.rawValue)
}
