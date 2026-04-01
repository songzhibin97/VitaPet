import SwiftUI

@MainActor
public struct MessageBubble: View {
    let message: ChatMessage

    public init(message: ChatMessage) {
        self.message = message
    }

    public var body: some View {
        HStack {
            if isUserMessage {
                Spacer(minLength: 48)
            }

            VStack(alignment: isUserMessage ? .trailing : .leading, spacing: 6) {
                bubbleBody

                Text(timestampText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 420, alignment: isUserMessage ? .trailing : .leading)

            if !isUserMessage {
                Spacer(minLength: 48)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUserMessage ? .trailing : .leading)
    }

    private var isUserMessage: Bool {
        message.role == .user
    }

    private var bubbleColor: Color {
        switch message.role {
        case .user:
            return .blue
        case .assistant:
            return Color(nsColor: .quaternaryLabelColor).opacity(0.14)
        case .system:
            return Color(nsColor: .tertiaryLabelColor).opacity(0.18)
        }
    }

    private var foregroundColor: Color {
        message.role == .user ? .white : .primary
    }

    @ViewBuilder
    private var bubbleBody: some View {
        HStack(spacing: 0) {
            if showsPetAccent {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(petAccentColor)
                    .frame(width: 2)
                    .padding(.vertical, 8)
                    .padding(.leading, 8)
            }

            VStack(alignment: isUserMessage ? .trailing : .leading, spacing: 0) {
                if showsPetAccent, let petName = message.petName {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(petAccentColor)
                            .frame(width: 8, height: 8)
                        Text(petName)
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(petAccentColor)
                    }
                    .padding(.bottom, 2)
                }

                Text(message.content)
                    .textSelection(.enabled)
                    .foregroundStyle(foregroundColor)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: isUserMessage ? .trailing : .leading)
        }
        .background(bubbleColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var showsPetAccent: Bool {
        message.role == .assistant && message.petName != nil
    }

    private var petAccentColor: Color {
        petColor(for: message.petId)
    }

    private func petColor(for petId: UUID?) -> Color {
        guard let petId else { return .secondary }
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo, .mint]
        let index = abs(petId.hashValue) % colors.count
        return colors[index]
    }

    private var timestampText: String {
        message.timestamp.formatted(date: .omitted, time: .shortened)
    }
}
