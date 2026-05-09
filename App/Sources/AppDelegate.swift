import AppKit
import AIEngine
import ChatUI
import EventBus
import Localization
import Persistence
import PluginRuntime
import RenderEngine
import SecurityLayer
import CoreLocation
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private struct PreparedConversationRequest {
        let stream: AsyncThrowingStream<String, Error>
        let targetPets: [PetIdentity]
        let isGroupChat: Bool
    }

    private var petWindowControllers: [UUID: PetWindowController] = [:]
    private var chatViewModel: ChatViewModel!
    private var chatController: ChatWindowController!
    private var statusBarController: StatusBarController!
    private var inputBarController: InputBarWindowController!
    private let eventBus = EventBus()
    private var timerSource: TimerSource!
    private var hourBoundaryTimer: HourBoundaryTimerSource!
    private var workspaceMonitor: WorkspaceMonitor!
    private var notificationMonitor: NotificationMonitor!
    private var githubMonitor: GitHubMonitor!
    private var calendarMonitor: CalendarMonitor!
    private var clipboardMonitor: ClipboardMonitor!
    private var fsEventsMonitor: FSEventsMonitor!
    private var keyboardMonitor: KeyboardMonitor!
    private var webhookServer: WebhookServer?
    private var sitReminderTimer: TimerSource!
    private var eventSubscriptionID: UUID?
    private var databaseManager: DatabaseManager?
    private let capabilityManager = CapabilityManager()
    private var pluginManager: PluginManager!
    private var configManager: ConfigManager!
    private var spritePackManager: SpritePackManager!
    private var spritePackImporter: SpritePackImporter!
    private var aiProactiveTrigger: AIProactiveTrigger?
    private var aiStatus: AIEngine.AIEngineStatus = .notConfigured
    private var ollamaService: OllamaService?
    private var memoryWorkerService: MemoryWorkerService?
    private var interactionManager: PetInteractionManager!
    private var desktopAwareness = DesktopAwarenessController()
    private var timeWeatherController = TimeWeatherController()
    private var miniGameManager = MiniGameManager()
    private var pomodoroController = PomodoroController()
    private var conversationTurnCount = 0
    private var chatPathSomersaultFired = false
    private var chatPathToolActionFired = false
    private static let memoryExtractionEveryNTurns = 2
    private var memoryRemoteSyncTask: Task<Void, Never>?
    /// 周期性把本地未同步的记忆推到远端，避免单次失败后只能等下次抽取/重启才重传。
    private static let memoryRemoteFlushInterval: UInt64 = 10 * 60 * 1_000_000_000
    private let maximumPets = 5
    private let windowDetector = WindowDetector()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            await bootstrap()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        aiProactiveTrigger?.stop()
        timeWeatherController.stop()
        memoryRemoteSyncTask?.cancel()
        memoryRemoteSyncTask = nil
        VitaPetApp.releaseAppLock()

        let timerSource = timerSource
        let hourBoundaryTimer = hourBoundaryTimer
        let sitReminderTimer = sitReminderTimer
        let workspaceMonitor = workspaceMonitor
        let notificationMonitor = notificationMonitor
        let githubMonitor = githubMonitor
        let calendarMonitor = calendarMonitor
        let clipboardMonitor = clipboardMonitor
        let fsEventsMonitor = fsEventsMonitor
        let keyboardMonitor = keyboardMonitor
        let webhookServer = webhookServer
        let eventBus = eventBus
        let eventSubscriptionID = eventSubscriptionID

        Task {
            await timerSource?.stop()
            await hourBoundaryTimer?.stop()
            await sitReminderTimer?.stop()
            await workspaceMonitor?.stop()
            await notificationMonitor?.stop()
            await githubMonitor?.stop()
            await calendarMonitor?.stop()
            await clipboardMonitor?.stop()
            await fsEventsMonitor?.stop()
            await keyboardMonitor?.stop()
            await webhookServer?.stop()
            await pluginManager?.stop()

            if let eventSubscriptionID {
                await eventBus.unsubscribe(eventSubscriptionID)
            }
        }
    }

    private func bootstrap() async {
        let configManager = ConfigManager()
        let databaseManager = DatabaseManager()
        L10n.locale = configManager.config.locale
        installMainMenuIfNeeded()
        let initialEndpointValue = Self.normalizedAIEndpoint(configManager.config.ollamaEndpoint)
        let initialBackend = Self.inferredAIBackend(
            preferred: Self.resolvedAIBackend(from: configManager.config.aiBackend),
            endpointValue: initialEndpointValue
        )
        let initialModel = Self.normalizedAIModel(configManager.config.ollamaModel, backend: initialBackend)
        let initialMCPServers = Self.decodedMCPServers(from: configManager.config.mcpServersJSON)
        let initialEndpoint = URL(string: initialEndpointValue) ?? URL(string: "http://localhost:11434")!
        let ollamaService = OllamaService(
            endpoint: initialEndpoint,
            model: initialModel,
            backend: initialBackend,
            openAIApiKey: configManager.config.openAIApiKey
        )
        self.ollamaService = ollamaService
        let initialMemoryConfig = Self.memoryWorkerConfig(from: configManager.config)
        if initialMemoryConfig.enabled {
            self.memoryWorkerService = MemoryWorkerService(config: initialMemoryConfig)
        } else {
            self.memoryWorkerService = nil
        }
        await ollamaService.updateMCPServers(initialMCPServers)
        await ollamaService.updateSystemPrompt(configManager.config.aiSystemPrompt)

        Task {
            await ollamaService.checkConnection()
            aiStatus = await ollamaService.status
        }

        let chatViewModel = ChatViewModel(
            sendToAI: { [weak self] message, _ in
                guard let self else {
                    throw OllamaServiceError.serviceUnavailable
                }

                guard let chatViewModel = await MainActor.run(body: { self.chatViewModel }) else {
                    throw OllamaServiceError.serviceUnavailable
                }

                let targetPetIDs = await MainActor.run {
                    self.resolvedConversationTargetPetIDs(for: chatViewModel)
                }
                let sessionId = await MainActor.run {
                    chatViewModel.selectedConversationId
                        ?? self.fallbackConversationId(for: targetPetIDs)
                        ?? "default"
                }
                let userSomersaultCount = await MainActor.run {
                    Self.parseSomersaultCount(from: message)
                }
                let preparedRequest = try await self.prepareConversationRequest(
                    text: message,
                    targetPetIDs: targetPetIDs,
                    sessionId: sessionId,
                    userSomersaultCount: userSomersaultCount,
                    markChatToolActions: true
                )
                return preparedRequest.stream
            },
            getAIStatus: {
                Self.chatUIStatus(from: await ollamaService.status)
            }
        )
        self.chatViewModel = chatViewModel
        chatViewModel.onUserSent = { [weak self, weak chatViewModel] in
            Task { @MainActor in
                guard let self else {
                    return
                }

                // 用户输入快路径：识别「翻N个跟头」直接触发，不依赖模型
                if let lastUser = chatViewModel?.currentMessages.last(where: { $0.role == .user })?.content,
                   let count = Self.parseSomersaultCount(from: lastUser) {
                    self.chatPathSomersaultFired = true
                    for controller in self.petWindowControllers.values {
                        controller.executeAIAction("somersault", count: count)
                    }
                    return  // somersault is its own reaction, skip generic userInteract
                }

                self.chatPathSomersaultFired = false
                self.chatPathToolActionFired = false
                for controller in self.petWindowControllers.values {
                    await controller.handleAnimationTrigger(.userInteract)
                }
            }
        }
        chatViewModel.onAssistantReplied = { [weak self, weak chatViewModel] in
            Task { @MainActor in
                guard let self else {
                    return
                }

                // 解析最后一条助手消息中的 [ACTION:...] 标签，触发动画并清理可见文本
                    var firedAnyAction = self.chatPathSomersaultFired || self.chatPathToolActionFired
                if let chatViewModel,
                   let last = chatViewModel.currentMessages.last,
                   last.role == .assistant {
                    let (cleanText, actions) = Self.parseActionTags(from: last.content)

                    for action in actions {
                        if action.name == "somersault" && self.chatPathSomersaultFired {
                            continue
                        }
                        for controller in self.petWindowControllers.values {
                            controller.executeAIAction(action.name, count: action.count)
                        }
                        firedAnyAction = true
                    }

                    if cleanText != last.content {
                        chatViewModel.replaceLastAssistantContent(cleanText)
                    }
                }

                // 兜底庆祝动画：只在没有任何具体动作被触发时才放，否则会盖掉刚开始的动作（比如翻跟头）
                if !firedAnyAction {
                    for controller in self.petWindowControllers.values {
                        await controller.handleAnimationTrigger(.custom("celebrate"))
                    }
                }

                self.chatPathSomersaultFired = false
                self.chatPathToolActionFired = false
                self.conversationTurnCount += 1
                if self.conversationTurnCount % Self.memoryExtractionEveryNTurns == 0 {
                    Task { await self.runMemoryExtractionCycle() }
                }
            }
        }
        chatViewModel.onConversationChanged = { [weak self] conversationId in
            guard let self else {
                return
            }

            Task {
                await self.ollamaService?.switchSession(conversationId)
            }
        }
        chatViewModel.onSlashCommand = { [weak self, weak chatViewModel] name, arguments in
            guard let self else { return false }
            return await self.handleChatSlashCommand(
                name: name,
                arguments: arguments,
                chatViewModel: chatViewModel
            )
        }
        chatViewModel.onCreateGroup = { [weak self] _, _ in
            guard let self, let databaseManager = self.databaseManager else {
                return
            }

            Task {
                do {
                    if let thread = chatViewModel.conversations.last(where: { $0.type == .group }) {
                        try await databaseManager.insertConversation(
                            id: thread.id,
                            type: thread.type.rawValue,
                            participantIds: thread.participantIds,
                            title: thread.title
                        )
                    }
                } catch {
                    AppLogger.error("Failed to create group: \(error.localizedDescription)")
                }
            }
        }
        let onSaveAIConfig: @MainActor (String, String, String, AIBackend, String, String) -> Void = { [weak self, weak configManager] endpoint, model, aiSystemPrompt, backend, openAIApiKey, mcpServersJSON in
            guard let self,
                  let configManager else {
                return
            }

            let trimmedPrompt = aiSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedOpenAIKey = openAIApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedMCPServersJSON = Self.normalizedMCPServersJSON(mcpServersJSON)
            let resolvedMCPServers = Self.decodedMCPServers(from: normalizedMCPServersJSON)
            let resolvedEndpointValue = Self.normalizedAIEndpoint(endpoint)
            let currentBackend = Self.inferredAIBackend(
                preferred: Self.resolvedAIBackend(from: configManager.config.aiBackend),
                endpointValue: configManager.config.ollamaEndpoint
            )
            let effectiveBackend = Self.inferredAIBackend(preferred: backend, endpointValue: resolvedEndpointValue)
            let resolvedModel = Self.normalizedAIModel(
                model,
                backend: effectiveBackend,
                previousBackend: currentBackend
            )
            let resolvedEndpoint = URL(string: resolvedEndpointValue) ?? URL(string: "http://localhost:11434")!

            do {
                try configManager.update {
                    $0.ollamaEndpoint = resolvedEndpointValue
                    $0.aiBackend = effectiveBackend.rawValue
                    $0.ollamaModel = resolvedModel
                    $0.openAIApiKey = trimmedOpenAIKey
                    $0.mcpServersJSON = normalizedMCPServersJSON
                    $0.aiSystemPrompt = trimmedPrompt
                }
            } catch {
                AppLogger.error("Failed to save AI config: \(error.localizedDescription)")
            }

            Task {
                await ollamaService.updateConfig(
                    endpoint: resolvedEndpoint,
                    model: resolvedModel,
                    backend: effectiveBackend,
                    openAIApiKey: trimmedOpenAIKey,
                    mcpServers: resolvedMCPServers
                )
                await ollamaService.updateSystemPrompt(trimmedPrompt)
                await ollamaService.checkConnection()
                self.aiStatus = await ollamaService.status
                chatViewModel.refreshStatus()
            }
        }
        let onSaveAIMemoryConfig: @MainActor (Bool, String, String, String, String, String, String, Int) -> Void = {
            [weak self, weak configManager] enabled, endpoint, authMode, username, secret, scope, subject, queryLimit in
            guard let self,
                  let configManager else {
                return
            }

            let resolvedEndpoint = Self.normalizedMemoryWorkerEndpoint(endpoint)
            let resolvedAuthMode = Self.resolvedMemoryWorkerAuthMode(from: authMode)
            let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedScope = Self.normalizedMemoryWorkerScope(scope)
            let resolvedSubject = Self.normalizedMemoryWorkerSubject(subject)
            let resolvedQueryLimit = Self.normalizedMemoryWorkerQueryLimit(queryLimit)

            do {
                try configManager.update {
                    $0.memoryWorkerEnabled = enabled
                    $0.memoryWorkerEndpoint = resolvedEndpoint
                    $0.memoryWorkerAuthMode = resolvedAuthMode.rawValue
                    $0.memoryWorkerUsername = trimmedUsername
                    $0.memoryWorkerSecret = trimmedSecret
                    $0.memoryWorkerScope = resolvedScope
                    $0.memoryWorkerSubject = resolvedSubject
                    $0.memoryWorkerQueryLimit = resolvedQueryLimit
                }
            } catch {
                AppLogger.error("Failed to save memory worker config: \(error.localizedDescription)")
                return
            }

            let memoryConfig = Self.memoryWorkerConfig(from: configManager.config)
            if memoryConfig.enabled {
                if let service = self.memoryWorkerService {
                    Task {
                        await service.updateConfig(memoryConfig)
                        await self.pushUnsyncedMemoriesToRemote()
                    }
                } else {
                    self.memoryWorkerService = MemoryWorkerService(config: memoryConfig)
                    Task {
                        await self.pushUnsyncedMemoriesToRemote()
                    }
                }
            } else {
                self.memoryWorkerService = nil
            }
        }
        let onTestConnection: @MainActor () -> Void = { [weak self] in
            Task {
                await ollamaService.checkConnection()
                chatViewModel.refreshStatus()
                self?.aiStatus = await ollamaService.status
            }
        }
        let onTestAIMemoryConnection: @MainActor () async -> String? = { [weak configManager] in
            guard let configManager else {
                return "配置管理器未初始化"
            }

            let resolvedConfig = Self.memoryWorkerConfig(from: configManager.config)
            let testConfig = MemoryWorkerConfig(
                enabled: true,
                endpoint: resolvedConfig.endpoint,
                authMode: resolvedConfig.authMode,
                username: resolvedConfig.username,
                secret: resolvedConfig.secret,
                namespace: resolvedConfig.namespace,
                scope: resolvedConfig.scope,
                subject: resolvedConfig.subject,
                queryLimit: resolvedConfig.queryLimit,
                createHorizon: resolvedConfig.createHorizon
            )

            let service = MemoryWorkerService(config: testConfig)

            do {
                _ = try await service.queryMemories(q: "connection test")
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        let onTestAIMemoryWrite: @MainActor () async -> String? = { [weak configManager] in
            guard let configManager else {
                return "配置管理器未初始化"
            }
            let resolvedConfig = Self.memoryWorkerConfig(from: configManager.config)
            guard resolvedConfig.enabled else {
                return "请先启用「远程记忆服务」"
            }
            let testConfig = MemoryWorkerConfig(
                enabled: true,
                endpoint: resolvedConfig.endpoint,
                authMode: resolvedConfig.authMode,
                username: resolvedConfig.username,
                secret: resolvedConfig.secret,
                namespace: resolvedConfig.namespace,
                scope: resolvedConfig.scope,
                subject: resolvedConfig.subject,
                queryLimit: resolvedConfig.queryLimit,
                createHorizon: resolvedConfig.createHorizon
            )
            let service = MemoryWorkerService(config: testConfig)
            let token = String(UUID().uuidString.prefix(8))
            do {
                _ = try await service.createMemory(
                    content: "VitaPet 写入自检 \(token)",
                    category: "fact",
                    importance: 1,
                    tags: ["vitapet-self-test", token]
                )
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        let onSaveNotificationConfig: @MainActor (String, Bool, Int, String) -> Void = { [weak configManager] token, enabled, port, secret in
            guard let configManager else {
                return
            }

            let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedPort = port > 0 ? port : 19280

            do {
                try configManager.update {
                    $0.githubToken = trimmedToken
                    $0.webhookEnabled = enabled
                    $0.webhookPort = resolvedPort
                    $0.webhookSecret = trimmedSecret
                }
            } catch {
                AppLogger.error("Failed to save notification config: \(error.localizedDescription)")
            }
        }

        do {
            try await databaseManager.initialize()
            try await databaseManager.migrateMemoryHashesToStableFingerprintIfNeeded()
        } catch {
            AppLogger.error("Failed to initialize database: \(error.localizedDescription)")
        }

        await ollamaService.setOnConversationUpdated { [weak databaseManager] role, content, sessionId, petId, petName in
            guard let databaseManager else {
                return
            }
            try? await databaseManager.insertConversationTurn(
                role: role,
                content: content,
                sessionId: sessionId,
                petId: petId,
                petName: petName
            )
        }

        self.databaseManager = databaseManager
        await syncFromRemoteMemories(databaseManager: databaseManager)
        await pushUnsyncedMemoriesToRemote()
        await refreshMemoryContext()
        startMemoryRemoteSyncTaskIfNeeded()
        Task {
            try? await databaseManager.pruneOldEvents(keepDays: 30)
        }
        self.configManager = configManager
        await warmupSecurityState()
        do {
            try installBuiltInPluginsIfNeeded()
        } catch {
            NSLog("[VitaPet] Failed to install built-in plugins: %@", error.localizedDescription)
        }
        do {
            try installBuiltInSpritePacksIfNeeded()
        } catch {
            NSLog("[VitaPet] Failed to install built-in sprite packs: %@", error.localizedDescription)
        }
        #if DEBUG
        let pluginLoader = PluginLoader(developerMode: true)
        #else
        let pluginLoader = PluginLoader(developerMode: false)
        #endif
        pluginManager = PluginManager(loader: pluginLoader, configManager: configManager)
        await pluginManager.setBubbleRequestHandler { [weak self] message in
            self?.primaryPetController?.showBubble(message)
        }
        await pluginManager.setMoodRequestHandler { [weak self] delta in
            guard let self else {
                return
            }

            for controller in self.petWindowControllers.values {
                Task { @MainActor in
                    await controller.adjustMood(by: delta)
                }
            }
        }
        await pluginManager.start(publishingTo: eventBus)
        let pluginSettingsViewModel = PluginSettingsViewModel(
            loadPlugins: { [weak pluginManager] in
                guard let pluginManager else {
                    return []
                }

                let plugins = await pluginManager.listPlugins()
                return plugins.map {
                    (
                        id: $0.id,
                        name: $0.name,
                        version: $0.version,
                        description: $0.description,
                        directory: $0.directory,
                        isDeclarative: $0.isDeclarative,
                        isBuiltIn: $0.isBuiltIn,
                        isEnabled: $0.isEnabled
                    )
                }
            },
            setEnabled: { [weak pluginManager] id, enabled in
                guard let pluginManager else {
                    return
                }

                try await pluginManager.setPluginEnabled(id: id, enabled: enabled)
            }
        )
        let activityLogViewModel = ActivityLogViewModel(
            loadEvents: { [weak databaseManager] limit, offset in
                guard let databaseManager else {
                    return []
                }

                return try await databaseManager.fetchRecentEvents(limit: limit, offset: offset).map {
                    ActivityLogViewModel.EventEntry(
                        id: $0.id,
                        timestamp: $0.timestamp,
                        source: $0.source,
                        payload: $0.payload
                    )
                }
            }
        )
        let statisticsViewModel = StatisticsViewModel(
            loadMoodHistory: { [weak databaseManager] petId, days in
                guard let databaseManager else {
                    return []
                }

                return try await databaseManager.fetchMoodHistory(petId: petId, days: days)
            },
            loadBehaviorCounts: { [weak databaseManager] days in
                guard let databaseManager else {
                    return []
                }

                return try await databaseManager.fetchPetBehaviorCounts(days: days)
            },
            loadDailyInteractions: { [weak databaseManager] days in
                guard let databaseManager else {
                    return []
                }

                return try await databaseManager.fetchDailyInteractionCounts(days: days)
            }
        )
        chatController = ChatWindowController(
            chatViewModel: chatViewModel,
            pluginSettingsViewModel: pluginSettingsViewModel,
            activityLogViewModel: activityLogViewModel,
            statisticsViewModel: statisticsViewModel
        )
        do {
            try await initializeConversations(
                chatViewModel: chatViewModel,
                databaseManager: databaseManager,
                ollamaService: ollamaService,
                pets: configManager.config.pets
            )
            try? await databaseManager.deleteOldTurns(keepLast: 100)
        } catch {
            AppLogger.error("Failed to initialize conversations: \(error.localizedDescription)")
        }
        spritePackManager = SpritePackManager()
        spritePackImporter = SpritePackImporter(manager: spritePackManager)
        chatController.configureChatConversations(
            listAvailablePets: { [weak self] in
                self?.configManager.config.pets.map { (id: $0.id, name: $0.name) } ?? []
            },
            onDeleteConversation: { [weak self] conversationId in
                guard let self, let databaseManager = self.databaseManager else {
                    return
                }

                Task {
                    try? await databaseManager.deleteConversation(id: conversationId)
                }
            },
            onUpdateConversationParticipants: { [weak self] conversationId, participantIds in
                guard let self, let databaseManager = self.databaseManager else {
                    return
                }

                Task {
                    try? await databaseManager.updateConversationParticipantIds(
                        id: conversationId,
                        participantIds: participantIds
                    )
                }
            }
        )
        chatController.configureStatistics(
            loadMoodHistory: { [weak databaseManager] petId, days in
                guard let databaseManager else {
                    return []
                }

                return try await databaseManager.fetchMoodHistory(petId: petId, days: days)
            },
            loadBehaviorCounts: { [weak databaseManager] days in
                guard let databaseManager else {
                    return []
                }

                return try await databaseManager.fetchPetBehaviorCounts(days: days)
            },
            loadDailyInteractions: { [weak databaseManager] days in
                guard let databaseManager else {
                    return []
                }

                return try await databaseManager.fetchDailyInteractionCounts(days: days)
            }
        )
        chatController.configurePluginCreation(
            onDeletePlugin: { [weak self] id in
                guard let self else {
                    return "Internal error"
                }

                do {
                    try await self.deletePlugin(id: id)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            },
            onRevealPluginInFinder: { [weak self] id in
                self?.revealPluginInFinder(id: id)
            },
            onReloadPlugins: { [weak self] in
                guard let self else {
                    return "Internal error"
                }

                await self.pluginManager.reloadPlugins()
                return nil
            },
            onCreatePlugin: { [weak self] name, description, template in
                guard let self else {
                    return "Internal error"
                }

                do {
                    try await self.createDeclarativePluginTemplate(
                        name: name,
                        description: description,
                        template: template
                    )
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }
        )
        chatController.configureAISettings(
            aiEndpoint: { [weak configManager] in
                configManager?.config.ollamaEndpoint ?? "http://localhost:11434"
            },
            aiBackend: { [weak configManager] in
                let endpoint = configManager?.config.ollamaEndpoint ?? ""
                let preferred = Self.resolvedAIBackend(from: configManager?.config.aiBackend ?? "ollama")
                return Self.inferredAIBackend(preferred: preferred, endpointValue: endpoint)
            },
            aiModel: { [weak configManager] in
                configManager?.config.ollamaModel ?? "llama3.2"
            },
            openAIApiKey: { [weak configManager] in
                configManager?.config.openAIApiKey ?? ""
            },
            mcpServersJSON: { [weak configManager] in
                configManager?.config.mcpServersJSON ?? ""
            },
            aiSystemPrompt: { [weak configManager] in
                configManager?.config.aiSystemPrompt ?? ""
            },
            memoryWorkerEnabled: { [weak configManager] in
                configManager?.config.memoryWorkerEnabled ?? false
            },
            memoryWorkerEndpoint: { [weak configManager] in
                configManager?.config.memoryWorkerEndpoint ?? "https://memory.example.com"
            },
            memoryWorkerAuthMode: { [weak configManager] in
                let rawValue = configManager?.config.memoryWorkerAuthMode ?? "basic"
                return Self.resolvedMemoryWorkerAuthMode(from: rawValue).rawValue
            },
            memoryWorkerUsername: { [weak configManager] in
                configManager?.config.memoryWorkerUsername ?? ""
            },
            memoryWorkerSecret: { [weak configManager] in
                configManager?.config.memoryWorkerSecret ?? ""
            },
            memoryWorkerScope: { [weak configManager] in
                configManager?.config.memoryWorkerScope ?? "user"
            },
            memoryWorkerSubject: { [weak configManager] in
                configManager?.config.memoryWorkerSubject ?? "demo-user"
            },
            memoryWorkerQueryLimit: { [weak configManager] in
                configManager?.config.memoryWorkerQueryLimit ?? 5
            },
            aiStatus: { [weak self] in
                Self.chatUIStatus(from: self?.aiStatus ?? .notConfigured)
            },
            onTestConnection: { [weak self] in
                onTestConnection()
                self?.aiStatus = .connecting
            },
            onTestAIMemoryConnection: onTestAIMemoryConnection,
            onTestAIMemoryWrite: onTestAIMemoryWrite,
            onSaveAIConfig: onSaveAIConfig,
            onSaveAIMemoryConfig: onSaveAIMemoryConfig
        )
        chatController.configureNotificationSettings(
            githubToken: { [weak configManager] in
                configManager?.config.githubToken ?? ""
            },
            webhookEnabled: { [weak configManager] in
                configManager?.config.webhookEnabled ?? false
            },
            webhookPort: { [weak configManager] in
                configManager?.config.webhookPort ?? 19280
            },
            webhookSecret: { [weak configManager] in
                configManager?.config.webhookSecret ?? ""
            },
            onSaveNotificationConfig: onSaveNotificationConfig
        )
        chatController.configureDesktopAwarenessSettings(
            isEnabled: { [weak self] in
                self?.desktopAwareness.isEnabled ?? true
            },
            rules: {
                AppBehaviorRules.loadRules()
            },
            onSetEnabled: { [weak self] enabled in
                self?.desktopAwareness.setEnabled(enabled)
            },
            onSaveRules: { [weak self] rules in
                do {
                    try AppBehaviorRules.saveRules(rules)
                    self?.desktopAwareness.reloadRules()
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }
        )
        chatController.configureSoundSettings(
            soundEnabled: {
                SoundManager().isEnabled
            },
            soundVolume: {
                Double(SoundManager().volume)
            },
            onSetSoundEnabled: { [weak self] enabled in
                let globalSoundManager = SoundManager()
                globalSoundManager.setEnabled(enabled)

                guard let self else {
                    return
                }

                for pet in self.configManager.config.pets where pet.soundEnabled == nil {
                    self.petWindowControllers[pet.id]?.soundManager?.applyRuntimeSettings(
                        enabled: enabled,
                        volume: self.resolvedVolume(for: pet)
                    )
                }
            },
            onSetSoundVolume: { [weak self] volume in
                let globalSoundManager = SoundManager()
                globalSoundManager.setVolume(volume)

                guard let self else {
                    return
                }

                for pet in self.configManager.config.pets where pet.soundVolume == nil {
                    self.petWindowControllers[pet.id]?.soundManager?.applyRuntimeSettings(
                        enabled: self.resolvedSoundEnabled(for: pet),
                        volume: volume
                    )
                }
            }
        )
        chatController.configureWeatherSettings(
            isEnabled: { [weak self] in
                self?.timeWeatherController.weatherEnabled ?? true
            },
            currentSummary: { [weak self] in
                self?.timeWeatherController.currentWeatherSummary
            },
            onSetEnabled: { [weak self] enabled in
                self?.timeWeatherController.setWeatherEnabled(enabled)
                self?.updateBehaviorMultipliers()
            },
            latitude: { [weak self] in
                self?.timeWeatherController.manualLatitude
            },
            longitude: { [weak self] in
                self?.timeWeatherController.manualLongitude
            },
            onSaveLocation: { [weak self] lat, lon in
                self?.timeWeatherController.manualLatitude = lat
                self?.timeWeatherController.manualLongitude = lon
                // 保存后立即刷新天气
                self?.timeWeatherController.refreshWeather()
            }
        )
        chatController.configureWeatherRefresh(
            refreshMinutes: { [weak self] in
                Int((self?.timeWeatherController.weatherRefreshInterval ?? 7200) / 60)
            },
            onSetInterval: { [weak self] interval in
                self?.timeWeatherController.weatherRefreshInterval = interval
                // 重启定时器
                if self?.timeWeatherController.weatherEnabled == true {
                    self?.timeWeatherController.stop()
                    self?.timeWeatherController.start()
                }
            }
        )
        chatController.configurePetManagement(
            petProfiles: { [weak self] in
                guard let self else {
                    return []
                }

                return self.configManager.config.pets.map {
                    PetProfileItem(
                        id: $0.id,
                        name: $0.name,
                        spritePack: $0.spritePack,
                        size: $0.size,
                        gender: $0.gender,
                        age: $0.age,
                        personality: $0.personality,
                        hobbies: $0.hobbies,
                        customLanguage: $0.customLanguage,
                        soundEnabled: $0.soundEnabled,
                        soundVolume: $0.soundVolume
                    )
                }
            },
            onUpdatePet: { [weak self] id, name, spritePack, size, gender, age, personality, hobbies in
                guard let self else {
                    return
                }

                do {
                    try self.configManager.update { config in
                        guard let index = config.pets.firstIndex(where: { $0.id == id }) else {
                            return
                        }

                        config.pets[index].name = name
                        config.pets[index].spritePack = spritePack
                        config.pets[index].size = size
                        config.pets[index].gender = gender
                        config.pets[index].age = age
                        config.pets[index].personality = personality
                        config.pets[index].hobbies = hobbies
                    }

                    if let controller = self.petWindowControllers[id] {
                        controller.selectSpritePack(id: spritePack)
                        controller.resizePet(to: CGFloat(size))
                    }

                    // 同步更新对话标题
                    let conversationId = "single_\(id.uuidString)"
                    self.chatViewModel.updateConversationTitle(conversationId, title: name)
                    Task {
                        try? await self.databaseManager?.updateConversationTitle(id: conversationId, title: name)
                    }
                } catch {
                    AppLogger.error("Failed to update pet: \(error.localizedDescription)")
                }
            },
            onUpdatePetSound: { [weak self] id, soundEnabled, soundVolume in
                guard let self else {
                    return
                }

                do {
                    var updatedPet: PetIdentity?
                    try self.configManager.update { config in
                        guard let index = config.pets.firstIndex(where: { $0.id == id }) else {
                            return
                        }

                        config.pets[index].soundEnabled = soundEnabled
                        config.pets[index].soundVolume = soundVolume
                        updatedPet = config.pets[index]
                    }

                    if let updatedPet {
                        self.applySoundOverrides(for: updatedPet)
                    }
                } catch {
                    AppLogger.error("Failed to update pet sound overrides: \(error.localizedDescription)")
                }
            },
            onUpdatePetLanguage: { [weak self] id, language in
                guard let self else {
                    return "AppDelegate 已释放"
                }

                do {
                    try self.configManager.update { config in
                        guard let index = config.pets.firstIndex(where: { $0.id == id }) else {
                            return
                        }

                        config.pets[index].customLanguage = language
                    }

                    self.petWindowControllers[id]?.setCustomLanguage(language)
                    return nil
                } catch {
                    AppLogger.error("Failed to update pet custom language: \(error.localizedDescription)")
                    return error.localizedDescription
                }
            },
            onRemovePet: { [weak self] id in
                self?.removePet(id: id)
            },
            onAddPet: { [weak self] in
                self?.addPet()
            },
            canAddMorePets: { [weak self] in
                (self?.petWindowControllers.count ?? 0) < (self?.maximumPets ?? 5)
            }
        )
        chatController.configureResetCallbacks(
            onResetLanguage: { [weak self] petId in
                guard let self else {
                    return
                }

                do {
                    try self.configManager.update { config in
                        guard let index = config.pets.firstIndex(where: { $0.id == petId }) else {
                            return
                        }

                        config.pets[index].customLanguage = nil
                    }

                    self.petWindowControllers[petId]?.setCustomLanguage(nil)
                } catch {
                    AppLogger.error("Failed to reset pet language: \(error.localizedDescription)")
                }
            },
            onResetAttributes: { [weak self] petId in
                guard let self else {
                    return
                }

                do {
                    var updatedPet: PetIdentity?
                    try self.configManager.update { config in
                        guard let index = config.pets.firstIndex(where: { $0.id == petId }) else {
                            return
                        }

                        config.pets[index].name = "Pet"
                        config.pets[index].size = 96
                        config.pets[index].gender = "neutral"
                        config.pets[index].age = ""
                        config.pets[index].personality = ""
                        config.pets[index].hobbies = ""
                        updatedPet = config.pets[index]
                    }

                    if let updatedPet {
                        self.petWindowControllers[petId]?.resizePet(to: CGFloat(updatedPet.size))
                    }
                } catch {
                    AppLogger.error("Failed to reset pet attributes: \(error.localizedDescription)")
                }
            },
            onResetAll: { [weak self] petId in
                guard let self else {
                    return
                }

                do {
                    var updatedPet: PetIdentity?
                    try self.configManager.update { config in
                        guard let index = config.pets.firstIndex(where: { $0.id == petId }) else {
                            return
                        }

                        config.pets[index].customLanguage = nil
                        config.pets[index].soundEnabled = nil
                        config.pets[index].soundVolume = nil
                        config.pets[index].name = "Pet"
                        config.pets[index].size = 96
                        config.pets[index].gender = "neutral"
                        config.pets[index].age = ""
                        config.pets[index].personality = ""
                        config.pets[index].hobbies = ""
                        updatedPet = config.pets[index]
                    }

                    self.petWindowControllers[petId]?.setCustomLanguage(nil)
                    if let updatedPet {
                        self.petWindowControllers[petId]?.resizePet(to: CGFloat(updatedPet.size))
                        self.applySoundOverrides(for: updatedPet)
                    }
                } catch {
                    AppLogger.error("Failed to reset pet settings: \(error.localizedDescription)")
                }
            }
        )
        chatController.configureSpritePackManagement(
            loadSpritePackItems: { [weak self] in
                guard self != nil else {
                    return []
                }

                let packs = SpritePackLoader.discoverPacks()
                return packs.map { pack in
                    let manifest = try? SpritePackLoader.loadManifest(from: pack.directory)
                    let stateCount = manifest?.states.count ?? 0
                    let totalFrameCount = manifest?.states.values.reduce(0) { $0 + $1.frames.count } ?? 0
                    return SpritePackDisplayItem(
                        id: pack.id,
                        name: pack.name,
                        directory: pack.directory,
                        stateCount: stateCount,
                        totalFrameCount: totalFrameCount,
                        isBuiltIn: SpritePackLoader.builtInPackIDs.contains(pack.id)
                    )
                }
            },
            selectedSpritePackID: { [weak self] in
                self?.primaryPetController?.currentSpritePackID ?? "PixelCat"
            },
            onSelectSpritePack: { [weak self] selectedID in
                self?.primaryPetController?.selectSpritePack(id: selectedID)
            },
            onImportPack: { [weak self] in
                guard let self else {
                    return "Internal error"
                }

                do {
                    let info = try await self.spritePackImporter.importFromPicker()
                    self.primaryPetController?.selectSpritePack(id: info.id)
                    return nil
                } catch {
                    if case SpritePackImporterError.cancelled = error {
                        return nil
                    }
                    if case let SpritePackImporterError.noManifest(folderURL) = error {
                        let detected = SpritePackBuilder.autoDetect(from: folderURL)
                        self.chatController.showSpritePackCreator(initialFrames: detected)
                        return nil
                    }
                    return error.localizedDescription
                }
            },
            onExportPack: { [weak self] packID in
                guard let self else {
                    return "Internal error"
                }

                let panel = NSSavePanel()
                panel.nameFieldStringValue = "\(packID).zip"
                panel.allowedContentTypes = [.zip]

                guard panel.runModal() == .OK, let url = panel.url else {
                    return nil
                }

                do {
                    try await self.spritePackManager.exportAsZip(packID: packID, to: url)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            },
            onDeletePack: { [weak self] packID in
                guard let self else {
                    return "Internal error"
                }

                do {
                    try await self.spritePackManager.delete(packID: packID)
                    if self.primaryPetController?.currentSpritePackID == packID {
                        self.primaryPetController?.selectSpritePack(id: "PixelCat")
                    }
                    return nil
                } catch {
                    return error.localizedDescription
                }
            },
            onRevealInFinder: { [weak self] packID in
                guard self != nil else {
                    return
                }

                let packs = SpritePackLoader.discoverPacks()
                if let pack = packs.first(where: { $0.id == packID }) {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: pack.directory.path)
                }
            },
            onCreateTemplate: { [weak self] in
                guard let self else {
                    return "Internal error"
                }

                self.chatController.showSpritePackCreator()
                return nil
            }
        )
        chatController.configureSpritePackCreator(
            onBuild: { [weak self] name, frames in
                guard let self else {
                    return "Internal error"
                }

                do {
                    let outputDirectory = SpritePackLoader.spritePacksDirectory()
                    let packURL = try SpritePackBuilder.build(
                        named: name,
                        frames: frames,
                        outputDirectory: outputDirectory
                    )
                    self.primaryPetController?.selectSpritePack(id: packURL.lastPathComponent)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }
        )
        inputBarController = InputBarWindowController()
        inputBarController.onSubmitWithTargets = { [weak self] text, targetPetIDs in
            guard let self else {
                return
            }

            let currentParticipants = Set(chatViewModel.currentParticipantIds)
            let effectiveTargetPetIDs = currentParticipants.isEmpty ? targetPetIDs : currentParticipants

            // 用户输入快路径：识别「翻N个跟头/跟斗/筋斗」直接触发，不依赖模型工具调用
            let userSomersaultCount = Self.parseSomersaultCount(from: text)

            Task { @MainActor in
                if chatViewModel.selectedConversationId == nil,
                   let fallbackConversationId = self.fallbackConversationId(for: effectiveTargetPetIDs) {
                    chatViewModel.selectConversation(fallbackConversationId)
                }

                for (id, controller) in self.petWindowControllers where effectiveTargetPetIDs.contains(id) {
                    await controller.handleAnimationTrigger(.userInteract)
                    if let count = userSomersaultCount {
                        controller.executeAIAction("somersault", count: count)
                    } else {
                        controller.showThinkingBubble()
                    }
                }
                chatViewModel.addExternalMessage(text)
            }

            Task {
                do {
                    let sessionId = await MainActor.run {
                        if let selectedConversationId = chatViewModel.selectedConversationId {
                            return selectedConversationId
                        }
                        return self.fallbackConversationId(for: effectiveTargetPetIDs) ?? "default"
                    }
                    let preparedRequest = try await self.prepareConversationRequest(
                        text: text,
                        targetPetIDs: effectiveTargetPetIDs,
                        sessionId: sessionId,
                        userSomersaultCount: userSomersaultCount,
                        markChatToolActions: false
                    )
                    let stream = preparedRequest.stream
                    let targetPets = preparedRequest.targetPets
                    let isGroupChat = preparedRequest.isGroupChat

                    var fullResponse = ""
                    for try await chunk in stream {
                        fullResponse += chunk
                    }

                    await MainActor.run {
                        // 无论是否有内容，都清除 thinking 状态
                        for (id, controller) in self.petWindowControllers where effectiveTargetPetIDs.contains(id) {
                            controller.dismissThinkingBubble()
                        }

                        if !fullResponse.isEmpty {
                            // Parse [ACTION:xxx] tags from text (fallback for models without tool calling)
                            let (cleanText, actions) = Self.parseActionTags(from: fullResponse)

                            for action in actions {
                                if action.name == "somersault" && userSomersaultCount != nil {
                                    continue
                                }
                                for (id, controller) in self.petWindowControllers where effectiveTargetPetIDs.contains(id) {
                                    controller.executeAIAction(action.name, count: action.count)
                                }
                            }

                            let displayText = ThinkingStripper.strip(cleanText)
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            if !displayText.isEmpty {
                                if isGroupChat {
                                    let petResponses = Self.parsePetResponses(from: displayText)

                                    if petResponses.isEmpty {
                                        for (id, controller) in self.petWindowControllers where effectiveTargetPetIDs.contains(id) {
                                            controller.showAIBubble(displayText)
                                        }
                                        chatViewModel.addAssistantMessage(displayText, displayThinking: false)
                                    } else {
                                        for (petName, message) in petResponses {
                                            let strippedMessage = ThinkingStripper.strip(message)
                                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                            let pet = targetPets.first(where: { $0.name == petName })
                                            if let pet,
                                               let controller = self.petWindowControllers[pet.id] {
                                                controller.showAIBubble(strippedMessage)
                                            }
                                            chatViewModel.addAssistantMessage(
                                                strippedMessage,
                                                petId: pet?.id,
                                                petName: petName,
                                                displayThinking: false
                                            )
                                        }
                                    }
                                } else {
                                    let targetPet = targetPets.first
                                    for (id, controller) in self.petWindowControllers where effectiveTargetPetIDs.contains(id) {
                                        controller.showAIBubble(displayText)
                                    }
                                    chatViewModel.addAssistantMessage(
                                        displayText,
                                        petId: targetPet?.id,
                                        petName: targetPet?.name,
                                        displayThinking: false
                                    )
                                }

                                if let conversationId = chatViewModel.selectedConversationId {
                                    Task {
                                        try? await databaseManager.updateConversationLastMessage(
                                            id: conversationId,
                                            message: String(displayText.prefix(50)),
                                            timestamp: Date()
                                        )
                                    }
                                }
                            }
                        }
                    }

                    self.conversationTurnCount += 1
                    if self.conversationTurnCount % Self.memoryExtractionEveryNTurns == 0 {
                        Task {
                            await self.runMemoryExtractionCycle()
                        }
                    }
                } catch {
                    await MainActor.run {
                        for (id, controller) in self.petWindowControllers where effectiveTargetPetIDs.contains(id) {
                            controller.dismissThinkingBubble()
                        }
                        let errorText = "Error: \(error.localizedDescription)"
                        for (id, controller) in self.petWindowControllers where effectiveTargetPetIDs.contains(id) {
                            controller.showAIBubble(errorText)
                        }
                    }
                }
            }
        }
        inputBarController.onSubmitToConversation = { [weak self] text, conversationId in
            guard let self else { return }
            // Switch to conversation and get participants
            self.chatViewModel.selectConversation(conversationId)
            let participantIds = Set(self.chatViewModel.currentParticipantIds)
            // Reuse existing target-based flow
            self.inputBarController.onSubmitWithTargets?(text, participantIds)
        }
        statusBarController = StatusBarController(
            chatController: chatController,
            isPetVisible: { [weak self] in self?.isAnyPetVisible ?? false },
            togglePetVisibility: { [weak self] in self?.togglePetVisibility() },
            currentPetSize: { [weak self] in self?.currentGlobalPetSize ?? 96 },
            currentMoodLevel: { [weak self] in self?.primaryPetController?.currentMoodLevel ?? .normal },
            resizePets: { [weak self] size in self?.resizePets(to: size) },
            canAddPet: { [weak self] in (self?.petWindowControllers.count ?? 0) < (self?.maximumPets ?? 5) },
            addPet: { [weak self] in self?.addPet() },
            removePet: { [weak self] id in self?.removePet(id: id) },
            listPets: { [weak self] in
                guard let self else { return [] }
                return self.configManager.config.pets.map { (id: $0.id, name: $0.name) }
            },
            pomodoroMenuState: { [weak self] in
                guard let self else {
                    return StatusBarController.PomodoroMenuState(
                        startEnabled: true,
                        pauseTitle: "暂停",
                        pauseEnabled: false,
                        resetEnabled: false,
                        skipEnabled: false
                    )
                }

                let isIdle = self.pomodoroController.state == .idle
                let isPaused = self.pomodoroController.isPaused
                return StatusBarController.PomodoroMenuState(
                    startEnabled: isIdle,
                    pauseTitle: isPaused ? "继续" : "暂停",
                    pauseEnabled: !isIdle,
                    resetEnabled: !isIdle || self.pomodoroController.remainingSeconds > 0,
                    skipEnabled: !isIdle
                )
            },
            startPomodoro: { [weak self] in self?.pomodoroController.start() },
            pauseOrResumePomodoro: { [weak self] in
                guard let self else {
                    return
                }
                if self.pomodoroController.isPaused {
                    self.pomodoroController.resume()
                } else {
                    self.pomodoroController.pause()
                }
            },
            resetPomodoro: { [weak self] in self?.pomodoroController.reset() },
            skipPomodoro: { [weak self] in self?.pomodoroController.skip() },
            debugTriggerAnimation: { [weak self] name in
                self?.primaryPetController?.debugPlayAnimation(name)
            },
            debugTriggerBehavior: { [weak self] name in
                self?.primaryPetController?.debugExecuteBehavior(name)
            },
            debugListBehaviors: { [weak self] in
                self?.primaryPetController?.debugListBehaviors() ?? []
            }
        )
        statusBarController.availableMiniGames = { [weak self] in
            self?.miniGameManager.availableGames().map(\.name) ?? []
        }
        statusBarController.onStartGame = { [weak self] gameName in
            self?.miniGameManager.startGame(named: gameName)
        }
        interactionManager = PetInteractionManager()
        interactionManager.onInteractionTriggered = { [weak self] type, petNames in
            guard let databaseManager = self?.databaseManager else {
                return
            }

            Task {
                do {
                    try await databaseManager.insertEvent(
                        source: "petInteraction",
                        payload: try Self.encodePetInteractionPayload(
                            PetInteractionEventPayload(type: type, pets: petNames)
                        )
                    )
                } catch {
                    AppLogger.error("Failed to record pet interaction: \(error.localizedDescription)")
                }
            }
        }
        miniGameManager.configure(
            getPetControllers: { [weak self] in
                guard let self, let configManager = self.configManager else { return [] }
                return configManager.config.pets.compactMap { self.petWindowControllers[$0.id] }
            },
            onGameStateChanged: { [weak self] isPlaying in
                self?.setMiniGameSystemsPaused(isPlaying)
            }
        )
        miniGameManager.onGameStarted = { [weak self] gameName, petCount in
            guard let databaseManager = self?.databaseManager else {
                return
            }

            Task {
                do {
                    try await databaseManager.insertEvent(
                        source: "gamePlay",
                        payload: try Self.encodeGamePlayPayload(
                            GamePlayEventPayload(game: gameName, petCount: petCount)
                        )
                    )
                } catch {
                    AppLogger.error("Failed to record game start: \(error.localizedDescription)")
                }
            }
        }
        pomodoroController.getPetControllers = { [weak self] in
            guard let self else {
                return []
            }
            return self.configManager.config.pets.compactMap { self.petWindowControllers[$0.id] }
        }
        pomodoroController.onStateChanged = { [weak self] _, _ in
            self?.statusBarController?.refreshPomodoroMenuState()
        }

        for pet in configManager.config.pets {
            createAndShowPetController(for: pet)
        }
        desktopAwareness.getPetControllers = { [weak self] in
            guard let self else { return [] }
            return Array(self.petWindowControllers.values)
        }
        updateBehaviorMultipliers()
        timeWeatherController.onTimePeriodChanged = { [weak self] oldPeriod, newPeriod in
            guard let self else { return }

            self.updateBehaviorMultipliers()

            for controller in self.petWindowControllers.values {
                Task {
                    await controller.adjustMood(by: newPeriod.moodDelta)
                }
            }

            if oldPeriod == .night && newPeriod == .dawn {
                for controller in self.petWindowControllers.values {
                    controller.transitionToState("idle")
                    controller.showBubble(newPeriod.greeting ?? "早上好~")
                }
            } else if newPeriod == .night {
                for (index, controller) in self.petWindowControllers.values.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.5) {
                        controller.transitionToState("sleep")
                        if let greeting = newPeriod.greeting {
                            controller.showBubble(greeting)
                        }
                    }
                }
            } else if let greeting = newPeriod.greeting {
                self.primaryPetController?.showBubble(greeting)
            }
        }
        timeWeatherController.onWeatherUpdated = { [weak self] weather in
            guard let self else { return }

            self.updateBehaviorMultipliers()
            self.primaryPetController?.showBubble(weather.bubble)

            let delta = weather.moodDelta + weather.temperatureMoodDelta
            guard delta != 0 else {
                return
            }

            for controller in self.petWindowControllers.values {
                Task {
                    await controller.adjustMood(by: delta)
                }
            }
        }
        timeWeatherController.onMoodDecay = { [weak self] in
            guard let self else { return }

            for controller in self.petWindowControllers.values {
                Task {
                    let currentHappiness = await controller.petMood.happiness
                    let delta = currentHappiness > 50 ? -1 : (currentHappiness < 50 ? 1 : 0)
                    if delta != 0 {
                        await controller.adjustMood(by: delta)
                    }
                }
            }
        }
        timeWeatherController.start()

        // Populate available actions for AI system prompt
        let behaviorActions = primaryPetController?.debugListBehaviors() ?? []
        let animActions = AnimationState.allCases.filter { $0 != .idle && $0 != .drag }.map(\.rawValue)
        let initialActions = Array(Set(behaviorActions + animActions)).sorted()
        await ollamaService.updateAvailableActions(initialActions)

        aiProactiveTrigger = AIProactiveTrigger(
            ollamaService: ollamaService,
            configManager: configManager,
            moodProvider: { [weak self] in
                self?.primaryPetController?.currentMoodLevel ?? .normal
            },
            onMessage: { [weak self] message in
                self?.primaryPetController?.showBubble(message)
            },
            onAction: { [weak self] action in
                guard let self else { return }
                for controller in self.petWindowControllers.values {
                    controller.executeAIAction(action)
                }
            }
        )
        aiProactiveTrigger?.start()

        timerSource = TimerSource(interval: 10.0)
        hourBoundaryTimer = HourBoundaryTimerSource()
        sitReminderTimer = TimerSource(interval: 1800, sourceId: "sit-reminder")
        workspaceMonitor = WorkspaceMonitor()
        notificationMonitor = NotificationMonitor()
        githubMonitor = GitHubMonitor(tokenProvider: { [weak configManager] in
            await MainActor.run {
                configManager?.config.githubToken ?? ""
            }
        })
        calendarMonitor = CalendarMonitor()
        clipboardMonitor = await ClipboardMonitor()
        fsEventsMonitor = FSEventsMonitor(paths: [NSHomeDirectory()])
        // 请求辅助功能权限（全局快捷键需要）
        requestAccessibilityPermission()
        keyboardMonitor = KeyboardMonitor()
        if configManager.config.webhookEnabled {
            webhookServer = WebhookServer(port: UInt16(configManager.config.webhookPort), secret: configManager.config.webhookSecret)
        }

        eventSubscriptionID = await eventBus.subscribe { [weak self] event in
            guard let self else {
                return
            }

            await self.handleEvent(event)
        }

        await timerSource.start(publishingTo: eventBus)
        await hourBoundaryTimer.start(publishingTo: eventBus)
        await sitReminderTimer.start(publishingTo: eventBus)
        await workspaceMonitor.start(publishingTo: eventBus)
        await notificationMonitor.start(publishingTo: eventBus)
        await githubMonitor.start(publishingTo: eventBus)
        await calendarMonitor.start(publishingTo: eventBus)
        await clipboardMonitor.start(publishingTo: eventBus)
        await fsEventsMonitor.start(publishingTo: eventBus)
        await keyboardMonitor.start(publishingTo: eventBus)
        await webhookServer?.start(publishingTo: eventBus)
    }

    private func handleEvent(_ event: AppEvent) async {
        recordEvent(event)

        if case .custom(let name, let payload) = event, name == "plugin.notification.request" {
            showNotification(
                title: payload["title"] ?? "VitaPet",
                body: payload["body"] ?? ""
            )
        }

        if case let .notificationReceived(source, title, body) = event {
            let fallbackText = body.isEmpty ? "[\(source)] \(title)" : "[\(source)] \(title)\n\(body)"
            let animState: AnimationState = (source == "GitHub" || source == "Calendar") ? .alert : .listen

            for controller in petWindowControllers.values {
                controller.petScene.playAnimation(for: animState)
            }

            // Try AI-enhanced display if Ollama is ready
            if let ollamaService {
                Task {
                    do {
                        let context = "你收到一条通知：来源=\(source)，标题=\(title)，内容=\(body)。用一句可爱的话转述给主人。"
                        let aiText = try await ollamaService.generateProactive(context: context)
                        await MainActor.run {
                            self.primaryPetController?.showBubble(aiText.isEmpty ? fallbackText : aiText)
                        }
                    } catch {
                        await MainActor.run {
                            self.primaryPetController?.showBubble(fallbackText)
                        }
                    }
                }
            } else {
                primaryPetController?.showBubble(fallbackText)
            }
        }

        if case let .hotkeyPressed(keyCode, modifiers) = event,
           KeyboardMonitor.isChatHotkey(keyCode: keyCode, modifiers: modifiers) {
            let conversations = self.chatViewModel.conversations.map {
                (id: $0.id, title: $0.title, type: $0.type.rawValue)
            }
            inputBarController.configureConversations(
                conversations,
                selectedId: self.chatViewModel.selectedConversationId
            )
            inputBarController.show()
        }

        if case .timerFired = event, interactionManager.canInteract {
            if !miniGameManager.isPlaying, Double.random(in: 0...1) < 0.15 {
                interactionManager.triggerRandomInteraction()
            }
        }

        if case let .appActivated(bundleId, appName) = event {
            guard !miniGameManager.isPlaying else { return }
            desktopAwareness.handleAppActivated(bundleId: bundleId, appName: appName)
        }

        // 不在 appDeactivated 时清除桌面行为——让 appActivated 的新规则覆盖
        // 如果新应用没有匹配规则，handleAppActivated 内部会清除

        // 桌面感知激活时，不再走通用的 animationTrigger 路径（避免覆盖）
        if case .appActivated = event { return }
        if case .appDeactivated = event { return }

        guard let trigger = animationTrigger(for: event) else {
            return
        }

        if miniGameManager.isPlaying, case .timer = trigger {
            return
        }

        for controller in petWindowControllers.values {
            await controller.handleAnimationTrigger(trigger)
        }
    }

    func addPet() {
        guard petWindowControllers.count < maximumPets else {
            return
        }

        let existingNames = Set(configManager.config.pets.map(\.name))
        var counter = petWindowControllers.count + 1
        var newName = "Pet \(counter)"
        while existingNames.contains(newName) {
            counter += 1
            newName = "Pet \(counter)"
        }

        let basePet = primaryPetController.map { controller in
            PetIdentity(
                id: UUID(),
                name: newName,
                spritePack: controller.currentSpritePackID,
                size: Double(controller.currentPetSize),
                positionX: Double((controller.window?.frame.origin.x ?? 120) + 36),
                positionY: Double((controller.window?.frame.origin.y ?? 120) + 36)
            )
        } ?? PetIdentity.defaultPet()

        let pet = basePet.positionX == 120 && basePet.positionY == 120 && petWindowControllers.isEmpty
            ? basePet
            : PetIdentity(
                id: basePet.id,
                name: basePet.name,
                spritePack: basePet.spritePack,
                size: basePet.size,
                positionX: basePet.positionX,
                positionY: basePet.positionY
            )

        do {
            try configManager.update { $0.pets.append(pet) }
        } catch {
            AppLogger.error("Failed to add pet: \(error.localizedDescription)")
            return
        }

        Task {
            await self.createSingleConversationIfNeeded(for: pet)
        }

        createAndShowPetController(for: pet)
        refreshChatIfOpen()
    }

    func removePet(id: UUID) {
        guard petWindowControllers.count > 1 else {
            return
        }

        petWindowControllers[id]?.closePet()
        petWindowControllers[id] = nil
        interactionManager?.unregister(id: id)

        do {
            try configManager.update { config in
                config.pets.removeAll { $0.id == id }
            }
        } catch {
            AppLogger.error("Failed to remove pet: \(error.localizedDescription)")
            return
        }

        // 清理对话：直接操作数据库 + 内存
        chatController.removePetConversations(petId: id)
        // 数据库层面也直接删除单聊（避免内存未加载时遗漏）
        Task {
            try? await databaseManager?.deleteConversation(id: "single_\(id.uuidString)")
            // 查询数据库中包含该宠物的群聊并清理
            if let conversations = try? await databaseManager?.fetchConversations() {
                for conv in conversations where conv.type == .group && conv.participantIds.contains(id) {
                    let remaining = conv.participantIds.filter { $0 != id }
                    if remaining.count <= 1 {
                        try? await databaseManager?.deleteConversation(id: conv.id)
                    } else {
                        try? await databaseManager?.updateConversationParticipantIds(id: conv.id, participantIds: remaining)
                    }
                }
            }
        }
        refreshChatIfOpen()
    }

    private func refreshChatIfOpen() {
        guard chatController.window?.title == "VitaPet Chat" else {
            return
        }
        chatController.showChat()
    }

    private func initializeConversations(
        chatViewModel: ChatViewModel,
        databaseManager: DatabaseManager,
        ollamaService: OllamaService,
        pets: [PetIdentity]
    ) async throws {
        var conversations = try await databaseManager.fetchConversations()

        let legacyDefaultTurns = try await databaseManager.fetchRecentTurns(sessionId: "default", limit: 50)
        if !legacyDefaultTurns.isEmpty, !conversations.contains(where: { $0.id == "default" }) {
            let thread = ConversationThread(
                id: "default",
                type: .single,
                participantIds: [],
                title: "Legacy Chat"
            )
            try await databaseManager.insertConversation(
                id: thread.id,
                type: thread.type.rawValue,
                participantIds: thread.participantIds,
                title: thread.title
            )
            if let lastTurn = legacyDefaultTurns.last {
                try? await databaseManager.updateConversationLastMessage(
                    id: thread.id,
                    message: String(lastTurn.content.prefix(50)),
                    timestamp: Date()
                )
            }
        }

        let legacyGroupTurns = try await databaseManager.fetchRecentTurns(sessionId: "group", limit: 50)
        if !legacyGroupTurns.isEmpty, !conversations.contains(where: { $0.id == "group" }) {
            let thread = ConversationThread(
                id: "group",
                type: .group,
                participantIds: pets.map(\.id),
                title: "Legacy Group"
            )
            try await databaseManager.insertConversation(
                id: thread.id,
                type: thread.type.rawValue,
                participantIds: thread.participantIds,
                title: thread.title
            )
            if let lastTurn = legacyGroupTurns.last {
                try? await databaseManager.updateConversationLastMessage(
                    id: thread.id,
                    message: String(lastTurn.content.prefix(50)),
                    timestamp: Date()
                )
            }
        }

        for pet in pets {
            let singleId = "single_\(pet.id.uuidString)"
            if let existing = conversations.first(where: { $0.id == singleId }) {
                // 同步标题（宠物可能被改过名）
                if existing.title != pet.name {
                    try? await databaseManager.updateConversationTitle(id: singleId, title: pet.name)
                }
            } else {
                let thread = ConversationThread(
                    id: singleId,
                    type: .single,
                    participantIds: [pet.id],
                    title: pet.name
                )
                try await databaseManager.insertConversation(
                    id: thread.id,
                    type: thread.type.rawValue,
                    participantIds: thread.participantIds,
                    title: thread.title
                )
            }
        }

        conversations = try await databaseManager.fetchConversations()
        chatViewModel.loadConversations(conversations)

        for conversation in conversations {
            let turns = try await databaseManager.fetchRecentTurns(sessionId: conversation.id, limit: 50)
            let messages = turns.map {
                ChatMessage(
                    role: ChatUI.ChatMessage.Role(rawValue: $0.role) ?? ChatUI.ChatMessage.Role.user,
                    content: $0.content,
                    petId: $0.petId.flatMap(UUID.init(uuidString:)),
                    petName: $0.petName
                )
            }
            chatViewModel.loadMessages(for: conversation.id, messages: messages)
            await ollamaService.loadHistory(
                turns: turns.map { ($0.role, $0.content) },
                sessionId: conversation.id
            )
        }

        if let selectedConversationId = chatViewModel.selectedConversationId {
            await ollamaService.switchSession(selectedConversationId)
        }
    }

    private func createSingleConversationIfNeeded(for pet: PetIdentity) async {
        guard let databaseManager, let chatViewModel else {
            return
        }

        let singleId = "single_\(pet.id.uuidString)"
        if chatViewModel.conversations.contains(where: { $0.id == singleId }) {
            return
        }

        let thread = ConversationThread(
            id: singleId,
            type: .single,
            participantIds: [pet.id],
            title: pet.name
        )

        chatViewModel.addConversation(thread)

        do {
            try await databaseManager.insertConversation(
                id: thread.id,
                type: thread.type.rawValue,
                participantIds: thread.participantIds,
                title: thread.title
            )
        } catch {
            AppLogger.error("Failed to create single conversation: \(error.localizedDescription)")
        }
    }

    private func fallbackConversationId(for participantIds: Set<UUID>) -> String? {
        guard !participantIds.isEmpty else {
            return nil
        }

        if participantIds.count == 1, let singleId = participantIds.first {
            return "single_\(singleId.uuidString)"
        }

        return chatViewModel.conversations.first(where: {
            $0.type == .group && Set($0.participantIds) == participantIds
        })?.id
    }

    private func recordEvent(_ event: AppEvent) {
        guard let databaseManager else {
            return
        }

        Task {
            do {
                try await databaseManager.insertEvent(
                    source: event.caseName,
                    payload: try Self.encodeEventPayload(from: event.metadata)
                )
            } catch {
                AppLogger.error("Failed to record event: \(error.localizedDescription)")
            }
        }
    }

    private func animationTrigger(for event: AppEvent) -> AnimationTrigger? {
        switch event {
        case .timerFired:
            return .timer
        case .appActivated(let bundleId, _):
            return AppBehaviorRules.matchAnimationTrigger(for: bundleId) ?? .appSwitch
        case .appDeactivated:
            return .appSwitch
        case .notificationReceived:
            return .custom("alert")
        case .focusEntered:
            return .focusEnter
        case .focusExited:
            return .focusExit
        case .custom(let name, _):
            return .custom(name)
        case .fileChanged, .clipboardChanged, .hotkeyPressed:
            return nil
        }
    }

    private func warmupSecurityState() async {
        _ = PermissionGate.checkPermission(.accessibility)
        _ = await capabilityManager.status(of: .basePet)
    }

    // MARK: - Memory pipeline

    private static func memoryContentHash(_ content: String) -> String {
        MemoryContentHasher.stableHash(content)
    }

    /// Full extraction cycle: pulls recent turns, asks LLM to extract structured memories,
    /// dedups against existing local rows (by content_hash), inserts new ones, pushes to
    /// remote if configured, and refreshes the LLM context.
    private func runMemoryExtractionCycle() async {
        guard let ollamaService = self.ollamaService,
              let databaseManager = self.databaseManager else {
            return
        }

        do {
            let recentTurns = try await databaseManager.fetchRecentTurns(limit: 20)
            guard !recentTurns.isEmpty else {
                AppLogger.info("Memory extraction skipped: no recent turns")
                await pushUnsyncedMemoriesToRemote()
                await refreshMemoryContext()
                return
            }

            AppLogger.info("Memory extraction starting from \(recentTurns.count) turns")
            let extracted = try await ollamaService.extractStructuredMemories(
                from: recentTurns.map { (role: $0.role, content: $0.content) }
            )
            AppLogger.info("Memory extraction returned \(extracted.count) candidates")
            guard !extracted.isEmpty else {
                await pushUnsyncedMemoriesToRemote()
                await refreshMemoryContext()
                return
            }

            for memory in extracted {
                let hash = Self.memoryContentHash(memory.content)
                if (try? await databaseManager.memoryExists(contentHash: hash)) == true {
                    continue
                }

                do {
                    let localId = try await databaseManager.insertMemory(
                        content: memory.content,
                        category: memory.category.rawValue,
                        importance: memory.importance,
                        source: "auto",
                        contentHash: hash
                    )

                    if let memoryWorkerService = self.memoryWorkerService {
                        do {
                            let remote = try await memoryWorkerService.createMemory(
                                content: memory.content,
                                category: memory.category.rawValue,
                                importance: memory.importance,
                                tags: ["auto", memory.category.rawValue]
                            )
                            let remoteId = remote.id.map(String.init)
                            do {
                                try await databaseManager.markMemorySynced(id: localId, remoteId: remoteId)
                            } catch {
                                AppLogger.error(
                                    "Remote memory created but failed to mark synced locally: \(error.localizedDescription)"
                                )
                            }
                        } catch {
                            AppLogger.error("Failed to create remote memory: \(error.localizedDescription)")
                        }
                    }
                } catch {
                    AppLogger.error("Failed to insert memory: \(error.localizedDescription)")
                }
            }

            await pushUnsyncedMemoriesToRemote()
            await refreshMemoryContext()
        } catch {
            AppLogger.error("Memory extraction cycle failed: \(error.localizedDescription)")
            await pushUnsyncedMemoriesToRemote()
            await refreshMemoryContext()
        }
    }

    /// 启动一个后台任务，周期性 flush 未同步记忆。重复调用会先取消旧任务。
    /// 即便 `memoryWorkerService` 暂时为 nil 也无所谓——`pushUnsyncedMemoriesToRemote` 会直接返回。
    private func startMemoryRemoteSyncTaskIfNeeded() {
        memoryRemoteSyncTask?.cancel()
        memoryRemoteSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: AppDelegate.memoryRemoteFlushInterval)
                } catch {
                    return
                }
                guard let self else { return }
                await self.pushUnsyncedMemoriesToRemote()
            }
        }
    }

    /// 当前本地存在、但还没被远端确认的记忆条数。0 表示一切都已同步。
    func unsyncedMemoryCount() async -> Int {
        guard let databaseManager = self.databaseManager else { return 0 }
        return (try? await databaseManager.unsyncedMemoryCount()) ?? 0
    }

    /// 立即触发一次推送，返回此前未同步的条数（用于在 UI 里给一个明确的反馈）。
    @discardableResult
    func flushUnsyncedMemoriesNow() async -> Int {
        let before = await unsyncedMemoryCount()
        await pushUnsyncedMemoriesToRemote()
        return before
    }

    /// Uploads local rows that never got `synced_at` (e.g. worker was off or the network failed once).
    private func pushUnsyncedMemoriesToRemote() async {
        guard let databaseManager = self.databaseManager,
              let memoryWorkerService = self.memoryWorkerService else {
            return
        }

        do {
            let pending = try await databaseManager.fetchUnsyncedMemoryRecords(limit: 200)
            guard !pending.isEmpty else { return }

            AppLogger.info("Memory worker: uploading \(pending.count) previously unsynced local memories")
            for record in pending {
                do {
                    var tags = [record.source, record.category].map {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    }.filter { !$0.isEmpty }
                    if tags.isEmpty {
                        tags = ["auto"]
                    }
                    let remote = try await memoryWorkerService.createMemory(
                        content: record.content,
                        category: record.category,
                        importance: record.importance,
                        tags: tags
                    )
                    try await databaseManager.markMemorySynced(
                        id: record.id,
                        remoteId: remote.id.map(String.init)
                    )
                } catch {
                    AppLogger.error(
                        "Failed to push unsynced memory id=\(record.id): \(error.localizedDescription)"
                    )
                }
            }
        } catch {
            AppLogger.error("Failed to read unsynced memories: \(error.localizedDescription)")
        }
    }

    /// Recompute and push the memory block to the current AI service.
    @discardableResult
    func refreshMemoryContext() async -> [DatabaseManager.MemoryRecord] {
        guard let databaseManager = self.databaseManager else { return [] }

        let local = (try? await databaseManager.fetchMemoryRecords(limit: 40)) ?? []
        let items = local.map {
            MemoryContextItem(
                content: $0.content,
                category: MemoryCategory(rawValue: $0.category) ?? .fact,
                importance: $0.importance
            )
        }

        await ollamaService?.updateStructuredMemories(items)
        return local
    }

    enum ManualMemoryOutcome {
        /// 已存入；`storedContent` 是最终落库的文本，`synthesized=true` 表示走了 LLM 合成。
        case inserted(storedContent: String, category: MemoryCategory, synthesized: Bool)
        case duplicate
        case failed
    }

    /// Record a memory the user explicitly asked to remember (slash command / menu).
    /// 走一次 LLM 合成：把用户原话改写成第三人称陈述（"用户……"），再入库 + 推远端。
    /// 合成失败或 LLM 不可用时回退到原话，避免命令完全失败。
    @discardableResult
    func recordManualMemory(content: String, category: MemoryCategory = .fact) async -> ManualMemoryOutcome {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let databaseManager = self.databaseManager else { return .failed }

        let synthesized: ExtractedMemory? = await synthesizeManualMemory(rawInput: trimmed)
        let storedContent = synthesized?.content ?? trimmed
        let storedCategory = synthesized?.category ?? category
        // 用户主动 /记住 默认仍按高优先级处理，不让 LLM 把它压到 1。
        let storedImportance = max(3, synthesized?.importance ?? 3)
        let didSynthesize = synthesized != nil

        let hash = Self.memoryContentHash(storedContent)
        if (try? await databaseManager.memoryExists(contentHash: hash)) == true {
            await refreshMemoryContext()
            return .duplicate
        }

        do {
            let localId = try await databaseManager.insertMemory(
                content: storedContent,
                category: storedCategory.rawValue,
                importance: storedImportance,
                source: "manual",
                contentHash: hash
            )

            if let memoryWorkerService = self.memoryWorkerService {
                do {
                    let remote = try await memoryWorkerService.createMemory(
                        content: storedContent,
                        category: storedCategory.rawValue,
                        importance: storedImportance,
                        tags: ["manual", storedCategory.rawValue]
                    )
                    try? await databaseManager.markMemorySynced(id: localId, remoteId: remote.id.map(String.init))
                } catch {
                    AppLogger.error("Failed to sync manual memory: \(error.localizedDescription)")
                }
            }

            await refreshMemoryContext()
            return .inserted(storedContent: storedContent, category: storedCategory, synthesized: didSynthesize)
        } catch {
            AppLogger.error("Failed to save manual memory: \(error.localizedDescription)")
            return .failed
        }
    }

    /// 把单条用户原话送给抽取链条，取第一条返回。失败/为空都返回 nil（调用方用原话兜底）。
    private func synthesizeManualMemory(rawInput: String) async -> ExtractedMemory? {
        guard let ollamaService = self.ollamaService else { return nil }
        do {
            let extracted = try await ollamaService.extractStructuredMemories(
                from: [(role: "user", content: rawInput)]
            )
            return extracted.first
        } catch {
            AppLogger.error("Manual memory synthesis failed, falling back to raw text: \(error.localizedDescription)")
            return nil
        }
    }

    func deleteMemoryRecord(id: Int64) async {
        guard let databaseManager = self.databaseManager else { return }
        do {
            try await databaseManager.deleteMemory(id: id)
            await refreshMemoryContext()
        } catch {
            AppLogger.error("Failed to delete memory: \(error.localizedDescription)")
        }
    }

    func loadMemoryRecords(keyword: String? = nil) async -> [DatabaseManager.MemoryRecord] {
        guard let databaseManager = self.databaseManager else { return [] }
        let trimmed = keyword?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            return (try? await databaseManager.searchMemoryRecords(keyword: trimmed, limit: 100)) ?? []
        }
        return (try? await databaseManager.fetchMemoryRecords(limit: 100)) ?? []
    }

    /// Handles `/command arguments` messages typed in the chat window. Returns true if the
    /// command was recognised (caller should not forward the message to the AI).
    @discardableResult
    func handleChatSlashCommand(
        name: String,
        arguments: String,
        chatViewModel: ChatViewModel?
    ) async -> Bool {
        let normalized = name.lowercased()
        let trimmedArgs = arguments.trimmingCharacters(in: .whitespacesAndNewlines)

        switch normalized {
        case "记住", "记下", "remember":
            if trimmedArgs.isEmpty {
                chatViewModel?.addAssistantMessage("请在命令后面写要记住的内容，例如：/记住 我生日是 6 月 3 日")
                return true
            }
            switch await recordManualMemory(content: trimmedArgs, category: .fact) {
            case .inserted(let storedContent, let category, let synthesized):
                let prefix = synthesized
                    ? "好的，我记下了 📌（已整理为 \(category.displayName)）"
                    : "好的，我记下了 📌（AI 不可用，按原话保存）"
                chatViewModel?.addAssistantMessage("\(prefix)\n→ \(storedContent)")
            case .duplicate:
                chatViewModel?.addAssistantMessage("这条我已经记过了")
            case .failed:
                chatViewModel?.addAssistantMessage("没存上，去 Console 查看日志看看哪里出错了")
            }
            return true

        case "记忆", "memories":
            let records = await loadMemoryRecords()
            if records.isEmpty {
                chatViewModel?.addAssistantMessage("目前还没有存下任何记忆")
            } else {
                let unsynced = await unsyncedMemoryCount()
                let header: String
                if memoryWorkerService == nil {
                    header = "当前记忆（远端未配置，全部仅本地）："
                } else if unsynced == 0 {
                    header = "当前记忆（☁️ 表示已同步远端，全部已同步）："
                } else {
                    header = "当前记忆（☁️ 表示已同步远端，未同步 \(unsynced) 条，可用 /同步 立即推送）："
                }
                let lines = records.prefix(10).map { record -> String in
                    let cat = (MemoryCategory(rawValue: record.category) ?? .fact).displayName
                    let syncFlag = record.syncedAt != nil ? " ☁️" : ""
                    return "• [\(cat)] \(record.content)\(syncFlag)"
                }
                let suffix = records.count > 10 ? "\n...共 \(records.count) 条" : ""
                chatViewModel?.addAssistantMessage(header + "\n" + lines.joined(separator: "\n") + suffix)
            }
            return true

        case "同步", "sync":
            guard memoryWorkerService != nil else {
                chatViewModel?.addAssistantMessage("还没有配置远端 Memory Worker，去 设置 → AI 设置 → 记忆 打开吧")
                return true
            }
            let before = await flushUnsyncedMemoriesNow()
            let after = await unsyncedMemoryCount()
            if before == 0 {
                chatViewModel?.addAssistantMessage("本地没有未同步的记忆 ✅")
            } else if after == 0 {
                chatViewModel?.addAssistantMessage("已把 \(before) 条记忆推到远端 ☁️")
            } else {
                let pushed = max(0, before - after)
                chatViewModel?.addAssistantMessage("推送 \(pushed)/\(before) 条；还有 \(after) 条失败，下个周期会自动重试")
            }
            return true

        case "提取", "extract":
            chatViewModel?.addAssistantMessage("正在从最近对话中提取记忆…")
            let before = await loadMemoryRecords()
            await runMemoryExtractionCycle()
            let after = await loadMemoryRecords()
            let added = after.count - before.count
            chatViewModel?.addAssistantMessage(added > 0 ? "提取完成，新增 \(added) 条记忆。/记忆 查看" : "提取完成，这段对话里没有抓到值得长期记住的信息")
            return true

        case "忘记", "forget":
            chatViewModel?.addAssistantMessage("想删除具体某条记忆，请打开 设置 → AI 设置 → 记忆管理")
            return true

        default:
            chatViewModel?.addAssistantMessage("未知命令 /\(name)。可用：/记住 <内容>、/记忆、/提取、/同步、/忘记")
            return true
        }
    }

    /// One-shot pull from the remote worker to hydrate local memories (useful for multi-device
    /// scenarios). Dedups against local content_hash so repeated pulls don't duplicate rows.
    private func syncFromRemoteMemories(databaseManager: DatabaseManager) async {
        guard let memoryWorkerService = self.memoryWorkerService else { return }

        do {
            let remote = try await memoryWorkerService.queryMemories()
            for item in remote {
                let hash = Self.memoryContentHash(item.content)
                if (try? await databaseManager.memoryExists(contentHash: hash)) == true { continue }
                do {
                    let localId = try await databaseManager.insertMemory(
                        content: item.content,
                        category: MemoryCategory.fact.rawValue,
                        importance: 1,
                        source: "remote",
                        contentHash: hash
                    )
                    if let remoteId = item.id.map(String.init) {
                        try? await databaseManager.markMemorySynced(id: localId, remoteId: remoteId)
                    }
                } catch {
                    AppLogger.error("Failed to hydrate remote memory: \(error.localizedDescription)")
                }
            }
        } catch {
            AppLogger.error("Failed to pull remote memories: \(error.localizedDescription)")
        }
    }

    private var primaryPetController: PetWindowController? {
        configManager?.config.pets.first.flatMap { petWindowControllers[$0.id] }
    }

    private var isAnyPetVisible: Bool {
        petWindowControllers.values.contains { $0.isPetVisible }
    }

    private var currentGlobalPetSize: CGFloat {
        primaryPetController?.currentPetSize ?? 96
    }

    private func togglePetVisibility() {
        if isAnyPetVisible {
            for controller in petWindowControllers.values {
                controller.hidePet()
            }
            return
        }

        for controller in petWindowControllers.values {
            controller.showPet()
        }
    }

    private func resizePets(to size: CGFloat) {
        for controller in petWindowControllers.values {
            controller.resizePet(to: size)
        }
    }

    private func resolvedSoundEnabled(for pet: PetIdentity) -> Bool {
        pet.soundEnabled ?? SoundManager().isEnabled
    }

    private func resolvedVolume(for pet: PetIdentity) -> Float {
        pet.soundVolume ?? SoundManager().volume
    }

    private func applySoundOverrides(for pet: PetIdentity) {
        petWindowControllers[pet.id]?.soundManager?.applyRuntimeSettings(
            enabled: resolvedSoundEnabled(for: pet),
            volume: resolvedVolume(for: pet)
        )
    }

    private func createAndShowPetController(for pet: PetIdentity) {
        let controller = PetWindowController(
            petIdentity: pet,
            configManager: configManager,
            chatController: chatController,
            moodDidChange: { [weak self] in
                self?.statusBarController?.refreshMoodTooltip()
            }
        )
        controller.soundManager = SoundManager()
        controller.soundManager?.applyRuntimeSettings(
            enabled: resolvedSoundEnabled(for: pet),
            volume: resolvedVolume(for: pet)
        )
        controller.reloadCurrentSpritePackSounds()
        controller.windowDetector = { [weak self] in
            guard let self else {
                return []
            }

            let ownWindowNumbers = Set(
                self.petWindowControllers.values
                    .compactMap { $0.window?.windowNumber }
                    .compactMap { Int($0) }
            )

            return self.windowDetector
                .detectWindows(excludingWindowNumbers: ownWindowNumbers)
                .map(\.appKitFrame)
        }
        controller.onMoodChange = { [weak self] petId, petName, happiness, delta, level in
            guard let databaseManager = self?.databaseManager else {
                return
            }

            Task {
                do {
                    try await databaseManager.insertEvent(
                        source: "moodChange",
                        payload: try Self.encodeMoodChangePayload(
                            MoodChangeEventPayload(
                                petId: petId,
                                petName: petName,
                                happiness: happiness,
                                delta: delta,
                                level: level
                            )
                        )
                    )
                } catch {
                    AppLogger.error("Failed to record mood change: \(error.localizedDescription)")
                }
            }
        }
        controller.onBehaviorChange = { [weak self] petId, petName, state in
            guard let databaseManager = self?.databaseManager else {
                return
            }

            Task {
                do {
                    try await databaseManager.insertEvent(
                        source: "petBehavior",
                        payload: try Self.encodePetBehaviorPayload(
                            PetBehaviorEventPayload(
                                petId: petId,
                                petName: petName,
                                state: state
                            )
                        )
                    )
                } catch {
                    AppLogger.error("Failed to record pet behavior: \(error.localizedDescription)")
                }
            }
        }
        controller.onPetClick = { [weak self] petId, petName, type in
            guard let databaseManager = self?.databaseManager else {
                return
            }

            Task {
                do {
                    try await databaseManager.insertEvent(
                        source: "petClick",
                        payload: try Self.encodePetClickPayload(
                            PetClickEventPayload(
                                petId: petId,
                                petName: petName,
                                type: type
                            )
                        )
                    )
                } catch {
                    AppLogger.error("Failed to record pet click: \(error.localizedDescription)")
                }
            }
        }
        controller.behaviorWeightMultipliers = timeWeatherController.currentBehaviorMultipliers
        petWindowControllers[pet.id] = controller
        interactionManager?.register(id: pet.id, controller: controller)
        controller.setOtherPetPositionsProvider { [weak self, petId = pet.id] in
            self?.interactionManager?.otherPetPositions(excluding: petId) ?? []
        }
        controller.showPet()
        controller.petScene.playAnimation(for: .idle)
        statusBarController.refreshMoodTooltip()
    }

    private func showNotification(title: String, body: String) {
        // Show notification as pet bubble instead of blocking NSAlert.
        let text = body.isEmpty ? title : "\(title): \(body)"
        primaryPetController?.showBubble(text)
    }

    private func updateBehaviorMultipliers() {
        let multipliers = timeWeatherController.currentBehaviorMultipliers
        for controller in petWindowControllers.values {
            controller.behaviorWeightMultipliers = multipliers
        }
    }

    private func installBuiltInPluginsIfNeeded() throws {
        guard let pluginsDirectory = PluginLoader.pluginDirectories().first else {
            return
        }

        try FileManager.default.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)

        for plugin in Self.builtInDeclarativePlugins {
            let pluginDir = pluginsDirectory.appendingPathComponent(plugin.directoryName, isDirectory: true)
            let manifestPath = pluginDir.appendingPathComponent("plugin.json")
            var needsWrite = !FileManager.default.fileExists(atPath: manifestPath.path)
            if !needsWrite,
               let data = try? Data(contentsOf: manifestPath),
               let existing = try? JSONDecoder().decode(PluginManifest.self, from: data) {
                needsWrite = existing.version != plugin.manifest.version
            } else if !needsWrite {
                // Exists but malformed — refresh from embedded manifest.
                needsWrite = true
            }
            if needsWrite {
                try writePluginManifest(plugin.manifest, to: pluginDir)
            }
        }
    }

    private func installBuiltInSpritePacksIfNeeded() throws {
        let fileManager = FileManager.default
        let spritePacksDirectory = SpritePackLoader.spritePacksDirectory()
        try fileManager.createDirectory(at: spritePacksDirectory, withIntermediateDirectories: true)

        for packID in SpritePackLoader.builtInPackIDs.sorted() {
            let destinationDirectory = spritePacksDirectory.appendingPathComponent(packID, isDirectory: true)
            let manifestURL = destinationDirectory.appendingPathComponent("manifest.json")
            guard !fileManager.fileExists(atPath: manifestURL.path) else {
                continue
            }

            guard let sourceDirectory = SpritePackLoader.bundledSpritePackDirectory(named: packID) else {
                continue
            }

            if fileManager.fileExists(atPath: destinationDirectory.path) {
                try fileManager.removeItem(at: destinationDirectory)
            }

            try fileManager.copyItem(at: sourceDirectory, to: destinationDirectory)
        }
    }

    private func createDeclarativePluginTemplate(
        name: String,
        description: String,
        template: String
    ) async throws {
        guard let pluginsDirectory = PluginLoader.pluginDirectories().first else {
            throw PluginCreationError.invalidPluginDirectory
        }

        try FileManager.default.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)

        let directoryName = Self.sanitizedDirectoryName(from: name)
        let pluginURL = pluginsDirectory.appendingPathComponent(directoryName, isDirectory: true)
        if FileManager.default.fileExists(atPath: pluginURL.path) {
            throw PluginCreationError.pluginAlreadyExists(directoryName)
        }

        let manifest = Self.pluginTemplateManifest(
            name: name,
            description: description,
            template: template
        )
        try writePluginManifest(manifest, to: pluginURL)
        await pluginManager.reloadPlugins()
    }

    private func deletePlugin(id: String) async throws {
        let plugins = await pluginManager.listPlugins()
        guard let plugin = plugins.first(where: { $0.id == id }),
              let directory = plugin.directory
        else {
            throw PluginCreationError.invalidPluginDirectory
        }

        try FileManager.default.removeItem(at: directory)
        await pluginManager.reloadPlugins()
    }

    private func revealPluginInFinder(id: String) {
        Task {
            let plugins = await pluginManager.listPlugins()
            guard let plugin = plugins.first(where: { $0.id == id }),
                  let directory = plugin.directory
            else {
                return
            }

            NSWorkspace.shared.selectFile(directory.path, inFileViewerRootedAtPath: "")
        }
    }

    private func writePluginManifest(_ manifest: PluginManifest, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.vitaPetPrettyPrinted.encode(manifest)
        try data.write(to: directory.appendingPathComponent("plugin.json"), options: .atomic)
    }

    private func setMiniGameSystemsPaused(_ paused: Bool) {
        if paused {
            desktopAwareness.clearDesktopBehavior()
            Task {
                await self.timerSource?.stop()
            }
            return
        }

        // 游戏结束，恢复所有宠物到 idle
        for controller in petWindowControllers.values {
            controller.transitionToState("idle")
        }

        Task {
            guard let timerSource = self.timerSource else { return }
            await timerSource.stop()
            await timerSource.start(publishingTo: self.eventBus)
        }
    }

    private func buildPetProfileDescription(for pet: PetIdentity) -> String {
        var parts: [String] = []
        parts.append("你的名字叫\"\(pet.name)\"，你是主人的桌面宠物。用第一人称说话，不要用自己的名字称呼主人。")
        if pet.gender != "neutral" {
            parts.append("性别：\(pet.gender == "male" ? "男" : "女")。")
        }
        if !pet.age.isEmpty {
            parts.append("年龄：\(pet.age)。")
        }
        if !pet.personality.isEmpty {
            parts.append("性格：\(pet.personality)。")
        }
        if !pet.hobbies.isEmpty {
            parts.append("爱好：\(pet.hobbies)。")
        }
        return parts.joined(separator: "")
    }

    private func resolvedConversationTargetPetIDs(for chatViewModel: ChatViewModel) -> Set<UUID> {
        let participantIDs = Set(chatViewModel.currentParticipantIds)
        if !participantIDs.isEmpty {
            return participantIDs
        }
        return Set(configManager.config.pets.map(\.id))
    }

    private func buildConversationActionTool() -> (tool: OllamaTool, availableActions: [String]) {
        let behaviorActions = primaryPetController?.debugListBehaviors() ?? []
        let animationActions = AnimationState.allCases
            .filter { $0 != .idle && $0 != .drag }
            .map(\.rawValue)
        let uniqueActions = Array(Set(behaviorActions + animationActions)).sorted()
        return (OllamaTool.petActionTool(availableActions: uniqueActions), uniqueActions)
    }

    private func prepareConversationRequest(
        text: String,
        targetPetIDs: Set<UUID>,
        sessionId: String,
        userSomersaultCount: Int?,
        markChatToolActions: Bool
    ) async throws -> PreparedConversationRequest {
        guard let ollamaService else {
            throw OllamaServiceError.serviceUnavailable
        }

        let (tool, uniqueActions) = buildConversationActionTool()
        await ollamaService.updateAvailableActions(uniqueActions)

        let systemPrompt = configManager.config.aiSystemPrompt
        await ollamaService.updateSystemPrompt(systemPrompt)
        await refreshMemoryContext()

        let targetPets = configManager.config.pets.filter { targetPetIDs.contains($0.id) }
        let isGroupChat = targetPets.count > 1
        await ollamaService.switchSession(sessionId)

        if isGroupChat {
            let petInfos = targetPets.map {
                PetProfileInfo(
                    id: $0.id,
                    name: $0.name,
                    gender: $0.gender,
                    age: $0.age,
                    personality: $0.personality,
                    hobbies: $0.hobbies
                )
            }
            let groupProfile = await ollamaService.buildGroupChatProfile(pets: petInfos)
            await ollamaService.updatePetProfile(groupProfile)
        } else if let firstTarget = targetPets.first {
            let profile = buildPetProfileDescription(for: firstTarget)
            await ollamaService.updatePetProfile(profile)
        } else {
            await ollamaService.updatePetProfile("")
        }

        let stream = try await ollamaService.sendWithTools(
            message: text,
            tools: [tool],
            onToolCall: { [weak self] toolCall in
                guard let self else {
                    return nil
                }
                return await self.handleLocalConversationToolCall(
                    toolCall,
                    targetPetIDs: targetPetIDs,
                    userSomersaultCount: userSomersaultCount,
                    markChatToolActions: markChatToolActions
                )
            }
        )

        return PreparedConversationRequest(stream: stream, targetPets: targetPets, isGroupChat: isGroupChat)
    }

    private func handleLocalConversationToolCall(
        _ toolCall: PetToolCall,
        targetPetIDs: Set<UUID>,
        userSomersaultCount: Int?,
        markChatToolActions: Bool
    ) async -> String? {
        guard toolCall.functionName == "pet_action",
              let action = toolCall.arguments["action"]?.stringValue else {
            return nil
        }

        if action == "somersault", let userSomersaultCount {
            let payload = JSONValue.object([
                "status": .string("ok"),
                "tool": .string(toolCall.functionName),
                "action": .string(action),
                "count": .number(Double(userSomersaultCount)),
                "source": .string("user_fast_path")
            ])
            return payload.compactJSONString()
        }

        let count = max(1, min(toolCall.arguments["count"]?.intValue ?? 1, 8))
        for (id, controller) in petWindowControllers where targetPetIDs.contains(id) {
            controller.executeAIAction(action, count: count)
        }
        if markChatToolActions {
            chatPathToolActionFired = true
        }

        let payload = JSONValue.object([
            "status": .string("ok"),
            "tool": .string(toolCall.functionName),
            "action": .string(action),
            "count": .number(Double(count))
        ])
        return payload.compactJSONString()
    }

    private func installMainMenuIfNeeded() {
        guard NSApp.mainMenu == nil else {
            return
        }

        let mainMenu = NSMenu(title: "MainMenu")

        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "VitaPet")
        appMenuItem.submenu = appMenu

        let quitItem = NSMenuItem(
            title: L10n.menuQuit,
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        appMenu.addItem(quitItem)

        // Edit menu
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu

        let undoItem = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        undoItem.keyEquivalentModifierMask = [.command]
        editMenu.addItem(undoItem)

        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)

        editMenu.addItem(.separator())

        let cutItem = NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        cutItem.keyEquivalentModifierMask = [.command]
        editMenu.addItem(cutItem)

        let copyItem = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        copyItem.keyEquivalentModifierMask = [.command]
        editMenu.addItem(copyItem)

        let pasteItem = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        pasteItem.keyEquivalentModifierMask = [.command]
        editMenu.addItem(pasteItem)

        editMenu.addItem(.separator())

        let selectAllItem = NSMenuItem(title: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        selectAllItem.keyEquivalentModifierMask = [.command]
        editMenu.addItem(selectAllItem)

        NSApp.mainMenu = mainMenu
    }

    nonisolated private static func chatUIStatus(from status: AIEngine.AIEngineStatus) -> ChatUI.AIEngineStatus {
        switch status {
        case .notConfigured:
            return .notConfigured
        case .connecting:
            return .connecting
        case .ready:
            return .ready
        case .error(let message):
            return .error(message)
        }
    }

    private static func encodeEventPayload(from metadata: [String: String]) throws -> String {
        try encodePayload(metadata)
    }

    private static func encodeMoodChangePayload(_ payload: MoodChangeEventPayload) throws -> String {
        try encodePayload(payload)
    }

    private static func encodePetBehaviorPayload(_ payload: PetBehaviorEventPayload) throws -> String {
        try encodePayload(payload)
    }

    private static func encodePetClickPayload(_ payload: PetClickEventPayload) throws -> String {
        try encodePayload(payload)
    }

    private static func encodePetInteractionPayload(_ payload: PetInteractionEventPayload) throws -> String {
        try encodePayload(payload)
    }

    private static func encodeGamePlayPayload(_ payload: GamePlayEventPayload) throws -> String {
        try encodePayload(payload)
    }

    private static func encodePayload<T: Encodable>(_ payload: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        guard let payload = String(data: data, encoding: .utf8) else {
            throw EventEncodingError.invalidUTF8
        }
        return payload
    }
}

