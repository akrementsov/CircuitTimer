/// Why workouts do not sync while sync is on; they keep working on the device either way.
public enum CloudSyncProblem: Equatable, Sendable {
    case noAccount
    case restricted
    case temporarilyUnavailable
    case quotaExceeded
    case syncFailed
}

public struct CloudSyncStatus: Equatable, Sendable {
    /// Whether sync was on when this launch opened the store.
    public var isRequested: Bool
    /// Whether the store mirrors to iCloud; `nil` until the store has opened.
    public var isMirroring: Bool?
    public var problem: CloudSyncProblem?

    public init(isRequested: Bool, isMirroring: Bool?, problem: CloudSyncProblem?) {
        self.isRequested = isRequested
        self.isMirroring = isMirroring
        self.problem = problem
    }
}
