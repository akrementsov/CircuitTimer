@testable import CloudSync

import CloudKit
import Dependencies
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct CloudSyncMonitorAccountTests {
    @Test(arguments: [
        (CKAccountStatus.available, nil),
        (.couldNotDetermine, nil),
        // A status a later SDK may add.
        (CKAccountStatus(rawValue: 99)!, nil),
        (.noAccount, .noAccount),
        (.restricted, .restricted),
        (.temporarilyUnavailable, .temporarilyUnavailable),
    ] as [(CKAccountStatus, CloudSyncProblem?)])
    func test_storeOpened_mirroring_showsMirroringThenAccountProblem(
        accountStatus: CKAccountStatus,
        problem: CloudSyncProblem?
    ) async throws {
        let harness = MonitorHarness()
        let statuses = harness.monitor.status()
        _ = await statuses.next()

        harness.monitor.storeOpened(isMirroring: true)
        #expect(await statuses.next() == MonitorHarness.mirroring(nil))
        let read = try await harness.accounts.next()
        read.answer.resume(returning: accountStatus)

        #expect(read.container == MonitorHarness.container)
        #expect(await statuses.next() == MonitorHarness.mirroring(problem))
    }

    @Test
    func test_accountRead_throws_blamesNoAccountAndKeepsEventProblems() async throws {
        let harness = MonitorHarness()
        try await harness.openMirroring(answer: .noAccount)
        harness.fail(.import, error: CKError(.quotaExceeded))
        let statuses = harness.monitor.status()
        #expect(await statuses.next()?.problem == .noAccount)

        harness.fail(.export, error: CKError(.notAuthenticated))
        try await harness.accounts.next().answer.resume(throwing: TestFailure.unknown)

        #expect(await statuses.next() == MonitorHarness.mirroring(.quotaExceeded))
    }

    @Test
    func test_accountChanged_withProblems_clearsThemAndAnnouncesTwice() async throws {
        let harness = MonitorHarness()
        try await harness.openMirroring(answer: .noAccount)
        harness.fail(.export, error: TestFailure.unknown)
        let changes = harness.monitor.remoteChanges()

        harness.postAccountChange()
        #expect(await changes.next() != nil)
        let read = try await harness.accounts.next()
        read.answer.resume(returning: .available)

        #expect(await changes.next() != nil)
        #expect(await harness.monitor.status().next() == MonitorHarness.mirroring(nil))
        #expect(read.container == MonitorHarness.container)
    }

    @Test
    func test_accountRead_answersOutOfOrder_appliesOnlyLatest() async throws {
        // Serial, so a dropped answer has been handled before the test goes on.
        try await withMainSerialExecutor {
            let harness = MonitorHarness()
            try await harness.openMirroring()
            let statuses = harness.monitor.status()
            _ = await statuses.next()

            harness.postAccountChange()
            #expect(await statuses.next() == MonitorHarness.mirroring(nil))
            let afterChange = try await harness.accounts.next()
            harness.fail(.import, error: CKError(.notAuthenticated))
            let latest = try await harness.accounts.next()

            afterChange.answer.resume(returning: .noAccount)
            await Task.megaYield()
            #expect(await harness.monitor.status().next() == MonitorHarness.mirroring(nil))

            let announced = harness.monitor.remoteChanges()
            latest.answer.resume(returning: .restricted)

            #expect(await statuses.next() == MonitorHarness.mirroring(.restricted))
            #expect(await announced.takeBuffered() != nil)

            let unannounced = harness.monitor.remoteChanges()
            harness.fail(.export, error: CKError(.accountTemporarilyUnavailable))
            try await harness.accounts.next().answer.resume(returning: .available)

            #expect(await statuses.next() == MonitorHarness.mirroring(nil))
            #expect(await unannounced.takeBuffered() == nil)
        }
    }

    @Test
    func test_accountChanged_beforeStoreOpened_announcesWithoutAccountRead() async {
        await withMainSerialExecutor {
            let harness = MonitorHarness()
            #expect(harness.monitor.mirroredContainer() == MonitorHarness.container)
            let changes = harness.monitor.remoteChanges()

            harness.postAccountChange()
            await Task.megaYield()

            #expect(await changes.takeBuffered() != nil)
            #expect(harness.accounts.readsStarted == 0)
        }
    }

    @Test(arguments: [(true, nil), (false, MonitorHarness.container)] as [(Bool, String?)])
    func test_accountChanged_withoutContainer_isNotObserved(preference: Bool, container: String?) async {
        let harness = MonitorHarness(preference: preference, container: container)
        #expect(harness.monitor.mirroredContainer() == nil)
        let changes = harness.monitor.remoteChanges()

        harness.postAccountChange()

        #expect(await changes.takeBuffered() == nil)
    }
}