private extension AppEvent {
    var caseName: String {
        switch self {
        case .appActivated:
            return "appActivated"
        case .appDeactivated:
            return "appDeactivated"
        case .notificationReceived:
            return "notificationReceived"
        case .timerFired:
            return "timerFired"
        case .fileChanged:
            return "fileChanged"
        case .clipboardChanged:
            return "clipboardChanged"
        case .hotkeyPressed:
            return "hotkeyPressed"
        case .focusEntered:
            return "focusEntered"
        case .focusExited:
            return "focusExited"
        case .custom:
            return "custom"
        }
    }

    var metadata: [String: String] {
        switch self {
        case .appActivated(let bundleId, let appName):
            return [
                "bundleId": bundleId,
                "appName": appName
            ]
        case .appDeactivated(let bundleId, let appName):
            return [
                "bundleId": bundleId,
                "appName": appName
            ]
        case .notificationReceived(let source, let title, let body):
            return [
                "source": source,
                "title": title,
                "body": body
            ]
        case .timerFired(let id):
            return ["id": id]
        case .fileChanged(let path, let flags):
            return [
                "path": path,
                "flags": String(flags)
            ]
        case .clipboardChanged(let content):
            return ["content": content]
        case .hotkeyPressed(let keyCode, let modifiers):
            return [
                "keyCode": String(keyCode),
                "modifiers": String(modifiers)
            ]
        case .focusEntered, .focusExited:
            return [:]
        case .custom(let name, let payload):
            var metadata = payload
            metadata["name"] = name
            return metadata
        }
    }
}

