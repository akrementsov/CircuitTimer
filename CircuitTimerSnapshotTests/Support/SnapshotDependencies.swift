import BackgroundNotifications
import CloudSync
import ComposableArchitecture
import Purchases

enum SnapshotDependencies {
    static func prepare(_ dependencies: inout DependencyValues) {
        dependencies.defaultAppStorage = .inMemory
        dependencies.backgroundNotifications.access = { .authorized }
        dependencies.cloudSync = .previewValue
        dependencies.purchases = .previewValue
        dependencies.continuousClock = TestClock()
    }
}
