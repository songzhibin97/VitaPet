import Localization
import Observation
import SwiftUI

@MainActor
public struct TabbedChatView: View {
    @Bindable var viewModel: ChatViewModel
    let availablePets: [(id: UUID, name: String)]

    @State private var showCreateGroup = false

    public init(viewModel: ChatViewModel, availablePets: [(id: UUID, name: String)] = []) {
        self.viewModel = viewModel
        self.availablePets = availablePets
    }

    public var body: some View {
        NavigationSplitView {
            ConversationListView(
                conversations: viewModel.conversations,
                selectedId: viewModel.selectedConversationId,
                onSelect: { id in
                    viewModel.selectConversation(id)
                },
                onDelete: { id in
                    viewModel.deleteConversation(id)
                },
                onCreateGroup: {
                    showCreateGroup = true
                }
            )
            .navigationSplitViewColumnWidth(min: 250, ideal: 280, max: 320)
        } detail: {
            if viewModel.selectedConversationId != nil {
                ChatView(viewModel: viewModel)
            } else {
                emptyDetailState
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, minHeight: 580)
        .toolbar(removing: .sidebarToggle)
        .sheet(isPresented: $showCreateGroup) {
            CreateGroupView(
                availablePets: availablePets,
                onCreate: { title, memberIds in
                    _ = viewModel.createGroupChat(title: title, participantIds: memberIds)
                    showCreateGroup = false
                },
                onCancel: {
                    showCreateGroup = false
                }
            )
        }
    }

    private var emptyDetailState: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .underPageBackgroundColor)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.15, green: 0.17, blue: 0.22),
                                    Color(red: 0.26, green: 0.29, blue: 0.36)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                }
                .frame(width: 92, height: 92)

                VStack(spacing: 6) {
                    Text("选择一个会话")
                        .font(.title2.weight(.semibold))
                    Text(L10n.chatNoConversation)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    detailChip(title: "本地模型", symbolName: "cpu")
                    detailChip(title: "桌面宠物", symbolName: "pawprint.fill")
                    detailChip(title: "多宠群聊", symbolName: "person.3.fill")
                }
            }
            .padding(36)
        }
    }

    private func detailChip(title: String, symbolName: String) -> some View {
        Label(title, systemImage: symbolName)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.05), in: Capsule())
    }
}

@MainActor
struct CreateGroupView: View {
    let availablePets: [(id: UUID, name: String)]
    let onCreate: (String, [UUID]) -> Void
    let onCancel: () -> Void

    @State private var groupName = ""
    @State private var selectedMembers: Set<UUID> = []

    var body: some View {
        VStack(spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.accentColor,
                                    Color.accentColor.opacity(0.72)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: Color.accentColor.opacity(0.3), radius: 6, x: 0, y: 3)

                    Image(systemName: "person.3.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.chatCreateGroup)
                        .font(.title3.weight(.semibold))
                    Text("把多只宠物放进同一个会话里。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.chatGroupName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField(L10n.chatGroupNamePlaceholder, text: $groupName)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                    }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L10n.chatSelectMembers)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(selectedMembers.count) / \(availablePets.count)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tertiary)
                }

                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(availablePets, id: \.id) { pet in
                            let isSelected = selectedMembers.contains(pet.id)
                            HStack(spacing: 10) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.6))
                                Text(pet.name)
                                    .font(.subheadline)
                                    .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.85))
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(
                                        isSelected
                                            ? AnyShapeStyle(
                                                LinearGradient(
                                                    colors: [
                                                        Color.accentColor.opacity(0.18),
                                                        Color.accentColor.opacity(0.08)
                                                    ],
                                                    startPoint: .topLeading,
                                                    endPoint: .bottomTrailing
                                                )
                                            )
                                            : AnyShapeStyle(Color(nsColor: .textBackgroundColor).opacity(0.6))
                                    )
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(
                                        isSelected ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.08),
                                        lineWidth: 1
                                    )
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if isSelected {
                                    selectedMembers.remove(pet.id)
                                } else {
                                    selectedMembers.insert(pet.id)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 240)
            }

            HStack(spacing: 10) {
                Button(L10n.settingsPetManagementCancel) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.chatCreateGroup) {
                    let trimmedName = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let name = trimmedName.isEmpty ? "Group" : trimmedName
                    onCreate(name, Array(selectedMembers))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedMembers.count < 2)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 380)
        .onAppear {
            selectedMembers = Set(availablePets.map(\.id))
        }
    }
}