private enum EventEncodingError: Error {
    case invalidUTF8
}

private struct MoodChangeEventPayload: Encodable {
    let petId: String
    let petName: String
    let happiness: Int
    let delta: Int
    let level: String
}

private struct PetBehaviorEventPayload: Encodable {
    let petId: String
    let petName: String
    let state: String
}

private struct PetClickEventPayload: Encodable {
    let petId: String
    let petName: String
    let type: String
}

private struct PetInteractionEventPayload: Encodable {
    let type: String
    let pets: [String]
}

private struct GamePlayEventPayload: Encodable {
    let game: String
    let petCount: Int
}

private enum PluginCreationError: LocalizedError {
    case invalidPluginDirectory
    case pluginAlreadyExists(String)

    var errorDescription: String? {
        switch self {
        case .invalidPluginDirectory:
            return "无法定位插件目录"
        case .pluginAlreadyExists(let name):
            return "插件目录已存在：\(name)"
        }
    }
}

extension AppDelegate {
    fileprivate static let builtInDeclarativePlugins: [(directoryName: String, manifest: PluginManifest)] = [
        (
            "SitReminder",
            PluginManifest(
                id: "com.vitapet.sit-reminder",
                name: "久坐提醒",
                version: "1.0.1",
                description: "每30分钟提醒你站起来活动",
                capabilities: [],
                triggers: [
                    TriggerRule(
                        event: "timerFired",
                        conditions: ["id": "sit-reminder"],
                        actions: [
                            PluginAction(type: "animation", state: "stretch"),
                            PluginAction(type: "bubble", message: "该站起来活动了！🧘"),
                            PluginAction(type: "mood", delta: "2")
                        ]
                    )
                ]
            )
        ),
        (
            "GitCelebrateJSON",
            PluginManifest(
                id: "com.vitapet.git-celebrate-json",
                name: "Git 提交庆祝",
                version: "1.0",
                description: "检测到 git commit 就庆祝",
                capabilities: [],
                triggers: [
                    TriggerRule(
                        event: "fileChanged",
                        conditions: ["path": "*COMMIT_EDITMSG*"],
                        actions: [
                            PluginAction(type: "animation", state: "celebrate"),
                            PluginAction(type: "bubble", message: "提交成功！🎉"),
                            PluginAction(type: "mood", delta: "5")
                        ]
                    )
                ]
            )
        ),
        (
            "HourlyChime",
            PluginManifest(
                id: "com.vitapet.hourly-chime",
                name: "整点报时",
                version: "1.0.1",
                description: "每小时报时",
                capabilities: [],
                triggers: [
                    TriggerRule(
                        event: "timerFired",
                        conditions: ["id": "hour-boundary"],
                        actions: [
                            PluginAction(type: "animation", state: "alert"),
                            PluginAction(type: "bubble", message: "现在是 {hour} 点~⏰")
                        ]
                    )
                ]
            )
        ),
        (
            "BirthdayReminder",
            PluginManifest(
                id: "com.vitapet.birthday",
                name: "生日提醒",
                version: "1.0",
                description: "在设定日期庆祝生日",
                capabilities: [],
                triggers: [
                    TriggerRule(
                        event: "timerFired",
                        conditions: [:],
                        actions: [
                            PluginAction(type: "animation", state: "celebrate"),
                            PluginAction(type: "bubble", message: "生日快乐！🎂🎉")
                        ]
                    )
                ]
            )
        )
    ]

