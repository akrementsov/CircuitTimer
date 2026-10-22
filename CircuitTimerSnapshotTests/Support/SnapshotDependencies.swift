import BackgroundNotifications
import CloudSync
import ComposableArchitecture

enum SnapshotDependencies {
    static func prepare(_ dependencies: inout DependencyValues) {
        dependencies.defaultAppStorage = .inMemory
        dependencies.backgroundNotifications.access = { .authorized }
        dependencies.cloudSync = .previewValue
        dependencies.continuousClock = TestClock()
    }
}
