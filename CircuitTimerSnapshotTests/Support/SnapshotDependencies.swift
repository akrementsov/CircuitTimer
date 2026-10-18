import BackgroundNotifications
import ComposableArchitecture

enum SnapshotDependencies {
    static func prepare(_ dependencies: inout DependencyValues) {
        dependencies.defaultAppStorage = .inMemory
        dependencies.backgroundNotifications.access = { .authorized }
        dependencies.continuousClock = TestClock()
    }
}
