import AppKit
import RenderEngine
import UniformTypeIdentifiers

public enum SpritePackImporterError: Error, Sendable {
    case cancelled
    case noManifest(URL)
}

@MainActor
public struct SpritePackImporter {
    public let manager: SpritePackManager

    public init(manager: SpritePackManager) {
        self.manager = manager
    }

    /// 打开文件选择器，选择 zip 或文件夹导入
    public func importFromPicker() async throws -> SpritePackInfo {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip, .folder]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = "Select a sprite pack folder or .zip file"

        let response = panel.runModal()
        guard response == .OK, let selectedURL = panel.url else {
            throw SpritePackImporterError.cancelled
        }

        if selectedURL.pathExtension.lowercased() == "zip" {
            return try await manager.extractAndImportZip(selectedURL)
        }

        let manifestURL = selectedURL.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw SpritePackImporterError.noManifest(selectedURL)
        }

        return try await manager.copyFolder(selectedURL)
    }
}
