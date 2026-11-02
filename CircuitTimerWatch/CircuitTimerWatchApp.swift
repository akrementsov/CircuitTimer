import ComposableArchitecture
import SwiftUI
import WatchLink
import WatchRemoteFeature

@main
struct CircuitTimerWatchApp: App {
    @MainActor private static let store = Store(initialState: WatchRemoteFeature.State()) {
        WatchRemoteFeature()
    }

    init() {
        // In `init`, so a context WatchConnectivity delivers before the first screen is kept for it.
        @Dependency(\.phoneCompanion) var phoneCompanion
        phoneCompanion.activate()
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView(store: Self.store)
        }
    }
}
