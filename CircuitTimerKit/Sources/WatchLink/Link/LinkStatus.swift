/// What the watch knows about its link to the iPhone.
public struct LinkStatus: Equatable, Sendable {
    public let isActivated: Bool
    public let isReachable: Bool
    /// The iPhone restarted and stays unreachable until it is unlocked.
    public let needsUnlock: Bool

    public init(isActivated: Bool, isReachable: Bool, needsUnlock: Bool) {
        self.isActivated = isActivated
        self.isReachable = isReachable
        self.needsUnlock = needsUnlock
    }

    public static let inactive = LinkStatus(isActivated: false, isReachable: false, needsUnlock: false)

    /// A request can be sent now.
    public var canSend: Bool {
        isActivated && isReachable && !needsUnlock
    }
}
