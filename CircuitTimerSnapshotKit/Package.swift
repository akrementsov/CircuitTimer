// swift-tools-version: 6.2
import PackageDescription

// Xcode suppresses warnings when building a package dependency; strict builds use separate DerivedData.
let strictSettings: [SwiftSetting] = Context.environment["CIRCUITTIMER_STRICT_WARNINGS"] == "1"
    ? [.treatAllWarnings(as: .error)]
    : []

let package = Package(
    name: "CircuitTimerSnapshotKit",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "SnapshotCapture", targets: ["SnapshotCapture"]),
    ],
    dependencies: [
        // A renderer update is reviewed together with the references.
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", exact: "1.19.6"),
    ],
    targets: [
        .target(
            name: "SnapshotCapture",
            dependencies: [
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            swiftSettings: strictSettings
        ),
    ]
)
