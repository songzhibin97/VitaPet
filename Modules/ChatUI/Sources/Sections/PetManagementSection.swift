import Foundation
import Localization
import RenderEngine
import SwiftUI

// MARK: - PetManagementSection

@MainActor
struct PetManagementSection: View {
    // ── state ──
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

    // ── props ──
    @Binding var petProfiles: [PetProfileItem]
    let spritePackItems: [SpritePackDisplayItem]
    let soundEnabled: Bool
    let soundVolume: Double
    let canAddMorePets: Bool
    let loadPetProfiles: @MainActor () -> [PetProfileItem]
    let onUpdatePet: @MainActor (UUID, String, String, Double, String, String, String, String) -> Void
    let onUpdatePetSound: @MainActor (UUID, Bool?, Float?) -> Void
    let onUpdatePetLanguage: @MainActor (UUID, [String: [String]]?) -> String?
    let onRemovePet: @MainActor (UUID) -> Void
    let onAddPet: @MainActor () -> Void
    let onResetLanguage: (@MainActor (UUID) -> Void)?
    let onResetAttributes: (@MainActor (UUID) -> Void)?
    let onResetAll: (@MainActor (UUID) -> Void)?
    let onError: @MainActor (String) -> Void

    var body: some View {
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
                                    onError(message)
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
    }

    // MARK: - helpers

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
}

// MARK: - collapsibleSection helper (used by PetManagementSection)

@MainActor
@ViewBuilder
func collapsibleSection<Content: View>(
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

// MARK: - LanguagePackEditor

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
