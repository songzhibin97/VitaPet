import Localization
import SwiftUI

@MainActor
struct ConversationListView: View {
    let conversations: [ConversationThread]
    let selectedId: String?
    let onSelect: (String) -> Void
    let onDelete: (String) -> Void
    let onCreateGroup: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.chatConversations)
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            List {
                ForEach(conversations) { thread in
                    ConversationRow(thread: thread, isSelected: thread.id == selectedId)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onSelect(thread.id)
                        }
                        .contextMenu {
                            if thread.type == .group {
                                Button(L10n.chatDeleteConversation, role: .destructive) {
                                    onDelete(thread.id)
                                }
                            }
                        }
                }
            }
            .listStyle(.sidebar)

            Divider()

            Button(action: onCreateGroup) {
                Label(L10n.chatNewGroup, systemImage: "plus.bubble")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
        }
    }
}

struct ConversationRow: View {
    let thread: ConversationThread
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(thread.type == .group ? Color.purple.opacity(0.2) : Color.blue.opacity(0.2))
                    .frame(width: 36, height: 36)

                Image(systemName: thread.type == .group ? "person.3.fill" : "pawprint.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(thread.type == .group ? .purple : .blue)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(thread.title.isEmpty ? fallbackTitle : thread.title)
                    .font(.headline)
                    .lineLimit(1)

                if !thread.lastMessage.isEmpty {
                    Text(thread.lastMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if thread.unreadCount > 0 {
                Text("\(thread.unreadCount)")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.red)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        )
    }

    private var fallbackTitle: String {
        thread.type == .group ? L10n.chatGroupChat : L10n.chatSingleChat
    }
}
