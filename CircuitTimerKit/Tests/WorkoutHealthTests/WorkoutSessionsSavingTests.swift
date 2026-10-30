@testable import WorkoutHealth

import Dependencies
import Foundation
import Testing

extension WorkoutSessionsTests {
    // MARK: - Saving workouts

    @Test
    func test_end_afterASync_savesTheTrackItIsGiven() async {
        await running()
        await sync(track(stopsAt: 5))

        await end(track: track(stopsAt: 100), at: moment(10))
        await settle()

        #expect(health.saved.value == [workout(0, 10)])
    }

    @Test(arguments: [false, true])
    func test_endAll_runningWithATrack_savesUpToTheDateAndWaitsForTheEndAndTheSave(endsFirst: Bool) async {
        let session = await running()
        await sync(track())
        health.holdSaves()

        let ending = endAllInTheBackground(at: moment(10))
        await settle()
        #expect(health.saved.value == [workout(0, 10)])

        if endsFirst {
            session.report(.changed(.ended, date: moment(10)))
        } else {
            health.releaseSaves()
        }
        await settle()
        #expect(!ending.isDone.value)

        if endsFirst {
            health.releaseSaves()
        } else {
            session.report(.changed(.ended, date: moment(10)))
        }
        await ending.task.value
        #expect(session.calls.value.last == .release)
    }

    @Test(arguments: [false, true])
    func test_running_withoutATrack_endOrEndAllEndsTheSessionAndSavesNothing(byEndAll: Bool) async {
        let session = await running()

        if byEndAll {
            let ending = endAllInTheBackground(at: moment(10))
            await settle()
            session.report(.changed(.ended, date: moment(10)))
            await ending.task.value
        } else {
            await end(at: moment(10))
            session.report(.changed(.ended, date: moment(10)))
            await settle()
        }

        #expect(session.calls.value == [.observe, .start(moment(0)), .stop(moment(10)), .end, .release])
        #expect(health.saved.value.isEmpty)
    }

    @Test
    func test_endAll_trackSyncedBeforeTheSessionStarted_savesIt() async {
        await sync(track())
        let session = await running()

        let ending = endAllInTheBackground(at: moment(10))
        await settle()
        session.report(.changed(.ended, date: moment(10)))
        await ending.task.value

        #expect(health.saved.value == [workout(0, 10)])
    }

    @Test(arguments: [false, true])
    func test_endAll_saveThrows_endsTheSessionAndReturnsWithoutARetry(isCancellation: Bool) async {
        health.saveFailures.setValue([isCancellation ? CancellationError() : FakeError()])
        let session = await running()
        await sync(track())

        let ending = endAllInTheBackground(at: moment(10))
        await settle()
        session.report(.changed(.ended, date: moment(10)))
        await ending.task.value
        await settle()

        #expect(session.calls.value == [.observe, .start(moment(0)), .stop(moment(10)), .end, .release])
        #expect(health.saved.value == [workout(0, 10)])
    }

    @Test
    func test_endAll_severalOwners_savesEachTrackAlthoughOneSaveFails() async {
        health.saveFailures.setValue([FakeError()])
        let first = await running(at: moment(0))
        let second = await running(Self.other, at: moment(1))
        await sync(track(from: 0))
        await sync(track(from: 1), owner: Self.other)

        let ending = endAllInTheBackground(at: moment(10))
        await settle()
        first.report(.changed(.ended, date: moment(10)))
        second.report(.changed(.ended, date: moment(10)))
        await ending.task.value

        #expect(health.saved.value.count == 2)
        #expect(Set(health.saved.value) == [workout(0, 10), workout(1, 10)])
    }

    static let datedRunningLosses: [SessionEvent] = [
        .changed(.ended, date: moment(30)),
        .changed(.stopped, date: moment(30)),
        .failed(FakeError()),
    ]

    @Test(arguments: datedRunningLosses)
    func test_runningSession_lostWithATrack_savesItOnceUpToTheLoss(event: SessionEvent) async {
        let session = await running()
        await sync(track(stopsAt: 2_000))
        health.holdSaves()

        session.report(event)
        await settle()
        // A failure carries no date: the workout ends at `now()`.
        let lost = if case .failed = event { workout(0, 1_000) } else { workout(0, 30) }
        let ended: [FakeSession.Call] = if case .changed(.ended, _) = event { [.release] } else { [.end, .release] }
        #expect(health.saved.value == [lost])
        #expect(session.calls.value == [.observe, .start(moment(0))] + ended)

        let ending = endAllInTheBackground(at: moment(40))
        await settle()
        #expect(!ending.isDone.value)

        health.releaseSaves()
        await ending.task.value
        await end(track: track(stopsAt: 2_000), at: moment(50))
        await settle()
        #expect(health.saved.value == [lost])
    }

    @Test
    func test_runningSession_lostBeforeASyncedPause_savesUpToTheLossWithoutShiftingIt() async {
        let session = await running()
        var paused = track(stopsAt: 100)
        paused.follow(.halted, at: moment(40))
        await sync(paused)

        session.report(.changed(.ended, date: moment(30)))
        await settle()

        #expect(health.saved.value == [workout(0, 30)])
    }

    // MARK: - Saving concurrently

    @Test
    func test_sync_olderOrEqualRevision_keepsTheNewestTrack() async {
        let session = await running()
        await sync(track(from: 0), revision: 2)
        await sync(track(from: 3), revision: 1)
        await sync(track(from: 5), revision: 2)

        let ending = endAllInTheBackground(at: moment(10))
        await settle()
        session.report(.changed(.ended, date: moment(10)))
        await ending.task.value

        #expect(health.saved.value == [workout(0, 10)])
    }

    @Test
    func test_lostBeforeAnyTrack_firstSyncSavesUpToTheLossAndNothingLaterSaves() async {
        let session = await running()
        session.report(.changed(.ended, date: moment(30)))
        await settle()

        await sync(track(from: 0), revision: 1)
        await sync(track(from: 5), revision: 2)
        await end(track: track(from: 10), at: moment(50))
        await settle()

        #expect(health.saved.value == [workout(0, 30)])
    }

    @Test
    func test_lostBeforeAnyTrack_endSavesUpToTheLossAndALateSyncNothing() async {
        let session = await running()
        session.report(.changed(.ended, date: moment(30)))
        await settle()

        await end(track: track(from: 10), at: moment(50))
        await sync(track(from: 0))
        await endAll(at: moment(60))

        #expect(health.saved.value == [workout(10, 30)])
    }

    @Test
    func test_end_whileASaveIsUnderWay_returnsAndAnotherOwnerEnds() async {
        await running(at: moment(0))
        await running(Self.other, at: moment(1))
        health.holdSaves()

        await end(track: track(from: 0), at: moment(10))
        await end(Self.other, track: track(from: 1), at: moment(20))
        await settle()

        #expect(health.saved.value.count == 2)
        #expect(Set(health.saved.value) == [workout(0, 10), workout(1, 20)])
        #expect(health.finishedSaves.value == 0)
        health.releaseSaves()
    }

    @Test
    func test_endAll_cancelledWhileASaveIsUnderWay_leavesTheSaveRunning() async {
        let session = await running()
        await sync(track())
        health.holdSaves()
        let ending = endAllInTheBackground(at: moment(10))
        await settle()
        session.report(.changed(.ended, date: moment(10)))
        await settle()

        ending.task.cancel()
        await ending.task.value
        await settle()
        #expect(health.finishedSaves.value == 0)

        health.releaseSaves()
        await endAll(at: moment(20))
        #expect(health.finishedSaves.value == 1)
    }
}
