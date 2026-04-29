import Localization
import SwiftUI

// MARK: - Data models (plugin editor)

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

private struct PersistedTriggerRule: Codable {
    let event: String
    let conditions: [String: String]
    let actions: [PersistedPluginAction]
}

private struct PersistedPluginManifest: Codable {
    let id: String
    let name: String
    let version: String
    let description: String
    let capabilities: [String]
    let triggers: [PersistedTriggerRule]
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

// MARK: - PluginTemplateOption

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

// MARK: - PluginManagementSection

@MainActor
struct PluginManagementSection: View {
    @Binding var editingPluginID: String?
    @Binding var pluginSettingsViewModel: PluginSettingsViewModel

    let onCreatePlugin: @MainActor (String, String, String) async -> String?
    let onDeletePlugin: @MainActor (String) async -> String?
    let onRevealPluginInFinder: @MainActor (String) -> Void
    let onReloadPlugins: @MainActor () async -> String?
    let onError: @MainActor (String) -> Void

    @State private var showPluginCreator = false
    @State private var newPluginName = ""
    @State private var newPluginDescription = ""
    @State private var selectedPluginTemplate = PluginTemplateOption.blank
    @State private var showPluginDeleteConfirm = false
    @State private var pendingPluginDeleteID: String?

    var body: some View {
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
                                onError(message)
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
        .alert("确认卸载插件？", isPresented: $showPluginDeleteConfirm) {
            Button("卸载插件", role: .destructive) {
                guard let id = pendingPluginDeleteID else {
                    return
                }

                Task {
                    if let error = await onDeletePlugin(id) {
                        onError(error)
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
        .sheet(isPresented: $showPluginCreator) {
            pluginCreatorSheet
        }
    }

    private func togglePluginEditor(for pluginID: String) {
        editingPluginID = editingPluginID == pluginID ? nil : pluginID
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
                        onError("请输入插件名称")
                        return
                    }

                    Task {
                        if let error = await onCreatePlugin(name, description, selectedPluginTemplate.rawValue) {
                            onError(error)
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
}

// MARK: - PluginTriggerEditor

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

// MARK: - PluginKeyValueEditor

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
