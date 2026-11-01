import BackgroundNotifications
import CloudSync
import ComposableArchitecture
import WatchLink

enum SnapshotDependencies {
    static func prepare(_ dependencies: inout DependencyValues) {
        dependencies.defaultAppStorage = .inMemory
        dependencies.backgroundNotifications.access = { .authorized }
        dependencies.cloudSync = .previewValue
        dependencies.watchCompanion = .previewValue
        dependencies.continuousClock = TestClock()
    }
}
