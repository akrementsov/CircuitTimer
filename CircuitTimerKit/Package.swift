// swift-tools-version: 6.2
import PackageDescription

// When the app project builds this package as a dependency, Xcode compiles it with
// -suppress-warnings, which conflicts with -warnings-as-errors. Strict mode is therefore opt-in
// for builds of the package itself (`make test`, CI). Those builds use their own DerivedData,
// because the evaluated manifest is cached there and does not notice an environment change.
let strictSettings: [SwiftSetting] = Context.environment["CIRCUITTIMER_STRICT_WARNINGS"] == "1"
    ? [.treatAllWarnings(as: .error)]
    : []

let package = Package(
    name: "CircuitTimerKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .watchOS(.v10)],
    products: [
        .library(name: "UITestContract", targets: ["UITestContract"]),
        .library(name: "BackgroundExecution", targets: ["BackgroundExecution"]),
        .library(name: "BackgroundNotifications", targets: ["BackgroundNotifications"]),
        .library(name: "CloudSync", targets: ["CloudSync"]),
        .library(name: "WorkoutDomain", targets: ["WorkoutDomain"]),
        .library(name: "WorkoutActivity", targets: ["WorkoutActivity"]),
        .library(name: "WorkoutHealth", targets: ["WorkoutHealth"]),
        .library(name: "TimerPreferences", targets: ["TimerPreferences"]),
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
        .library(name: "WorkoutStorage", targets: ["WorkoutStorage"]),
        .library(name: "WorkoutEditorFeature", targets: ["WorkoutEditorFeature"]),
        .library(name: "WorkoutTimerFeature", targets: ["WorkoutTimerFeature"]),
        .library(name: "WatchLink", targets: ["WatchLink"]),
        .library(name: "WatchRemoteFeature", targets: ["WatchRemoteFeature"]),
        .library(name: "SettingsFeature", targets: ["SettingsFeature"]),
        .library(name: "AppFeature", targets: ["AppFeature"]),
        .library(name: "AppScenarios", targets: ["AppScenarios"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/pointfreeco/swift-composable-architecture",
            from: "1.26.2",
            traits: ["ComposableArchitecture2Deprecations"]
        ),
        .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.17.1"),
        .package(url: "https://github.com/pointfreeco/swift-sharing", from: "2.10.1"),
    ],
    targets: [
        .target(
            name: "AppFeature",
            dependencies: [
                "TimerPreferences",
                "BackgroundNotifications",
                "BackgroundExecution",
                "CloudSync",
                "DesignSystem",
                "SettingsFeature",
                "UITestContract",
                "WatchLink",
                "WorkoutActivity",
                "WorkoutDomain",
                "WorkoutEditorFeature",
                "WorkoutHealth",
                "WorkoutStorage",
                "WorkoutTimerFeature",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ],
            resources: [.process("Resources")],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "AppFeatureTests",
            dependencies: [
                "TestSupport",
                "TimerPreferences",
                "BackgroundNotifications",
                "BackgroundExecution",
                "CloudSync",
                "AppFeature",
                "SettingsFeature",
                "WatchLink",
                "WorkoutActivity",
                "WorkoutDomain",
                "WorkoutHealth",
                "WorkoutStorage",
                "WorkoutTimerFeature",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
            ],
            swiftSettings: strictSettings
        ),
        // Debug-only: every file is under `#if DEBUG`, so Release links an empty module.
        .target(
            name: "AppScenarios",
            dependencies: [
                "BackgroundExecution",
                "BackgroundNotifications",
                "CloudSync",
                "SettingsFeature",
                "UITestContract",
                "WatchLink",
                "WorkoutActivity",
                "WorkoutDomain",
                "WorkoutEditorFeature",
                "WorkoutHealth",
                "WorkoutStorage",
                "WorkoutTimerFeature",
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "Sharing", package: "swift-sharing"),
            ],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "AppScenariosTests",
            dependencies: [
                "AppScenarios",
                "UITestContract",
                "WorkoutDomain",
                "WorkoutStorage",
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "Sharing", package: "swift-sharing"),
            ],
            swiftSettings: strictSettings
        ),
        .target(
            name: "BackgroundExecution",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
            ],
            swiftSettings: strictSettings
        ),
        .target(
            name: "BackgroundNotifications",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
            ],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "BackgroundNotificationsTests",
            dependencies: [
                "BackgroundNotifications",
                "TestSupport",
                .product(name: "Dependencies", package: "swift-dependencies"),
            ],
            swiftSettings: strictSettings
        ),
        .target(
            name: "DesignSystem",
            resources: [.process("Resources")],
            swiftSettings: strictSettings
        ),
        .target(
            name: "SettingsFeature",
            dependencies: [
                "CloudSync",
                "TimerPreferences",
                "DesignSystem",
                "UITestContract",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ],
            resources: [.process("Resources")],
            swiftSettings: strictSettings
        ),
        .target(
            name: "CloudSync",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
                .product(name: "Sharing", package: "swift-sharing"),
            ],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "CloudSyncTests",
            dependencies: [
                "CloudSync",
                .product(name: "Dependencies", package: "swift-dependencies"),
            ],
            swiftSettings: strictSettings
        ),
        .target(
            name: "TimerPreferences",
            dependencies: [
                .product(name: "Sharing", package: "swift-sharing"),
            ],
            swiftSettings: strictSettings
        ),
        .target(
            name: "UITestContract",
            swiftSettings: strictSettings
        ),
        .target(
            name: "WorkoutActivity",
            dependencies: [
                "WorkoutDomain",
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
            ],
            resources: [.process("Resources")],
            swiftSettings: strictSettings
        ),
        .target(
            name: "WorkoutDomain",
            swiftSettings: strictSettings
        ),
        .target(
            name: "WorkoutHealth",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
            ],
            swiftSettings: strictSettings
        ),
        .target(
            name: "WorkoutEditorFeature",
            dependencies: [
                "DesignSystem",
                "UITestContract",
                "WorkoutDomain",
                "WorkoutStorage",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ],
            resources: [.process("Resources")],
            swiftSettings: strictSettings
        ),
        .target(
            name: "WorkoutStorage",
            dependencies: [
                "CloudSync",
                "WorkoutDomain",
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
            ],
            resources: [.process("Resources")],
            swiftSettings: strictSettings
        ),
        // Clocks and values that tests wait on without yielding; linked by test targets only, so it is no product.
        .target(
            name: "TestSupport",
            swiftSettings: strictSettings
        ),
        // The channel between the iPhone app and the watch app: its wire format, the WatchConnectivity bridge and the
        // clients of both sides. Builds for iOS and watchOS.
        .target(
            name: "WatchLink",
            dependencies: [
                "WorkoutActivity",
                "WorkoutDomain",
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
            ],
            swiftSettings: strictSettings
        ),
        // The watch app's screens. Builds for iOS too, so its tests run in `make test` on the iPhone simulator.
        .target(
            name: "WatchRemoteFeature",
            dependencies: [
                "DesignSystem",
                "WatchLink",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ],
            resources: [.process("Resources")],
            swiftSettings: strictSettings
        ),
        .target(
            name: "WorkoutTimerFeature",
            dependencies: [
                "BackgroundNotifications",
                "TimerPreferences",
                "BackgroundExecution",
                "DesignSystem",
                "UITestContract",
                "WorkoutActivity",
                "WorkoutDomain",
                "WorkoutHealth",
                "WorkoutStorage",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ],
            resources: [.process("Resources")],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "DesignSystemTests",
            dependencies: ["DesignSystem"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "WatchLinkTests",
            dependencies: [
                "WatchLink",
                "WorkoutDomain",
                .product(name: "Dependencies", package: "swift-dependencies"),
            ],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "WatchRemoteFeatureTests",
            dependencies: [
                "WatchLink",
                "WatchRemoteFeature",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "SettingsFeatureTests",
            dependencies: [
                "CloudSync",
                "TimerPreferences",
                "SettingsFeature",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
            ],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "WorkoutEditorFeatureTests",
            dependencies: [
                "WorkoutDomain",
                "WorkoutEditorFeature",
                "WorkoutStorage",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "WorkoutStorageTests",
            dependencies: [
                "CloudSync",
                "WorkoutDomain",
                "WorkoutStorage",
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
            ],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "WorkoutActivityTests",
            dependencies: [
                "TestSupport",
                "WorkoutActivity",
                "WorkoutDomain",
                .product(name: "Dependencies", package: "swift-dependencies"),
            ],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "WorkoutDomainTests",
            dependencies: ["WorkoutDomain"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "WorkoutHealthTests",
            dependencies: [
                "TestSupport",
                "WorkoutHealth",
                .product(name: "Dependencies", package: "swift-dependencies"),
            ],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "WorkoutTimerFeatureTests",
            dependencies: [
                "BackgroundNotifications",
                "BackgroundExecution",
                "WorkoutActivity",
                "WorkoutDomain",
                "WorkoutHealth",
                "WorkoutStorage",
                "WorkoutTimerFeature",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ],
            swiftSettings: strictSettings
        ),
    ]
)
