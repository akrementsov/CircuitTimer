@testable import CloudSync

import CloudKit
import Dependencies
import Foundation
import Testing

/// A monitor on a private notification center, with a preference the test changes and account reads it answers.
struct MonitorHarness: Sendable {
    static let container = "iCloud.com.example.circuittimer"

    let notificationCenter = NotificationCenter()
    let preference: LockIsolated<Bool>
    let preferenceReads = LockIsolated(0)
    let containerReads = LockIsolated(0)
    let accounts = AccountReads()
    let monitor: CloudSyncMonitor

    init(preference isOn: Bool = true, container: String? = Self.container) {
        let preference = LockIsolated(isOn)
        let preferenceReads = preferenceReads
        let containerReads = containerReads
        let accounts = accounts
        self.preference = preference
        monitor = CloudSyncMonitor(
            notificationCenter: notificationCenter,
            preference: {
                preferenceReads.withValue { $0 += 1 }
                return preference.value
            },
            containerID: {
                containerReads.withValue { $0 += 1 }
                return container
            },
            accountStatus: { try await accounts.status(of: $0) }
        )
    }

    static func mirroring(_ problem: CloudSyncProblem?) -> CloudSyncStatus {
        CloudSyncStatus(isRequested: true, isMirroring: true, problem: problem)
    }

    /// Opens the store mirroring and returns once the first account read has been answered and applied, so no read
    /// is left in flight.
    func openMirroring(answer: CKAccountStatus = .available, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let statuses = monitor.status()
        _ = await statuses.next()
        monitor.storeOpened(isMirroring: true)
        _ = await statuses.next()
        try await accounts.next(sourceLocation: sourceLocation).answer.resume(returning: answer)
        _ = await statuses.next()
    }

    func succeed(_ kind: CloudSyncMonitor.EventKind) {
        monitor.handle(kind: kind, isFinished: true, succeeded: true, error: nil)
    }

    func fail(_ kind: CloudSyncMonitor.EventKind, error: (any Error)?) {
        monitor.handle(kind: kind, isFinished: true, succeeded: false, error: error)
    }

    func postAccountChange() {
        notificationCenter.post(name: .CKAccountChanged, object: nil)
    }
}

/// Account reads that wait until the test answers them, in any order.
final class AccountReads: Sendable {
    struct Read: Sendable {
        let container: String
        let answer: CheckedContinuation<CKAccountStatus, any Error>
    }

    private let requests: AsyncStream<Read>
    private let continuation: AsyncStream<Read>.Continuation
    private let started = LockIsolated(0)

    init() {
        (requests, continuation) = AsyncStream.makeStream()
    }

    var readsStarted: Int { started.value }

    func status(of container: String) async throws -> CKAccountStatus {
        started.withValue { $0 += 1 }
        return try await withCheckedThrowingContinuation { answer in
            continuation.yield(Read(container: container, answer: answer))
        }
    }

    /// The next read the monitor started, in the order the reads started.
    func next(sourceLocation: SourceLocation = #_sourceLocation) async throws -> Read {
        try #require(await requests.next(), sourceLocation: sourceLocation)
    }
}

extension AsyncStream where Element: Sendable {
    func next() async -> Element? {
        var iterator = makeAsyncIterator()
        return await iterator.next()
    }

    /// The element the stream holds right now, or `nil` without waiting for one. It ends the stream: `next()` in a
    /// cancelled task finishes it at once, yet still returns an element it had buffered.
    func takeBuffered() async -> Element? {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await next()
        }
        return await task.value
    }
}

enum TestFailure: Error {
    case unknown
}
