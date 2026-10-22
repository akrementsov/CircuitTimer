import CloudKit
import Foundation

/// Sorts an error that a CloudKit import or export ended with by what the user should be told.
enum CloudSyncClassification {
    enum Verdict: Equatable, Sendable {
        /// The user's iCloud storage is full.
        case quotaExceeded
        /// The account may have changed; read its status again.
        case recheckAccount
        /// The network or the service holds the operation back; CloudKit retries it on its own.
        case transient
        case failed
    }

    // Core Data's mirroring errors carry Cocoa codes that neither the SDK headers nor the documentation declare;
    // their meanings come from Apple engineers' answers on the Apple Developer Forums.
    /// 134400: setup failed without a usable iCloud account. 134406: a request aborted because the mirroring delegate
    /// never started, which follows a failed setup; a `CKError` inside it is classified first.
    private static let accountCocoaCodes: Set<Int> = [134_400, 134_406]
    /// 134419: the system deferred the history analysis. 134417: an export gave way to one already pending.
    private static let transientCocoaCodes: Set<Int> = [134_419, 134_417]

    private static let transientCodes: Set<CKError.Code> = [
        .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy, .operationCancelled,
    ]

    static func verdict(for error: (any Error)?) -> Verdict {
        guard let error else { return .failed }

        let codes = cloudKitCodes(in: error as NSError)
        if codes.contains(.quotaExceeded) {
            return .quotaExceeded
        }
        if codes.contains(.notAuthenticated) || codes.contains(.accountTemporarilyUnavailable) {
            return .recheckAccount
        }
        if !codes.isEmpty, codes.allSatisfy(transientCodes.contains) {
            return .transient
        }
        let nsError = error as NSError
        if codes.isEmpty, nsError.domain == NSCocoaErrorDomain {
            if accountCocoaCodes.contains(nsError.code) {
                return .recheckAccount
            }
            if transientCocoaCodes.contains(nsError.code) {
                return .transient
            }
        }
        return .failed
    }

    /// The CloudKit codes in `error`, its underlying errors and the per-item errors of a partial failure.
    private static func cloudKitCodes(in error: NSError) -> [CKError.Code] {
        var codes: [CKError.Code] = []
        if error.domain == CKError.errorDomain, let code = CKError.Code(rawValue: error.code) {
            codes.append(code)
            if code == .partialFailure, let items = error.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: any Error] {
                codes += items.values.flatMap { cloudKitCodes(in: $0 as NSError) }
            }
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            codes += cloudKitCodes(in: underlying)
        }
        return codes
    }
}