    fileprivate static func pluginTemplateManifest(
        name: String,
        description: String,
        template: String
    ) -> PluginManifest {
        let normalizedID = sanitizedIdentifier(from: name)
        let manifestDescription = description.isEmpty ? "\(name) 插件" : description

        let triggers: [TriggerRule]
        switch template {
        case "fileWatch":
            triggers = [
                TriggerRule(
                    event: "fileChanged",
                    conditions: ["path": "*"],
                    actions: [
                        PluginAction(type: "animation", state: "react"),
                        PluginAction(type: "bubble", message: "\(name)：检测到文件变化")
                    ]
                )
            ]
        case "appSwitch":
            triggers = [
                TriggerRule(
                    event: "appActivated",
                    conditions: ["bundleId": "com.apple.finder"],
                    actions: [
                        PluginAction(type: "animation", state: "alert"),
                        PluginAction(type: "bubble", message: "\(name)：欢迎回来")
                    ]
                )
            ]
        case "timer":
            triggers = [
                TriggerRule(
                    event: "timerFired",
                    conditions: ["id": "timer"],
                    actions: [
                        PluginAction(type: "animation", state: "wave"),
                        PluginAction(type: "bubble", message: "\(name)：定时任务触发")
                    ]
                )
            ]
        default:
            triggers = []
        }

        return PluginManifest(
            id: "com.vitapet.user.\(normalizedID)",
            name: name,
            version: "1.0",
            description: manifestDescription,
            capabilities: [],
            triggers: triggers
        )
    }

