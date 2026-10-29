@testable import BackgroundNotifications

import Dependencies
import Foundation
import Testing

struct NotificationSchedulerLifecycleTests: Sendable {
    private let owner = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
    private let otherOwner = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2))
    private let now = Date(timeIntervalSince1970: 1_000)

    @Test(arguments: ["nearDate", "farDate", "title", "body", "sound"])
    func test_sync_changedContent_preservesOnlyMatchingRequests(change: String) async throws {
        let fake = NotificationFake()
        let scheduler = NotificationScheduler(transport: fake.transport)
        let original = notification()
        _ = try await scheduler.sync(owner, revision: 1, plan: [original], now: { now }, clock: TestClock<Duration>())
        let oldID = try #require(fake.added.first)
        var changed = original
        switch change {
            case "nearDate": changed.fireDate = original.fireDate.addingTimeInterval(0.0005)
            case "farDate": changed.fireDate = original.fireDate.addingTimeInterval(0.002)
            case "title": changed.title = "Another workout"
            case "body": changed.body = "Rest"
            default: changed.isAudible = false
        }
        let report = try await scheduler.sync(owner, revision: 2, plan: [changed], now: { now }, clock: TestClock<Duration>())
        #expect(report.isClean)
        #expect(report.confirmedFuture == 1)
        #expect(fake.added.count == (change == "nearDate" ? 1 : 2))
        #expect(fake.removed.contains(oldID) == (change != "nearDate"))
        if change != "nearDate" {
            let freshID = try #require(fake.added.last)
            #expect(freshID != oldID)
        }
    }

    @Test(arguments: [
        NotificationAccess.Authorization.notDetermined, .denied, .authorized, .provisional, .ephemeral,
    ], [false, true])
    func test_access_authorizationAndAlerts_defineDelivery(authorization: NotificationAccess.Authorization, alerts: Bool) {
        let access = NotificationAccess(authorization: authorization, showsAlerts: alerts, playsSound: false)
        let granted = authorization == .authorized || authorization == .provisional || authorization == .ephemeral
        #expect(access.canDeliver == (granted && alerts))
        #expect(access.isDetermined == (authorization != .notDetermined))
    }

    @Test
    func test_sync_deliveryRevoked_removesFutureRequestsWithoutAdding() async throws {
        let fake = NotificationFake()
        let scheduler = NotificationScheduler(transport: fake.transport)
        _ = try await scheduler.sync(owner, revision: 1, plan: [notification()], now: { now }, clock: TestClock<Duration>())
        let oldID = try #require(fake.added.first)
        fake.access = NotificationAccess(authorization: .denied, showsAlerts: false, playsSound: false)
        let report = try await scheduler.sync(owner, revision: 2, plan: [notification()], now: { now }, clock: TestClock<Duration>())
        #expect(!report.canDeliver)
        #expect(report.access == fake.access)
        #expect(!report.isClean)
        #expect(report.confirmedFuture == 0)
        #expect(fake.added.count == 1)
        #expect(fake.removed.contains(oldID))
    }

    @Test
    func test_sync_olderRevisionRejected_equalRevisionAccepted() async throws {
        let fake = NotificationFake()
        let scheduler = NotificationScheduler(transport: fake.transport)
        _ = try await scheduler.sync(owner, revision: 2, plan: [notification()], now: { now }, clock: TestClock<Duration>())
        let replacement = notification(after: 20)
        let older = try await scheduler.sync(owner, revision: 1, plan: [replacement], now: { now }, clock: TestClock<Duration>())
        #expect(older.superseded)
        #expect(fake.added.count == 1)
        let equal = try await scheduler.sync(owner, revision: 2, plan: [replacement], now: { now }, clock: TestClock<Duration>())
        #expect(equal.isClean)
        #expect(fake.added.count == 2)
    }

    @Test
    func test_sync_settingsTimeout_throwsAfterRetiringOldRequest() async throws {
        try await withMainSerialExecutor {
            let fake = NotificationFake()
            let scheduler = NotificationScheduler(transport: fake.transport)
            let clock = TestClock<Duration>()
            _ = try await scheduler.sync(owner, revision: 1, plan: [notification()], now: { now }, clock: clock)
            let oldID = try #require(fake.added.first)
            fake.holdsSettings = true
            let operation = Task {
                try await scheduler.sync(owner, revision: 2, plan: [notification(after: 20)], now: { now }, clock: clock)
            }
            await fake.waitForSettings(count: 2)
            #expect(fake.removed.contains(oldID))
            await clock.advance(by: .milliseconds(500))
            await #expect(throws: NotificationFailure.timedOut) { try await operation.value }
        }
    }

    @Test
    func test_sync_addTimeout_neverClaimsVerifiedCoverage() async throws {
        try await withMainSerialExecutor {
            let fake = NotificationFake()
            fake.holdsAdd = true
            let clock = TestClock<Duration>()
            let scheduler = NotificationScheduler(transport: fake.transport)
            let operation = Task {
                try await scheduler.sync(owner, revision: 1, plan: [notification()], now: { now }, clock: clock)
            }
            await fake.waitForAdd()
            await clock.advance(by: .seconds(2))
            let report = try await operation.value
            #expect(!report.isVerified)
            #expect(!report.isClean)
            fake.completeAdds()
        }
    }

    @Test
    func test_sync_multipleAdds_waitsForEveryCallback() async throws {
        try await withMainSerialExecutor {
            let fake = NotificationFake()
            fake.holdsAdd = true
            let clock = TestClock<Duration>()
            let initialInstant = clock.now
            let finished = LockIsolated(false)
            let scheduler = NotificationScheduler(transport: fake.transport)
            var second = notification(after: 20)
            second.key = "finish"
            let plan = [notification(), second]
            let operation = Task {
                let report = try await scheduler.sync(owner, revision: 1, plan: plan, now: { now }, clock: clock)
                finished.setValue(true)
                return report
            }
            await fake.waitForAdd(count: 2)
            let firstID = try #require(fake.added.first)
            let secondID = try #require(fake.added.last)
            #expect(firstID != secondID)
            fake.completeAdd(firstID)
            await Task.megaYield()
            #expect(!finished.value)
            fake.completeAdd(secondID)
            let report = try await operation.value
            #expect(report.isClean)
            #expect(report.confirmedFuture == 2)
            #expect(clock.now == initialInstant)
        }
    }

    @Test(arguments: [false, true])
    func test_sync_cancelledWhileWaiting_throwsCancellationError(atPending: Bool) async throws {
        try await withMainSerialExecutor {
            let fake = NotificationFake()
            fake.holdsAdd = !atPending
            fake.holdsPending = atPending
            let clock = TestClock<Duration>()
            let scheduler = NotificationScheduler(transport: fake.transport)
            let operation = Task {
                try await scheduler.sync(owner, revision: 1, plan: [notification()], now: { now }, clock: clock)
            }
            if atPending { await fake.waitForPending(count: 2) } else { await fake.waitForAdd() }
            await #expect(throws: (any Error).self) { try await clock.checkSuspension() }
            operation.cancel()
            await #expect(throws: CancellationError.self) { try await operation.value }
            fake.completeAdds()
            fake.completePending()
            try await clock.checkSuspension()
        }
    }

    @Test(arguments: OwnerEnding.allCases)
    func test_end_duringSDKAdmission_removesRequestBeforeCallback(ending: OwnerEnding) async throws {
        try await withMainSerialExecutor {
            let fake = NotificationFake()
            fake.holdsAdd = true
            let scheduler = NotificationScheduler(transport: fake.transport)
            fake.beforeAdd = { ending.fire(scheduler, owner: owner) }
            let operation = Task {
                try await scheduler.sync(owner, revision: 1, plan: [notification()], now: { now }, clock: TestClock<Duration>())
            }
            await fake.waitForAdd()
            await Task.megaYield()
            fake.beforeAdd = nil
            let id = try #require(fake.added.first)
            #expect(!fake.pendingIdentifiers.contains(id))
            #expect(fake.removed.contains(id))
            #expect(fake.removedDelivered.contains(id))
            operation.cancel()
            await #expect(throws: CancellationError.self) { try await operation.value }
            fake.completeAdds()
        }
    }

    @Test(arguments: [false, true])
    func test_sync_lateObsoleteFailure_doesNotPoisonCurrentPlan(ended: Bool) async throws {
        let fake = NotificationFake()
        fake.holdsAdd = true
        let scheduler = NotificationScheduler(transport: fake.transport)
        let first = Task {
            try await scheduler.sync(owner, revision: 1, plan: [notification()], now: { now }, clock: TestClock<Duration>())
        }
        await fake.waitForAdd()
        let oldID = try #require(fake.added.first)
        if ended { scheduler.end(owner) }
        let currentOwner = ended ? otherOwner : owner
        fake.holdsAdd = false
        let plan = [notification(after: 20)]
        let current = try await scheduler.sync(currentOwner, revision: 2, plan: plan, now: { now }, clock: TestClock<Duration>())
        let newID = try #require(fake.added.last)
        #expect(newID != oldID)
        #expect(current.isClean)
        fake.pendingIdentifiers.insert(oldID)
        #expect(fake.pendingIdentifiers.contains(oldID))
        fake.completeAdd(oldID, result: .failure(.system("Late obsolete error")))
        #expect(try await first.value.superseded)
        #expect(!fake.pendingIdentifiers.contains(oldID))
        #expect(fake.pendingIdentifiers.contains(newID))
        let afterCallback = try await scheduler.sync(currentOwner, revision: 3, plan: plan, now: { now }, clock: TestClock<Duration>())
        #expect(afterCallback.isClean)
        #expect(afterCallback.failed == 0)
        #expect(fake.removed.contains(oldID))
        #expect(!fake.removed.contains(newID))
        #expect(fake.pendingIdentifiers.contains(newID))
    }

    @Test
    func test_sync_lateFailureForRetainedID_isCarriedExactlyOnce() async throws {
        let fake = NotificationFake()
        fake.holdsAdd = true
        let scheduler = NotificationScheduler(transport: fake.transport)
        let plan = [notification()]
        let first = Task {
            try await scheduler.sync(owner, revision: 1, plan: plan, now: { now }, clock: TestClock<Duration>())
        }
        await fake.waitForAdd()
        let id = try #require(fake.added.first)
        let retained = try await scheduler.sync(owner, revision: 2, plan: plan, now: { now }, clock: TestClock<Duration>())
        #expect(retained.isClean)
        #expect(fake.added == [id])
        fake.completeAdd(id, result: .failure(.system("Late current error")))
        #expect(try await first.value.superseded)
        fake.holdsAdd = false
        let carried = try await scheduler.sync(owner, revision: 3, plan: plan, now: { now }, clock: TestClock<Duration>())
        #expect(carried.failed == 1)
        #expect(!carried.isClean)
        #expect(carried.confirmedFuture == 1)
        let recovered = try await scheduler.sync(owner, revision: 4, plan: plan, now: { now }, clock: TestClock<Duration>())
        #expect(recovered.failed == 0)
        #expect(recovered.isClean)
    }

    @Test
    func test_removeDelivered_ownerScoped_endClearsEveryIssuedIdentifier() async throws {
        let fake = NotificationFake()
        let scheduler = NotificationScheduler(transport: fake.transport)
        _ = try await scheduler.sync(owner, revision: 1, plan: [notification()], now: { now }, clock: TestClock<Duration>())
        let firstID = try #require(fake.added.first)
        _ = try await scheduler.sync(
            owner, revision: 2, plan: [notification(after: 20)], now: { now }, clock: TestClock<Duration>()
        )
        let replacementID = try #require(fake.added.last)
        #expect(firstID != replacementID)
        _ = try await scheduler.sync(otherOwner, revision: 1, plan: [notification()], now: { now }, clock: TestClock<Duration>())
        let otherID = try #require(fake.added.last)
        fake.deliveredIdentifiers = [firstID, replacementID, otherID, "another-app"]
        scheduler.removeDelivered(owner)
        #expect(fake.deliveredIdentifiers == [otherID, "another-app"])
        #expect(!fake.removedDelivered.contains(otherID))
        fake.deliveredIdentifiers = [firstID, replacementID, otherID, "another-app"]
        scheduler.end(owner)
        #expect(fake.deliveredIdentifiers == [otherID, "another-app"])
        #expect(!fake.pendingIdentifiers.contains(replacementID))
        scheduler.end(otherOwner)
        scheduler.end(otherOwner)
        #expect(fake.removed.contains(otherID))
        #expect(fake.removedDelivered.contains(otherID))
        #expect(fake.deliveredIdentifiers == ["another-app"])
        scheduler.removeDelivered(otherOwner)
        #expect(fake.deliveredIdentifiers == ["another-app"])
        let unknownOwner = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3))
        let callsBeforeUnknown = fake.removeDeliveredCalls.count
        scheduler.removeDelivered(unknownOwner)
        #expect(fake.removeDeliveredCalls.count == callsBeforeUnknown + 1)
        #expect(fake.removeDeliveredCalls.last?.isEmpty == true)
    }

    private func notification(after seconds: TimeInterval = 10) -> ScheduledNotification {
        ScheduledNotification(key: "stage-1", fireDate: now.addingTimeInterval(seconds), title: "Workout", body: "Work", isAudible: true)
    }
}
