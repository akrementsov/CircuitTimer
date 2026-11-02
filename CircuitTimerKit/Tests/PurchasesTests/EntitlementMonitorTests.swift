@testable import Purchases

import Dependencies
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct EntitlementMonitorTests {
    let store = FakeStore()
    let timeout = FakeTimeout()
    let monitor: EntitlementMonitor

    init() {
        let timeout = timeout
        monitor = EntitlementMonitor(transport: store.transport) { _ in try await timeout.sleep() }
    }

    // MARK: - Start and status

    @Test
    func test_firstUse_fromACancelledCaller_startsOneListenerAndOneRead() async throws {
        // Serial, so every task the monitor started has run before the test checks what it did not do.
        try await withMainSerialExecutor {
            let caller = Task { [monitor] in
                withUnsafeCurrentTask { $0?.cancel() }
                return monitor.currentStatus
            }
            #expect(await caller.value == .unknown)
            _ = monitor.changes()
            _ = monitor.currentStatus

            let read = try await store.nextRead()
            let statuses = monitor.changes()
            #expect(await statuses.next() == .unknown)
            read.answer.resume(returning: true)

            #expect(await statuses.next() == .full)
            while store.listenersStarted.value == 0 {
                await Task.yield()
            }
            await Task.megaYield()
            #expect(store.readsStarted.value == 1)
            #expect(store.listenersStarted.value == 1)
            store.finish()
        }
    }

    @Test
    func test_changes_currentStatusFirstThenEachChangeWithoutRepeats() async throws {
        let statuses = monitor.changes()
        #expect(await statuses.next() == .unknown)

        try await store.nextRead().answer.resume(returning: true)
        #expect(await statuses.next() == .full)

        store.sendUpdate()
        try await store.nextRead().answer.resume(returning: true)
        store.sendUpdate()
        try await store.nextRead().answer.resume(returning: false)

        // The second `.full` answer changed nothing and was not published.
        #expect(await statuses.next() == .free)
        store.finish()
    }

    @Test
    func test_refreshStatus_answeredBeforeTheTimeout_returnsTheAnswer() async throws {
        let refresh = Task { [monitor] in await monitor.refreshStatus(timeout: .seconds(1)) }

        try await store.nextRead().answer.resume(returning: true)

        #expect(await refresh.value == .full)
        store.finish()
    }

    @Test
    func test_refreshStatus_unansweredUntilTheTimeout_returnsTheCurrentStatus() async throws {
        let refresh = Task { [monitor] in await monitor.refreshStatus(timeout: .seconds(1)) }
        let read = try await store.nextRead()
        timeout.fire()

        #expect(await refresh.value == .unknown)
        read.answer.resume(returning: false)
        store.finish()
    }

    @Test
    func test_refreshStatus_cancelledCaller_returnsAtOnceAndTheReadStillPublishes() async throws {
        let refresh = Task { [monitor] in await monitor.refreshStatus(timeout: .seconds(1)) }
        let read = try await store.nextRead()
        refresh.cancel()
        #expect(await refresh.value == .unknown)

        let statuses = monitor.changes()
        #expect(await statuses.next() == .unknown)
        read.answer.resume(returning: true)

        #expect(await statuses.next() == .full)
        store.finish()
    }

    // MARK: - Purchase

    @Test
    func test_purchase_purchased_publishesFullBeforeItReturns() async throws {
        let read = try startedRead()

        #expect(try await monitor.purchase() == .purchased)

        #expect(monitor.currentStatus == .full)
        try await read.answer()
        store.finish()
    }

    @Test(arguments: [PurchaseOutcome.pending, .cancelled])
    func test_purchase_pendingOrCancelled_publishesNothing(outcome: PurchaseOutcome) async throws {
        store.purchaseResult.setValue(.success(outcome))
        let read = try startedRead()

        #expect(try await monitor.purchase() == outcome)

        #expect(monitor.currentStatus == .unknown)
        try await read.answer()
        store.finish()
    }

    @Test
    func test_purchaseAndOffer_failing_throwAndPublishNothing() async throws {
        store.purchaseResult.setValue(.failure(TestFailure()))
        store.offerResult.setValue(.failure(TestFailure()))
        let read = try startedRead()

        await #expect(throws: TestFailure.self) { try await monitor.purchase() }
        await #expect(throws: TestFailure.self) { try await monitor.offer() }

        #expect(monitor.currentStatus == .unknown)
        try await read.answer()
        store.finish()
    }

    // MARK: - Restore

    @Test(arguments: [(true, RestoreOutcome.restored), (false, .nothingFound)])
    func test_restore_afterASync_answersByTheEntitlement(isEntitled: Bool, outcome: RestoreOutcome) async throws {
        // The first read has taken its number before the restore starts, so the restore's read is the newest.
        let initial = try await store.nextReadAfterStart(monitor)
        let restore = Task { [monitor] in try await monitor.restore() }
        let restoreRead = try await store.nextRead()
        initial.answer.resume(returning: false)

        restoreRead.answer.resume(returning: isEntitled)

        #expect(try await restore.value == outcome)
        #expect(monitor.currentStatus == (isEntitled ? .full : .free))
        store.finish()
    }

    @Test
    func test_restore_cancelledSignIn_returnsCancelledWithoutReading() async throws {
        store.syncResult.setValue(.success(false))
        let read = try startedRead()

        #expect(try await monitor.restore() == .cancelled)

        try await read.answer()
        #expect(store.readsStarted.value == 1)
        store.finish()
    }

    @Test
    func test_restore_failingSync_throws() async throws {
        store.syncResult.setValue(.failure(TestFailure()))
        let read = try startedRead()

        await #expect(throws: TestFailure.self) { try await monitor.restore() }

        try await read.answer()
        store.finish()
    }

    @Test
    func test_restore_cancelledCaller_readAnsweringFree_publishesNothing() async throws {
        try await store.nextReadAfterStart(monitor).answer.resume(returning: true)
        while monitor.currentStatus != .full {
            await Task.yield()
        }
        let restore = Task { [monitor] in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await monitor.restore()
        }

        // A cancelled walk of the entitlements may end early with nothing found.
        try await store.nextRead().answer.resume(returning: false)
        _ = try await restore.value

        #expect(monitor.currentStatus == .full)
        store.finish()
    }

    // MARK: - Transaction updates and order

    @Test(arguments: [(false, true), (true, false)])
    func test_transactionUpdate_readsAgainAndPublishes(before: Bool, after: Bool) async throws {
        let statuses = monitor.changes()
        #expect(await statuses.next() == .unknown)
        try await store.nextRead().answer.resume(returning: before)
        #expect(await statuses.next() == (before ? .full : .free))

        store.sendUpdate()
        try await store.nextRead().answer.resume(returning: after)

        #expect(await statuses.next() == (after ? .full : .free))
        store.finish()
    }

    @Test
    func test_olderRead_answeringAfterANewerOne_publishesNothing() async throws {
        // Serial, so every task the monitor started has run before the test checks what it did not do.
        try await withMainSerialExecutor {
            let statuses = monitor.changes()
            #expect(await statuses.next() == .unknown)
            let older = try await store.nextRead()
            store.sendUpdate()
            let newer = try await store.nextRead()

            newer.answer.resume(returning: true)
            #expect(await statuses.next() == .full)
            older.answer.resume(returning: false)
            await Task.megaYield()

            #expect(monitor.currentStatus == .full)
            #expect(await statuses.takeBuffered() == nil)
            store.finish()
        }
    }

    @Test
    func test_readStartedBeforeAPurchase_answeringFree_keepsFull() async throws {
        // Serial, so every task the monitor started has run before the test checks what it did not do.
        try await withMainSerialExecutor {
            let read = try await store.nextReadAfterStart(monitor)

            _ = try await monitor.purchase()
            read.answer.resume(returning: false)
            await Task.megaYield()

            #expect(monitor.currentStatus == .full)
            store.finish()
        }
    }

    @Test
    func test_restore_overtakenByANewerRead_readsUntilItsReadIsTheNewest() async throws {
        let initial = try await store.nextReadAfterStart(monitor)
        initial.answer.resume(returning: false)
        let restore = Task { [monitor] in try await monitor.restore() }
        let restoreRead = try await store.nextRead()
        store.sendUpdate()
        let updateRead = try await store.nextRead()

        // The restore's read misses the full version that the newer read then finds.
        restoreRead.answer.resume(returning: false)
        let retry = try await store.nextRead()
        updateRead.answer.resume(returning: true)
        retry.answer.resume(returning: true)

        #expect(try await restore.value == .restored)
        #expect(monitor.currentStatus == .full)
        store.finish()
    }

    // MARK: - Helpers

    /// Starts the monitor and returns its first read, to be answered `false` by `answer()` once the test is done with
    /// it, so no continuation leaks.
    private func startedRead() throws -> PendingRead {
        PendingRead(store: store, monitor: monitor)
    }
}

/// The monitor's first read, held until the test lets it answer.
struct PendingRead {
    let store: FakeStore
    let monitor: EntitlementMonitor

    init(store: FakeStore, monitor: EntitlementMonitor) {
        self.store = store
        self.monitor = monitor
        _ = monitor.currentStatus
    }

    func answer(_ isEntitled: Bool = false) async throws {
        try await store.nextRead().answer.resume(returning: isEntitled)
    }
}

extension FakeStore {
    func nextReadAfterStart(_ monitor: EntitlementMonitor, sourceLocation: SourceLocation = #_sourceLocation) async throws -> Read {
        _ = monitor.currentStatus
        return try await nextRead(sourceLocation: sourceLocation)
    }
}
