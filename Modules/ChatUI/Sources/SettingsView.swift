import EventBus
import Foundation
import AIEngine
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

private enum PluginTemplateOption: String, CaseIterable, Identifiable {
    case blank
    case fileWatch
    case appSwitch
    case timer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blank:
            return "空白"
        case .fileWatch:
            return "文件监控"
        case .appSwitch:
            return "应用切换"
        case .timer:
            return "定时触发"
        }
    }
}

@MainActor
public struct SettingsView: View {
    @State private var capabilityItems: [CapabilityItem]
    @State private var pluginSettingsViewModel: PluginSettingsViewModel
    @State private var petProfiles: [PetProfileItem]
    @State private var editingPetID: UUID?
    @State private var editName: String = ""
    @State private var editSpritePack: String = "default"
    @State private var editSize: Double = 96
    @State private var editGender: String = "neutral"
    @State private var editAge: String = ""
    @State private var editPersonality: String = ""
    @State private var editHobbies: String = ""
    @State private var editUsesCustomSound: Bool = false
    @State private var editSoundEnabled: Bool = false
    @State private var editSoundVolume: Double = 0.5
    @State private var editBasicExpanded: Bool = true
    @State private var editLanguageExpanded: Bool = false
    @State private var editSoundExpanded: Bool = false
    @State private var editResetExpanded: Bool = false
    @State private var showRemoveConfirm = false
    @State private var pendingRemoveID: UUID?
    @State private var showResetLanguageConfirm = false
    @State private var showResetAttributesConfirm = false
    @State private var showResetAllConfirm = false
    @State private var pendingResetPetID: UUID?
    @State private var selectedSpritePackID: String
    @State private var ollamaEndpoint: String
    @State private var aiBackend: AIEngine.AIBackend
    @State private var ollamaModel: String
    @State private var aiSystemPrompt: String
    @State private var liveAIStatus: AIEngineStatus
    @State private var githubToken: String
    @State private var webhookEnabled: Bool
    @State private var webhookPort: Int
    @State private var webhookSecret: String
    @State private var errorMessage: String?
    @State private var showError: Bool
    @State private var showDeleteConfirm: Bool
    @State private var pendingDeleteID: String?
    @State private var desktopAwarenessEnabled: Bool
    @State private var desktopAwarenessRules: [EditableDesktopAwarenessRule]
    @State private var expandedDesktopRuleIDs: Set<UUID>
    @State private var desktopAwarenessStatusMessage: String?
    @State private var soundEnabled: Bool
    @State private var soundVolume: Double
    @State private var weatherAwarenessEnabled: Bool
    @State private var weatherLatitude: String
    @State private var weatherLongitude: String
    @State private var weatherRefreshMinutes: Int
    @State private var showPluginCreator = false
    @State private var newPluginName = ""
    @State private var newPluginDescription = ""
    @State private var selectedPluginTemplate = PluginTemplateOption.blank
    @State private var editingPluginID: String?
    @State private var showPluginDeleteConfirm = false
    @State private var pendingPluginDeleteID: String?
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
    private let aiStatusProvider: @MainActor () -> AIEngineStatus
    private let onTestConnection: @MainActor () -> Void
    private let onSaveAIConfig: @MainActor (String, String, String, AIEngine.AIBackend) -> Void
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
        aiBackend: AIEngine.AIBackend = .ollama,
        ollamaModel: String = "llama3.2",
        aiSystemPrompt: String = "",
        githubToken: String = "",
        webhookEnabled: Bool = false,
        webhookPort: Int = 19280,
        webhookSecret: String = "",
        aiStatus: AIEngineStatus = .notConfigured,
        aiStatusProvider: @escaping @MainActor () -> AIEngineStatus = { .notConfigured },
        onTestConnection: @escaping @MainActor () -> Void = {},
        onSaveAIConfig: @escaping @MainActor (String, String, String, AIEngine.AIBackend) -> Void = { _, _, _, _ in },
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
        _selectedSpritePackID = State(initialValue: selectedSpritePackID)
        _ollamaEndpoint = State(initialValue: ollamaEndpoint)
        _aiBackend = State(initialValue: aiBackend)
        _ollamaModel = State(initialValue: ollamaModel)
        _aiSystemPrompt = State(initialValue: aiSystemPrompt)
        _liveAIStatus = State(initialValue: aiStatus)
        _githubToken = State(initialValue: githubToken)
        _webhookEnabled = State(initialValue: webhookEnabled)
        _webhookPort = State(initialValue: webhookPort)
        _webhookSecret = State(initialValue: webhookSecret)
        _errorMessage = State(initialValue: nil)
        _showError = State(initialValue: false)
        _showDeleteConfirm = State(initialValue: false)
        _pendingDeleteID = State(initialValue: nil)
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
        _showPluginDeleteConfirm = State(initialValue: false)
        _pendingPluginDeleteID = State(initialValue: nil)
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
        self.aiStatusProvider = aiStatusProvider
        self.onTestConnection = onTestConnection
        self.onSaveAIConfig = onSaveAIConfig
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
            Section(L10n.settingsPetManagement) {
                ForEach(petProfiles) { pet in
                    if editingPetID == pet.id {
                        VStack(alignment: .leading, spacing: 12) {
                            // ── 基础属性（始终展示） ──
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(L10n.settingsPetManagementName)
                                        .frame(width: 50, alignment: .leading)
                                    TextField("", text: $editName)
                                        .textFieldStyle(.roundedBorder)
                                }

                                HStack {
                                    Text(L10n.settingsPetManagementAppearance)
                                        .frame(width: 50, alignment: .leading)
                                    Picker("", selection: $editSpritePack) {
                                        ForEach(spritePackItems) { item in
                                            Text(item.name).tag(item.id)
                                        }
                                    }
                                    .labelsHidden()
                                }

                                HStack {
                                    Text(L10n.settingsPetManagementSize)
                                        .frame(width: 50, alignment: .leading)
                                    Slider(value: $editSize, in: 48...128, step: 8)
                                    Text("\(Int(editSize))pt")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 40)
                                }

                                HStack {
                                    Text(L10n.settingsPetManagementGender)
                                        .frame(width: 50, alignment: .leading)
                                    Picker("", selection: $editGender) {
                                        Text(L10n.settingsPetManagementGenderNeutral).tag("neutral")
                                        Text(L10n.settingsPetManagementGenderMale).tag("male")
                                        Text(L10n.settingsPetManagementGenderFemale).tag("female")
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.segmented)
                                }

                                HStack {
                                    Text(L10n.settingsPetManagementAge)
                                        .frame(width: 50, alignment: .leading)
                                    TextField(L10n.settingsPetManagementAgePlaceholder, text: $editAge)
                                        .textFieldStyle(.roundedBorder)
                                }

                                HStack {
                                    Text(L10n.settingsPetManagementPersonality)
                                        .frame(width: 50, alignment: .leading)
                                    TextField(L10n.settingsPetManagementPersonalityPlaceholder, text: $editPersonality)
                                        .textFieldStyle(.roundedBorder)
                                }

                                HStack {
                                    Text(L10n.settingsPetManagementHobbies)
                                        .frame(width: 50, alignment: .leading)
                                    TextField(L10n.settingsPetManagementHobbiesPlaceholder, text: $editHobbies)
                                        .textFieldStyle(.roundedBorder)
                                }
                            }

                            Divider()

                            // ── 气泡文字（可折叠） ──
                            collapsibleSection("气泡文字", icon: "text.bubble", isExpanded: $editLanguageExpanded) {
                                if let packDirectory = spritePackDirectory(for: editSpritePack) {
                                    LanguagePackEditor(
                                        directory: packDirectory,
                                        pet: editingPetLanguageTarget(for: pet),
                                        onSave: onUpdatePetLanguage
                                    ) { message in
                                        errorMessage = message
                                        showError = true
                                    }
                                } else {
                                    Text("当前外观缺少可用的语言模板。")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            // ── 音效设置（可折叠，即时保存） ──
                            collapsibleSection("音效设置", icon: "speaker.wave.2", isExpanded: $editSoundExpanded) {
                                Toggle("独立设置（不跟随全局）", isOn: $editUsesCustomSound)
                                    .onChange(of: editUsesCustomSound) { _, newValue in
                                        onUpdatePetSound(
                                            pet.id,
                                            newValue ? editSoundEnabled : nil,
                                            newValue ? Float(editSoundVolume) : nil
                                        )
                                    }

                                if editUsesCustomSound {
                                    Toggle("启用音效", isOn: $editSoundEnabled)
                                        .onChange(of: editSoundEnabled) { _, _ in
                                            onUpdatePetSound(pet.id, editSoundEnabled, Float(editSoundVolume))
                                        }

                                    HStack {
                                        Text("音量")
                                            .frame(width: 50, alignment: .leading)
                                        Slider(value: $editSoundVolume, in: 0...1)
                                            .disabled(!editSoundEnabled)
                                            .onChange(of: editSoundVolume) { _, _ in
                                                onUpdatePetSound(pet.id, editSoundEnabled, Float(editSoundVolume))
                                            }
                                        Text("\(Int(editSoundVolume * 100))%")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 42)
                                    }
                                    .opacity(editSoundEnabled ? 1 : 0.6)
                                } else {
                                    Text("跟随全局：\(soundEnabled ? "已启用" : "已关闭")，音量 \(Int(soundVolume * 100))%")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Divider()

                            // ── 操作按钮 ──
                            HStack(spacing: 12) {
                                Button("还原语言") {
                                    pendingResetPetID = pet.id
                                    showResetLanguageConfirm = true
                                }
                                .buttonStyle(.borderless)
                                .disabled(pet.customLanguage == nil)

                                Button("还原属性") {
                                    pendingResetPetID = pet.id
                                    showResetAttributesConfirm = true
                                }
                                .buttonStyle(.borderless)

                                Button("全部还原") {
                                    pendingResetPetID = pet.id
                                    showResetAllConfirm = true
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.red)

                                Spacer()

                                Button(L10n.settingsPetManagementCancel) {
                                    editingPetID = nil
                                }
                                .buttonStyle(.borderless)
                                Button {
                                    let normalizedName = normalizedPetName(editName, fallback: pet.name)
                                    onUpdatePet(
                                        pet.id,
                                        normalizedName,
                                        editSpritePack,
                                        editSize,
                                        editGender,
                                        editAge,
                                        editPersonality,
                                        editHobbies
                                    )
                                    refreshPetProfiles()
                                    editingPetID = nil
                                } label: {
                                    Text(L10n.settingsPetManagementSave)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 4)
                                        .background(Color.accentColor)
                                        .foregroundStyle(.white)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .padding(.vertical, 4)
                    } else {
                        Button {
                            startEditing(pet)
                        } label: {
                            HStack(spacing: 12) {
                                SpritePackPreviewView(
                                    packDirectory: spritePackItems.first(where: { $0.id == pet.spritePack })?.directory,
                                    previewSize: 40
                                )
                                .frame(width: 40, height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 6))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pet.name)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text("\(spritePackName(for: pet.spritePack)) · \(Int(pet.size))pt")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if petProfiles.count > 1 {
                                    Button(role: .destructive) {
                                        pendingRemoveID = pet.id
                                        showRemoveConfirm = true
                                    } label: {
                                        Image(systemName: "trash")
                                            .foregroundStyle(.red)
                                    }
                                    .buttonStyle(.borderless)
                                }

                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 4)
                    }
                }

                if canAddMorePets {
                    Button(L10n.settingsPetManagementAdd) {
                        onAddPet()
                        petProfiles = loadPetProfiles()
                    }
                } else {
                    Text(L10n.settingsPetManagementMaxReached)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .alert(L10n.settingsPetManagementDeleteConfirm, isPresented: $showRemoveConfirm) {
                Button(L10n.settingsPetManagementDelete, role: .destructive) {
                    let idToRemove = pendingRemoveID
                    pendingRemoveID = nil
                    if let id = idToRemove {
                        onRemovePet(id)
                        if editingPetID == id {
                            editingPetID = nil
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            petProfiles = loadPetProfiles()
                        }
                    }
                }
                Button(L10n.settingsPetManagementCancel, role: .cancel) {
                    pendingRemoveID = nil
                }
            }
            .alert("确定还原语言设置？", isPresented: $showResetLanguageConfirm) {
                Button("还原", role: .destructive) {
                    if let id = pendingResetPetID {
                        onResetLanguage?(id)
                        refreshPetProfiles(reloadEditingPetID: id)
                    }
                    pendingResetPetID = nil
                }
                Button("取消", role: .cancel) {
                    pendingResetPetID = nil
                }
            }
            .alert("确定还原所有属性到默认？", isPresented: $showResetAttributesConfirm) {
                Button("还原", role: .destructive) {
                    if let id = pendingResetPetID {
                        onResetAttributes?(id)
                        refreshPetProfiles(reloadEditingPetID: id)
                    }
                    pendingResetPetID = nil
                }
                Button("取消", role: .cancel) {
                    pendingResetPetID = nil
                }
            }
            .alert("确定还原所有设置到默认？这将清除语言、音效、属性的所有自定义。", isPresented: $showResetAllConfirm) {
                Button("全部还原", role: .destructive) {
                    if let id = pendingResetPetID {
                        onResetAll?(id)
                        refreshPetProfiles(reloadEditingPetID: id)
                    }
                    pendingResetPetID = nil
                }
                Button("取消", role: .cancel) {
                    pendingResetPetID = nil
                }
            }

            Section(L10n.settingsSpritePacks) {
                if spritePackItems.isEmpty {
                    Text(L10n.settingsNoSpritePacks)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    ForEach(spritePackItems) { item in
                        spritePackRow(for: item)
                    }
                }

                HStack(spacing: 12) {
                    Button(L10n.settingsSpritePacksImport) {
                        Task {
                            if let error = await onImportPack() {
                                errorMessage = error
                                showError = true
                            }
                        }
                    }

                    Button(L10n.settingsSpritePacksCreateTemplate) {
                        Task {
                            if let error = await onCreateTemplate() {
                                errorMessage = error
                                showError = true
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }

            // ─── 环境感知 ───
            Section("桌面感知") {
                Toggle("启用桌面感知", isOn: $desktopAwarenessEnabled)
                    .onChange(of: desktopAwarenessEnabled) { _, newValue in
                        onSetDesktopAwarenessEnabled(newValue)
                    }

                Text("为不同应用类别配置动画、气泡文案和匹配的 Bundle ID。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if desktopAwarenessRules.isEmpty {
                    Text("暂无规则")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(Array(desktopAwarenessRules.indices), id: \.self) { index in
                        let ruleID = desktopAwarenessRules[index].id
                        DesktopAwarenessRuleEditor(
                            rule: $desktopAwarenessRules[index],
                            isExpanded: Binding(
                                get: { expandedDesktopRuleIDs.contains(ruleID) },
                                set: { isExpanded in
                                    if isExpanded {
                                        expandedDesktopRuleIDs.insert(ruleID)
                                    } else {
                                        expandedDesktopRuleIDs.remove(ruleID)
                                    }
                                }
                            ),
                            availableAnimations: Self.availableDesktopAnimations,
                            onDelete: {
                                removeDesktopAwarenessRule(id: ruleID)
                            }
                        )
                    }
                }

                HStack {
                    Button {
                        addDesktopAwarenessRule()
                    } label: {
                        Label("添加规则", systemImage: "plus")
                    }

                    Spacer()

                    if let desktopAwarenessStatusMessage {
                        Text(desktopAwarenessStatusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button("保存") {
                        saveDesktopAwarenessRules()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.top, 4)
            }

            Section("天气感知") {
                Toggle("启用天气感知", isOn: $weatherAwarenessEnabled)
                    .onChange(of: weatherAwarenessEnabled) { _, newValue in
                        onSetWeatherAwarenessEnabled(newValue)
                    }

                Text("根据当前天气和时段调整宠物心情与待机动作。天气变化时显示气泡。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let currentWeatherSummary, !currentWeatherSummary.isEmpty {
                    HStack {
                        Text("当前天气：")
                            .font(.subheadline)
                        Text(currentWeatherSummary)
                            .font(.subheadline.weight(.medium))
                    }
                } else {
                    Text(weatherAwarenessEnabled ? "正在等待天气数据…" : "天气感知已关闭")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if weatherAwarenessEnabled {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("位置坐标（留空则自动通过 IP 定位）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Text("纬度")
                                .font(.caption)
                                .frame(width: 30)
                            TextField("如 39.9", text: $weatherLatitude)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                            Text("经度")
                                .font(.caption)
                                .frame(width: 30)
                            TextField("如 116.4", text: $weatherLongitude)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                            Button("保存") {
                                let lat = Double(weatherLatitude)
                                let lon = Double(weatherLongitude)
                                onSaveWeatherLocation(lat, lon)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }

                    HStack {
                        Text("刷新间隔")
                            .font(.caption)
                        Picker("", selection: $weatherRefreshMinutes) {
                            Text("30 分钟").tag(30)
                            Text("1 小时").tag(60)
                            Text("2 小时").tag(120)
                            Text("4 小时").tag(240)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 300)
                        .onChange(of: weatherRefreshMinutes) { _, newValue in
                            onSaveWeatherLocation(Double(weatherLatitude), Double(weatherLongitude))
                            onSetWeatherRefreshInterval(Double(newValue) * 60)
                        }
                    }
                }
            }

            Section("音效") {
                Toggle("启用音效", isOn: $soundEnabled)
                    .onChange(of: soundEnabled) { _, newValue in
                        onSetSoundEnabled(newValue)
                    }

                Text("每只宠物可在「宠物管理」中单独设置音效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if soundEnabled {
                    HStack {
                        Text("音量")
                        Slider(value: $soundVolume, in: 0...1)
                            .onChange(of: soundVolume) { _, newValue in
                                onSetSoundVolume(Float(newValue))
                            }
                    }
                }
            }

            // ─── AI & 通信 ───
            Section(L10n.settingsAI) {
                HStack(alignment: .center, spacing: 12) {
                    Circle()
                        .fill(statusColor(for: liveAIStatus))
                        .frame(width: 10, height: 10)

                    Text(aiStatusText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 2)

                Picker(L10n.settingsAIBackend, selection: $aiBackend) {
                    ForEach(AIEngine.AIBackend.allCases, id: \.self) { backend in
                        Text(aiBackendTitle(backend)).tag(backend)
                    }
                }
                .onChange(of: aiBackend) { oldValue, newValue in
                    let trimmedModel = ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmedModel.isEmpty || trimmedModel == oldValue.defaultModel {
                        ollamaModel = newValue.defaultModel
                    }
                    onSaveAIConfig(ollamaEndpoint, ollamaModel, aiSystemPrompt, newValue)
                }

                TextField(L10n.settingsAIEndpoint, text: $ollamaEndpoint)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: ollamaEndpoint) { _, newValue in
                        onSaveAIConfig(newValue, ollamaModel, aiSystemPrompt, aiBackend)
                    }

                TextField(L10n.settingsAIModel, text: $ollamaModel)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: ollamaModel) { _, newValue in
                        onSaveAIConfig(ollamaEndpoint, newValue, aiSystemPrompt, aiBackend)
                    }

                Text(L10n.settingsAISystemPrompt)
                    .font(.headline)

                ZStack(alignment: .topLeading) {
                    if aiSystemPrompt.isEmpty {
                        Text(L10n.settingsAISystemPromptPlaceholder)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                            .padding(.leading, 6)
                            .padding(.trailing, 6)
                    }

                    TextEditor(text: $aiSystemPrompt)
                        .font(.body)
                        .frame(minHeight: 96)
                        .onChange(of: aiSystemPrompt) { _, newValue in
                            onSaveAIConfig(ollamaEndpoint, ollamaModel, newValue, aiBackend)
                        }
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.35))
                        )
                }

                Button(L10n.settingsAITestConnection) {
                    liveAIStatus = .connecting
                    onTestConnection()

                    Task { @MainActor in
                        for _ in 0..<60 {
                            try? await Task.sleep(for: .seconds(1))
                            let status = aiStatusProvider()
                            liveAIStatus = status
                            if case .connecting = status {
                                continue
                            }
                            break
                        }
                    }
                }
            }

            Section(L10n.settingsNotifications) {
                Text(L10n.settingsNotificationsGithub)
                    .font(.headline)

                Text(L10n.settingsNotificationsGithubToken)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                SecureField(L10n.settingsNotificationsGithubTokenPlaceholder, text: $githubToken)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: githubToken) { _, newValue in
                        onSaveNotificationConfig(newValue, webhookEnabled, webhookPort, webhookSecret)
                    }

                Text(L10n.settingsNotificationsWebhook)
                    .font(.headline)

                Toggle(L10n.settingsNotificationsWebhookEnabled, isOn: $webhookEnabled)
                    .onChange(of: webhookEnabled) { _, newValue in
                        onSaveNotificationConfig(githubToken, newValue, webhookPort, webhookSecret)
                    }

                if webhookEnabled {
                    HStack {
                        Text(L10n.settingsNotificationsWebhookPort)

                        TextField("19280", value: $webhookPort, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .onChange(of: webhookPort) { _, newValue in
                                onSaveNotificationConfig(githubToken, webhookEnabled, newValue, webhookSecret)
                            }
                    }

                    SecureField("Webhook Secret (可选)", text: $webhookSecret)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: webhookSecret) { _, newValue in
                            onSaveNotificationConfig(githubToken, webhookEnabled, webhookPort, newValue)
                        }

                    Text(String(format: L10n.settingsNotificationsWebhookHint, webhookPort))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // ─── 扩展 ───
            Section(L10n.settingsPlugins) {
                HStack {
                    Text("创建自己的 JSON 插件模板")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("创建插件") {
                        if newPluginName.isEmpty {
                            newPluginName = "My Plugin"
                        }
                        showPluginCreator = true
                    }
                }
                .padding(.vertical, 4)

                if pluginSettingsViewModel.plugins.isEmpty {
                    Text(L10n.settingsNoPlugins)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    ForEach(pluginSettingsViewModel.plugins) { plugin in
                        let isEditingPlugin = editingPluginID == plugin.id

                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top, spacing: 14) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 8) {
                                        Text(plugin.name)
                                            .font(.headline)

                                        Text(plugin.version)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)

                                        if plugin.isBuiltIn {
                                            Text("内建")
                                                .font(.caption2)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.secondary.opacity(0.2))
                                                .clipShape(Capsule())
                                        }
                                    }

                                    Text(plugin.description)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer(minLength: 12)

                                Toggle(
                                    "",
                                    isOn: Binding(
                                        get: { plugin.isEnabled },
                                        set: { pluginSettingsViewModel.togglePlugin(plugin.id, enabled: $0) }
                                    )
                                )
                                .labelsHidden()
                            }
                            .contextMenu {
                                Button("在 Finder 中显示") {
                                    onRevealPluginInFinder(plugin.id)
                                }

                                if plugin.isDeclarative, plugin.directory != nil {
                                    Button(isEditingPlugin ? "收起触发规则" : "编辑触发规则") {
                                        togglePluginEditor(for: plugin.id)
                                    }
                                }

                                if !plugin.isBuiltIn {
                                    Divider()

                                    Button("卸载插件", role: .destructive) {
                                        pendingPluginDeleteID = plugin.id
                                        showPluginDeleteConfirm = true
                                    }
                                }
                            }

                            if isEditingPlugin, let directory = plugin.directory {
                                PluginTriggerEditor(
                                    directory: directory,
                                    onReloadPlugins: onReloadPlugins
                                ) { message in
                                    errorMessage = message
                                    showError = true
                                } onSaved: {
                                    Task {
                                        await pluginSettingsViewModel.refresh()
                                    }
                                }
                                .padding(.leading, 12)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }

            Section(L10n.settingsCapabilities) {
                ForEach($capabilityItems) { $item in
                    HStack(alignment: .center, spacing: 14) {
                        Circle()
                            .fill(statusColor(for: item.status))
                            .frame(width: 10, height: 10)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name)
                                .font(.headline)

                            Text(item.description)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Toggle("", isOn: $item.isEnabled)
                            .labelsHidden()
                            .onChange(of: item.isEnabled) { _, newValue in
                                item.status = newValue ? .active : .inactive
                            }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .listStyle(.inset)
        .navigationTitle(L10n.settingsTitle)
        .frame(minWidth: 420, minHeight: 360)
        .alert(L10n.settingsSpritePacksImportError, isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert(L10n.settingsSpritePacksDeleteConfirm, isPresented: $showDeleteConfirm) {
            Button(L10n.settingsSpritePacksDelete, role: .destructive) {
                guard let id = pendingDeleteID else {
                    return
                }

                Task {
                    if let error = await onDeletePack(id) {
                        errorMessage = error
                        showError = true
                    }
                    pendingDeleteID = nil
                }
            }

            Button("Cancel", role: .cancel) {
                pendingDeleteID = nil
            }
        }
        .alert("确认卸载插件？", isPresented: $showPluginDeleteConfirm) {
            Button("卸载插件", role: .destructive) {
                guard let id = pendingPluginDeleteID else {
                    return
                }

                Task {
                    if let error = await onDeletePlugin(id) {
                        errorMessage = error
                        showError = true
                    } else {
                        if editingPluginID == id {
                            editingPluginID = nil
                        }
                        await pluginSettingsViewModel.refresh()
                    }
                    pendingPluginDeleteID = nil
                }
            }

            Button("取消", role: .cancel) {
                pendingPluginDeleteID = nil
            }
        } message: {
            Text("卸载后将删除该插件目录，且无法恢复。")
        }
        .onAppear {
            liveAIStatus = aiStatusProvider()
        }
        .task {
            await pluginSettingsViewModel.refresh()
        }
        .sheet(isPresented: $showPluginCreator) {
            pluginCreatorSheet
        }
    }

    private var pluginCreatorSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("创建插件")
                .font(.title3.weight(.semibold))

            TextField("插件名称", text: $newPluginName)
                .textFieldStyle(.roundedBorder)

            TextField("描述", text: $newPluginDescription)
                .textFieldStyle(.roundedBorder)

            Picker("模板类型", selection: $selectedPluginTemplate) {
                ForEach(PluginTemplateOption.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Spacer()

                Button("取消") {
                    showPluginCreator = false
                }

                Button("创建") {
                    let name = newPluginName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let description = newPluginDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else {
                        errorMessage = "请输入插件名称"
                        showError = true
                        return
                    }

                    Task {
                        if let error = await onCreatePlugin(name, description, selectedPluginTemplate.rawValue) {
                            errorMessage = error
                            showError = true
                        } else {
                            showPluginCreator = false
                            await pluginSettingsViewModel.refresh()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 460)
    }

    private func statusColor(for status: CapabilityItemStatus) -> Color {
        switch status {
        case .active:
            return .green
        case .needsPermission:
            return .yellow
        case .inactive:
            return .gray
        }
    }

    private var aiStatusText: String {
        switch liveAIStatus {
        case .ready:
            return L10n.settingsAIStatusReady
        case .notConfigured:
            return L10n.settingsAIStatusNotConfigured
        case .connecting:
            return L10n.settingsAIStatusConnecting
        case .error(let message):
            if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return L10n.settingsAIStatusError
            }
            return "\(L10n.settingsAIStatusError): \(message)"
        }
    }

    private func aiBackendTitle(_ backend: AIEngine.AIBackend) -> String {
        switch backend {
        case .ollama:
            return L10n.settingsAIBackendOllama
        case .openAICompatible:
            return L10n.settingsAIBackendOpenAICompatible
        }
    }

    private func statusColor(for status: AIEngineStatus) -> Color {
        switch status {
        case .ready:
            return .green
        case .connecting:
            return .orange
        case .notConfigured:
            return .red
        case .error:
            return .red
        }
    }

    @ViewBuilder
    private func collapsibleSection<Content: View>(
        _ title: String,
        icon: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation { isExpanded.wrappedValue.toggle() }
            } label: {
                HStack {
                    Image(systemName: icon)
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(isExpanded.wrappedValue ? "收起 ▲" : "展开 ▼")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)

            if isExpanded.wrappedValue {
                VStack(alignment: .leading, spacing: 8) {
                    content()
                }
                .padding(.leading, 26)
            }
        }
    }

    @ViewBuilder
    private func spritePackRow(for item: SpritePackDisplayItem) -> some View {
        let packDirectory: URL? = item.directory

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                SpritePackPreviewView(packDirectory: packDirectory, previewSize: 48)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(item.name)
                            .font(.headline)

                        if item.isBuiltIn {
                            Text(L10n.settingsSpritePacksBuiltIn)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.2))
                                .clipShape(Capsule())
                        }
                    }

                    Text(spritePackMetadataText(for: item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(L10n.settingsSpritePacksRevealFinder) {
                    onRevealInFinder(item.id)
                }
                .buttonStyle(.borderless)

                if !item.isBuiltIn {
                    Button(L10n.settingsSpritePacksExport) {
                        Task {
                            if let error = await onExportPack(item.id) {
                                errorMessage = error
                                showError = true
                            }
                        }
                    }
                    .buttonStyle(.borderless)

                    Button(L10n.settingsSpritePacksDelete, role: .destructive) {
                        pendingDeleteID = item.id
                        showDeleteConfirm = true
                    }
                    .buttonStyle(.borderless)
                }

            }
            .contextMenu {
                Button(L10n.settingsSpritePacksRevealFinder) {
                    onRevealInFinder(item.id)
                }

                if !item.isBuiltIn {
                    Button(L10n.settingsSpritePacksExport) {
                        Task {
                            if let error = await onExportPack(item.id) {
                                errorMessage = error
                                showError = true
                            }
                        }
                    }

                    Divider()

                    Button(L10n.settingsSpritePacksDelete, role: .destructive) {
                        pendingDeleteID = item.id
                        showDeleteConfirm = true
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func togglePluginEditor(for pluginID: String) {
        editingPluginID = editingPluginID == pluginID ? nil : pluginID
    }

    private func spritePackMetadataText(for item: SpritePackDisplayItem) -> String {
        let states = String(format: L10n.settingsSpritePacksStatesCount, item.stateCount)
        let frames = String(format: L10n.settingsSpritePacksFramesCount, item.totalFrameCount)
        return "\(states) · \(frames)"
    }

    private func normalizedPetName(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func spritePackName(for id: String) -> String {
        spritePackItems.first(where: { $0.id == id })?.name ?? id
    }

    private func spritePackDirectory(for id: String) -> URL? {
        spritePackItems.first(where: { $0.id == id })?.directory
    }

    private func editingPetLanguageTarget(for pet: PetProfileItem) -> PetProfileItem {
        PetProfileItem(
            id: pet.id,
            name: normalizedPetName(editName, fallback: pet.name),
            spritePack: editSpritePack,
            size: editSize,
            gender: editGender,
            age: editAge,
            personality: editPersonality,
            hobbies: editHobbies,
            customLanguage: pet.customLanguage,
            soundEnabled: pet.soundEnabled,
            soundVolume: pet.soundVolume
        )
    }

    private func startEditing(_ pet: PetProfileItem) {
        editName = pet.name
        editSpritePack = pet.spritePack
        editSize = pet.size
        editGender = pet.gender
        editAge = pet.age
        editPersonality = pet.personality
        editHobbies = pet.hobbies
        editUsesCustomSound = pet.soundEnabled != nil || pet.soundVolume != nil
        editSoundEnabled = pet.soundEnabled ?? soundEnabled
        editSoundVolume = Double(pet.soundVolume ?? Float(soundVolume))
        editBasicExpanded = true
        editLanguageExpanded = false
        editSoundExpanded = false
        editResetExpanded = false
        editingPetID = pet.id
    }

    private func refreshPetProfiles(reloadEditingPetID: UUID? = nil) {
        let latestProfiles = loadPetProfiles()
        petProfiles = latestProfiles

        guard let targetID = reloadEditingPetID,
              let pet = latestProfiles.first(where: { $0.id == targetID })
        else {
            return
        }

        startEditing(pet)
    }

    private func addDesktopAwarenessRule() {
        let newRule = EditableDesktopAwarenessRule(
            category: "new-rule",
            bundleIdPatterns: [""],
            animation: Self.availableDesktopAnimations.first ?? "idle",
            bubbleTexts: [""],
            bubbleInterval: 30
        )
        desktopAwarenessRules.append(newRule)
        expandedDesktopRuleIDs.insert(newRule.id)
        desktopAwarenessStatusMessage = nil
    }

    private func removeDesktopAwarenessRule(id: UUID) {
        desktopAwarenessRules.removeAll { $0.id == id }
        expandedDesktopRuleIDs.remove(id)
        desktopAwarenessStatusMessage = nil
    }

    private func saveDesktopAwarenessRules() {
        let rulesToSave = desktopAwarenessRules.map(\.appBehaviorRule)
        if let error = onSaveDesktopAwarenessRules(rulesToSave) {
            desktopAwarenessStatusMessage = error
        } else {
            desktopAwarenessStatusMessage = "已保存"
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

private struct EditableDesktopAwarenessRule: Identifiable {
    let id: UUID
    var category: String
    var bundleIdPatterns: [String]
    var animation: String
    var bubbleTexts: [String]
    var bubbleInterval: Double

    init(
        id: UUID = UUID(),
        category: String,
        bundleIdPatterns: [String],
        animation: String,
        bubbleTexts: [String],
        bubbleInterval: Double
    ) {
        self.id = id
        self.category = category
        self.bundleIdPatterns = bundleIdPatterns.isEmpty ? [""] : bundleIdPatterns
        self.animation = animation
        self.bubbleTexts = bubbleTexts.isEmpty ? [""] : bubbleTexts
        self.bubbleInterval = bubbleInterval
    }

    init(rule: AppBehaviorRule) {
        self.init(
            category: rule.category,
            bundleIdPatterns: rule.bundleIdPatterns,
            animation: rule.animation,
            bubbleTexts: rule.bubbleTexts,
            bubbleInterval: rule.bubbleInterval
        )
    }

    var appBehaviorRule: AppBehaviorRule {
        AppBehaviorRule(
            category: category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "untitled" : category.trimmingCharacters(in: .whitespacesAndNewlines),
            bundleIdPatterns: bundleIdPatterns.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            animation: animation.trimmingCharacters(in: .whitespacesAndNewlines),
            bubbleTexts: bubbleTexts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            bubbleInterval: bubbleInterval
        )
    }
}

private struct DesktopAwarenessRuleEditor: View {
    @Binding var rule: EditableDesktopAwarenessRule
    @Binding var isExpanded: Bool
    let availableAnimations: [String]
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayTitle)
                        .font(.headline)
                    Text("\(rule.bundleIdPatterns.filter { !$0.isEmpty }.count) 个 Bundle ID · \(rule.bubbleTexts.filter { !$0.isEmpty }.count) 条气泡")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(isExpanded ? "收起" : "编辑") {
                    isExpanded.toggle()
                }
                .buttonStyle(.borderless)

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                isExpanded.toggle()
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("分类")
                            .frame(width: 72, alignment: .leading)
                        TextField("例如：coding", text: $rule.category)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack(alignment: .top) {
                        Text("动画")
                            .frame(width: 72, alignment: .leading)
                        VStack(alignment: .leading, spacing: 6) {
                            Picker("动画", selection: animationBinding) {
                                ForEach(availableAnimations, id: \.self) { animation in
                                    Text(animation).tag(animation)
                                }
                            }
                            .labelsHidden()

                            TextField("自定义动画名", text: animationBinding)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    HStack {
                        Text("间隔")
                            .frame(width: 72, alignment: .leading)
                        TextField("30", value: $rule.bubbleInterval, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                        Text("秒")
                            .foregroundStyle(.secondary)
                    }

                    EditableStringList(
                        title: "Bundle ID",
                        placeholder: "com.apple.Safari",
                        items: $rule.bundleIdPatterns
                    )

                    EditableStringList(
                        title: "气泡文案",
                        placeholder: "正在工作中~",
                        items: $rule.bubbleTexts
                    )
                }
                .padding(.leading, 4)
            }
        }
        .padding(.vertical, 4)
    }

    private var displayTitle: String {
        let trimmed = rule.category.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名规则" : trimmed
    }

    private var animationBinding: Binding<String> {
        Binding(
            get: { rule.animation },
            set: { rule.animation = $0 }
        )
    }
}

private struct EditableStringList: View {
    let title: String
    let placeholder: String
    @Binding var items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            ForEach(Array(items.indices), id: \.self) { index in
                HStack(spacing: 6) {
                    TextField(placeholder, text: binding(for: index))
                        .textFieldStyle(.roundedBorder)

                    Button {
                        removeItem(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(.red.opacity(0.7))
                    }
                    .buttonStyle(.borderless)
                }
            }

            Button {
                items.append("")
            } label: {
                Label("添加", systemImage: "plus")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
    }

    private func binding(for index: Int) -> Binding<String> {
        Binding(
            get: {
                guard items.indices.contains(index) else { return "" }
                return items[index]
            },
            set: { newValue in
                guard items.indices.contains(index) else { return }
                items[index] = newValue
            }
        )
    }

    private func removeItem(at index: Int) {
        guard items.indices.contains(index) else { return }
        items.remove(at: index)
        if items.isEmpty {
            items.append("")
        }
    }
}

private struct LanguagePackEditor: View {
    let directory: URL
    let pet: PetProfileItem?
    let onSave: @MainActor (UUID, [String: [String]]?) -> String?
    let onError: (String) -> Void

    @State private var actions: [LanguageActionEntry] = []
    @State private var statusMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("气泡文字配置")
                        .font(.subheadline.weight(.semibold))
                    Text("配置宠物在执行不同动作时显示的气泡文字（不影响动作本身）")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let pet {
                        Text("当前覆盖对象：\(pet.name)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button("保存") {
                    saveManifest()
                }
                .buttonStyle(.borderedProminent)
            }

            if actions.isEmpty {
                Text("暂无语言配置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach($actions) { $action in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(action.key)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(Array(action.texts.indices), id: \.self) { index in
                            HStack(spacing: 4) {
                                TextField("气泡文字", text: binding(for: action.id, textIndex: index))
                                    .textFieldStyle(.roundedBorder)
                                    .font(.caption)

                                Button {
                                    removeText(from: action.id, at: index)
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .foregroundStyle(.red.opacity(0.6))
                                }
                                .buttonStyle(.borderless)
                            }
                        }

                        Button {
                            addText(to: action.id)
                        } label: {
                            Label("添加", systemImage: "plus")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 2)
        .task(id: directory) {
            loadManifest()
        }
    }

    private func binding(for actionID: UUID, textIndex: Int) -> Binding<String> {
        Binding(
            get: {
                guard let actionIndex = actions.firstIndex(where: { $0.id == actionID }),
                      actions[actionIndex].texts.indices.contains(textIndex)
                else {
                    return ""
                }
                return actions[actionIndex].texts[textIndex]
            },
            set: { newValue in
                guard let actionIndex = actions.firstIndex(where: { $0.id == actionID }),
                      actions[actionIndex].texts.indices.contains(textIndex)
                else {
                    return
                }
                actions[actionIndex].texts[textIndex] = newValue
            }
        )
    }

    private func loadManifest() {
        do {
            let manifest = try SpritePackLoader.loadManifest(from: directory)
            let templateLanguage = manifest.language ?? [:]
            let mergedLanguage = templateLanguage.merging(pet?.customLanguage ?? [:]) { _, override in override }
            actions = mergedLanguage
                .map { LanguageActionEntry(key: $0.key, texts: $0.value.isEmpty ? [""] : $0.value) }
                .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            statusMessage = nil
        } catch {
            onError("加载语言包失败：\(error.localizedDescription)")
        }
    }

    private func saveManifest() {
        let trimmedEntries = actions.map { action in
            LanguageActionEntry(
                id: action.id,
                key: action.key.trimmingCharacters(in: .whitespacesAndNewlines),
                texts: action.texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            )
        }

        if trimmedEntries.contains(where: { $0.key.isEmpty }) {
            onError("动作名不能为空")
            return
        }

        let keys = trimmedEntries.map(\.key)
        if Set(keys).count != keys.count {
            onError("动作名不能重复")
            return
        }

        guard let pet else {
            onError("当前没有可写入语言覆盖的宠物")
            return
        }

        let language = Dictionary(
            uniqueKeysWithValues: trimmedEntries.map { entry in
                let texts = entry.texts.filter { !$0.isEmpty }
                return (entry.key, texts)
            }
        )
        if let error = onSave(pet.id, language.isEmpty ? nil : language) {
            onError("保存语言包失败：\(error)")
            return
        }

        statusMessage = "已保存到宠物语言覆盖"
    }

    private func addText(to actionID: UUID) {
        guard let index = actions.firstIndex(where: { $0.id == actionID }) else {
            return
        }
        actions[index].texts.append("")
        statusMessage = nil
    }

    private func removeText(from actionID: UUID, at index: Int) {
        guard let actionIndex = actions.firstIndex(where: { $0.id == actionID }),
              actions[actionIndex].texts.indices.contains(index)
        else {
            return
        }

        actions[actionIndex].texts.remove(at: index)
        if actions[actionIndex].texts.isEmpty {
            actions[actionIndex].texts.append("")
        }
        statusMessage = nil
    }

    private func removeAction(id: UUID) {
        actions.removeAll { $0.id == id }
        statusMessage = nil
    }
}

private struct LanguageActionEntry: Identifiable {
    let id: UUID
    var key: String
    var texts: [String]

    init(id: UUID = UUID(), key: String, texts: [String]) {
        self.id = id
        self.key = key
        self.texts = texts
    }
}

private struct PluginTriggerEditor: View {
    let directory: URL
    let onReloadPlugins: @MainActor () async -> String?
    let onError: (String) -> Void
    let onSaved: () -> Void

    @State private var manifest: EditablePluginManifest?
    @State private var statusMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("触发规则")
                        .font(.subheadline.weight(.semibold))
                    Text("编辑 plugin.json 中的事件、条件与动作")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("保存") {
                    saveManifest()
                }
                .buttonStyle(.borderedProminent)
                .disabled(manifest == nil)
            }

            if manifest != nil {
                ForEach(triggerBindings) { $trigger in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            TextField("事件类型", text: $trigger.event)
                                .textFieldStyle(.roundedBorder)

                            Button {
                                removeTrigger(id: trigger.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                        }

                        PluginKeyValueEditor(title: "条件", items: $trigger.conditions, keyPlaceholder: "key", valuePlaceholder: "value")

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("动作")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)

                                Spacer()

                                Button {
                                    addAction(to: trigger.id)
                                } label: {
                                    Label("添加动作", systemImage: "plus")
                                        .font(.caption)
                                }
                                .buttonStyle(.borderless)
                            }

                            ForEach($trigger.actions) { $action in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        TextField("动作类型", text: $action.type)
                                            .textFieldStyle(.roundedBorder)

                                        Button {
                                            removeAction(triggerID: trigger.id, actionID: action.id)
                                        } label: {
                                            Image(systemName: "minus.circle")
                                        }
                                        .buttonStyle(.borderless)
                                        .foregroundStyle(.red.opacity(0.7))
                                    }

                                    PluginKeyValueEditor(
                                        title: "参数",
                                        items: $action.params,
                                        keyPlaceholder: "字段名",
                                        valuePlaceholder: "值"
                                    )
                                }
                                .padding(8)
                                .background(Color.secondary.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                    .padding(10)
                    .background(Color.secondary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                Button {
                    addTrigger()
                } label: {
                    Label("添加触发规则", systemImage: "plus")
                        .font(.subheadline)
                }
                .buttonStyle(.borderless)
            } else {
                Text("未找到可编辑的 plugin.json")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 2)
        .task(id: directory) {
            loadManifest()
        }
    }

    private func loadManifest() {
        do {
            let manifestURL = directory.appendingPathComponent("plugin.json", isDirectory: false)
            let data = try Data(contentsOf: manifestURL)
            manifest = try JSONDecoder().decode(EditablePluginManifest.self, from: data)
            statusMessage = nil
        } catch {
            manifest = nil
            onError("加载插件规则失败：\(error.localizedDescription)")
        }
    }

    private func saveManifest() {
        guard var manifest else {
            return
        }

        manifest.triggers = manifest.triggers.map { trigger in
            var normalized = trigger
            normalized.event = trigger.event.trimmingCharacters(in: .whitespacesAndNewlines)
            normalized.conditions = trigger.conditions.map { item in
                EditableKeyValueItem(id: item.id, key: item.key.trimmingCharacters(in: .whitespacesAndNewlines), value: item.value.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            normalized.actions = trigger.actions.map { action in
                EditablePluginAction(
                    id: action.id,
                    type: action.type.trimmingCharacters(in: .whitespacesAndNewlines),
                    params: action.params.map {
                        EditableKeyValueItem(
                            id: $0.id,
                            key: $0.key.trimmingCharacters(in: .whitespacesAndNewlines),
                            value: $0.value.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    }
                )
            }
            return normalized
        }

        guard !manifest.triggers.contains(where: { $0.event.isEmpty }) else {
            onError("事件类型不能为空")
            return
        }

        do {
            let pluginManifest = try manifest.toPluginManifest()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(pluginManifest)
            try data.write(to: directory.appendingPathComponent("plugin.json"), options: .atomic)

            Task { @MainActor in
                if let error = await onReloadPlugins() {
                    onError(error)
                    return
                }

                statusMessage = "已保存到 plugin.json"
                onSaved()
                loadManifest()
            }
        } catch {
            onError("保存插件规则失败：\(error.localizedDescription)")
        }
    }

    private var triggerBindings: Binding<[EditableTriggerRule]> {
        Binding(
            get: { manifest?.triggers ?? [] },
            set: { newValue in
                manifest?.triggers = newValue
            }
        )
    }

    private func addTrigger() {
        guard var manifest else {
            return
        }
        manifest.triggers.append(EditableTriggerRule(event: "", conditions: [EditableKeyValueItem()], actions: [EditablePluginAction(type: "", params: [EditableKeyValueItem()])]))
        self.manifest = manifest
        statusMessage = nil
    }

    private func removeTrigger(id: UUID) {
        guard var manifest else {
            return
        }
        manifest.triggers.removeAll { $0.id == id }
        self.manifest = manifest
        statusMessage = nil
    }

    private func addAction(to triggerID: UUID) {
        guard var manifest,
              let index = manifest.triggers.firstIndex(where: { $0.id == triggerID })
        else {
            return
        }
        manifest.triggers[index].actions.append(EditablePluginAction(type: "", params: [EditableKeyValueItem()]))
        self.manifest = manifest
        statusMessage = nil
    }

    private func removeAction(triggerID: UUID, actionID: UUID) {
        guard var manifest,
              let triggerIndex = manifest.triggers.firstIndex(where: { $0.id == triggerID })
        else {
            return
        }
        manifest.triggers[triggerIndex].actions.removeAll { $0.id == actionID }
        self.manifest = manifest
        statusMessage = nil
    }
}

private struct PluginKeyValueEditor: View {
    let title: String
    @Binding var items: [EditableKeyValueItem]
    let keyPlaceholder: String
    let valuePlaceholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    items.append(EditableKeyValueItem())
                } label: {
                    Label("添加", systemImage: "plus")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
            }

            ForEach(Array(items.indices), id: \.self) { index in
                HStack(spacing: 6) {
                    TextField(keyPlaceholder, text: $items[index].key)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)

                    TextField(valuePlaceholder, text: $items[index].value)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)

                    Button {
                        items.remove(at: index)
                        if items.isEmpty {
                            items.append(EditableKeyValueItem())
                        }
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(.red.opacity(0.7))
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }
}

private struct EditablePluginManifest: Codable {
    var id: String
    var name: String
    var version: String
    var description: String
    var capabilities: [String]
    var triggers: [EditableTriggerRule]

    func toPluginManifest() throws -> PersistedPluginManifest {
        let triggers = try triggers.map { trigger in
            let conditions = try normalizedDictionary(from: trigger.conditions)

            let actions = try trigger.actions.map { action in
                let type = action.type.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !type.isEmpty else {
                    throw PluginEditorError.emptyActionType
                }

                let params = try normalizedDictionary(from: action.params)

                return PersistedPluginAction(type: type, params: params)
            }

            return PersistedTriggerRule(
                event: trigger.event,
                conditions: conditions,
                actions: actions
            )
        }

        return PersistedPluginManifest(
            id: id,
            name: name,
            version: version,
            description: description,
            capabilities: capabilities,
            triggers: triggers
        )
    }

    private func normalizedDictionary(from items: [EditableKeyValueItem]) throws -> [String: String] {
        var result: [String: String] = [:]
        for item in items {
            let key = item.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = item.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty {
                if value.isEmpty {
                    continue
                }
                throw PluginEditorError.emptyKey
            }
            if result[key] != nil {
                throw PluginEditorError.duplicateKey(key)
            }
            result[key] = value
        }
        return result
    }
}

private struct EditableTriggerRule: Identifiable, Codable {
    let id: UUID
    var event: String
    var conditions: [EditableKeyValueItem]
    var actions: [EditablePluginAction]

    init(id: UUID = UUID(), event: String, conditions: [EditableKeyValueItem], actions: [EditablePluginAction]) {
        self.id = id
        self.event = event
        self.conditions = conditions.isEmpty ? [EditableKeyValueItem()] : conditions
        self.actions = actions
    }

    private enum CodingKeys: String, CodingKey {
        case event
        case conditions
        case actions
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        event = try container.decode(String.self, forKey: .event)
        let conditions = try container.decode([String: String].self, forKey: .conditions)
        self.conditions = conditions.isEmpty ? [EditableKeyValueItem()] : conditions.keys.sorted().map {
            EditableKeyValueItem(key: $0, value: conditions[$0] ?? "")
        }
        let actions = try container.decode([EditablePluginAction].self, forKey: .actions)
        self.actions = actions.isEmpty ? [EditablePluginAction(type: "", params: [EditableKeyValueItem()])] : actions
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(event, forKey: .event)
        var encodedConditions: [String: String] = [:]
        for item in conditions {
            let key = item.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            encodedConditions[key] = item.value
        }
        try container.encode(encodedConditions, forKey: .conditions)
        try container.encode(actions, forKey: .actions)
    }
}

private struct EditablePluginAction: Identifiable, Codable {
    let id: UUID
    var type: String
    var params: [EditableKeyValueItem]

    init(id: UUID = UUID(), type: String, params: [EditableKeyValueItem]) {
        self.id = id
        self.type = type
        self.params = params.isEmpty ? [EditableKeyValueItem()] : params
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        id = UUID()
        type = try container.decode(String.self, forKey: DynamicCodingKey("type"))

        var params: [EditableKeyValueItem] = []
        for key in container.allKeys.sorted(by: { $0.stringValue < $1.stringValue }) where key.stringValue != "type" {
            params.append(EditableKeyValueItem(key: key.stringValue, value: try container.decode(String.self, forKey: key)))
        }
        self.params = params.isEmpty ? [EditableKeyValueItem()] : params
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        try container.encode(type, forKey: DynamicCodingKey("type"))
        for item in params {
            let key = item.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            try container.encode(item.value, forKey: DynamicCodingKey(key))
        }
    }
}

private struct EditableKeyValueItem: Identifiable, Codable {
    let id: UUID
    var key: String
    var value: String

    init(id: UUID = UUID(), key: String = "", value: String = "") {
        self.id = id
        self.key = key
        self.value = value
    }
}

private struct PersistedPluginManifest: Codable {
    let id: String
    let name: String
    let version: String
    let description: String
    let capabilities: [String]
    let triggers: [PersistedTriggerRule]
}

private struct PersistedTriggerRule: Codable {
    let event: String
    let conditions: [String: String]
    let actions: [PersistedPluginAction]
}

private struct PersistedPluginAction: Codable {
    let type: String
    let params: [String: String]

    init(type: String, params: [String: String]) {
        self.type = type
        self.params = params
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        type = try container.decode(String.self, forKey: DynamicCodingKey("type"))
        var params: [String: String] = [:]
        for key in container.allKeys where key.stringValue != "type" {
            params[key.stringValue] = try container.decode(String.self, forKey: key)
        }
        self.params = params
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        try container.encode(type, forKey: DynamicCodingKey("type"))
        for key in params.keys.sorted() {
            try container.encode(params[key], forKey: DynamicCodingKey(key))
        }
    }
}

private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private enum PluginEditorError: LocalizedError {
    case emptyKey
    case emptyActionType
    case duplicateKey(String)

    var errorDescription: String? {
        switch self {
        case .emptyKey:
            return "键名不能为空"
        case .emptyActionType:
            return "动作类型不能为空"
        case .duplicateKey(let key):
            return "重复的键名：\(key)"
        }
    }
}
