import PluginProtocols
import PluginSDK

final class GitCelebratePlugin: VitaPlugin, @unchecked Sendable {
    let pluginId = "com.vitapet.plugin.git-celebrate"

    func activate(capabilities: [String]) async {
        // 插件激活，可初始化资源
    }

    func deactivate() async {
        // 插件停用，清理资源
    }

    func handle(event: XPCEventEnvelope) async -> [PluginActionResult] {
        // 检测 git commit 事件
        guard event.eventType == "fileChanged",
              let path = event.payload["path"],
              path.contains(".git/COMMIT_EDITMSG")
        else {
            return []
        }

        return [
            PluginActionResult(kind: .animation("celebrate")),
            PluginActionResult(
                kind: .notification(
                    title: "Git Celebrate",
                    body: "Commit successful!"
                )
            )
        ]
    }
}
