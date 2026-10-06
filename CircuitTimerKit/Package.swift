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
        .testTarget(
            name: "WorkoutDomainTests",
            dependencies: ["WorkoutDomain"],
            swiftSettings: strictSettings
        ),
    ]
)
