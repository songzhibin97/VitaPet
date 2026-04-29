import Localization
import SwiftUI

// MARK: - NotificationSection

@MainActor
struct NotificationSection: View {
    @Binding var githubToken: String
    @Binding var webhookEnabled: Bool
    @Binding var webhookPort: Int
    @Binding var webhookSecret: String

    let onSaveNotificationConfig: @MainActor (String, Bool, Int, String) -> Void

    var body: some View {
        Section(L10n.settingsNotifications) {
            Text(L10n.settingsNotificationsGithub)
                .font(.headline)

            Text(L10n.settingsNotificationsGithubToken)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            SecureField(L10n.settingsNotificationsGithubTokenPlaceholder, text: $githubToken)
                .textFieldStyle(.roundedBorder)
                .onChange(of: githubToken) { _, newValue in
                    onSaveNotificationConfig(newValue, webhookEnabled, webhookPort, webhookSecret)
                }

            Text(L10n.settingsNotificationsWebhook)
                .font(.headline)

            Toggle(L10n.settingsNotificationsWebhookEnabled, isOn: $webhookEnabled)
                .onChange(of: webhookEnabled) { _, newValue in
                    onSaveNotificationConfig(githubToken, newValue, webhookPort, webhookSecret)
                }

            if webhookEnabled {
                HStack {
                    Text(L10n.settingsNotificationsWebhookPort)

                    TextField("19280", value: $webhookPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .onChange(of: webhookPort) { _, newValue in
                            onSaveNotificationConfig(githubToken, webhookEnabled, newValue, webhookSecret)
                        }
                }

                SecureField("Webhook Secret (可选)", text: $webhookSecret)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: webhookSecret) { _, newValue in
                        onSaveNotificationConfig(githubToken, webhookEnabled, webhookPort, newValue)
                    }

                Text(String(format: L10n.settingsNotificationsWebhookHint, webhookPort))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
