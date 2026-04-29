import Localization
import SwiftUI

// MARK: - CapabilitiesSection

@MainActor
struct CapabilitiesSection: View {
    @Binding var capabilityItems: [CapabilityItem]

    var body: some View {
        Section(L10n.settingsCapabilities) {
            ForEach($capabilityItems) { $item in
                HStack(alignment: .center, spacing: 14) {
                    Circle()
                        .fill(statusColor(for: item.status))
                        .frame(width: 10, height: 10)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name)
                            .font(.headline)

                        Text(item.description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Toggle("", isOn: $item.isEnabled)
                        .labelsHidden()
                        .onChange(of: item.isEnabled) { _, newValue in
                            item.status = newValue ? .active : .inactive
                        }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func statusColor(for status: CapabilityItemStatus) -> Color {
        switch status {
        case .active:
            return .green
        case .needsPermission:
            return .yellow
        case .inactive:
            return .gray
        }
    }
}
