@testable import Purchases

import Dependencies
import Foundation
import Testing

/// StoreKit as a test answers it: every entitlement read waits until the test answers it, in any order, and the test
/// sends transaction updates itself.
final class FakeStore: Sendable {
    struct Read: Sendable {
        let answer: CheckedContinuation<Bool, Never>
    }

    let purchaseResult = LockIsolated<Result<PurchaseOutcome, TestFailure>>(.success(.purchased))
    let syncResult = LockIsolated<Result<Bool, TestFailure>>(.success(true))
    let offerResult = LockIsolated<Result<FullVersionOffer, TestFailure>>(.success(FullVersionOffer(displayPrice: "€1,29")))
    let readsStarted = LockIsolated(0)
    let listenersStarted = LockIsolated(0)
    let syncs = LockIsolated(0)

    private let reads: AsyncStream<Read>
    private let readContinuation: AsyncStream<Read>.Continuation
    private let updates: AsyncStream<Void>
    private let updateContinuation: AsyncStream<Void>.Continuation

    init() {
        (reads, readContinuation) = AsyncStream.makeStream()
        (updates, updateContinuation) = AsyncStream.makeStream()
    }

    var transport: StoreTransport {
        StoreTransport(
            offer: { [offerResult] in try offerResult.value.get() },
            purchase: { [purchaseResult] in try purchaseResult.value.get() },
            sync: { [syncResult, syncs] in
                syncs.withValue { $0 += 1 }
                return try syncResult.value.get()
            },
            isEntitled: { [readsStarted, readContinuation] in
                readsStarted.withValue { $0 += 1 }
                return await withCheckedContinuation { answer in
                    readContinuation.yield(Read(answer: answer))
                }
            },
            listen: { [listenersStarted, updates] handle in
                listenersStarted.withValue { $0 += 1 }
                for await _ in updates {
                    await handle()
                }
            }
        )
    }

    /// The next read the monitor started, in the order the reads started.
    func nextRead(sourceLocation: SourceLocation = #_sourceLocation) async throws -> Read {
        try #require(await reads.next(), sourceLocation: sourceLocation)
    }

    /// A transaction update, such as an approved Ask to Buy or a refund.
    func sendUpdate() {
        updateContinuation.yield()
    }

    /// Ends the listener, so no task of a test outlives it.
    func finish() {
        updateContinuation.finish()
    }
}

struct TestFailure: Error, Equatable {}

/// The monitor's timeout, fired by the test instead of a clock, so it never races the sleep's start.
final class FakeTimeout: Sendable {
    private let firings: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (firings, continuation) = AsyncStream.makeStream()
    }

    /// Returns when the test fires, throws when the sleeping task is cancelled first.
    func sleep() async throws {
        for await _ in firings {
            return
        }
        throw CancellationError()
    }

    func fire() {
        continuation.yield()
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
