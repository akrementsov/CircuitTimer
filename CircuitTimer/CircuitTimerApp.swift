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
    @MainActor private static let store = Store(initialState: AppFeature.State()) {
        AppFeature()
    } withDependencies: { dependencies in
        #if DEBUG
        if let scenario = requestedScenario() {
            scenario.prepare(&dependencies)
        }
        #endif
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

    #if DEBUG
    /// The scenario a UI test asked for, which replaces every dependency inside the store. `init` reads its clients
    /// from the process's context instead, so a scenario runs only in the preview context, where none of them is live.
    private static func requestedScenario() -> AppScenario? {
        guard let scenario = AppScenario.requested(in: ProcessInfo.processInfo.environment) else { return nil }

        @Dependency(\.context) var context
        guard context == .preview else {
            let launch = "\(ScenarioLaunch.dependencyContextKey)=\(ScenarioLaunch.dependencyContext)"
            fatalError("UI test scenario \(scenario.rawValue) needs \(launch)")
        }
        return scenario
    }
    #endif

    var body: some Scene {
        WindowGroup {
            AppView(store: Self.store)
        }
    }
}
