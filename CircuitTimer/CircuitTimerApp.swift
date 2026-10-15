import AppFeature
import BackgroundNotifications
import ComposableArchitecture
import Foundation
import os
import SwiftUI
import TipKit

@main
struct CircuitTimerApp: App {
    @MainActor private static let store = Store(initialState: AppFeature.State()) {
        AppFeature()
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CircuitTimer", category: "App")

    init() {
        @Dependency(\.backgroundNotifications) var notifications
        notifications.installForegroundSuppression()
        // Once per launch, before any tip shows. Without it tips stay hidden; what they explain is said elsewhere too.
        do {
            try Tips.configure([.datastoreLocation(.applicationDefault), .displayFrequency(.immediate)])
        } catch {
            Self.logger.error("Failed to configure tips: \(String(reflecting: error), privacy: .public)")
        }
    }

    var body: some Scene {
        WindowGroup {
            AppView(store: Self.store)
        }
    }
}
