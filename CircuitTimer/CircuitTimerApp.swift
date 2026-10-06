import AppFeature
import ComposableArchitecture
import SwiftUI

@main
struct CircuitTimerApp: App {
    @MainActor private static let store = Store(initialState: AppFeature.State()) {
        AppFeature()
    }

    var body: some Scene {
        WindowGroup {
            AppView(store: Self.store)
        }
    }
}
