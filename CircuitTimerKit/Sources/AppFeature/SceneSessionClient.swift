import ComposableArchitecture
import Foundation
import os
import UIKit

/// The identifier of the scene session the app runs in.
///
/// A system kill keeps the session, so a relaunch reconnects the same identifier; closing the app in the App
/// Switcher discards it. Run records are filed under it, so only a run the user did not close comes back.
@DependencyClient
struct SceneSessionClient: Sendable {
    /// The persistent identifier of the one connected application window scene, or `nil` when there is not exactly
    /// one. The default is what the unimplemented `testValue` returns after reporting the call.
    var currentID: @Sendable () async -> String? = { nil }
}

extension SceneSessionClient: DependencyKey {
    // The iPhone app has one window scene; an unknown session counts as discarded.
    static let liveValue = Self(
        currentID: {
            await MainActor.run {
                let scenes = UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .filter { $0.session.role == .windowApplication && $0.activationState != .unattached }
                let found = scenes.map { "\($0.session.persistentIdentifier) (state \($0.activationState.rawValue))" }
                Self.logger.info("Connected window scenes: \(found.joined(separator: ", "), privacy: .public)")
                guard scenes.count == 1, let id = scenes.first?.session.persistentIdentifier, !id.isEmpty else { return nil }

                return id
            }
        }
    )
    static let previewValue = Self(currentID: { "preview" })
    /// Declared explicitly so a test that forgets to override `currentID` reports it as unimplemented.
    static let testValue = Self()

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CircuitTimer", category: "SceneSession")
}

extension DependencyValues {
    var sceneSession: SceneSessionClient {
        get { self[SceneSessionClient.self] }
        set { self[SceneSessionClient.self] = newValue }
    }
}
