@preconcurrency import WatchConnectivity

import Foundation
import os

/// The delegate of the default `WCSession`, turning its callbacks into one stream of events. WatchConnectivity calls
/// the delegate on its own serial queue; the stream and the events nobody has read yet share one lock.
///
/// Unchecked: WatchConnectivity does not mark `WCSession` as `Sendable`. The bridge only calls the session's methods,
/// from the delegate's queue and from the clients' callers, and never replaces it after `init`.
final class WCSessionBridge: NSObject, WCSessionDelegate, @unchecked Sendable {
    private struct Subscription {
        var current: AsyncStream<SessionEvent>.Continuation?
        /// Events that arrived while no stream was read: the request that launched the iPhone app comes before its
        /// actor subscribes, and the watch activates in its host's `init`, before the first `.task`.
        var pending: [SessionEvent] = []
        /// WatchConnectivity has reported the end of an activation, successful or not.
        var hasActivationEnded = false
    }

    private let session: WCSession
    private let subscription = OSAllocatedUnfairLock(initialState: Subscription())

    init(session: WCSession = .default) {
        self.session = session
        super.init()
        // A session without a delegate refuses to send.
        session.delegate = self
    }

    var transport: LinkTransport {
        LinkTransport(
            activate: { self.session.activate() },
            events: { self.events() },
            status: { self.status() },
            updateContext: { try self.session.updateApplicationContext([WatchLinkSchema.contextKey: $0]) },
            sendMessage: { data in
                self.session.sendMessageData(data, replyHandler: nil) { error in
                    // Mapping logs an unexpected error; an unreachable watch needs nothing, the context still reaches it.
                    _ = PhoneLinkError(error)
                }
            },
            sendRequest: { data in
                try await withCheckedThrowingContinuation { continuation in
                    // WatchConnectivity calls exactly one of the two handlers.
                    self.session.sendMessageData(
                        data,
                        replyHandler: { continuation.resume(returning: $0) },
                        errorHandler: { continuation.resume(throwing: $0) }
                    )
                }
            }
        )
    }

    private func events() -> AsyncStream<SessionEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: SessionEvent.self, bufferingPolicy: .unbounded)
        var snapshot: [SessionEvent] = [.statusChanged]
        #if os(watchOS)
        if let context = session.receivedApplicationContext[WatchLinkSchema.contextKey] as? Data {
            snapshot.append(.context(context))
        }
        #endif
        let opening = snapshot
        let previous = subscription.withLock { subscription in
            // What waited goes first: the snapshot is newer than any of it.
            for event in subscription.pending + opening {
                continuation.yield(event)
            }
            subscription.pending = []
            defer { subscription.current = continuation }
            return subscription.current
        }
        // Finishing runs the old stream's termination, which must not find the lock taken.
        previous?.finish()
        return stream
    }

    private func status() -> SessionSnapshot {
        var snapshot = currentStatus()
        snapshot.isActivating = !snapshot.isActivated && !subscription.withLock { $0.hasActivationEnded }
        return snapshot
    }

    private func currentStatus() -> SessionSnapshot {
        let isActivated = session.activationState == .activated
        #if os(iOS)
        return SessionSnapshot(
            isActivated: isActivated,
            isReachable: session.isReachable,
            needsUnlock: false,
            canPublish: isActivated && session.isPaired && session.isWatchAppInstalled
        )
        #else
        return SessionSnapshot(
            isActivated: isActivated,
            isReachable: session.isReachable,
            needsUnlock: session.iOSDeviceNeedsUnlockAfterRebootForReachability,
            canPublish: isActivated
        )
        #endif
    }

    private func deliver(_ event: SessionEvent) {
        subscription.withLock { subscription in
            if let current = subscription.current, case .enqueued = current.yield(event) {
                return
            }
            subscription.current = nil
            subscription.pending.append(event)
        }
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: (any Error)?) {
        if let error {
            Logger.watchLink.error("The session did not activate: \(String(reflecting: error), privacy: .public)")
        }
        subscription.withLock { $0.hasActivationEnded = true }
        deliver(state == .activated ? .activated : .statusChanged)
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        deliver(.statusChanged)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        // A context of another format reads as an envelope of no known version.
        deliver(.context(applicationContext[WatchLinkSchema.contextKey] as? Data ?? Data()))
    }

    func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        deliver(.message(messageData))
    }

    func session(_ session: WCSession, didReceiveMessageData messageData: Data, replyHandler: @escaping (Data) -> Void) {
        deliver(.request(messageData, ReplyTicket(replyHandler)))
    }

    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}

    /// The user switched to another watch: the session comes back for the new one.
    func sessionDidDeactivate(_ session: WCSession) {
        deliver(.watchChanged)
        session.activate()
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        deliver(.statusChanged)
    }
    #endif

    #if os(watchOS)
    /// Documented for watch apps that run without the iPhone; ours may never get it.
    func sessionCompanionAppInstalledDidChange(_ session: WCSession) {
        deliver(.statusChanged)
    }
    #endif
}
