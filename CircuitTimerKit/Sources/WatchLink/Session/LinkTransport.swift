import Foundation

/// What the session says about the other side right now.
struct SessionSnapshot: Equatable, Sendable {
    var isActivated: Bool
    var isReachable: Bool
    /// The iPhone restarted and is unreachable until unlocked; only the watch can know it.
    var needsUnlock: Bool
    /// The context can reach a watch: on the iPhone a paired watch with the app; on the watch, always.
    var canPublish: Bool

    static let inactive = SessionSnapshot(isActivated: false, isReachable: false, needsUnlock: false, canPublish: false)

    var linkStatus: LinkStatus {
        LinkStatus(isActivated: isActivated, isReachable: isReachable, needsUnlock: needsUnlock)
    }
}

enum SessionEvent: Sendable {
    case activated
    /// Reachability, pairing, the watch app or the companion app changed; read `status()` again.
    case statusChanged
    /// The iPhone switched to another watch; its session activates again for it.
    case watchChanged
    case context(Data)
    case message(Data)
    /// The other side waits for exactly one answer through the ticket.
    case request(Data, ReplyTicket)
}

/// WatchConnectivity as closures, so the clients can run on a stand-in.
struct LinkTransport: Sendable {
    var activate: @Sendable () -> Void
    /// A new stream that replaces the previous one. It starts with the events that arrived while no stream was read,
    /// then the current status and, on the watch, the last context received.
    var events: @Sendable () -> AsyncStream<SessionEvent>
    var status: @Sendable () -> SessionSnapshot
    /// Replaces the context the other side receives. Synchronous: WatchConnectivity throws at once.
    var updateContext: @Sendable (Data) throws -> Void
    /// Sends a message nobody answers; delivery errors are logged, not reported.
    var sendMessage: @Sendable (Data) -> Void
    var sendRequest: @Sendable (Data) async throws -> Data
}
