import AppKit
import AIEngine
import EventBus
import Localization
import SwiftUI

@MainActor
public final class ChatWindowController: NSWindowController {
    private let chatViewModel: ChatViewModel
    private let pluginSettingsViewModel: PluginSettingsViewModel
    private let activityLogViewModel: ActivityLogViewModel
    private let statisticsViewModel: StatisticsViewModel
    private var loadSpritePackItems: @MainActor () -> [SpritePackDisplayItem] = { [] }
    private var selectedSpritePackID: @MainActor () -> String = { "default" }
    private var onSelectSpritePack: @MainActor (String) -> Void = { _ in }
    private var onImportPack: @MainActor () async -> String? = { nil }
    private var onExportPack: @MainActor (String) async -> String? = { _ in nil }
    private var onDeletePack: @MainActor (String) async -> String? = { _ in nil }
    private var onRevealInFinder: @MainActor (String) -> Void = { _ in }
    private var onDeletePlugin: @MainActor (String) async -> String? = { _ in nil }
    private var onRevealPluginInFinder: @MainActor (String) -> Void = { _ in }
    private var onReloadPlugins: @MainActor () async -> String? = { nil }
    private var onCreateTemplate: @MainActor () async -> String? = { nil }
    private var onBuildSpritePack: @MainActor (String, [String: [URL]]) async -> String? = { _, _ in nil }
    private var aiEndpoint: @MainActor () -> String = { "http://localhost:11434" }
    private var aiBackend: @MainActor () -> AIEngine.AIBackend = { .ollama }
    private var aiModel: @MainActor () -> String = { "llama3.2" }
    private var aiStatus: @MainActor () -> AIEngineStatus = { .notConfigured }
    private var openAIApiKey: @MainActor () -> String = { "" }
    private var mcpServersJSON: @MainActor () -> String = { "" }
    private var aiSystemPrompt: @MainActor () -> String = { "" }
    private var memoryWorkerEnabled: @MainActor () -> Bool = { false }
    private var memoryWorkerEndpoint: @MainActor () -> String = { "https://memory.example.com" }
    private var memoryWorkerAuthMode: @MainActor () -> String = { "basic" }
    private var memoryWorkerUsername: @MainActor () -> String = { "" }
    private var memoryWorkerSecret: @MainActor () -> String = { "" }
    private var memoryWorkerScope: @MainActor () -> String = { "user" }
    private var memoryWorkerSubject: @MainActor () -> String = { "demo-user" }
    private var memoryWorkerQueryLimit: @MainActor () -> Int = { 5 }
    private var onTestConnection: @MainActor () -> Void = {}
    private var onTestAIMemoryConnection: @MainActor () async -> String? = { nil }
    private var onTestAIMemoryWrite: @MainActor () async -> String? = { nil }
    private var onSaveAIConfig: @MainActor (String, String, String, AIEngine.AIBackend, String, String) -> Void = { _, _, _, _, _, _ in }
    private var onSaveAIMemoryConfig: @MainActor (Bool, String, String, String, String, String, String, Int) -> Void = { _, _, _, _, _, _, _, _ in }
    private var githubToken: @MainActor () -> String = { "" }
    private var webhookEnabled: @MainActor () -> Bool = { false }
    private var webhookPort: @MainActor () -> Int = { 19280 }
    private var webhookSecret: @MainActor () -> String = { "" }
    private var onSaveNotificationConfig: @MainActor (String, Bool, Int, String) -> Void = { _, _, _, _ in }
    private var petProfiles: @MainActor () -> [PetProfileItem] = { [] }
    private var onUpdatePet: @MainActor (UUID, String, String, Double, String, String, String, String) -> Void = { _, _, _, _, _, _, _, _ in }
    private var onUpdatePetSound: @MainActor (UUID, Bool?, Float?) -> Void = { _, _, _ in }
    private var onUpdatePetLanguage: @MainActor (UUID, [String: [String]]?) -> String? = { _, _ in nil }
    private var onRemovePet: @MainActor (UUID) -> Void = { _ in }
    private var onAddPet: @MainActor () -> Void = {}
    private var canAddMorePets: @MainActor () -> Bool = { true }
    private var onResetLanguage: @MainActor (UUID) -> Void = { _ in }
    private var onResetAttributes: @MainActor (UUID) -> Void = { _ in }
    private var onResetAll: @MainActor (UUID) -> Void = { _ in }
    private var desktopAwarenessEnabled: @MainActor () -> Bool = { true }
    private var desktopAwarenessRules: @MainActor () -> [AppBehaviorRule] = { [] }
    private var onSetDesktopAwarenessEnabled: @MainActor (Bool) -> Void = { _ in }
    private var onSaveDesktopAwarenessRules: @MainActor ([AppBehaviorRule]) -> String? = { _ in nil }
    private var soundEnabled: @MainActor () -> Bool = { false }
    private var soundVolume: @MainActor () -> Double = { 0.5 }
    private var onSetSoundEnabled: @MainActor (Bool) -> Void = { _ in }
    private var onSetSoundVolume: @MainActor (Float) -> Void = { _ in }
    private var weatherAwarenessEnabled: @MainActor () -> Bool = { true }
    private var currentWeatherSummary: @MainActor () -> String? = { nil }
    private var onSetWeatherAwarenessEnabled: @MainActor (Bool) -> Void = { _ in }
    private var weatherLatitude: @MainActor () -> Double? = { nil }
    private var weatherLongitude: @MainActor () -> Double? = { nil }
    private var onSaveWeatherLocation: @MainActor (Double?, Double?) -> Void = { _, _ in }
    private var weatherRefreshMinutes: @MainActor () -> Int = { 120 }
    private var onSetWeatherRefreshInterval: @MainActor (Double) -> Void = { _ in }
    private var onCreatePlugin: @MainActor (String, String, String) async -> String? = { _, _, _ in nil }
    private var listAvailablePets: @MainActor () -> [(id: UUID, name: String)] = { [] }
    private var onDeleteConversation: @MainActor (String) -> Void = { _ in }
    private var onUpdateConversationParticipants: @MainActor (String, [UUID]) -> Void = { _, _ in }

