import AppFeature
import ComposableArchitecture
import Dispatch
import Foundation
import os
import UIKit

/// Tears the open timers down when iOS terminates the app. From iOS 26 a workout session keeps a running timer's app
/// alive, so an App Switcher swipe reaches it; earlier versions reach it only while the app still runs in the
/// background.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CircuitTimer", category: "App")

    /// iOS ends the process soon after this returns, so it blocks the main thread until the teardown finishes or its
    /// budget runs out; nothing it waits for runs on the main thread.
    func applicationWillTerminate(_ application: UIApplication) {
        let deadline = DispatchTime.now() + .nanoseconds(Int(ProcessTeardown.budget / .nanoseconds(1)))
        @Dependency(\.date) var date
        let teardown = ProcessTeardown()
        teardown.begin()
        let now = date.now
        let finished = DispatchSemaphore(value: 0)
        // Detached: the main actor stays blocked on the semaphore below until the teardown ends.
        Task.detached {
            await teardown.run(at: now)
            finished.signal()
        }
        if finished.wait(timeout: deadline) == .timedOut {
            Self.logger.notice("The teardown took over \(ProcessTeardown.budget, privacy: .public); iOS ends the process anyway")
        }
    }
}
