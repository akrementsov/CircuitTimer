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
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "WorkoutDomain", targets: ["WorkoutDomain"]),
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
        .library(name: "WorkoutStorage", targets: ["WorkoutStorage"]),
        .library(name: "AppFeature", targets: ["AppFeature"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/pointfreeco/swift-composable-architecture",
            from: "1.26.2",
            traits: ["ComposableArchitecture2Deprecations"]
        ),
        .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.17.1"),
    ],
    targets: [
        .target(
            name: "AppFeature",
            dependencies: [
                "DesignSystem",
                "WorkoutDomain",
                "WorkoutStorage",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ],
            resources: [.process("Resources")],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "AppFeatureTests",
            dependencies: [
                "AppFeature",
                "WorkoutDomain",
                "WorkoutStorage",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
            ],
            swiftSettings: strictSettings
        ),
        .target(
            name: "DesignSystem",
            resources: [.process("Resources")],
            swiftSettings: strictSettings
        ),
        .target(
            name: "WorkoutDomain",
            swiftSettings: strictSettings
        ),
        .target(
            name: "WorkoutStorage",
            dependencies: [
                "WorkoutDomain",
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
            ],
            resources: [.process("Resources")],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "WorkoutDomainTests",
            dependencies: ["WorkoutDomain"],
            swiftSettings: strictSettings
        ),
    ]
)
