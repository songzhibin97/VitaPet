import Foundation
import Observation

@MainActor
@Observable
public final class PluginSettingsViewModel {
    public struct PluginItem: Identifiable, Sendable {
        public let id: String
        public let name: String
        public let version: String
        public let description: String
        public let directory: URL?
        public let isDeclarative: Bool
        public let isBuiltIn: Bool
        public var isEnabled: Bool

        public init(
            id: String,
            name: String,
            version: String,
            description: String,
            directory: URL?,
            isDeclarative: Bool,
            isBuiltIn: Bool,
            isEnabled: Bool
        ) {
            self.id = id
            self.name = name
            self.version = version
            self.description = description
            self.directory = directory
            self.isDeclarative = isDeclarative
            self.isBuiltIn = isBuiltIn
            self.isEnabled = isEnabled
        }
    }

    public typealias PluginSnapshot = (
        id: String,
        name: String,
        version: String,
        description: String,
        directory: URL?,
        isDeclarative: Bool,
        isBuiltIn: Bool,
        isEnabled: Bool
    )

    public private(set) var plugins: [PluginItem] = []

    private let loadPlugins: @Sendable () async -> [PluginSnapshot]
    private let setEnabled: @Sendable (String, Bool) async throws -> Void

    public init(
        loadPlugins: @escaping @Sendable () async -> [PluginSnapshot],
        setEnabled: @escaping @Sendable (String, Bool) async throws -> Void
    ) {
        self.loadPlugins = loadPlugins
        self.setEnabled = setEnabled
    }

    public func refresh() async {
        plugins = await loadPlugins().map {
            PluginItem(
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
    }

    public func togglePlugin(_ id: String, enabled: Bool) {
        guard let index = plugins.firstIndex(where: { $0.id == id }) else {
            return
        }

        plugins[index].isEnabled = enabled

        Task { @MainActor in
            do {
                try await setEnabled(id, enabled)
            } catch {
                plugins[index].isEnabled.toggle()
            }
            await refresh()
        }
    }
}
