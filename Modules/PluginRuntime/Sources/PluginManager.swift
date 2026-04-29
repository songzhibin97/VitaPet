import EventBus
import Foundation
import OSLog
import Persistence
import SecurityLayer

public actor PluginManager: EventSource {
    public let sourceId: String = "pluginManager"

    private let loader: PluginLoader
    private let pluginDirectories: @Sendable () -> [URL]
    private let configManager: ConfigManager
    private var handles: [String: PluginHandle] = [:]
    private weak var eventBus: EventBus?
    private var eventSubscriptionId: UUID?
    private var directoryWatcher: PluginDirectoryWatcher?
    private var triggerDeduplicationTokens: [String: String] = [:]

    public var onBubbleRequest: (@MainActor @Sendable (String) -> Void)?
    public var onMoodRequest: (@MainActor @Sendable (Int) -> Void)?

    private static let logger = Logger(subsystem: "VitaPet", category: "PluginManager")
    private static let builtInPluginIDs: Set<String> = [
        "com.vitapet.sit-reminder",
        "com.vitapet.git-celebrate-json",
        "com.vitapet.hourly-chime",
        "com.vitapet.birthday"
    ]

    public init(
        loader: PluginLoader,
        configManager: ConfigManager,
        pluginDirectories: @escaping @Sendable () -> [URL] = PluginLoader.pluginDirectories
    ) {
        self.loader = loader
        self.configManager = configManager
        self.pluginDirectories = pluginDirectories
    }

    public func listPlugins() async -> [PluginInfo] {
        let disabledPlugins = await MainActor.run {
            Set(configManager.config.disabledPlugins)
        }

        return handles.values
            .map { handle in
                PluginInfo(
                    id: handle.manifest.id,
                    name: handle.manifest.name,
                    version: handle.manifest.version,
                    description: handle.manifest.description,
                    isEnabled: !disabledPlugins.contains(handle.manifest.id),
                    directory: handle.bundleURL,
                    isDeclarative: handle.executableURL == nil,
                    isBuiltIn: Self.builtInPluginIDs.contains(handle.manifest.id)
                )
            }
            .sorted {
                if $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedSame {
                    return $0.id < $1.id
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    public func isPluginEnabled(_ id: String) async -> Bool {
        let disabledPlugins = await MainActor.run {
            Set(configManager.config.disabledPlugins)
        }
        return !disabledPlugins.contains(id)
    }

    public func setPluginEnabled(id: String, enabled: Bool) async throws {
        try await MainActor.run {
            try configManager.update { config in
                var disabledPlugins = Set(config.disabledPlugins)
                if enabled {
                    disabledPlugins.remove(id)
                } else {
                    disabledPlugins.insert(id)
                }
                config.disabledPlugins = disabledPlugins.sorted()
            }
        }
    }

    public func start(publishingTo eventBus: EventBus) async {
        guard eventSubscriptionId == nil else {
            return
        }

        self.eventBus = eventBus
        eventSubscriptionId = await eventBus.subscribe { [weak self] event in
            guard let self else {
                return
            }

            await self.routeEvent(event)
        }

        await loadAllPlugins()

        let directories = pluginDirectories()
        directoryWatcher = PluginDirectoryWatcher(directories: directories) { [weak self] _ in
            guard let self else {
                return
            }

            await self.loadAllPlugins()
        }
        directoryWatcher?.start()
    }

    public func setBubbleRequestHandler(_ handler: (@MainActor @Sendable (String) -> Void)?) {
        onBubbleRequest = handler
    }

    public func setMoodRequestHandler(_ handler: (@MainActor @Sendable (Int) -> Void)?) {
        onMoodRequest = handler
    }

    public func stop() async {
        directoryWatcher?.stop()
        directoryWatcher = nil
        triggerDeduplicationTokens.removeAll()

        if let eventBus, let eventSubscriptionId {
            await eventBus.unsubscribe(eventSubscriptionId)
        }
        eventSubscriptionId = nil
        eventBus = nil

        let ids = Array(handles.keys)
        for id in ids {
            await unloadPlugin(id: id)
        }
    }

    private func loadAllPlugins() async {
        let fileManager = FileManager.default
        let directories = pluginDirectories()

        for directory in directories {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                Self.logger.error("Failed to create plugin directory \(directory.path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        do {
            let bundles = try directories.flatMap { try loader.discover(in: $0) }
            let bundleIds = Set(bundles.map(\.manifest.id))
            let existingIds = Array(handles.keys)

            for id in existingIds where !bundleIds.contains(id) {
                await unloadPlugin(id: id)
            }

            for bundle in bundles {
                if handles[bundle.manifest.id] != nil {
                    await unloadPlugin(id: bundle.manifest.id)
                }
                await loadPlugin(bundle)
            }
        } catch {
Self.logger.error("Failed to reload plugins: \(String(describing: error), privacy: .public)")
        }
    }

    private func loadPlugin(_ bundle: PluginLoader.PluginBundle) async {
        handles[bundle.manifest.id] = PluginHandle(
            manifest: bundle.manifest,
            bundleURL: bundle.bundleURL,
            executableURL: bundle.executableURL
        )
Self.logger.info("Loaded plugin: \(bundle.manifest.name, privacy: .public) (\(bundle.manifest.id, privacy: .public))")
    }

    public func reloadPlugins() async {
        await loadAllPlugins()
    }

    public func unloadPlugin(id: String) async {
        guard let handle = handles.removeValue(forKey: id) else {
            return
        }

        Self.logger.info("Unloaded plugin: \(handle.manifest.id, privacy: .public)")
    }

    private func routeEvent(_ event: AppEvent) async {
        let disabledPlugins = await MainActor.run {
            Set(configManager.config.disabledPlugins)
        }

        for handle in handles.values where !disabledPlugins.contains(handle.manifest.id) {
            for (index, trigger) in handle.manifest.triggers.enumerated() where eventMatchesTrigger(trigger, event: event) {
                guard shouldExecuteTrigger(trigger, for: handle, triggerIndex: index, event: event) else {
                    continue
                }

                // Native plugin event routing is reserved for future XPC support.
                await executeActions(for: trigger, event: event)
            }
        }
    }

    func eventMatchesTrigger(_ rule: TriggerRule, event: AppEvent) -> Bool {
        guard rule.event == event.caseName else {
            return false
        }

        let eventMetadata = event.matchingMetadata
        for (key, value) in rule.conditions {
            if key == "pathPattern" || (key == "path" && value.containsWildcardPattern) {
                guard let path = eventMetadata["path"] else {
                    return false
                }

                if fnmatch(value, path, 0) != 0 {
                    return false
                }
                continue
            }

            guard let eventValue = eventMetadata[key], conditionMatches(value, eventValue: eventValue) else {
                return false
            }
        }

        return true
    }

    func handleAnimationRequest(_ stateName: String) async {
        guard let eventBus else {
            return
        }

        await eventBus.publish(.custom(name: stateName, payload: [:]))
    }

    func handleNotificationRequest(title: String, body: String) async {
        guard let eventBus else {
            return
        }

        await eventBus.publish(
            .custom(
                name: "plugin.notification.request",
                payload: [
                    "title": title,
                    "body": body
                ]
            )
        )
    }

    private func executeActions(for trigger: TriggerRule, event: AppEvent) async {
        for action in trigger.actions {
            switch action.type {
            case "animation":
                if let state = action.state {
await handleAnimationRequest(state)
                }
            case "bubble":
                if let message = action.message {
                    if let onBubbleRequest {
                        await onBubbleRequest(renderMessageTemplate(message, event: event))
                    }
                }
            case "mood":
                if let delta = resolveMoodDelta(for: action) {
                    if let onMoodRequest {
                        await onMoodRequest(delta)
                    }
                }
            case "notification":
                await handleNotificationRequest(
                    title: action.title ?? "VitaPet",
                    body: action.message ?? ""
                )
            case "event":
                if let name = action.name, let eventBus {
                    await eventBus.publish(.custom(name: name, payload: action.payload ?? [:]))
                }
            default:
                continue
            }
        }
    }

    private func shouldExecuteTrigger(
        _ trigger: TriggerRule,
        for handle: PluginHandle,
        triggerIndex: Int,
        event: AppEvent
    ) -> Bool {
        guard specialTriggerRequirementsSatisfied(trigger, for: handle, event: event) else {
            return false
        }

        guard let deduplicationToken = deduplicationToken(for: trigger, handle: handle, event: event) else {
            return true
        }

        let key = "\(handle.manifest.id)#\(triggerIndex)"
        if triggerDeduplicationTokens[key] == deduplicationToken {
            return false
        }

        triggerDeduplicationTokens[key] = deduplicationToken
        return true
    }

    private func specialTriggerRequirementsSatisfied(
        _ trigger: TriggerRule,
        for handle: PluginHandle,
        event: AppEvent
    ) -> Bool {
        switch handle.manifest.id {
        case "com.vitapet.hourly-chime":
            guard case .timerFired = event else {
                return false
            }
            return Calendar.current.component(.minute, from: Date()) == 0
        case "com.vitapet.birthday":
            guard case .timerFired = event else {
                return false
            }
            return birthdayMatches(conditions: trigger.conditions)
        default:
            return true
        }
    }

    private func deduplicationToken(
        for trigger: TriggerRule,
        handle: PluginHandle,
        event: AppEvent
    ) -> String? {
        let now = Date()
        switch handle.manifest.id {
        case "com.vitapet.hourly-chime":
            let hour = Calendar.current.dateComponents([.year, .month, .day, .hour], from: now)
            return "\(hour.year ?? 0)-\(hour.month ?? 0)-\(hour.day ?? 0)-\(hour.hour ?? 0)"
        case "com.vitapet.birthday":
            let day = Calendar.current.dateComponents([.year, .month, .day], from: now)
            return "\(day.year ?? 0)-\(day.month ?? 0)-\(day.day ?? 0)"
        default:
            return nil
        }
    }

    private func birthdayMatches(conditions: [String: String]) -> Bool {
        let now = Date()
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day], from: now)

        if let date = conditions["date"] {
            let parts = date.split(separator: "-").map(String.init)
            if parts.count == 3 {
                return parts[0] == String(components.year ?? 0)
                    && parts[1] == String(format: "%02d", components.month ?? 0)
                    && parts[2] == String(format: "%02d", components.day ?? 0)
            }
            if parts.count == 2 {
                return parts[0] == String(format: "%02d", components.month ?? 0)
                    && parts[1] == String(format: "%02d", components.day ?? 0)
            }
        }

        if let monthDay = conditions["monthDay"] {
            let today = String(format: "%02d-%02d", components.month ?? 0, components.day ?? 0)
            return monthDay == today
        }

        if let month = conditions["month"], let day = conditions["day"] {
            return month == String(components.month ?? 0) && day == String(components.day ?? 0)
        }

        return false
    }

    private func resolveMoodDelta(for action: PluginAction) -> Int? {
        if let delta = action.delta, let value = Int(delta) {
            return value
        }

        if let value = action.payload?["delta"], let delta = Int(value) {
            return delta
        }

        return nil
    }

    private func renderMessageTemplate(_ message: String, event: AppEvent) -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        return message.replacingOccurrences(of: "{hour}", with: String(hour))
    }

    private func conditionMatches(_ condition: String, eventValue: String) -> Bool {
        if condition.containsWildcardPattern {
            return fnmatch(condition, eventValue, 0) == 0
        }

        return eventValue == condition
    }
}

public struct PluginInfo: Sendable {
    public let id: String
    public let name: String
    public let version: String
    public let description: String
    public let isEnabled: Bool
    public let directory: URL?
    public let isDeclarative: Bool
    public let isBuiltIn: Bool

    public init(
        id: String,
        name: String,
        version: String,
        description: String,
        isEnabled: Bool,
        directory: URL? = nil,
        isDeclarative: Bool = false,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.isEnabled = isEnabled
        self.directory = directory
        self.isDeclarative = isDeclarative
        self.isBuiltIn = isBuiltIn
    }
}

struct PluginHandle: Sendable {
    let manifest: PluginManifest
    let bundleURL: URL
    let executableURL: URL?
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

    var matchingMetadata: [String: String] {
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
            var payload = payload
            payload["name"] = name
            return payload
        }
    }
}

private extension String {
    var containsWildcardPattern: Bool {
        contains("*") || contains("?")
    }
}
