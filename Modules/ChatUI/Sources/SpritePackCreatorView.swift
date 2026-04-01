import AppKit
import Localization
import RenderEngine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
public struct SpritePackCreatorView: View {
    @State private var packName: String = ""
    @State private var stateFrames: [String: [URL]] = [:]
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var isBuilding = false

    private let onBuild: @MainActor (String, [String: [URL]]) async -> String?
    private let onDismiss: @MainActor () -> Void

    public init(
        initialFrames: [String: [URL]] = [:],
        onBuild: @escaping @MainActor (String, [String: [URL]]) async -> String?,
        onDismiss: @escaping @MainActor () -> Void
    ) {
        _stateFrames = State(initialValue: initialFrames)
        self.onBuild = onBuild
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.spritePackCreatorTitle)
                    .font(.title2)
                    .bold()
                Spacer()
            }
            .padding()

            Divider()

            HStack {
                Text(L10n.spritePackCreatorPackName)
                TextField(L10n.spritePackCreatorPackNamePlaceholder, text: $packName)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal)
            .padding(.top, 12)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(RenderEngine.AnimationState.allCases, id: \.rawValue) { state in
                        stateRow(for: state)
                    }
                }
                .padding()
            }

            Divider()

            HStack {
                Button(L10n.spritePackCreatorImportFolder) {
                    importFromFolder()
                }

                Spacer()

                Button("Cancel") {
                    onDismiss()
                }

                Button(isBuilding ? L10n.spritePackCreatorBuilding : L10n.spritePackCreatorBuild) {
                    buildPack()
                }
                .disabled(packName.isEmpty || (stateFrames[RenderEngine.AnimationState.idle.rawValue]?.isEmpty ?? true) || isBuilding)
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 550)
        .frame(minHeight: 500)
        .alert(isPresented: $showError) {
            Alert(
                title: Text(L10n.settingsSpritePacksImportError),
                message: Text(errorMessage ?? "")
            )
        }
    }

    @ViewBuilder
    private func stateRow(for state: RenderEngine.AnimationState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(state.rawValue)
                    .font(.headline)
                    .frame(width: 100, alignment: .leading)

                if state == .idle {
                    Text(L10n.spritePackCreatorStateRequired)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Spacer()

                if let frames = stateFrames[state.rawValue], !frames.isEmpty {
                    Text("\(frames.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button(action: { addFrames(for: state) }) {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)

                if stateFrames[state.rawValue]?.isEmpty == false {
                    Button(action: { stateFrames[state.rawValue] = [] }) {
                        Image(systemName: "xmark.circle")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                }
            }

            if let frames = stateFrames[state.rawValue], !frames.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(frames, id: \.absoluteString) { url in
                            if let image = NSImage(contentsOf: url) {
                                Image(nsImage: image)
                                    .resizable()
                                    .interpolation(.none)
                                    .frame(width: 40, height: 40)
                                    .border(Color.secondary.opacity(0.3))
                            }
                        }
                    }
                }
                .frame(height: 44)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5]))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .frame(height: 44)
                    .overlay(
                        Text(L10n.spritePackCreatorDropHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    )
                    .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                        handleDrop(providers: providers, for: state)
                        return true
                    }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(state == .idle ? Color.accentColor.opacity(0.05) : Color.clear)
        )
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers, for: state)
            return true
        }
    }

    private func addFrames(for state: RenderEngine.AnimationState) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK else {
            return
        }

        var current = stateFrames[state.rawValue] ?? []
        current.append(contentsOf: panel.urls)
        stateFrames[state.rawValue] = current
    }

    private func importFromFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        let detected = SpritePackBuilder.autoDetect(from: url)
        for (state, urls) in detected where !urls.isEmpty {
            stateFrames[state] = urls
        }

        if packName.isEmpty {
            packName = url.lastPathComponent
        }
    }

    private func buildPack() {
        isBuilding = true
        let name = packName
        let frames = stateFrames

        Task { @MainActor in
            let error = await onBuild(name, frames)
            isBuilding = false

            if let error {
                errorMessage = error
                showError = true
            } else {
                onDismiss()
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider], for state: RenderEngine.AnimationState) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let nsURL = item as? NSURL {
                    url = nsURL as URL
                } else {
                    url = nil
                }

                guard let url, url.pathExtension.lowercased() == "png" else {
                    return
                }

                Task { @MainActor in
                    var current = stateFrames[state.rawValue] ?? []
                    current.append(url)
                    stateFrames[state.rawValue] = current
                }
            }
        }
    }
}
