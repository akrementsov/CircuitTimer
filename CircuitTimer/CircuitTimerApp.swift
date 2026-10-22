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
import WorkoutStorage
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
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-CTInitializeCloudKitSchema") {
            Self.initializeCloudKitSchema()
        }
        #endif
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
    /// Creates the CloudKit schema in the Development environment and ends the process before the app's store opens,
    /// so no second CloudKit store runs beside it. A one-off developer command: it may block the main thread.
    private static func initializeCloudKitSchema() -> Never {
        do {
            try WorkoutCloudKitSchema.initialize()
            logger.notice("Initialized the CloudKit schema")
            exit(EXIT_SUCCESS)
        } catch {
            logger.error("Failed to initialize the CloudKit schema: \(String(reflecting: error), privacy: .public)")
            exit(EXIT_FAILURE)
        }
    }

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
