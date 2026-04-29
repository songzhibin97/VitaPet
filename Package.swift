// swift-tools-version: 6.0
import PackageDescription

let strictConcurrency: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .define("DEBUG", .when(configuration: .debug)),
]

let package = Package(
    name: "VitaPet",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "RenderEngine", targets: ["RenderEngine"]),
        .library(name: "EventBus", targets: ["EventBus"]),
        .library(name: "PluginProtocols", targets: ["PluginProtocols"]),
        .library(name: "PluginRuntime", targets: ["PluginRuntime"]),
        .library(name: "PluginSDK", targets: ["PluginSDK"]),
        .library(name: "AIEngine", targets: ["AIEngine"]),
        .library(name: "FocusMonitor", targets: ["FocusMonitor"]),
        .library(name: "Localization", targets: ["Localization"]),
        .library(name: "ChatUI", targets: ["ChatUI"]),
        .library(name: "SecurityLayer", targets: ["SecurityLayer"]),
        .library(name: "Persistence", targets: ["Persistence"]),
        .executable(name: "VitaPetApp", targets: ["VitaPetApp"])
    ],
    targets: [
        .target(
            name: "RenderEngine",
            path: "Modules/RenderEngine",
            exclude: ["Tests"],
            sources: ["Sources"],
            resources: [.copy("Resources")],
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "EventBus",
            dependencies: ["RenderEngine"],
            path: "Modules/EventBus/Sources",
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "PluginProtocols",
            path: "Modules/PluginProtocols/Sources",
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "PluginRuntime",
            dependencies: ["EventBus", "SecurityLayer", "PluginProtocols", "Persistence"],
            path: "Modules/PluginRuntime/Sources",
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "PluginSDK",
            dependencies: ["PluginProtocols"],
            path: "Modules/PluginSDK/Sources",
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "AIEngine",
            dependencies: ["Localization"],
            path: "Modules/AIEngine/Sources",
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "FocusMonitor",
            dependencies: ["EventBus"],
            path: "Modules/FocusMonitor/Sources",
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "Localization",
            path: "Modules/Localization",
            exclude: ["Tests"],
            sources: ["Sources"],
            resources: [.copy("Resources")],
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "ChatUI",
            dependencies: ["AIEngine", "Localization", "RenderEngine", "EventBus", "Persistence"],
            path: "Modules/ChatUI/Sources",
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "SecurityLayer",
            path: "Modules/SecurityLayer/Sources",
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "Persistence",
            dependencies: ["SecurityLayer"],
            path: "Modules/Persistence/Sources",
            swiftSettings: strictConcurrency
        ),
        .executableTarget(
            name: "GitCelebratePlugin",
            dependencies: ["PluginSDK"],
            path: "Plugins/GitCelebrate/Sources",
            swiftSettings: strictConcurrency
        ),
        .executableTarget(
            name: "VitaPetApp",
            dependencies: [
                "RenderEngine",
                "EventBus",
                "PluginRuntime",
                "AIEngine",
                "FocusMonitor",
                "Localization",
                "ChatUI",
                "SecurityLayer",
                "Persistence"
            ],
            path: "App/Sources",
            swiftSettings: strictConcurrency
        ),
        .testTarget(name: "RenderEngineTests", dependencies: ["RenderEngine"], path: "Modules/RenderEngine/Tests", swiftSettings: strictConcurrency),
        .testTarget(name: "EventBusTests", dependencies: ["EventBus", "RenderEngine"], path: "Modules/EventBus/Tests", swiftSettings: strictConcurrency),
        .testTarget(name: "PluginRuntimeTests", dependencies: ["PluginRuntime", "EventBus", "SecurityLayer", "PluginProtocols", "Persistence"], path: "Modules/PluginRuntime/Tests", swiftSettings: strictConcurrency),
        .testTarget(name: "SecurityLayerTests", dependencies: ["SecurityLayer"], path: "Modules/SecurityLayer/Tests", swiftSettings: strictConcurrency),
        .testTarget(name: "FocusMonitorTests", dependencies: ["FocusMonitor", "EventBus"], path: "Modules/FocusMonitor/Tests", swiftSettings: strictConcurrency),
        .testTarget(name: "LocalizationTests", dependencies: ["Localization"], path: "Modules/Localization/Tests", swiftSettings: strictConcurrency),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence", "SecurityLayer"], path: "Modules/Persistence/Tests", swiftSettings: strictConcurrency),
        .testTarget(name: "AIEngineTests", dependencies: ["AIEngine"], path: "Modules/AIEngine/Tests", swiftSettings: strictConcurrency),
        .testTarget(name: "ChatUITests", dependencies: ["ChatUI", "AIEngine", "Persistence"], path: "Modules/ChatUI/Tests", swiftSettings: strictConcurrency)
    ]
)
