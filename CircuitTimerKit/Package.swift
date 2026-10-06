// swift-tools-version: 6.2
import PackageDescription

let strictSettings: [SwiftSetting] = [.treatAllWarnings(as: .error)]

let package = Package(
    name: "CircuitTimerKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "WorkoutDomain", targets: ["WorkoutDomain"]),
    ],
    targets: [
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
