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
    // MARK: - Coordinators (created at the start of bootstrap)
    let petCoordinator = PetCoordinator()
    let eventDispatcher = EventDispatcher()
    let appBootstrapper = AppBootstrapper()

    // MARK: - Shared fields (internal so AppBootstrapper / PetCoordinator can write them)
    var chatViewModel: ChatViewModel!
    var chatController: ChatWindowController!
    var statusBarController: StatusBarController!
    var inputBarController: InputBarWindowController!
    let eventBus = EventBus()
    var databaseManager: DatabaseManager?
    var isPersistenceAvailable: Bool = true
    let capabilityManager = CapabilityManager()
    var pluginManager: PluginManager!
    var configManager: ConfigManager!
    var spritePackManager: SpritePackManager!
    var spritePackImporter: SpritePackImporter!
    var aiProactiveTrigger: AIProactiveTrigger?
    var aiStatus: AIEngine.AIEngineStatus = .notConfigured
    var ollamaService: OllamaService?
    var interactionManager: PetInteractionManager!
    var desktopAwareness = DesktopAwarenessController()
    var timeWeatherController = TimeWeatherController()
    var miniGameManager = MiniGameManager()
    var pomodoroController = PomodoroController()
    var conversationTurnCount = 0
    let maximumPets = 5
    let windowDetector = WindowDetector()
    var dailyCleanupTimer: Timer?
    var permissionAlertShown = false
    var screenStateCoordinator: ScreenStateCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        petCoordinator.appDelegate = self
        appBootstrapper.appDelegate = self
        Task { @MainActor in
            await appBootstrapper.bootstrap()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        dailyCleanupTimer?.invalidate()
        dailyCleanupTimer = nil
        aiProactiveTrigger?.stop()
        timeWeatherController.stop()
        screenStateCoordinator?.stop()
        VitaPetApp.releaseAppLock()

        let eventBus = eventBus
        let dispatcher = eventDispatcher
        let pluginManager = pluginManager

        Task {
            await dispatcher.stop(eventBus: eventBus)
            await pluginManager?.stop()
        }
    }

    // MARK: - Event handling (stays in AppDelegate – accesses all fields)

    func handleEvent(_ event: AppEvent) async {
        recordEvent(event)

        if case .custom(let name, let payload) = event, name == "plugin.notification.request" {
            showNotification(
                title: payload["title"] ?? "VitaPet",
                body: payload["body"] ?? ""
            )
        }

        if case .custom(let name, _) = event, name == "permissionMissing", !permissionAlertShown {
            permissionAlertShown = true
            await MainActor.run {
                let alert = NSAlert()
                alert.messageText = "桌面感知不可用"
                alert.informativeText = "桌面感知不可用：需在系统设置授予屏幕录制权限"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "好的")
                alert.runModal()
            }
        }

        if case let .notificationReceived(source, title, body) = event {
            let fallbackText = body.isEmpty ? "[\(source)] \(title)" : "[\(source)] \(title)\n\(body)"
            let animState: AnimationState = (source == "GitHub" || source == "Calendar") ? .alert : .listen

            for controller in petCoordinator.petWindowControllers.values {
                controller.petScene.playAnimation(for: animState)
            }

            // Try AI-enhanced display if Ollama is ready
            if let ollamaService {
                Task {
                    do {
                        let context = "你收到一条通知：来源=\(source)，标题=\(title)，内容=\(body)。用一句可爱的话转述给主人。"
                        let aiText = try await ollamaService.generateProactive(context: context)
                        await MainActor.run {
                            self.petCoordinator.primaryPetController?.showBubble(aiText.isEmpty ? fallbackText : aiText)
                        }
                    } catch {
                        await MainActor.run {
                            self.petCoordinator.primaryPetController?.showBubble(fallbackText)
                        }
                    }
                }
            } else {
                petCoordinator.primaryPetController?.showBubble(fallbackText)
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

        for controller in petCoordinator.petWindowControllers.values {
            await controller.handleAnimationTrigger(trigger)
        }
    }

    // MARK: - Helpers called from AppBootstrapper / PetCoordinator

    func refreshChatIfOpen() {
        guard chatController.window?.title == "VitaPet Chat" else {
            return
        }
        chatController.showChat()
    }

    func initializeConversations(
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

    func createSingleConversationIfNeeded(for pet: PetIdentity) async {
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

    func fallbackConversationId(for participantIds: Set<UUID>) -> String? {
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

    func recordEvent(_ event: AppEvent) {
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

    func warmupSecurityState() async {
        _ = PermissionGate.checkPermission(.accessibility)
        _ = await capabilityManager.status(of: .basePet)
    }

    private func showNotification(title: String, body: String) {
        // Show notification as pet bubble instead of blocking NSAlert.
        let text = body.isEmpty ? title : "\(title): \(body)"
        petCoordinator.primaryPetController?.showBubble(text)
    }

    func setMiniGameSystemsPaused(_ paused: Bool) {
        if paused {
            desktopAwareness.clearDesktopBehavior()
            Task {
                await self.eventDispatcher.timerSource?.stop()
            }
            return
        }

        // 游戏结束，恢复所有宠物到 idle
        for controller in petCoordinator.petWindowControllers.values {
            controller.transitionToState("idle")
        }

        Task {
            guard let timerSource = self.eventDispatcher.timerSource else { return }
            await timerSource.stop()
            await timerSource.start(publishingTo: self.eventBus)
        }
    }

    func buildPetProfileDescription(for pet: PetIdentity) -> String {
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

    func installBuiltInPluginsIfNeeded() throws {
        guard let pluginsDirectory = PluginLoader.pluginDirectories().first else {
            return
        }

        try FileManager.default.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)

        // 逐个检查，缺的才安装
        for plugin in Self.builtInDeclarativePlugins {
            let pluginDir = pluginsDirectory.appendingPathComponent(plugin.directoryName, isDirectory: true)
            let manifestPath = pluginDir.appendingPathComponent("plugin.json")
            if !FileManager.default.fileExists(atPath: manifestPath.path) {
                try writePluginManifest(plugin.manifest, to: pluginDir)
            }
        }
    }

    func installBuiltInSpritePacksIfNeeded() throws {
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

    func createDeclarativePluginTemplate(
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

    func deletePlugin(id: String) async throws {
        let plugins = await pluginManager.listPlugins()
        guard let plugin = plugins.first(where: { $0.id == id }),
              let directory = plugin.directory
        else {
            throw PluginCreationError.invalidPluginDirectory
        }

        try FileManager.default.removeItem(at: directory)
        await pluginManager.reloadPlugins()
    }

    func revealPluginInFinder(id: String) {
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

    func showPersistenceFailureAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "数据持久化不可用"
        alert.informativeText = "本次会话的统计、记忆、对话历史不会被保存。请检查磁盘空间或文件权限。"
        alert.addButton(withTitle: "了解")
        let finderButton = alert.addButton(withTitle: "在 Finder 中打开 ~/Library/Application Support/VitaPet 目录")
        finderButton.keyEquivalent = ""
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            let supportURL = FileManager.default
                .homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/VitaPet", isDirectory: true)
            NSWorkspace.shared.open(supportURL)
        }
    }

    // MARK: - Daily cleanup

    func scheduleDailyCleanup(databaseManager: DatabaseManager) {
        // Run once immediately on startup.
        Task { [weak databaseManager] in
            try? await databaseManager?.pruneOldEvents(keepDays: 30)
        }

        // Schedule a repeating 24-hour timer on the main run loop.
        let timer = Timer.scheduledTimer(
            withTimeInterval: 86_400,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let db = self?.databaseManager else { return }
                try? await db.pruneOldEvents(keepDays: 30)
            }
        }
        dailyCleanupTimer = timer
    }

    // MARK: - Static helpers (must stay here – AIProactiveTrigger calls AppDelegate.parseActionTags)

    nonisolated static func chatUIStatus(from status: AIEngine.AIEngineStatus) -> ChatUI.AIEngineStatus {
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

    static func encodeEventPayload(from metadata: [String: String]) throws -> String {
        try encodePayload(metadata)
    }

    static func encodeMoodChangePayload(_ payload: MoodChangeEventPayload) throws -> String {
        try encodePayload(payload)
    }

    static func encodePetBehaviorPayload(_ payload: PetBehaviorEventPayload) throws -> String {
        try encodePayload(payload)
    }

    static func encodePetClickPayload(_ payload: PetClickEventPayload) throws -> String {
        try encodePayload(payload)
    }

    static func encodePetInteractionPayload(_ payload: PetInteractionEventPayload) throws -> String {
        try encodePayload(payload)
    }

    static func encodeGamePlayPayload(_ payload: GamePlayEventPayload) throws -> String {
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

struct MoodChangeEventPayload: Encodable {
    let petId: String
    let petName: String
    let happiness: Int
    let delta: Int
    let level: String
}

struct PetBehaviorEventPayload: Encodable {
    let petId: String
    let petName: String
    let state: String
}

struct PetClickEventPayload: Encodable {
    let petId: String
    let petName: String
    let type: String
}

struct PetInteractionEventPayload: Encodable {
    let type: String
    let pets: [String]
}

struct GamePlayEventPayload: Encodable {
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
                version: "1.0",
                description: "每45分钟提醒你站起来活动",
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
                version: "1.0",
                description: "每小时报时",
                capabilities: [],
                triggers: [
                    TriggerRule(
                        event: "timerFired",
                        conditions: [:],
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

    /// Parse [ACTION:xxx] tags from AI response text.
    /// Returns cleaned text (tags removed) and list of action names.
    static func parseActionTags(from text: String) -> (cleanText: String, actions: [String]) {
        var actions: [String] = []
        let pattern = #"\[ACTION:(\w+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return (text, [])
        }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        for match in matches {
            if let actionRange = Range(match.range(at: 1), in: text) {
                actions.append(String(text[actionRange]))
            }
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

func requestAccessibilityPermission() {
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    AXIsProcessTrustedWithOptions(options)
}