    fileprivate static func sanitizedDirectoryName(from value: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let normalized = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return normalized.isEmpty ? "Plugin_\(UUID().uuidString.prefix(8))" : normalized
    }

    fileprivate static func sanitizedIdentifier(from value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let lowercase = value.lowercased()
        let scalars = lowercase.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let normalized = String(scalars)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
        return normalized.isEmpty ? "plugin-\(UUID().uuidString.prefix(8).lowercased())" : normalized
    }

    static func parsePetResponses(from text: String) -> [(petName: String, message: String)] {
        let pattern = #"\[PET:([^\]]+)\]\s*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        guard !matches.isEmpty else {
            return []
        }

        var results: [(petName: String, message: String)] = []

        for (index, match) in matches.enumerated() {
            guard let nameRange = Range(match.range(at: 1), in: text) else {
                continue
            }

            let petName = String(text[nameRange])
            let contentStart = match.range.location + match.range.length
            let contentEnd: Int
            if index + 1 < matches.count {
                contentEnd = matches[index + 1].range.location
            } else {
                contentEnd = nsText.length
            }

            let content = nsText.substring(
                with: NSRange(location: contentStart, length: contentEnd - contentStart)
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)

            if !content.isEmpty {
                results.append((petName: petName, message: content))
            }
        }

