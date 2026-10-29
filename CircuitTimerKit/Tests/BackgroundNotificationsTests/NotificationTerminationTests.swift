@testable import BackgroundNotifications

import Dependencies
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct NotificationTerminationTests: Sendable {
    private let owner = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
    private let otherOwner = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2))
    private let newOwner = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3))
    private let now = Date(timeIntervalSince1970: 1_000)
    private static let foreign = "com.example.other"

    private func notification(after seconds: TimeInterval = 10) -> ScheduledNotification {
        ScheduledNotification(key: "stage-1", fireDate: now.addingTimeInterval(seconds), title: "Workout", body: "Work", isAudible: true)
    }

    private func sync(_ scheduler: NotificationScheduler, _ owner: UUID, revision: Int = 1) async throws -> NotificationSyncReport {
        try await scheduler.sync(owner, revision: revision, plan: [notification()], now: { now }, clock: TestClock<Duration>())
    }

    @Test
    func test_beginTermination_removesEveryOwnersRequestsSynchronously() async throws {
        let fake = NotificationFake()
        let scheduler = NotificationScheduler(transport: fake.transport)
        _ = try await sync(scheduler, owner)
        _ = try await sync(scheduler, otherOwner)
        let issued = fake.added

        scheduler.beginTermination()

        #expect(issued.count == 2)
        #expect(Set(fake.removed).isSuperset(of: issued))
        #expect(Set(fake.removedDelivered).isSuperset(of: issued))
    }

    @Test
    func test_sync_afterBeginTermination_schedulesNothingForAnyOwner() async throws {
        let fake = NotificationFake()
        let scheduler = NotificationScheduler(transport: fake.transport)
        _ = try await sync(scheduler, owner)

        scheduler.beginTermination()

        #expect(try await sync(scheduler, owner, revision: 2).superseded)
        #expect(try await sync(scheduler, newOwner).superseded)
        #expect(fake.added.count == 1)
    }

    @Test(arguments: [false, true])
    func test_finishTermination_removesAModuleRequestThatLandedAfterTheFirstRemoval(completesLate: Bool) async throws {
        let fake = NotificationFake()
        fake.holdsAdd = true
        fake.recordsPending = false
        let scheduler = NotificationScheduler(transport: fake.transport)
        let operation = Task { try await sync(scheduler, owner) }
        await fake.waitForAdd()
        scheduler.beginTermination()
        // iOS lists the request only after the removal that `beginTermination` sent.
        let late = try #require(fake.added.first)
        fake.pendingIdentifiers = [late, Self.foreign]
        fake.deliveredIdentifiers = [late, Self.foreign]

        if completesLate {
            fake.holdsPending = true
            let finishing = Task { await scheduler.finishTermination(clock: TestClock<Duration>()) }
            await fake.waitForPending()
            fake.completeAdds()
            fake.completePending()
            await finishing.value
        } else {
            fake.completeAdds()
            await scheduler.finishTermination(clock: TestClock<Duration>())
        }

        #expect(fake.pendingIdentifiers == [Self.foreign])
        #expect(fake.deliveredIdentifiers == [Self.foreign])
        #expect(!fake.removed.contains(Self.foreign))
        #expect(try await operation.value.superseded)
    }

    @Test
    func test_finishTermination_cancelledCaller_returnsAndTheCallbacksStillRemove() async {
        let fake = NotificationFake()
        fake.holdsPending = true
        fake.pendingIdentifiers = ["ct.cue.left"]
        let scheduler = NotificationScheduler(transport: fake.transport)
        let finishing = Task { await scheduler.finishTermination(clock: TestClock<Duration>()) }
        await fake.waitForPending()

        finishing.cancel()
        await finishing.value
        fake.completePending()

        #expect(fake.removed == ["ct.cue.left"])
    }
}
