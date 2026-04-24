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
            .frame(minWidth: 180, maxWidth: 220)
        } detail: {
            if viewModel.selectedConversationId != nil {
                ChatView(viewModel: viewModel)
            } else {
                Text(L10n.chatNoConversation)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 620, minHeight: 520)
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
}

@MainActor
struct CreateGroupView: View {
    let availablePets: [(id: UUID, name: String)]
    let onCreate: (String, [UUID]) -> Void
    let onCancel: () -> Void

    @State private var groupName = ""
    @State private var selectedMembers: Set<UUID> = []

    var body: some View {
        VStack(spacing: 16) {
            Text(L10n.chatCreateGroup)
                .font(.title2)
                .bold()

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.chatGroupName)
                    .font(.headline)
                TextField(L10n.chatGroupNamePlaceholder, text: $groupName)
                    .textFieldStyle(.roundedBorder)
            }

            Text(L10n.chatSelectMembers)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(availablePets, id: \.id) { pet in
                        HStack {
                            Image(systemName: selectedMembers.contains(pet.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedMembers.contains(pet.id) ? Color.accentColor : .secondary)
                            Text(pet.name)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selectedMembers.contains(pet.id) {
                                selectedMembers.remove(pet.id)
                            } else {
                                selectedMembers.insert(pet.id)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
            .frame(maxHeight: 220)

            HStack {
                Button(L10n.settingsPetManagementCancel) {
                    onCancel()
                }
                Spacer()
                Button(L10n.chatCreateGroup) {
                    let trimmedName = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let name = trimmedName.isEmpty ? "Group" : trimmedName
                    onCreate(name, Array(selectedMembers))
                }
                .disabled(selectedMembers.count < 2)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear {
            selectedMembers = Set(availablePets.map(\.id))
        }
    }
}
