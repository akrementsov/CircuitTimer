import ComposableArchitecture
import Foundation
import os

@DependencyClient
public struct AppVersionClient: Sendable {
    /// The marketing version, such as "1.2"; `nil` when the bundle has none.
    public var shortVersion: @Sendable () -> String?

    static func shortVersion(in info: [String: Any]?) -> String? {
        guard let version = info?["CFBundleShortVersionString"] as? String, !version.isEmpty else { return nil }

        return version
    }
}

extension AppVersionClient: DependencyKey {
    public static let liveValue = Self(
        shortVersion: {
            guard let version = Self.shortVersion(in: Bundle.main.infoDictionary) else {
                Self.logger.error("CFBundleShortVersionString is missing from the main bundle")
                return nil
            }
            return version
        }
    )
    public static let previewValue = Self(shortVersion: { "0.1.0" })
    /// Declared explicitly so each endpoint a test forgets to override reports itself as unimplemented,
    /// instead of any access failing the test while preview data is returned.
    public static let testValue = Self()

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CircuitTimer", category: "AppVersion")
}

extension DependencyValues {
    public var appVersion: AppVersionClient {
        get { self[AppVersionClient.self] }
        set { self[AppVersionClient.self] = newValue }
    }
}
