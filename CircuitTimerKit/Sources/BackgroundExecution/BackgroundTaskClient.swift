import Dependencies
import DependenciesMacros
import Foundation
import os
import UIKit

/// Identifies a request for time to finish work after the app leaves the screen.
public struct BackgroundTaskToken: Hashable, Sendable {
    let rawValue: Int

    /// What a request the system refused, or a test or a preview, gets back; ending it does nothing.
    public static let invalid = Self(rawValue: 0)
}

/// Asks iOS for time to finish a write when the app leaves the screen.
@DependencyClient
public struct BackgroundTaskClient: Sendable {
    /// Synchronous, so the reducer calls it before it returns the effect that does the work: a `.run` effect starts
    /// as a later task, and the app can be suspended before that task runs.
    /// The default is what the unimplemented `testValue` returns after reporting the call.
    public var begin: @Sendable (_ name: String) -> BackgroundTaskToken = { _ in .invalid }
    /// Ends the request; a token that has expired or ended already is ignored.
    public var end: @Sendable (_ token: BackgroundTaskToken) async -> Void
}

extension BackgroundTaskClient: DependencyKey {
    public static let liveValue: Self = {
        let tasks = BackgroundTasks()
        return Self(
            // Reducers run on the main actor, the only place `begin` is called.
            begin: { name in MainActor.assumeIsolated { tasks.begin(name) } },
            end: { token in await tasks.end(token) }
        )
    }()
    public static let previewValue = Self(
        begin: { _ in .invalid },
        end: { _ in }
    )
    /// Declared explicitly so each endpoint a test forgets to override reports itself as unimplemented.
    public static let testValue = Self()
}

extension DependencyValues {
    public var backgroundTask: BackgroundTaskClient {
        get { self[BackgroundTaskClient.self] }
        set { self[BackgroundTaskClient.self] = newValue }
    }
}

/// The background tasks still running, so each one ends exactly once: by its owner or when it expires.
@MainActor
final class BackgroundTasks {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CircuitTimer", category: "BackgroundTask")

    private var active: [Int: UIBackgroundTaskIdentifier] = [:]
    private var lastKey = 0

    nonisolated init() {}

    func begin(_ name: String) -> BackgroundTaskToken {
        lastKey += 1
        let key = lastKey
        let identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.expire(key, name: name)
        }
        guard identifier != .invalid else {
            Self.logger.notice("The system gave no background time for «\(name, privacy: .public)»")
            return .invalid
        }

        active[key] = identifier
        Self.logger.info("Background task «\(name, privacy: .public)» started")
        return BackgroundTaskToken(rawValue: key)
    }

    func end(_ token: BackgroundTaskToken) {
        guard let identifier = active.removeValue(forKey: token.rawValue) else { return }

        UIApplication.shared.endBackgroundTask(identifier)
    }

    private func expire(_ key: Int, name: String) {
        guard let identifier = active.removeValue(forKey: key) else { return }

        Self.logger.notice("Background task «\(name, privacy: .public)» expired before its work ended")
        UIApplication.shared.endBackgroundTask(identifier)
    }
}