        return results
    }

    /// 从用户输入中识别「翻 N 个 跟头/跟斗/筋斗/空翻」或英文 somersault/flip 命令。
    /// 返回次数（1-8 已 clamp），未匹配返回 nil。
    static func parseSomersaultCount(from text: String) -> Int? {
        let zhDigits: [Character: Int] = [
            "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
            "五": 5, "六": 6, "七": 7, "八": 8, "九": 9, "十": 10
        ]

        // 中文模式：可选数字 + 可选「个」 + 跟头/跟斗/筋斗/空翻
        let zhPattern = #"翻\s*(\d+|[一二三四五六七八九十两])?\s*个?\s*(跟头|跟斗|筋斗|空翻)"#
        if let regex = try? NSRegularExpression(pattern: zhPattern) {
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, range: range) {
                let countRange = match.range(at: 1)
                if countRange.location == NSNotFound {
                    return 1
                }
                if let r = Range(countRange, in: text) {
                    let raw = String(text[r])
                    if let n = Int(raw) {
                        return max(1, min(n, 8))
                    }
                    if let c = raw.first, let n = zhDigits[c] {
                        return max(1, min(n, 8))
                    }
                }
                return 1
            }
        }

        // 英文模式：N somersault(s)/flip(s) 或 do a somersault/flip
        let enPattern = #"(?i)(?:(\d+)\s*)?(?:somersault|backflip|flip)s?"#
        if let regex = try? NSRegularExpression(pattern: enPattern) {
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, range: range) {
                let countRange = match.range(at: 1)
                if countRange.location != NSNotFound,
                   let r = Range(countRange, in: text),
                   let n = Int(text[r]) {
                    return max(1, min(n, 8))
                }
                return 1
            }
        }

        return nil
    }

    /// Parse [ACTION:xxx] or [ACTION:xxx:N] tags from AI response text.
    /// Returns cleaned text (tags removed) and list of (action name, count) pairs.
    static func parseActionTags(from text: String) -> (cleanText: String, actions: [(name: String, count: Int)]) {
        var actions: [(name: String, count: Int)] = []
        let pattern = #"\[ACTION:(\w+)(?::(\d+))?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return (text, [])
        }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        for match in matches {
            guard let actionRange = Range(match.range(at: 1), in: text) else { continue }
            let name = String(text[actionRange])
            var count = 1
            if match.numberOfRanges > 2,
               let countRange = Range(match.range(at: 2), in: text),
               let parsed = Int(text[countRange]) {
                count = max(1, min(parsed, 8))
            }
            actions.append((name, count))
        }
        let cleanText = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        return (cleanText, actions)
    }
}

