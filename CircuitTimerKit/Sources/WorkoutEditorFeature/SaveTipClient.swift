import ComposableArchitecture
import Foundation
import TipKit

/// The one write to TipKit's store: the dimmed Save was explained, so its tip is not shown any more.
@DependencyClient
public struct SaveTipClient: Sendable {
    public var markExplained: @Sendable () async -> Void
}

extension SaveTipClient: DependencyKey {
    public static let liveValue = Self(
        markExplained: {
            // The tip's id does not depend on the reason, so any reason invalidates it.
            SaveWorkoutTip(blocker: .incomplete).invalidate(reason: .actionPerformed)
        }
    )
    public static let previewValue = Self(markExplained: {})
    /// Declared explicitly so a test that taps a dimmed Save without overriding it reports the endpoint.
    public static let testValue = Self()
}

extension DependencyValues {
    public var saveTip: SaveTipClient {
        get { self[SaveTipClient.self] }
        set { self[SaveTipClient.self] = newValue }
    }
}
