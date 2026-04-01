import Foundation
import RenderEngine

public struct AppBehaviorRule: Codable, Sendable {
    public var category: String
    public var bundleIdPatterns: [String]
    public var animation: String
    public var bubbleTexts: [String]
    public var bubbleInterval: TimeInterval

    public init(
        category: String,
        bundleIdPatterns: [String],
        animation: String,
        bubbleTexts: [String],
        bubbleInterval: TimeInterval
    ) {
        self.category = category
        self.bundleIdPatterns = bundleIdPatterns
        self.animation = animation
        self.bubbleTexts = bubbleTexts
        self.bubbleInterval = bubbleInterval
    }
}

public enum AppBehaviorRules {
    public static let builtinRules: [AppBehaviorRule] = [
        AppBehaviorRule(category: "coding", bundleIdPatterns: [
            "com.apple.Terminal", "com.googlecode.iterm2", "net.kovidgoyal.kitty",
            "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
            "com.jetbrains", "com.sublimetext", "com.panic.Nova", "dev.warp.Warp-Stable"
        ], animation: "type", bubbleTexts: ["噼里啪啦~", "写代码中...", "这个bug...", "编译中~", "commit!"], bubbleInterval: 30),
        AppBehaviorRule(category: "browsing", bundleIdPatterns: [
            "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox",
            "com.microsoft.edgemac", "company.thebrowser.Browser", "com.operasoftware.Opera"
        ], animation: "read", bubbleTexts: ["看什么呢？", "网上冲浪~", "这个网页有意思~", "又在摸鱼？"], bubbleInterval: 45),
        AppBehaviorRule(category: "chatting", bundleIdPatterns: [
            "com.tencent.xinWeChat", "com.tencent.qq", "org.telegram.desktop",
            "com.hnc.Discord", "com.tinyspeck.slackmacgap", "com.apple.MobileSMS",
            "ru.keepcoder.Telegram", "com.readdle.smartemail"
        ], animation: "chat", bubbleTexts: ["在和谁聊天？", "八卦时间~", "回消息中~", "有人找你~"], bubbleInterval: 40),
        AppBehaviorRule(category: "entertainment", bundleIdPatterns: [
            "com.apple.Music", "com.spotify.client", "com.apple.QuickTimePlayerX",
            "com.apple.tv", "io.mpv", "com.colliderli.iina", "com.bilibili.bili"
        ], animation: "dance", bubbleTexts: ["♪♪♪", "好好听~", "跟着节奏~", "一起摇摆~"], bubbleInterval: 25),
        AppBehaviorRule(category: "gaming", bundleIdPatterns: [
            "com.valvesoftware.steam", "com.epicgames.EpicGamesLauncher",
            "unity.DefaultCompany", "com.blizzard"
        ], animation: "play", bubbleTexts: ["好好玩！", "带我一起！", "加油加油！", "又菜又爱玩~"], bubbleInterval: 35),
        AppBehaviorRule(category: "office", bundleIdPatterns: [
            "com.microsoft.Word", "com.microsoft.Excel", "com.microsoft.Powerpoint",
            "com.apple.iWork.Pages", "com.apple.iWork.Keynote", "com.apple.iWork.Numbers",
            "notion.id", "md.obsidian"
        ], animation: "write", bubbleTexts: ["认真工作~", "加油！", "写得不错~", "要喝杯咖啡吗？"], bubbleInterval: 40),
        AppBehaviorRule(category: "reading", bundleIdPatterns: [
            "com.apple.Preview", "com.apple.iBooksX", "com.amazon.Kindle",
            "com.readdle.PDFExpert-Mac"
        ], animation: "read", bubbleTexts: ["看书中~", "好有趣~", "学到了！", "翻页~"], bubbleInterval: 50),
    ]

    private static let rulesFileURL: URL = {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return baseURL
            .appendingPathComponent("VitaPet", isDirectory: true)
            .appendingPathComponent("desktop_rules.json", isDirectory: false)
    }()

    public static func loadRules() -> [AppBehaviorRule] {
        let fileManager = FileManager.default
        let directoryURL = rulesFileURL.deletingLastPathComponent()

        do {
            if !fileManager.fileExists(atPath: directoryURL.path) {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
            }

            guard fileManager.fileExists(atPath: rulesFileURL.path) else {
                try saveRules(builtinRules)
                return builtinRules
            }

            let data = try Data(contentsOf: rulesFileURL)
            let rules = try JSONDecoder().decode([AppBehaviorRule].self, from: data)
            guard !rules.isEmpty else {
                try saveRules(builtinRules)
                return builtinRules
            }
            return rules
        } catch {
            return builtinRules
        }
    }

    public static func saveRules(_ rules: [AppBehaviorRule]) throws {
        let fileManager = FileManager.default
        let directoryURL = rulesFileURL.deletingLastPathComponent()

        if !fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(rules)
        try data.write(to: rulesFileURL, options: .atomic)
    }

    public static func matchRule(for bundleId: String) -> AppBehaviorRule? {
        for rule in loadRules() {
            for pattern in rule.bundleIdPatterns where bundleId == pattern || bundleId.hasPrefix(pattern + ".") {
                return rule
            }
        }
        return nil
    }

    public static func matchAnimationTrigger(for bundleId: String) -> AnimationTrigger? {
        guard let rule = matchRule(for: bundleId) else { return nil }
        return .custom(rule.animation)
    }
}

public typealias AppReactionRule = AppBehaviorRule
public typealias AppReactionRules = AppBehaviorRules