    public convenience init(
        chatViewModel: ChatViewModel = ChatViewModel(),
        pluginSettingsViewModel: PluginSettingsViewModel = PluginSettingsViewModel(loadPlugins: { [] }, setEnabled: { _, _ in }),
        activityLogViewModel: ActivityLogViewModel = ActivityLogViewModel(loadEvents: { _, _ in [] }),
        statisticsViewModel: StatisticsViewModel = StatisticsViewModel()
    ) {
        let contentRect = NSRect(x: 0, y: 0, width: 860, height: 640)
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )

        window.title = "VitaPet"
        window.level = .normal
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 580)
        window.center()
        window.contentView = NSHostingView(rootView: ChatView(viewModel: chatViewModel))

        self.init(
            window: window,
            chatViewModel: chatViewModel,
            pluginSettingsViewModel: pluginSettingsViewModel,
            activityLogViewModel: activityLogViewModel,
            statisticsViewModel: statisticsViewModel
        )
        shouldCascadeWindows = true
    }

    private init(
        window: NSWindow,
        chatViewModel: ChatViewModel,
        pluginSettingsViewModel: PluginSettingsViewModel,
        activityLogViewModel: ActivityLogViewModel,
        statisticsViewModel: StatisticsViewModel
    ) {
        self.chatViewModel = chatViewModel
        self.pluginSettingsViewModel = pluginSettingsViewModel
        self.activityLogViewModel = activityLogViewModel
        self.statisticsViewModel = statisticsViewModel
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    public func showChat() {
        window?.title = "VitaPet Chat"
        // Keep the title bar opaque so SwiftUI's NavigationSplitView doesn't render its toolbar
        // region on top of the scrollable chat content (otherwise messages appear to bleed into
        // the titlebar area when scrolling).
        window?.titlebarAppearsTransparent = false
        window?.titleVisibility = .visible
        window?.styleMask.remove(.fullSizeContentView)

        window?.contentView = NSHostingView(
            rootView: TabbedChatView(viewModel: chatViewModel, availablePets: listAvailablePets())
        )
        if let window, window.frame.width < 760 {
            window.setContentSize(NSSize(width: 860, height: 640))
            window.center()
        }
        // Float briefly to ensure chat pops above other apps on launch, then
        // drop back to normal level so it can be covered like any other window.
        window?.level = .floating
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.window?.level = .normal
        }
    }

    public func showSettings() {
        window?.title = "VitaPet 设置"
        window?.contentView = NSHostingView(
            rootView: SettingsView(
                pluginSettingsViewModel: pluginSettingsViewModel,
                petProfiles: petProfiles(),
                loadPetProfiles: petProfiles,
                spritePackItems: loadSpritePackItems(),
                selectedSpritePackID: selectedSpritePackID(),
                onSelectSpritePack: onSelectSpritePack,
                onImportPack: onImportPack,
                onExportPack: onExportPack,
                onDeletePack: onDeletePack,
                onRevealInFinder: onRevealInFinder,
                onCreateTemplate: onCreateTemplate,
                ollamaEndpoint: aiEndpoint(),
                aiBackend: aiBackend(),
                ollamaModel: aiModel(),
                openAIApiKey: openAIApiKey(),
                mcpServersJSON: mcpServersJSON(),
                aiSystemPrompt: aiSystemPrompt(),
                memoryWorkerEnabled: memoryWorkerEnabled(),
                memoryWorkerEndpoint: memoryWorkerEndpoint(),
                memoryWorkerAuthMode: memoryWorkerAuthMode(),
                memoryWorkerUsername: memoryWorkerUsername(),
                memoryWorkerSecret: memoryWorkerSecret(),
                memoryWorkerScope: memoryWorkerScope(),
                memoryWorkerSubject: memoryWorkerSubject(),
                memoryWorkerQueryLimit: memoryWorkerQueryLimit(),
                githubToken: githubToken(),
                webhookEnabled: webhookEnabled(),
                webhookPort: webhookPort(),
                webhookSecret: webhookSecret(),
                aiStatus: aiStatus(),
                aiStatusProvider: aiStatus,
                onTestConnection: onTestConnection,
                onTestAIMemoryConnection: onTestAIMemoryConnection,
                onTestAIMemoryWrite: onTestAIMemoryWrite,
                onSaveAIConfig: onSaveAIConfig,
                onSaveAIMemoryConfig: onSaveAIMemoryConfig,
                onSaveNotificationConfig: onSaveNotificationConfig,
                onUpdatePet: onUpdatePet,
                onUpdatePetSound: onUpdatePetSound,
                onUpdatePetLanguage: onUpdatePetLanguage,
                onRemovePet: onRemovePet,
                onAddPet: onAddPet,
                canAddMorePets: canAddMorePets(),
                desktopAwarenessEnabled: desktopAwarenessEnabled(),
                desktopAwarenessRules: desktopAwarenessRules(),
                onSetDesktopAwarenessEnabled: onSetDesktopAwarenessEnabled,
                onSaveDesktopAwarenessRules: onSaveDesktopAwarenessRules,
                soundEnabled: soundEnabled(),
                soundVolume: soundVolume(),
                onSetSoundEnabled: onSetSoundEnabled,
                onSetSoundVolume: onSetSoundVolume,
                weatherAwarenessEnabled: weatherAwarenessEnabled(),
                currentWeatherSummary: currentWeatherSummary(),
                onSetWeatherAwarenessEnabled: onSetWeatherAwarenessEnabled,
                weatherLatitude: weatherLatitude(),
                weatherLongitude: weatherLongitude(),
                onSaveWeatherLocation: onSaveWeatherLocation,
                weatherRefreshMinutes: weatherRefreshMinutes(),
                onSetWeatherRefreshInterval: onSetWeatherRefreshInterval,
                onCreatePlugin: onCreatePlugin,
                onDeletePlugin: onDeletePlugin,
                onRevealPluginInFinder: onRevealPluginInFinder,
                onReloadPlugins: onReloadPlugins,
                onResetLanguage: onResetLanguage,
                onResetAttributes: onResetAttributes,
                onResetAll: onResetAll
            )
        )
        window?.level = .floating
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.window?.level = .normal
        }
    }

    public func showSpritePackCreator(initialFrames: [String: [URL]] = [:]) {
        window?.title = L10n.spritePackCreatorTitle
        window?.contentView = NSHostingView(
            rootView: SpritePackCreatorView(
                initialFrames: initialFrames,
                onBuild: onBuildSpritePack,
                onDismiss: { [weak self] in
                    self?.showSettings()
                }
            )
        )
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    public func showActivityLog() {
        window?.title = "VitaPet Activity Log"
        window?.contentView = NSHostingView(rootView: ActivityLogView(activityLogViewModel: activityLogViewModel))
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    public func showStatistics() {
        window?.title = "VitaPet Statistics"
        window?.contentView = NSHostingView(rootView: StatisticsView(statisticsViewModel: statisticsViewModel))
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    public func configureSpritePackManagement(
        loadSpritePackItems: @escaping @MainActor () -> [SpritePackDisplayItem],
        selectedSpritePackID: @escaping @MainActor () -> String,
        onSelectSpritePack: @escaping @MainActor (String) -> Void,
        onImportPack: @escaping @MainActor () async -> String?,
        onExportPack: @escaping @MainActor (String) async -> String?,
        onDeletePack: @escaping @MainActor (String) async -> String?,
        onRevealInFinder: @escaping @MainActor (String) -> Void,
        onCreateTemplate: @escaping @MainActor () async -> String?
    ) {
        self.loadSpritePackItems = loadSpritePackItems
        self.selectedSpritePackID = selectedSpritePackID
        self.onSelectSpritePack = onSelectSpritePack
        self.onImportPack = onImportPack
        self.onExportPack = onExportPack
        self.onDeletePack = onDeletePack
        self.onRevealInFinder = onRevealInFinder
        self.onCreateTemplate = onCreateTemplate
    }

    public func configureSpritePackSettings(
        loadSpritePacks: @escaping @MainActor () -> [SpritePackOption],
        selectedSpritePackID: @escaping @MainActor () -> String,
        onSelectSpritePack: @escaping @MainActor (String) -> Void
    ) {
        self.loadSpritePackItems = {
            loadSpritePacks().map { option in
                SpritePackDisplayItem(
                    id: option.id,
                    name: option.name,
                    directory: URL(fileURLWithPath: "/"),
                    stateCount: 0,
                    totalFrameCount: 0,
                    isBuiltIn: option.id == "default"
                )
            }
        }
        self.selectedSpritePackID = selectedSpritePackID
        self.onSelectSpritePack = onSelectSpritePack
        self.onImportPack = { nil }
        self.onExportPack = { _ in nil }
        self.onDeletePack = { _ in nil }
        self.onRevealInFinder = { _ in }
        self.onCreateTemplate = { nil }
    }

    public func configureSpritePackCreator(
        onBuild: @escaping @MainActor (String, [String: [URL]]) async -> String?
    ) {
        self.onBuildSpritePack = onBuild
    }

    public func configureAISettings(
        aiEndpoint: @escaping @MainActor () -> String,
        aiBackend: @escaping @MainActor () -> AIEngine.AIBackend,
        aiModel: @escaping @MainActor () -> String,
        openAIApiKey: @escaping @MainActor () -> String = { "" },
        mcpServersJSON: @escaping @MainActor () -> String = { "" },
        aiSystemPrompt: @escaping @MainActor () -> String,
        memoryWorkerEnabled: @escaping @MainActor () -> Bool = { false },
        memoryWorkerEndpoint: @escaping @MainActor () -> String = { "https://memory.example.com" },
        memoryWorkerAuthMode: @escaping @MainActor () -> String = { "basic" },
        memoryWorkerUsername: @escaping @MainActor () -> String = { "" },
        memoryWorkerSecret: @escaping @MainActor () -> String = { "" },
        memoryWorkerScope: @escaping @MainActor () -> String = { "user" },
        memoryWorkerSubject: @escaping @MainActor () -> String = { "demo-user" },
        memoryWorkerQueryLimit: @escaping @MainActor () -> Int = { 5 },
        aiStatus: @escaping @MainActor () -> AIEngineStatus,
        onTestConnection: @escaping @MainActor () -> Void = {},
        onTestAIMemoryConnection: @escaping @MainActor () async -> String? = { nil },
        onTestAIMemoryWrite: @escaping @MainActor () async -> String? = { nil },
        onSaveAIConfig: @escaping @MainActor (String, String, String, AIEngine.AIBackend, String, String) -> Void = { _, _, _, _, _, _ in },
        onSaveAIMemoryConfig: @escaping @MainActor (Bool, String, String, String, String, String, String, Int) -> Void = { _, _, _, _, _, _, _, _ in }
    ) {
        self.aiEndpoint = aiEndpoint
        self.aiBackend = aiBackend
        self.aiModel = aiModel
        self.openAIApiKey = openAIApiKey
        self.mcpServersJSON = mcpServersJSON
        self.aiSystemPrompt = aiSystemPrompt
        self.memoryWorkerEnabled = memoryWorkerEnabled
        self.memoryWorkerEndpoint = memoryWorkerEndpoint
        self.memoryWorkerAuthMode = memoryWorkerAuthMode
        self.memoryWorkerUsername = memoryWorkerUsername
        self.memoryWorkerSecret = memoryWorkerSecret
        self.memoryWorkerScope = memoryWorkerScope
        self.memoryWorkerSubject = memoryWorkerSubject
        self.memoryWorkerQueryLimit = memoryWorkerQueryLimit
        self.aiStatus = aiStatus
        self.onTestConnection = onTestConnection
        self.onTestAIMemoryConnection = onTestAIMemoryConnection
        self.onTestAIMemoryWrite = onTestAIMemoryWrite
        self.onSaveAIConfig = onSaveAIConfig
        self.onSaveAIMemoryConfig = onSaveAIMemoryConfig
    }

    public func configureNotificationSettings(
        githubToken: @escaping @MainActor () -> String,
        webhookEnabled: @escaping @MainActor () -> Bool,
        webhookPort: @escaping @MainActor () -> Int,
        webhookSecret: @escaping @MainActor () -> String,
        onSaveNotificationConfig: @escaping @MainActor (String, Bool, Int, String) -> Void
    ) {
        self.githubToken = githubToken
        self.webhookEnabled = webhookEnabled
        self.webhookPort = webhookPort
        self.webhookSecret = webhookSecret
        self.onSaveNotificationConfig = onSaveNotificationConfig
    }

    public func configurePetManagement(
        petProfiles: @escaping @MainActor () -> [PetProfileItem],
        onUpdatePet: @escaping @MainActor (UUID, String, String, Double, String, String, String, String) -> Void,
        onUpdatePetSound: @escaping @MainActor (UUID, Bool?, Float?) -> Void = { _, _, _ in },
        onUpdatePetLanguage: @escaping @MainActor (UUID, [String: [String]]?) -> String? = { _, _ in nil },
        onRemovePet: @escaping @MainActor (UUID) -> Void,
        onAddPet: @escaping @MainActor () -> Void,
        canAddMorePets: @escaping @MainActor () -> Bool
    ) {
        self.petProfiles = petProfiles
        self.onUpdatePet = onUpdatePet
        self.onUpdatePetSound = onUpdatePetSound
        self.onUpdatePetLanguage = onUpdatePetLanguage
        self.onRemovePet = onRemovePet
        self.onAddPet = onAddPet
        self.canAddMorePets = canAddMorePets
    }

    public func configureResetCallbacks(
        onResetLanguage: @escaping @MainActor (UUID) -> Void,
        onResetAttributes: @escaping @MainActor (UUID) -> Void,
        onResetAll: @escaping @MainActor (UUID) -> Void
    ) {
        self.onResetLanguage = onResetLanguage
        self.onResetAttributes = onResetAttributes
        self.onResetAll = onResetAll
    }

    public func configureDesktopAwarenessSettings(
        isEnabled: @escaping @MainActor () -> Bool,
        rules: @escaping @MainActor () -> [AppBehaviorRule],
        onSetEnabled: @escaping @MainActor (Bool) -> Void,
        onSaveRules: @escaping @MainActor ([AppBehaviorRule]) -> String?
    ) {
        self.desktopAwarenessEnabled = isEnabled
        self.desktopAwarenessRules = rules
        self.onSetDesktopAwarenessEnabled = onSetEnabled
        self.onSaveDesktopAwarenessRules = onSaveRules
    }

    public func configureWeatherSettings(
        isEnabled: @escaping @MainActor () -> Bool,
        currentSummary: @escaping @MainActor () -> String?,
        onSetEnabled: @escaping @MainActor (Bool) -> Void,
        latitude: @escaping @MainActor () -> Double? = { nil },
        longitude: @escaping @MainActor () -> Double? = { nil },
        onSaveLocation: @escaping @MainActor (Double?, Double?) -> Void = { _, _ in }
    ) {
        self.weatherAwarenessEnabled = isEnabled
        self.currentWeatherSummary = currentSummary
        self.onSetWeatherAwarenessEnabled = onSetEnabled
        self.weatherLatitude = latitude
        self.weatherLongitude = longitude
        self.onSaveWeatherLocation = onSaveLocation
    }

    public func configureSoundSettings(
        soundEnabled: @escaping @MainActor () -> Bool,
        soundVolume: @escaping @MainActor () -> Double,
        onSetSoundEnabled: @escaping @MainActor (Bool) -> Void,
        onSetSoundVolume: @escaping @MainActor (Float) -> Void
    ) {
        self.soundEnabled = soundEnabled
        self.soundVolume = soundVolume
        self.onSetSoundEnabled = onSetSoundEnabled
        self.onSetSoundVolume = onSetSoundVolume
    }

    public func configureWeatherRefresh(
        refreshMinutes: @escaping @MainActor () -> Int,
        onSetInterval: @escaping @MainActor (Double) -> Void
    ) {
        self.weatherRefreshMinutes = refreshMinutes
        self.onSetWeatherRefreshInterval = onSetInterval
    }

    public func configureChatConversations(
        listAvailablePets: @escaping @MainActor () -> [(id: UUID, name: String)],
        onDeleteConversation: @escaping @MainActor (String) -> Void,
        onUpdateConversationParticipants: @escaping @MainActor (String, [UUID]) -> Void = { _, _ in }
    ) {
        self.listAvailablePets = listAvailablePets
        self.onDeleteConversation = onDeleteConversation
        self.onUpdateConversationParticipants = onUpdateConversationParticipants
        chatViewModel.onDeleteConversation = onDeleteConversation
    }

    public func removePetConversations(petId: UUID) {
        chatViewModel.deleteConversation("single_\(petId.uuidString)")

        let affectedGroups = chatViewModel.conversations.filter { conversation in
            conversation.type == .group && conversation.participantIds.contains(petId)
        }

        for conversation in affectedGroups {
            let remainingParticipants = conversation.participantIds.filter { $0 != petId }
            if remainingParticipants.count <= 1 {
                chatViewModel.deleteConversation(conversation.id)
                continue
            }

            chatViewModel.updateConversation(
                ConversationThread(
                    id: conversation.id,
                    type: conversation.type,
                    participantIds: remainingParticipants,
                    title: conversation.title,
                    lastMessage: conversation.lastMessage,
                    lastTimestamp: conversation.lastTimestamp,
                    unreadCount: conversation.unreadCount
                )
            )
            onUpdateConversationParticipants(conversation.id, remainingParticipants)
        }
    }

    public func configureStatistics(
        loadMoodHistory: @escaping @Sendable (String?, Int) async throws -> [(timestamp: Date, happiness: Int, petName: String)],
        loadBehaviorCounts: @escaping @Sendable (Int) async throws -> [(state: String, count: Int, petName: String)],
        loadDailyInteractions: @escaping @Sendable (Int) async throws -> [(date: String, clicks: Int, interactions: Int, games: Int)]
    ) {
        statisticsViewModel.configure(
            loadMoodHistory: loadMoodHistory,
            loadBehaviorCounts: loadBehaviorCounts,
            loadDailyInteractions: loadDailyInteractions
        )
    }

    public func configurePluginCreation(
        onDeletePlugin: @escaping @MainActor (String) async -> String? = { _ in nil },
        onRevealPluginInFinder: @escaping @MainActor (String) -> Void = { _ in },
        onReloadPlugins: @escaping @MainActor () async -> String? = { nil },
        onCreatePlugin: @escaping @MainActor (String, String, String) async -> String?
    ) {
        self.onDeletePlugin = onDeletePlugin
        self.onRevealPluginInFinder = onRevealPluginInFinder
        self.onReloadPlugins = onReloadPlugins
        self.onCreatePlugin = onCreatePlugin
    }
}
