import AppFeature
import BackgroundNotifications
import ComposableArchitecture
import Foundation
import os
import SwiftUI
import TipKit
#if DEBUG
import AppScenarios
import UITestContract
#endif

@main
struct CircuitTimerApp: App {
    @MainActor private static let store = makeStore()

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

    /// A UI test's scenario replaces every dependency inside the store. `init` reads its clients from the process's
    /// context instead, so a scenario runs only in the preview context, where none of them is live.
    @MainActor private static func makeStore() -> StoreOf<AppFeature> {
        #if DEBUG
        if let scenario = AppScenario.requested(in: ProcessInfo.processInfo.environment) {
            @Dependency(\.context) var context
            guard context == .preview else {
                let launch = "\(ScenarioLaunch.dependencyContextKey)=\(ScenarioLaunch.dependencyContext)"
                fatalError("UI test scenario \(scenario.rawValue) needs \(launch)")
            }
            return Store(initialState: AppFeature.State()) {
                AppFeature()
            } withDependencies: {
                scenario.prepare(&$0)
            }
        }
        #endif
        return Store(initialState: AppFeature.State()) {
            AppFeature()
        }
    }

    var body: some Scene {
        WindowGroup {
            AppView(store: Self.store)
        }
    }
}
