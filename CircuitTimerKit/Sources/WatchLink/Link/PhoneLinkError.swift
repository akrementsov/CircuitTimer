import Foundation
import os
import WatchConnectivity

/// Why a request to the iPhone failed, in the terms the watch's screen and retries use.
public enum PhoneLinkError: Error, Equatable, Sendable {
    /// The iPhone is out of reach, unpaired or without the watch app: expected, never logged as an error.
    case unreachable
    /// The session is not active yet or any more; activation brings it back.
    case inactive
    case timedOut
    /// The iPhone app is not installed.
    case companionMissing
    case payloadTooLarge
    /// The other side speaks another version; `nil` when its version is unknown.
    case incompatible(peerSchemaVersion: Int?)
    case failed

    /// Maps a WatchConnectivity error; anything else, or a code we do not expect, is `failed` and logged with its
    /// domain and code.
    public init(_ error: any Error) {
        let error = error as NSError
        guard error.domain == WCErrorDomain, let code = WCError.Code(rawValue: error.code) else {
            Logger.watchLink.error("A link error outside WatchConnectivity: \(error.domain, privacy: .public) \(error.code)")
            self = .failed
            return
        }
        switch code {
            case .notReachable, .deliveryFailed, .deviceNotPaired, .watchAppNotInstalled:
                self = .unreachable
            case .sessionNotActivated, .sessionInactive:
                self = .inactive
            case .messageReplyTimedOut, .transferTimedOut:
                self = .timedOut
            case .companionAppNotInstalled:
                self = .companionMissing
            case .payloadTooLarge:
                self = .payloadTooLarge
            default:
                Logger.watchLink.error("A WatchConnectivity error the link does not expect: \(error.code)")
                self = .failed
        }
    }
}
