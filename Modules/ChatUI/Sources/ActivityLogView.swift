import Localization
import SwiftUI

@MainActor
public struct ActivityLogView: View {
    @State private var activityLogViewModel: ActivityLogViewModel

    public init(
        activityLogViewModel: ActivityLogViewModel = ActivityLogViewModel(loadEvents: { _, _ in [] })
    ) {
        _activityLogViewModel = State(initialValue: activityLogViewModel)
    }

    public var body: some View {
        List {
            if let errorMessage = activityLogViewModel.errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .padding(.vertical, 6)
                }
            }

            Section(L10n.activityLogRecent) {
                if activityLogViewModel.events.isEmpty, !activityLogViewModel.isLoading {
                    Text(L10n.activityLogEmpty)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    ForEach(activityLogViewModel.events) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(
                                    entry.timestamp,
                                    format: Date.FormatStyle(
                                        date: .numeric,
                                        time: .standard
                                    )
                                )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Text(entry.source)
                                    .font(.headline)
                            }

                            Text(entry.summary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(3)
                        }
                        .padding(.vertical, 6)
                    }

                    if activityLogViewModel.isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    } else if activityLogViewModel.canLoadMore {
                        Button(L10n.activityLogLoadMore) {
                            Task { await activityLogViewModel.loadMore() }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
        }
        .listStyle(.inset)
        .navigationTitle(L10n.activityLogTitle)
        .frame(minWidth: 480, minHeight: 420)
        .task {
            if activityLogViewModel.events.isEmpty {
                await activityLogViewModel.refresh()
            }
        }
    }
}
