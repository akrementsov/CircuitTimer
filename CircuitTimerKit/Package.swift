// swift-tools-version: 6.2
import PackageDescription

let strictSettings: [SwiftSetting] = [.treatAllWarnings(as: .error)]

let package = Package(
    name: "CircuitTimerKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "WorkoutDomain", targets: ["WorkoutDomain"]),
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
        .library(name: "WorkoutStorage", targets: ["WorkoutStorage"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.17.1"),
    ],
    targets: [
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
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "WorkoutDomainTests",
            dependencies: ["WorkoutDomain"],
            swiftSettings: strictSettings
        ),
    ]
)
