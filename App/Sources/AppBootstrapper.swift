import AppKit
import AIEngine
import ChatUI
import EventBus
import Localization
import Persistence
import PluginRuntime
import RenderEngine
import SecurityLayer

/// Executes the full application bootstrap sequence previously contained in
/// AppDelegate.bootstrap(). Accepts a weak reference to AppDelegate and writes
/// all created objects back to AppDelegate fields.
/// The 12-stage startup order is preserved verbatim.
@MainActor
final class AppBootstrapper {

    weak var appDelegate: AppDelegate?

    func bootstrap() async {
        guard let appDelegate else { return }

        // ── Stage 1: ConfigManager + OllamaService + ChatViewModel ──────────

        let configManager = await ConfigManager.create()
        let databaseManager = DatabaseManager()
        L10n.locale = configManager.config.locale
        let initialEndpoint = URL(string: configManager.config.ollamaEndpoint) ?? URL(string: "http://localhost:11434")!
        let ollamaService = OllamaService(
            endpoint: initialEndpoint,
            model: configManager.config.ollamaModel
        )
        appDelegate.ollamaService = ollamaService
        await ollamaService.updateSystemPrompt(configManager.config.aiSystemPrompt)
        await ollamaService.setChatOptions(
            temperature: configManager.config.aiTemperature,
            topP: configManager.config.aiTopP,
            numCtx: configManager.config.aiNumCtx
        )

        Task {
            await ollamaService.checkConnection()
            appDelegate.aiStatus = await ollamaService.status
        }

        let chatViewModel = ChatViewModel(
            sendToAI: { message, _ in
                try await ollamaService.send(message: message)
            },
            cancelStream: { streamID in
                await ollamaService.cancel(streamID: streamID)
            },
            getAIStatus: {
                AppDelegate.chatUIStatus(from: await ollamaService.status)
            }
        )
        appDelegate.chatViewModel = chatViewModel
        chatViewModel.onUserSent = { [weak appDelegate] in
            Task { @MainActor in
                guard let appDelegate else {
                    return
                }

                for controller in appDelegate.petCoordinator.petWindowControllers.values {
                    await controller.handleAnimationTrigger(.userInteract)
                }
            }
        }
        chatViewModel.onAssistantReplied = { [weak appDelegate] in
            Task { @MainActor in
                guard let appDelegate else {
                    return
                }

                for controller in appDelegate.petCoordinator.petWindowControllers.values {
                    await controller.handleAnimationTrigger(.custom("celebrate"))
                }
            }
        }
        chatViewModel.onConversationChanged = { [weak appDelegate] conversationId in
            guard let appDelegate else {
                return
            }

            Task {
                await appDelegate.ollamaService?.switchSession(conversationId)
            }
        }
        chatViewModel.onCreateGroup = { [weak appDelegate] _, _ in
            guard let appDelegate, let databaseManager = appDelegate.databaseManager else {
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

        // ── Stage 2: Config callbacks ────────────────────────────────────────

        let onSaveAIConfig: @MainActor (String, String, String) -> Void = { [weak appDelegate, weak configManager] endpoint, model, aiSystemPrompt in
            guard let appDelegate,
                  let configManager else {
                return
            }

            let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedPrompt = aiSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedEndpointValue = trimmedEndpoint.isEmpty ? "http://localhost:11434" : trimmedEndpoint
            let resolvedModel = trimmedModel.isEmpty ? "llama3.2" : trimmedModel
            let resolvedEndpoint = URL(string: resolvedEndpointValue) ?? URL(string: "http://localhost:11434")!

            do {
                try configManager.update {
                    $0.ollamaEndpoint = resolvedEndpointValue
                    $0.ollamaModel = resolvedModel
                    $0.aiSystemPrompt = trimmedPrompt
                }
            } catch {
                AppLogger.error("Failed to save AI config: \(error.localizedDescription)")
            }

            Task {
                await ollamaService.updateConfig(endpoint: resolvedEndpoint, model: resolvedModel)
                await ollamaService.updateSystemPrompt(trimmedPrompt)
                await ollamaService.checkConnection()
                appDelegate.aiStatus = await ollamaService.status
                chatViewModel.refreshStatus()
            }
        }
        let onTestConnection: @MainActor () -> Void = { [weak appDelegate] in
            Task {
                await ollamaService.checkConnection()
                chatViewModel.refreshStatus()
                appDelegate?.aiStatus = await ollamaService.status
            }
        }
        let onSaveNotificationConfig: @MainActor (String, Bool, Int, String) -> Void = { [weak configManager] token, enabled, port, secret in
            guard let configManager else {
                return
            }

            let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedPort = port > 0 ? port : 19280

            Task { @MainActor in
                do {
                    try await configManager.setGithubToken(trimmedToken)
                } catch {
                    AppLogger.error("Failed to save github token to Keychain: \(error.localizedDescription)")
                }
                do {
                    try await configManager.setWebhookSecret(trimmedSecret)
                } catch {
                    AppLogger.error("Failed to save webhook secret to Keychain: \(error.localizedDescription)")
                }
                do {
                    try configManager.update {
                        $0.webhookEnabled = enabled
                        $0.webhookPort = resolvedPort
                    }
                } catch {
                    AppLogger.error("Failed to save notification config: \(error.localizedDescription)")
                }
            }
        }

        // ── Stage 3: Database initialization ────────────────────────────────

        do {
            try await databaseManager.initialize()
        } catch {
            AppLogger.error("Failed to initialize database: \(error.localizedDescription)")
            appDelegate.isPersistenceAvailable = false
            appDelegate.showPersistenceFailureAlert()
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

        do {
            let memories = try await databaseManager.fetchMemories(limit: 20)
            await ollamaService.updateMemories(memories.map(\.content))
        } catch {
            AppLogger.error("Failed to load AI memories: \(error.localizedDescription)")
        }

        appDelegate.databaseManager = databaseManager
        appDelegate.scheduleDailyCleanup(databaseManager: databaseManager)
        appDelegate.configManager = configManager
        await appDelegate.warmupSecurityState()

        // ── Stage 4: Built-in resources ─────────────────────────────────────

        do {
            try appDelegate.installBuiltInPluginsIfNeeded()
        } catch {
            NSLog("[VitaPet] Failed to install built-in plugins: %@", error.localizedDescription)
        }
        do {
            try appDelegate.installBuiltInSpritePacksIfNeeded()
        } catch {
            NSLog("[VitaPet] Failed to install built-in sprite packs: %@", error.localizedDescription)
        }

        // ── Stage 5: PluginManager + ChatController ──────────────────────────

        #if DEBUG
        let devPluginsDir = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VitaPet/Plugins/dev", isDirectory: true)
        let pluginLoader = PluginLoader(developerMode: true, developerWhitelistDirectory: devPluginsDir)
        #else
        let pluginLoader = PluginLoader(developerMode: false, developerWhitelistDirectory: nil)
        #endif
        appDelegate.pluginManager = PluginManager(loader: pluginLoader, configManager: configManager)
        await appDelegate.pluginManager.setBubbleRequestHandler { [weak appDelegate] message in
            appDelegate?.petCoordinator.primaryPetController?.showBubble(message)
        }
        await appDelegate.pluginManager.setMoodRequestHandler { [weak appDelegate] delta in
            guard let appDelegate else {
                return
            }

            for controller in appDelegate.petCoordinator.petWindowControllers.values {
                Task { @MainActor in
                    await controller.adjustMood(by: delta)
                }
            }
        }
        let pluginManager = appDelegate.pluginManager!
        await pluginManager.start(publishingTo: appDelegate.eventBus)
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
            isPersistenceAvailable: appDelegate.isPersistenceAvailable,
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
            isPersistenceAvailable: appDelegate.isPersistenceAvailable,
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
        appDelegate.chatController = ChatWindowController(
            chatViewModel: chatViewModel,
            pluginSettingsViewModel: pluginSettingsViewModel,
            activityLogViewModel: activityLogViewModel,
            statisticsViewModel: statisticsViewModel
        )
        do {
            try await appDelegate.initializeConversations(
                chatViewModel: chatViewModel,
                databaseManager: databaseManager,
                ollamaService: ollamaService,
                pets: configManager.config.pets
            )
            try? await databaseManager.deleteOldTurns(keepLast: 100)
        } catch {
            AppLogger.error("Failed to initialize conversations: \(error.localizedDescription)")
        }
        appDelegate.spritePackManager = SpritePackManager()
        appDelegate.spritePackImporter = SpritePackImporter(manager: appDelegate.spritePackManager)

        // ── Stage 6: configure* calls on chatController ───────────────────────

        appDelegate.chatController.configureChatConversations(
            listAvailablePets: { [weak appDelegate] in
                appDelegate?.configManager.config.pets.map { (id: $0.id, name: $0.name) } ?? []
            },
            onDeleteConversation: { [weak appDelegate] conversationId in
                guard let appDelegate, let databaseManager = appDelegate.databaseManager else {
                    return
                }

                Task {
                    try? await databaseManager.deleteConversation(id: conversationId)
                }
            },
            onUpdateConversationParticipants: { [weak appDelegate] conversationId, participantIds in
                guard let appDelegate, let databaseManager = appDelegate.databaseManager else {
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
        appDelegate.chatController.configureStatistics(
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
        appDelegate.chatController.configurePluginCreation(
            onDeletePlugin: { [weak appDelegate] id in
                guard let appDelegate else {
                    return "Internal error"
                }

                do {
                    try await appDelegate.deletePlugin(id: id)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            },
            onRevealPluginInFinder: { [weak appDelegate] id in
                appDelegate?.revealPluginInFinder(id: id)
            },
            onReloadPlugins: { [weak appDelegate] in
                guard let appDelegate else {
                    return "Internal error"
                }

                await appDelegate.pluginManager.reloadPlugins()
                return nil
            },
            onCreatePlugin: { [weak appDelegate] name, description, template in
                guard let appDelegate else {
                    return "Internal error"
                }

                do {
                    try await appDelegate.createDeclarativePluginTemplate(
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
        let onSaveAIProactiveConfig: @MainActor (Bool, Int) -> Void = { [weak appDelegate, weak configManager] enabled, interval in
            guard let configManager else { return }
            do {
                try configManager.update {
                    $0.aiProactiveEnabled = enabled
                    $0.aiProactiveInterval = interval
                }
            } catch {
                AppLogger.error("Failed to save AI proactive config: \(error.localizedDescription)")
            }
            if enabled {
                appDelegate?.aiProactiveTrigger?.start()
            } else {
                appDelegate?.aiProactiveTrigger?.stop()
            }
        }
        appDelegate.chatController.configureAISettings(
            aiEndpoint: { [weak configManager] in
                configManager?.config.ollamaEndpoint ?? "http://localhost:11434"
            },
            aiModel: { [weak configManager] in
                configManager?.config.ollamaModel ?? "llama3.2"
            },
            aiSystemPrompt: { [weak configManager] in
                configManager?.config.aiSystemPrompt ?? ""
            },
            aiStatus: { [weak appDelegate] in
                AppDelegate.chatUIStatus(from: appDelegate?.aiStatus ?? .notConfigured)
            },
            onTestConnection: { [weak appDelegate] in
                onTestConnection()
                appDelegate?.aiStatus = .connecting
            },
            onSaveAIConfig: onSaveAIConfig,
            aiProactiveEnabled: { [weak configManager] in
                configManager?.config.aiProactiveEnabled ?? true
            },
            aiProactiveInterval: { [weak configManager] in
                configManager?.config.aiProactiveInterval ?? 45
            },
            onSaveAIProactiveConfig: onSaveAIProactiveConfig,
            aiTemperature: { [weak configManager] in
                configManager?.config.aiTemperature ?? 0.7
            },
            aiTopP: { [weak configManager] in
                configManager?.config.aiTopP ?? 0.9
            },
            aiNumCtx: { [weak configManager] in
                configManager?.config.aiNumCtx ?? 4096
            },
            onSaveAIChatOptions: { [weak appDelegate, weak configManager] temperature, topP, numCtx in
                guard let configManager else { return }
                do {
                    try configManager.update {
                        $0.aiTemperature = temperature
                        $0.aiTopP = topP
                        $0.aiNumCtx = numCtx
                    }
                } catch {
                    AppLogger.error("Failed to save AI chat options: \(error.localizedDescription)")
                }
                Task {
                    await appDelegate?.ollamaService?.setChatOptions(
                        temperature: temperature,
                        topP: topP,
                        numCtx: numCtx
                    )
                }
            }
        )
        appDelegate.chatController.configureNotificationSettings(
            githubToken: { [weak configManager] in
                configManager?.cachedGithubTokenValue ?? ""
            },
            webhookEnabled: { [weak configManager] in
                configManager?.config.webhookEnabled ?? false
            },
            webhookPort: { [weak configManager] in
                configManager?.config.webhookPort ?? 19280
            },
            webhookSecret: { [weak configManager] in
                configManager?.cachedWebhookSecretValue ?? ""
            },
            onSaveNotificationConfig: onSaveNotificationConfig
        )
        appDelegate.chatController.configureDesktopAwarenessSettings(
            isEnabled: { [weak appDelegate] in
                appDelegate?.desktopAwareness.isEnabled ?? true
            },
            rules: {
                AppBehaviorRules.loadRules()
            },
            onSetEnabled: { [weak appDelegate] enabled in
                appDelegate?.desktopAwareness.setEnabled(enabled)
            },
            onSaveRules: { [weak appDelegate] rules in
                do {
                    try AppBehaviorRules.saveRules(rules)
                    appDelegate?.desktopAwareness.reloadRules()
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }
        )
        appDelegate.chatController.configureSoundSettings(
            soundEnabled: {
                SoundManager().isEnabled
            },
            soundVolume: {
                Double(SoundManager().volume)
            },
            onSetSoundEnabled: { [weak appDelegate] enabled in
                let globalSoundManager = SoundManager()
                globalSoundManager.setEnabled(enabled)

                guard let appDelegate else {
                    return
                }

                for pet in appDelegate.configManager.config.pets where pet.soundEnabled == nil {
                    appDelegate.petCoordinator.petWindowControllers[pet.id]?.soundManager?.applyRuntimeSettings(
                        enabled: enabled,
                        volume: appDelegate.petCoordinator.resolvedVolume(for: pet)
                    )
                }
            },
            onSetSoundVolume: { [weak appDelegate] volume in
                let globalSoundManager = SoundManager()
                globalSoundManager.setVolume(volume)

                guard let appDelegate else {
                    return
                }

                for pet in appDelegate.configManager.config.pets where pet.soundVolume == nil {
                    appDelegate.petCoordinator.petWindowControllers[pet.id]?.soundManager?.applyRuntimeSettings(
                        enabled: appDelegate.petCoordinator.resolvedSoundEnabled(for: pet),
                        volume: volume
                    )
                }
            }
        )
        appDelegate.chatController.configureWeatherSettings(
            isEnabled: { [weak appDelegate] in
                appDelegate?.timeWeatherController.weatherEnabled ?? true
            },
            currentSummary: { [weak appDelegate] in
                appDelegate?.timeWeatherController.currentWeatherSummary
            },
            onSetEnabled: { [weak appDelegate] enabled in
                appDelegate?.timeWeatherController.setWeatherEnabled(enabled)
                appDelegate?.petCoordinator.updateBehaviorMultipliers()
            },
            latitude: { [weak appDelegate] in
                appDelegate?.timeWeatherController.manualLatitude
            },
            longitude: { [weak appDelegate] in
                appDelegate?.timeWeatherController.manualLongitude
            },
            onSaveLocation: { [weak appDelegate] lat, lon in
                appDelegate?.timeWeatherController.manualLatitude = lat
                appDelegate?.timeWeatherController.manualLongitude = lon
                // 保存后立即刷新天气
                appDelegate?.timeWeatherController.refreshWeather()
            }
        )
        appDelegate.chatController.configureWeatherRefresh(
            refreshMinutes: { [weak appDelegate] in
                Int((appDelegate?.timeWeatherController.weatherRefreshInterval ?? 7200) / 60)
            },
            onSetInterval: { [weak appDelegate] interval in
                appDelegate?.timeWeatherController.weatherRefreshInterval = interval
                // 重启定时器
                if appDelegate?.timeWeatherController.weatherEnabled == true {
                    appDelegate?.timeWeatherController.stop()
                    appDelegate?.timeWeatherController.start()
                }
            }
        )
        appDelegate.chatController.configurePetManagement(
            petProfiles: { [weak appDelegate] in
                guard let appDelegate else {
                    return []
                }

                return appDelegate.configManager.config.pets.map {
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
            onUpdatePet: { [weak appDelegate] id, name, spritePack, size, gender, age, personality, hobbies in
                guard let appDelegate else {
                    return
                }

                do {
                    try appDelegate.configManager.update { config in
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

                    if let controller = appDelegate.petCoordinator.petWindowControllers[id] {
                        controller.selectSpritePack(id: spritePack)
                        controller.resizePet(to: CGFloat(size))
                    }

                    // 同步更新对话标题
                    let conversationId = "single_\(id.uuidString)"
                    appDelegate.chatViewModel.updateConversationTitle(conversationId, title: name)
                    Task {
                        try? await appDelegate.databaseManager?.updateConversationTitle(id: conversationId, title: name)
                    }
                } catch {
                    AppLogger.error("Failed to update pet: \(error.localizedDescription)")
                }
            },
            onUpdatePetSound: { [weak appDelegate] id, soundEnabled, soundVolume in
                guard let appDelegate else {
                    return
                }

                do {
                    var updatedPet: PetIdentity?
                    try appDelegate.configManager.update { config in
                        guard let index = config.pets.firstIndex(where: { $0.id == id }) else {
                            return
                        }

                        config.pets[index].soundEnabled = soundEnabled
                        config.pets[index].soundVolume = soundVolume
                        updatedPet = config.pets[index]
                    }

                    if let updatedPet {
                        appDelegate.petCoordinator.applySoundOverrides(for: updatedPet)
                    }
                } catch {
                    AppLogger.error("Failed to update pet sound overrides: \(error.localizedDescription)")
                }
            },
            onUpdatePetLanguage: { [weak appDelegate] id, language in
                guard let appDelegate else {
                    return "AppDelegate 已释放"
                }

                do {
                    try appDelegate.configManager.update { config in
                        guard let index = config.pets.firstIndex(where: { $0.id == id }) else {
                            return
                        }

                        config.pets[index].customLanguage = language
                    }

                    appDelegate.petCoordinator.petWindowControllers[id]?.setCustomLanguage(language)
                    return nil
                } catch {
                    AppLogger.error("Failed to update pet custom language: \(error.localizedDescription)")
                    return error.localizedDescription
                }
            },
            onRemovePet: { [weak appDelegate] id in
                appDelegate?.petCoordinator.removePet(id: id)
            },
            onAddPet: { [weak appDelegate] in
                appDelegate?.petCoordinator.addPet()
            },
            canAddMorePets: { [weak appDelegate] in
                (appDelegate?.petCoordinator.petWindowControllers.count ?? 0) < (appDelegate?.maximumPets ?? 5)
            }
        )
        appDelegate.chatController.configureResetCallbacks(
            onResetLanguage: { [weak appDelegate] petId in
                guard let appDelegate else {
                    return
                }

                do {
                    try appDelegate.configManager.update { config in
                        guard let index = config.pets.firstIndex(where: { $0.id == petId }) else {
                            return
                        }

                        config.pets[index].customLanguage = nil
                    }

                    appDelegate.petCoordinator.petWindowControllers[petId]?.setCustomLanguage(nil)
                } catch {
                    AppLogger.error("Failed to reset pet language: \(error.localizedDescription)")
                }
            },
            onResetAttributes: { [weak appDelegate] petId in
                guard let appDelegate else {
                    return
                }

                do {
                    var updatedPet: PetIdentity?
                    try appDelegate.configManager.update { config in
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
                        appDelegate.petCoordinator.petWindowControllers[petId]?.resizePet(to: CGFloat(updatedPet.size))
                    }
                } catch {
                    AppLogger.error("Failed to reset pet attributes: \(error.localizedDescription)")
                }
            },
            onResetAll: { [weak appDelegate] petId in
                guard let appDelegate else {
                    return
                }

                do {
                    var updatedPet: PetIdentity?
                    try appDelegate.configManager.update { config in
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

                    appDelegate.petCoordinator.petWindowControllers[petId]?.setCustomLanguage(nil)
                    if let updatedPet {
                        appDelegate.petCoordinator.petWindowControllers[petId]?.resizePet(to: CGFloat(updatedPet.size))
                        appDelegate.petCoordinator.applySoundOverrides(for: updatedPet)
                    }
                } catch {
                    AppLogger.error("Failed to reset pet settings: \(error.localizedDescription)")
                }
            }
        )
        appDelegate.chatController.configureSpritePackManagement(
            loadSpritePackItems: { [weak appDelegate] in
                guard appDelegate != nil else {
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
            selectedSpritePackID: { [weak appDelegate] in
                appDelegate?.petCoordinator.primaryPetController?.currentSpritePackID ?? "PixelCat"
            },
            onSelectSpritePack: { [weak appDelegate] selectedID in
                appDelegate?.petCoordinator.primaryPetController?.selectSpritePack(id: selectedID)
            },
            onImportPack: { [weak appDelegate] in
                guard let appDelegate else {
                    return "Internal error"
                }

                do {
                    let info = try await appDelegate.spritePackImporter.importFromPicker()
                    appDelegate.petCoordinator.primaryPetController?.selectSpritePack(id: info.id)
                    return nil
                } catch {
                    if case SpritePackImporterError.cancelled = error {
                        return nil
                    }
                    if case let SpritePackImporterError.noManifest(folderURL) = error {
                        let detected = SpritePackBuilder.autoDetect(from: folderURL)
                        appDelegate.chatController.showSpritePackCreator(initialFrames: detected)
                        return nil
                    }
                    return error.localizedDescription
                }
            },
            onExportPack: { [weak appDelegate] packID in
                guard let appDelegate else {
                    return "Internal error"
                }

                let panel = NSSavePanel()
                panel.nameFieldStringValue = "\(packID).zip"
                panel.allowedContentTypes = [.zip]

                guard panel.runModal() == .OK, let url = panel.url else {
                    return nil
                }

                do {
                    try await appDelegate.spritePackManager.exportAsZip(packID: packID, to: url)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            },
            onDeletePack: { [weak appDelegate] packID in
                guard let appDelegate else {
                    return "Internal error"
                }

                do {
                    try await appDelegate.spritePackManager.delete(packID: packID)
                    if appDelegate.petCoordinator.primaryPetController?.currentSpritePackID == packID {
                        appDelegate.petCoordinator.primaryPetController?.selectSpritePack(id: "PixelCat")
                    }
                    return nil
                } catch {
                    return error.localizedDescription
                }
            },
            onRevealInFinder: { [weak appDelegate] packID in
                guard appDelegate != nil else {
                    return
                }

                let packs = SpritePackLoader.discoverPacks()
                if let pack = packs.first(where: { $0.id == packID }) {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: pack.directory.path)
                }
            },
            onCreateTemplate: { [weak appDelegate] in
                guard let appDelegate else {
                    return "Internal error"
                }

                appDelegate.chatController.showSpritePackCreator()
                return nil
            }
        )
        appDelegate.chatController.configureSpritePackCreator(
            onBuild: { [weak appDelegate] name, frames in
                guard let appDelegate else {
                    return "Internal error"
                }

                do {
                    let outputDirectory = SpritePackLoader.spritePacksDirectory()
                    let packURL = try SpritePackBuilder.build(
                        named: name,
                        frames: frames,
                        outputDirectory: outputDirectory
                    )
                    appDelegate.petCoordinator.primaryPetController?.selectSpritePack(id: packURL.lastPathComponent)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }
        )
        appDelegate.inputBarController = InputBarWindowController()
        appDelegate.inputBarController.onSubmitWithTargets = { [weak appDelegate] text, targetPetIDs in
            guard let appDelegate else {
                return
            }

            let currentParticipants = Set(chatViewModel.currentParticipantIds)
            let effectiveTargetPetIDs = currentParticipants.isEmpty ? targetPetIDs : currentParticipants

            let behaviorActions = appDelegate.petCoordinator.primaryPetController?.debugListBehaviors() ?? []
            let animActions = AnimationState.allCases.filter { $0 != .idle && $0 != .drag }.map(\.rawValue)
            let uniqueActions = Array(Set(behaviorActions + animActions)).sorted()
            let tool = OllamaTool.petActionTool(availableActions: uniqueActions)

            // Update system prompt with current available actions
            Task { await ollamaService.updateAvailableActions(uniqueActions) }

            Task { @MainActor in
                if let selectedConversationId = chatViewModel.selectedConversationId {
                    await ollamaService.switchSession(selectedConversationId)
                } else if let fallbackConversationId = appDelegate.fallbackConversationId(for: effectiveTargetPetIDs) {
                    chatViewModel.selectConversation(fallbackConversationId)
                    await ollamaService.switchSession(fallbackConversationId)
                }

                for (id, controller) in appDelegate.petCoordinator.petWindowControllers where effectiveTargetPetIDs.contains(id) {
                    await controller.handleAnimationTrigger(.userInteract)
                    controller.showThinkingBubble()
                }
                chatViewModel.addExternalMessage(text)
            }

            Task {
                do {
                    let systemPrompt = appDelegate.configManager.config.aiSystemPrompt
                    await ollamaService.updateSystemPrompt(systemPrompt)
                    let targetPets = appDelegate.configManager.config.pets.filter { effectiveTargetPetIDs.contains($0.id) }
                    let isGroupChat = effectiveTargetPetIDs.count > 1
                    let sessionId = await MainActor.run {
                        if let selectedConversationId = chatViewModel.selectedConversationId {
                            return selectedConversationId
                        }
                        return appDelegate.fallbackConversationId(for: effectiveTargetPetIDs) ?? "default"
                    }
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
                        let profile = appDelegate.buildPetProfileDescription(for: firstTarget)
                        await ollamaService.updatePetProfile(profile)
                    }

                    let (_, stream) = try await ollamaService.sendWithTools(
                        message: text,
                        tools: [tool],
                        onToolCall: { [weak appDelegate] toolCall in
                            guard let appDelegate else {
                                return
                            }

                            if toolCall.functionName == "pet_action",
                               let action = toolCall.arguments["action"] {
                                await MainActor.run {
                                    for (id, controller) in appDelegate.petCoordinator.petWindowControllers where effectiveTargetPetIDs.contains(id) {
                                        controller.executeAIAction(action)
                                    }
                                }
                            }
                        }
                    )

                    var fullResponse = ""
                    for try await chunk in stream {
                        fullResponse += chunk
                    }

                    await MainActor.run {
                        // 无论是否有内容，都清除 thinking 状态
                        for (id, controller) in appDelegate.petCoordinator.petWindowControllers where effectiveTargetPetIDs.contains(id) {
                            controller.dismissThinkingBubble()
                        }

                        if !fullResponse.isEmpty {
                            // Parse [ACTION:xxx] tags from text (fallback for models without tool calling)
                            let (cleanText, actions) = AppDelegate.parseActionTags(from: fullResponse)

                            for action in actions {
                                for (id, controller) in appDelegate.petCoordinator.petWindowControllers where effectiveTargetPetIDs.contains(id) {
                                    controller.executeAIAction(action)
                                }
                            }

                            let displayText = cleanText.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !displayText.isEmpty {
                                if isGroupChat {
                                    let petResponses = AppDelegate.parsePetResponses(from: displayText)

                                    if petResponses.isEmpty {
                                        for (id, controller) in appDelegate.petCoordinator.petWindowControllers where effectiveTargetPetIDs.contains(id) {
                                            controller.showAIBubble(displayText)
                                        }
                                        chatViewModel.addAssistantMessage(displayText)
                                    } else {
                                        for (petName, message) in petResponses {
                                            let pet = targetPets.first(where: { $0.name == petName })
                                            if let pet,
                                               let controller = appDelegate.petCoordinator.petWindowControllers[pet.id] {
                                                controller.showAIBubble(message)
                                            }
                                            chatViewModel.addAssistantMessage(message, petId: pet?.id, petName: petName)
                                        }
                                    }
                                } else {
                                    let targetPet = targetPets.first
                                    for (id, controller) in appDelegate.petCoordinator.petWindowControllers where effectiveTargetPetIDs.contains(id) {
                                        controller.showAIBubble(displayText)
                                    }
                                    chatViewModel.addAssistantMessage(
                                        displayText,
                                        petId: targetPet?.id,
                                        petName: targetPet?.name
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

                    appDelegate.conversationTurnCount += 1
                    if appDelegate.conversationTurnCount % 5 == 0 {
                        Task {
                            do {
                                let recentTurns = try await databaseManager.fetchRecentTurns(limit: 10)
                                let newMemories = try await ollamaService.extractMemories(
                                    from: recentTurns.map { (role: $0.role, content: $0.content) }
                                )
                                for memory in newMemories {
                                    try? await databaseManager.insertMemory(content: memory, category: "auto")
                                }
                                let allMemories = try await databaseManager.fetchMemories(limit: 20)
                                await ollamaService.updateMemories(allMemories.map(\.content))
                            } catch {
                                AppLogger.error("Failed to extract memories: \(error.localizedDescription)")
                            }
                        }
                    }
                } catch {
                    await MainActor.run {
                        for (id, controller) in appDelegate.petCoordinator.petWindowControllers where effectiveTargetPetIDs.contains(id) {
                            controller.dismissThinkingBubble()
                        }
                        let errorText = "Error: \(error.localizedDescription)"
                        for (id, controller) in appDelegate.petCoordinator.petWindowControllers where effectiveTargetPetIDs.contains(id) {
                            controller.showAIBubble(errorText)
                        }
                    }
                }
            }
        }
        appDelegate.inputBarController.onSubmitToConversation = { [weak appDelegate] text, conversationId in
            guard let appDelegate else { return }
            // Switch to conversation and get participants
            appDelegate.chatViewModel.selectConversation(conversationId)
            let participantIds = Set(appDelegate.chatViewModel.currentParticipantIds)
            // Reuse existing target-based flow
            appDelegate.inputBarController.onSubmitWithTargets?(text, participantIds)
        }
        appDelegate.statusBarController = StatusBarController(
            chatController: appDelegate.chatController,
            isPetVisible: { [weak appDelegate] in appDelegate?.petCoordinator.isAnyPetVisible ?? false },
            togglePetVisibility: { [weak appDelegate] in appDelegate?.petCoordinator.togglePetVisibility() },
            currentPetSize: { [weak appDelegate] in appDelegate?.petCoordinator.currentGlobalPetSize ?? 96 },
            currentMoodLevel: { [weak appDelegate] in appDelegate?.petCoordinator.primaryPetController?.currentMoodLevel ?? .normal },
            resizePets: { [weak appDelegate] size in appDelegate?.petCoordinator.resizePets(to: size) },
            canAddPet: { [weak appDelegate] in (appDelegate?.petCoordinator.petWindowControllers.count ?? 0) < (appDelegate?.maximumPets ?? 5) },
            addPet: { [weak appDelegate] in appDelegate?.petCoordinator.addPet() },
            removePet: { [weak appDelegate] id in appDelegate?.petCoordinator.removePet(id: id) },
            listPets: { [weak appDelegate] in
                guard let appDelegate else { return [] }
                return appDelegate.configManager.config.pets.map { (id: $0.id, name: $0.name) }
            },
            pomodoroMenuState: { [weak appDelegate] in
                guard let appDelegate else {
                    return StatusBarController.PomodoroMenuState(
                        startEnabled: true,
                        pauseTitle: "暂停",
                        pauseEnabled: false,
                        resetEnabled: false,
                        skipEnabled: false
                    )
                }

                let isIdle = appDelegate.pomodoroController.state == .idle
                let isPaused = appDelegate.pomodoroController.isPaused
                return StatusBarController.PomodoroMenuState(
                    startEnabled: isIdle,
                    pauseTitle: isPaused ? "继续" : "暂停",
                    pauseEnabled: !isIdle,
                    resetEnabled: !isIdle || appDelegate.pomodoroController.remainingSeconds > 0,
                    skipEnabled: !isIdle
                )
            },
            startPomodoro: { [weak appDelegate] in appDelegate?.pomodoroController.start() },
            pauseOrResumePomodoro: { [weak appDelegate] in
                guard let appDelegate else {
                    return
                }
                if appDelegate.pomodoroController.isPaused {
                    appDelegate.pomodoroController.resume()
                } else {
                    appDelegate.pomodoroController.pause()
                }
            },
            resetPomodoro: { [weak appDelegate] in appDelegate?.pomodoroController.reset() },
            skipPomodoro: { [weak appDelegate] in appDelegate?.pomodoroController.skip() },
            debugTriggerAnimation: { [weak appDelegate] name in
                appDelegate?.petCoordinator.primaryPetController?.debugPlayAnimation(name)
            },
            debugTriggerBehavior: { [weak appDelegate] name in
                appDelegate?.petCoordinator.primaryPetController?.debugExecuteBehavior(name)
            },
            debugListBehaviors: { [weak appDelegate] in
                appDelegate?.petCoordinator.primaryPetController?.debugListBehaviors() ?? []
            }
        )
        appDelegate.statusBarController.availableMiniGames = { [weak appDelegate] in
            appDelegate?.miniGameManager.availableGames().map(\.name) ?? []
        }
        appDelegate.statusBarController.onStartGame = { [weak appDelegate] gameName in
            appDelegate?.miniGameManager.startGame(named: gameName)
        }
        appDelegate.interactionManager = PetInteractionManager()
        appDelegate.interactionManager.onInteractionTriggered = { [weak appDelegate] type, petNames in
            guard let databaseManager = appDelegate?.databaseManager else {
                return
            }

            Task {
                do {
                    try await databaseManager.insertEvent(
                        source: "petInteraction",
                        payload: try AppDelegate.encodePetInteractionPayload(
                            PetInteractionEventPayload(type: type, pets: petNames)
                        )
                    )
                } catch {
                    AppLogger.error("Failed to record pet interaction: \(error.localizedDescription)")
                }
            }
        }
        appDelegate.miniGameManager.configure(
            getPetControllers: { [weak appDelegate] in
                guard let appDelegate, let configManager = appDelegate.configManager else { return [] }
                return configManager.config.pets.compactMap { appDelegate.petCoordinator.petWindowControllers[$0.id] }
            },
            onGameStateChanged: { [weak appDelegate] isPlaying in
                appDelegate?.setMiniGameSystemsPaused(isPlaying)
            }
        )
        appDelegate.miniGameManager.onGameStarted = { [weak appDelegate] gameName, petCount in
            guard let databaseManager = appDelegate?.databaseManager else {
                return
            }

            Task {
                do {
                    try await databaseManager.insertEvent(
                        source: "gamePlay",
                        payload: try AppDelegate.encodeGamePlayPayload(
                            GamePlayEventPayload(game: gameName, petCount: petCount)
                        )
                    )
                } catch {
                    AppLogger.error("Failed to record game start: \(error.localizedDescription)")
                }
            }
        }
        appDelegate.pomodoroController.getPetControllers = { [weak appDelegate] in
            guard let appDelegate else {
                return []
            }
            return appDelegate.configManager.config.pets.compactMap { appDelegate.petCoordinator.petWindowControllers[$0.id] }
        }
        appDelegate.pomodoroController.onStateChanged = { [weak appDelegate] _, _ in
            appDelegate?.statusBarController?.refreshPomodoroMenuState()
        }

        // ── Stage 7: Pet management callbacks ────────────────────────────────

        for pet in configManager.config.pets {
            appDelegate.petCoordinator.createAndShowPetController(for: pet)
        }
        appDelegate.desktopAwareness.getPetControllers = { [weak appDelegate] in
            guard let appDelegate else { return [] }
            return Array(appDelegate.petCoordinator.petWindowControllers.values)
        }
        appDelegate.petCoordinator.updateBehaviorMultipliers()
        appDelegate.timeWeatherController.onTimePeriodChanged = { [weak appDelegate] oldPeriod, newPeriod in
            guard let appDelegate else { return }

            appDelegate.petCoordinator.updateBehaviorMultipliers()

            for controller in appDelegate.petCoordinator.petWindowControllers.values {
                Task {
                    await controller.adjustMood(by: newPeriod.moodDelta)
                }
            }

            if oldPeriod == .night && newPeriod == .dawn {
                for controller in appDelegate.petCoordinator.petWindowControllers.values {
                    controller.transitionToState("idle")
                    controller.showBubble(newPeriod.greeting ?? "早上好~")
                }
            } else if newPeriod == .night {
                for (index, controller) in appDelegate.petCoordinator.petWindowControllers.values.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.5) {
                        controller.transitionToState("sleep")
                        if let greeting = newPeriod.greeting {
                            controller.showBubble(greeting)
                        }
                    }
                }
            } else if let greeting = newPeriod.greeting {
                appDelegate.petCoordinator.primaryPetController?.showBubble(greeting)
            }
        }
        appDelegate.timeWeatherController.onWeatherUpdated = { [weak appDelegate] weather in
            guard let appDelegate else { return }

            appDelegate.petCoordinator.updateBehaviorMultipliers()
            appDelegate.petCoordinator.primaryPetController?.showBubble(weather.bubble)

            let delta = weather.moodDelta + weather.temperatureMoodDelta
            guard delta != 0 else {
                return
            }

            for controller in appDelegate.petCoordinator.petWindowControllers.values {
                Task {
                    await controller.adjustMood(by: delta)
                }
            }
        }
        appDelegate.timeWeatherController.onMoodDecay = { [weak appDelegate] in
            guard let appDelegate else { return }

            for controller in appDelegate.petCoordinator.petWindowControllers.values {
                Task {
                    let currentHappiness = await controller.petMood.happiness
                    let delta = currentHappiness > 50 ? -1 : (currentHappiness < 50 ? 1 : 0)
                    if delta != 0 {
                        await controller.adjustMood(by: delta)
                    }
                }
            }
        }
        appDelegate.timeWeatherController.start()

        // Populate available actions for AI system prompt
        let behaviorActions = appDelegate.petCoordinator.primaryPetController?.debugListBehaviors() ?? []
        let animActions = AnimationState.allCases.filter { $0 != .idle && $0 != .drag }.map(\.rawValue)
        let initialActions = Array(Set(behaviorActions + animActions)).sorted()
        await ollamaService.updateAvailableActions(initialActions)

        // ── Stage 8: AIProactiveTrigger ──────────────────────────────────────

        appDelegate.aiProactiveTrigger = AIProactiveTrigger(
            ollamaService: ollamaService,
            configManager: configManager,
            moodProvider: { [weak appDelegate] in
                appDelegate?.petCoordinator.primaryPetController?.currentMoodLevel ?? .normal
            },
            onMessage: { [weak appDelegate] message in
                appDelegate?.petCoordinator.primaryPetController?.showBubble(message)
            },
            onAction: { [weak appDelegate] action in
                guard let appDelegate else { return }
                for controller in appDelegate.petCoordinator.petWindowControllers.values {
                    controller.executeAIAction(action)
                }
            }
        )
        appDelegate.aiProactiveTrigger?.start()

        // ── Stage 9: Monitor instantiation ──────────────────────────────────

        appDelegate.eventDispatcher.timerSource = TimerSource(interval: 10.0)
        appDelegate.eventDispatcher.sitReminderTimer = TimerSource(interval: 1800, sourceId: "sit-reminder")
        appDelegate.eventDispatcher.workspaceMonitor = WorkspaceMonitor()
        appDelegate.eventDispatcher.notificationMonitor = NotificationMonitor()
        appDelegate.eventDispatcher.githubMonitor = GitHubMonitor(tokenProvider: { [weak configManager] in
            guard let configManager else { return "" }
            return await configManager.githubToken()
        })
        appDelegate.eventDispatcher.calendarMonitor = CalendarMonitor()
        appDelegate.eventDispatcher.clipboardMonitor = await ClipboardMonitor()
        appDelegate.eventDispatcher.fsEventsMonitor = FSEventsMonitor(paths: [NSHomeDirectory()])
        // 请求辅助功能权限（全局快捷键需要）
        requestAccessibilityPermission()
        appDelegate.eventDispatcher.keyboardMonitor = KeyboardMonitor()
        if configManager.config.webhookEnabled {
            let secret = await configManager.webhookSecret()
            appDelegate.eventDispatcher.webhookServer = WebhookServer(port: UInt16(configManager.config.webhookPort), secret: secret)
        }

        // Wire eventBus into WindowDetector so it can publish permission events.
        appDelegate.windowDetector.eventBus = appDelegate.eventBus

        // ── Stage 10: EventBus subscribe ────────────────────────────────────

        appDelegate.eventDispatcher.eventSubscriptionID = await appDelegate.eventBus.subscribe { [weak appDelegate] event in
            guard let appDelegate else {
                return
            }

            await appDelegate.handleEvent(event)
        }

        // ── Stage 11: Start all monitors ────────────────────────────────────

        await appDelegate.eventDispatcher.timerSource.start(publishingTo: appDelegate.eventBus)
        await appDelegate.eventDispatcher.sitReminderTimer.start(publishingTo: appDelegate.eventBus)
        await appDelegate.eventDispatcher.workspaceMonitor.start(publishingTo: appDelegate.eventBus)
        await appDelegate.eventDispatcher.notificationMonitor.start(publishingTo: appDelegate.eventBus)
        await appDelegate.eventDispatcher.githubMonitor.start(publishingTo: appDelegate.eventBus)
        await appDelegate.eventDispatcher.calendarMonitor.start(publishingTo: appDelegate.eventBus)
        await appDelegate.eventDispatcher.clipboardMonitor.start(publishingTo: appDelegate.eventBus)
        await appDelegate.eventDispatcher.fsEventsMonitor.start(publishingTo: appDelegate.eventBus)
        await appDelegate.eventDispatcher.keyboardMonitor.start(publishingTo: appDelegate.eventBus)
        await appDelegate.eventDispatcher.webhookServer?.start(publishingTo: appDelegate.eventBus)

        // ── Stage 12: ScreenStateCoordinator ────────────────────────────────

        // Register screen sleep/wake coordinator after all monitors are running.
        let coordinator = ScreenStateCoordinator(
            clipboardMonitor: appDelegate.eventDispatcher.clipboardMonitor,
            timerSource: appDelegate.eventDispatcher.timerSource,
            eventBus: appDelegate.eventBus,
            petScenesProvider: { [weak appDelegate] in
                guard let appDelegate else { return [] }
                return appDelegate.petCoordinator.petWindowControllers.values.map(\.petScene)
            }
        )
        coordinator.start()
        appDelegate.screenStateCoordinator = coordinator
    }
}