private extension JSONEncoder {
    static var vitaPetPrettyPrinted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private func requestAccessibilityPermission() {
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    AXIsProcessTrustedWithOptions(options)
}

private extension AppDelegate {
    static func resolvedAIBackend(from rawValue: String) -> AIBackend {
        AIBackend(rawValue: rawValue) ?? .ollama
    }

    static func inferredAIBackend(preferred: AIBackend, endpointValue: String) -> AIBackend {
        let lowercased = endpointValue.lowercased()
        if lowercased.contains("/v1/chat/completions") || lowercased.contains("/v1/models") {
            return .openAICompatible
        }
        if lowercased.contains("/api/chat") || lowercased.contains("/api/tags") {
            return .ollama
        }
        return preferred
    }

    static func normalizedAIEndpoint(_ rawValue: String, fallback: String = "http://localhost:11434") -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return fallback
        }

        if trimmed.contains("://") {
            return trimmed
        }

        return "http://\(trimmed)"
    }

    static func normalizedAIModel(_ rawValue: String, backend: AIBackend, previousBackend: AIBackend? = nil) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return backend.defaultModel
        }

        if let previousBackend, previousBackend != backend, trimmed == previousBackend.defaultModel {
            return backend.defaultModel
        }

        return trimmed
    }

    static func normalizedMCPServersJSON(_ rawValue: String) -> String {
        rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodedMCPServers(from rawValue: String) -> [MCPServerConfiguration] {
        do {
            return try MCPServerConfiguration.decodeList(from: normalizedMCPServersJSON(rawValue))
        } catch {
            AppLogger.error("Failed to decode MCP server config: \(error.localizedDescription)")
            return []
        }
    }

    static func resolvedMemoryWorkerAuthMode(from rawValue: String) -> MemoryWorkerAuthMode {
        MemoryWorkerAuthMode(rawValue: rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .basic
    }

    static func normalizedMemoryWorkerEndpoint(
        _ rawValue: String,
        fallback: String = "https://memory.example.com"
    ) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return fallback
        }

        if trimmed.contains("://") {
            return trimmed
        }

        return "https://\(trimmed)"
    }

    static func normalizedMemoryWorkerScope(_ rawValue: String, fallback: String = "user") -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    static func normalizedMemoryWorkerSubject(_ rawValue: String, fallback: String = "") -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != "demo-user" {
            return trimmed
        }

        let explicitFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicitFallback.isEmpty {
            return explicitFallback
        }

        let systemUser = NSUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return systemUser.isEmpty ? "default" : systemUser
    }

    static func normalizedMemoryWorkerQueryLimit(_ rawValue: Int, fallback: Int = 5) -> Int {
        let resolved = rawValue <= 0 ? fallback : rawValue
        return max(1, min(100, resolved))
    }

    static func normalizedMemoryWorkerHorizon(_ rawValue: String, fallback: String = "daily") -> String {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "daily", "weekly", "monthly", "permanent":
            return normalized
        default:
            return fallback
        }
    }

    static func memoryWorkerConfig(from config: ConfigManager.AppConfig) -> MemoryWorkerConfig {
        MemoryWorkerConfig(
            enabled: config.memoryWorkerEnabled,
            endpoint: normalizedMemoryWorkerEndpoint(config.memoryWorkerEndpoint),
            authMode: resolvedMemoryWorkerAuthMode(from: config.memoryWorkerAuthMode),
            username: config.memoryWorkerUsername.trimmingCharacters(in: .whitespacesAndNewlines),
            secret: config.memoryWorkerSecret.trimmingCharacters(in: .whitespacesAndNewlines),
            namespace: config.memoryWorkerNamespace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "default"
                : config.memoryWorkerNamespace.trimmingCharacters(in: .whitespacesAndNewlines),
            scope: normalizedMemoryWorkerScope(config.memoryWorkerScope),
            subject: normalizedMemoryWorkerSubject(config.memoryWorkerSubject),
            queryLimit: normalizedMemoryWorkerQueryLimit(config.memoryWorkerQueryLimit),
            createHorizon: normalizedMemoryWorkerHorizon(config.memoryWorkerCreateHorizon)
        )
    }

    static func mergeMemories(local: [String], remote: [String], maxCount: Int) -> [String] {
        var ordered: [String] = []
        var seen: Set<String> = []

        for memory in remote + local {
            let trimmed = memory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }

            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else {
                continue
            }

            ordered.append(trimmed)
            if ordered.count >= max(1, maxCount) {
                break
            }
        }

        return ordered
    }
}
