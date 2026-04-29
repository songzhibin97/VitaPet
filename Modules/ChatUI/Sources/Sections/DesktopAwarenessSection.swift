import EventBus
import RenderEngine
import SwiftUI

// MARK: - EditableDesktopAwarenessRule

struct EditableDesktopAwarenessRule: Identifiable {
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

// MARK: - DesktopAwarenessSection

@MainActor
struct DesktopAwarenessSection: View {
    @Binding var desktopAwarenessEnabled: Bool
    @Binding var desktopAwarenessRules: [EditableDesktopAwarenessRule]
    @Binding var expandedDesktopRuleIDs: Set<UUID>
    @Binding var desktopAwarenessStatusMessage: String?

    let availableAnimations: [String]
    let onSetDesktopAwarenessEnabled: @MainActor (Bool) -> Void
    let onSaveDesktopAwarenessRules: @MainActor ([AppBehaviorRule]) -> String?

    var body: some View {
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
                        availableAnimations: availableAnimations,
                        onDelete: {
                            removeRule(id: ruleID)
                        }
                    )
                }
            }

            HStack {
                Button {
                    addRule()
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
                    saveRules()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
    }

    private func addRule() {
        let newRule = EditableDesktopAwarenessRule(
            category: "new-rule",
            bundleIdPatterns: [""],
            animation: availableAnimations.first ?? "idle",
            bubbleTexts: [""],
            bubbleInterval: 30
        )
        desktopAwarenessRules.append(newRule)
        expandedDesktopRuleIDs.insert(newRule.id)
        desktopAwarenessStatusMessage = nil
    }

    private func removeRule(id: UUID) {
        desktopAwarenessRules.removeAll { $0.id == id }
        expandedDesktopRuleIDs.remove(id)
        desktopAwarenessStatusMessage = nil
    }

    private func saveRules() {
        let rulesToSave = desktopAwarenessRules.map(\.appBehaviorRule)
        if let error = onSaveDesktopAwarenessRules(rulesToSave) {
            desktopAwarenessStatusMessage = error
        } else {
            desktopAwarenessStatusMessage = "已保存"
        }
    }
}

// MARK: - DesktopAwarenessRuleEditor

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

// MARK: - EditableStringList

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
