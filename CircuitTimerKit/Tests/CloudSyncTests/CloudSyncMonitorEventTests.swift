@testable import CloudSync

import CloudKit
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct CloudSyncMonitorEventTests {
    @Test(arguments: [
        (CloudSyncMonitor.EventKind.setup, true),
        (.import, true),
        (.export, false),
    ])
    func test_handle_successfulEvent_yieldsRemoteChangeExceptForExport(kind: CloudSyncMonitor.EventKind, yields: Bool) async {
        let harness = MonitorHarness()
        let changes = harness.monitor.remoteChanges()

        harness.succeed(kind)

        let yielded = await changes.takeBuffered() != nil
        #expect(yielded == yields)
    }

    @Test
    func test_status_problemsWhileMirroring_prefersAccountThenQuotaThenOtherFailure() async throws {
        let harness = MonitorHarness()
        try await harness.openMirroring()

        harness.fail(.import, error: TestFailure.unknown)
        #expect(await harness.monitor.status().next()?.problem == .syncFailed)
        harness.fail(.export, error: CKError(.quotaExceeded))
        #expect(await harness.monitor.status().next()?.problem == .quotaExceeded)

        let statuses = harness.monitor.status()
        _ = await statuses.next()
        harness.fail(.setup, error: CKError(.notAuthenticated))
        try await harness.accounts.next().answer.resume(returning: .temporarilyUnavailable)
        #expect(await statuses.next()?.problem == .temporarilyUnavailable)

        harness.fail(.setup, error: CKError(.notAuthenticated))
        try await harness.accounts.next().answer.resume(returning: .available)
        #expect(await statuses.next()?.problem == .quotaExceeded)
    }

    @Test
    func test_handle_failedSetupBeforeStoreOpened_showsOnceMirroring() async throws {
        let harness = MonitorHarness()
        let statuses = harness.monitor.status()
        _ = await statuses.next()

        harness.fail(.setup, error: TestFailure.unknown)
        #expect(await statuses.next() == CloudSyncStatus(isRequested: true, isMirroring: nil, problem: nil))

        harness.monitor.storeOpened(isMirroring: true)
        #expect(await statuses.next() == MonitorHarness.mirroring(.syncFailed))
        try await harness.accounts.next().answer.resume(returning: .available)
        #expect(await statuses.next() == MonitorHarness.mirroring(.syncFailed))
    }

    @Test(arguments: [CloudSyncMonitor.EventKind.setup, .import, .export])
    func test_handle_eventStart_changesNothing(kind: CloudSyncMonitor.EventKind) async throws {
        let harness = MonitorHarness()
        try await harness.openMirroring()
        let statuses = harness.monitor.status()
        _ = await statuses.next()
        let changes = harness.monitor.remoteChanges()

        harness.monitor.handle(kind: kind, isFinished: false, succeeded: false, error: nil)

        #expect(await statuses.takeBuffered() == nil)
        #expect(await changes.takeBuffered() == nil)
    }

    @Test(arguments: [CloudSyncMonitor.EventKind.setup, .import])
    func test_handle_laterSuccess_clearsOnlyItsKindsProblem(otherKind: CloudSyncMonitor.EventKind) async throws {
        let harness = MonitorHarness()
        try await harness.openMirroring()
        harness.fail(.export, error: CKError(.quotaExceeded))

        harness.succeed(otherKind)
        #expect(await harness.monitor.status().next()?.problem == .quotaExceeded)

        harness.succeed(.export)
        #expect(await harness.monitor.status().next() == MonitorHarness.mirroring(nil))
    }

    @Test(arguments: [CloudSyncMonitor.EventKind.import, .export], [false, true])
    func test_handle_failureWithoutKnownCause_showsSyncFailed(kind: CloudSyncMonitor.EventKind, hasError: Bool) async throws {
        let harness = MonitorHarness()
        try await harness.openMirroring()

        harness.fail(kind, error: hasError ? TestFailure.unknown : nil)

        #expect(await harness.monitor.status().next() == MonitorHarness.mirroring(.syncFailed))
    }

    @Test(arguments: [CloudSyncMonitor.EventKind.import, .export])
    func test_handle_failureOnAccount_readsAccountWithoutEventProblem(kind: CloudSyncMonitor.EventKind) async throws {
        let harness = MonitorHarness()
        try await harness.openMirroring()
        let statuses = harness.monitor.status()
        _ = await statuses.next()

        harness.fail(kind, error: CKError(.notAuthenticated))
        let read = try await harness.accounts.next()
        read.answer.resume(returning: .available)

        #expect(read.container == MonitorHarness.container)
        #expect(await statuses.next() == MonitorHarness.mirroring(nil))
    }

    @Test(arguments: [CloudSyncMonitor.EventKind.import, .export], [CKError.Code.operationCancelled, .networkFailure])
    func test_handle_cancelledOrTransientFailure_changesNothing(kind: CloudSyncMonitor.EventKind, code: CKError.Code) async throws {
        let harness = MonitorHarness()
        try await harness.openMirroring()
        let statuses = harness.monitor.status()
        _ = await statuses.next()
        let changes = harness.monitor.remoteChanges()

        harness.fail(kind, error: CKError(code))

        #expect(await statuses.takeBuffered() == nil)
        #expect(await changes.takeBuffered() == nil)
    }

    @Test
    func test_handle_concurrentEvents_lastPublishedStatusIsCurrent() async throws {
        let harness = MonitorHarness()
        try await harness.openMirroring()
        let statuses = harness.monitor.status()
        _ = await statuses.next()

        DispatchQueue.concurrentPerform(iterations: 400) { index in
            switch index % 4 {
                case 0: harness.fail(.export, error: CKError(.quotaExceeded))
                case 1: harness.succeed(.export)
                case 2: harness.fail(.import, error: TestFailure.unknown)
                default: harness.succeed(.import)
            }
        }

        let last = await statuses.takeBuffered()
        #expect(last != nil)
        #expect(await harness.monitor.status().next() == last)
    }
}
