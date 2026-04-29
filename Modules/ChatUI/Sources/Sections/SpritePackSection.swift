import Localization
import SwiftUI

// MARK: - SpritePackSection

@MainActor
struct SpritePackSection: View {
    let spritePackItems: [SpritePackDisplayItem]
    let onImportPack: @MainActor () async -> String?
    let onExportPack: @MainActor (String) async -> String?
    let onDeletePack: @MainActor (String) async -> String?
    let onRevealInFinder: @MainActor (String) -> Void
    let onCreateTemplate: @MainActor () async -> String?
    let onError: @MainActor (String) -> Void

    @State private var showDeleteConfirm: Bool = false
    @State private var pendingDeleteID: String?

    var body: some View {
        Section(L10n.settingsSpritePacks) {
            if spritePackItems.isEmpty {
                Text(L10n.settingsNoSpritePacks)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(spritePackItems) { item in
                    spritePackRow(for: item)
                }
            }

            HStack(spacing: 12) {
                Button(L10n.settingsSpritePacksImport) {
                    Task {
                        if let error = await onImportPack() {
                            onError(error)
                        }
                    }
                }

                Button(L10n.settingsSpritePacksCreateTemplate) {
                    Task {
                        if let error = await onCreateTemplate() {
                            onError(error)
                        }
                    }
                }
            }
            .padding(.top, 4)
        }
        .alert(L10n.settingsSpritePacksDeleteConfirm, isPresented: $showDeleteConfirm) {
            Button(L10n.settingsSpritePacksDelete, role: .destructive) {
                guard let id = pendingDeleteID else {
                    return
                }
                Task {
                    if let error = await onDeletePack(id) {
                        onError(error)
                    }
                    pendingDeleteID = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteID = nil
            }
        }
    }

    @ViewBuilder
    private func spritePackRow(for item: SpritePackDisplayItem) -> some View {
        let packDirectory: URL? = item.directory

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                SpritePackPreviewView(packDirectory: packDirectory, previewSize: 48)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(item.name)
                            .font(.headline)

                        if item.isBuiltIn {
                            Text(L10n.settingsSpritePacksBuiltIn)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.2))
                                .clipShape(Capsule())
                        }
                    }

                    Text(spritePackMetadataText(for: item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(L10n.settingsSpritePacksRevealFinder) {
                    onRevealInFinder(item.id)
                }
                .buttonStyle(.borderless)

                if !item.isBuiltIn {
                    Button(L10n.settingsSpritePacksExport) {
                        Task {
                            if let error = await onExportPack(item.id) {
                                onError(error)
                            }
                        }
                    }
                    .buttonStyle(.borderless)

                    Button(L10n.settingsSpritePacksDelete, role: .destructive) {
                        pendingDeleteID = item.id
                        showDeleteConfirm = true
                    }
                    .buttonStyle(.borderless)
                }
            }
            .contextMenu {
                Button(L10n.settingsSpritePacksRevealFinder) {
                    onRevealInFinder(item.id)
                }

                if !item.isBuiltIn {
                    Button(L10n.settingsSpritePacksExport) {
                        Task {
                            if let error = await onExportPack(item.id) {
                                onError(error)
                            }
                        }
                    }

                    Divider()

                    Button(L10n.settingsSpritePacksDelete, role: .destructive) {
                        pendingDeleteID = item.id
                        showDeleteConfirm = true
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func spritePackMetadataText(for item: SpritePackDisplayItem) -> String {
        let states = String(format: L10n.settingsSpritePacksStatesCount, item.stateCount)
        let frames = String(format: L10n.settingsSpritePacksFramesCount, item.totalFrameCount)
        return "\(states) · \(frames)"
    }
}
