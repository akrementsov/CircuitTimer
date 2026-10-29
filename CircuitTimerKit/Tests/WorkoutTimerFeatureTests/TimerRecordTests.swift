@testable import WorkoutTimerFeature

import ComposableArchitecture
import Testing
import WorkoutDomain

@MainActor
@Suite
struct TimerRecordTests {
    @Test
    func test_ticked_ordinaryRunningTick_doesNotWriteTheRecord() async {
        let timer = TimerHarness(.appearing())
        await timer.appearRunning()
        let firstWrite = timer.writes.value
        await timer.advance(seconds: 1)
        await timer.receive(.internal(.ticked(generation: 1, isFinal: false))) {
            $0.settle(at: moment(1))
            $0.clockAnchor = timer.anchor(totalElapsed: .seconds(1))
        }

        #expect(timer.writes.value == firstWrite)
        #expect(firstWrite.count == 1)
        #expect(timer.releasedAssertions.value == timer.assertions.value)
        await timer.send(.view(.playPauseButtonTapped), saving: true) {
            $0.run.pause(at: moment(1))
            $0.settle(at: moment(1))
            $0.clockGeneration = 2
            $0.clockAnchor = nil
            $0.requestedAwake = false
            $0.awakeRevision = 2
        }
        await timer.store.finish()
    }

    @Test
    func test_recordWritten_olderCompletion_doesNotOverrideTheNewestWrite() async {
        var state = WorkoutTimerFeature.State.fixture(.paused)
        let record = WorkoutRunRecord(workoutID: state.workoutID, run: state.run)
        state.recordSync = .pending(revision: 2, record: record)
        state.hasRecordFailed = true
        let timer = TimerHarness(state)

        await timer.send(.internal(.recordWritten(revision: 1, succeeded: true)))
        await timer.send(.internal(.recordWritten(revision: 1, succeeded: false)))
        await timer.send(.internal(.recordWritten(revision: 2, succeeded: true))) {
            $0.recordSync = .stored(record)
            $0.hasRecordFailed = false
        }
        await timer.send(.internal(.recordWritten(revision: 1, succeeded: false)))
        await timer.store.finish()

        #expect(!timer.store.state.hasRecordFailed)
        #expect(timer.writes.value.isEmpty)
    }

    @Test
    func test_persist_failedWrite_showsFailureAndRetriesAtTheNextSync() async {
        let timer = TimerHarness(.fixture(.paused))
        let store = timer.store
        let record = WorkoutRunRecord(workoutID: timerWorkoutID, run: store.state.run)
        timer.recordFailures.setValue(1)

        await store.send(.view(.scenePhaseChanged(.background))) {
            $0.isInBackground = true
            $0.clockGeneration = 2
            $0.recordSync = .pending(revision: 1, record: record)
        }
        #expect(timer.assertions.value.count == 1)
        await store.receive(.internal(.recordWritten(revision: 1, succeeded: false))) {
            $0.recordSync = .failed(record)
            $0.hasRecordFailed = true
        }
        #expect(timer.releasedAssertions.value == timer.assertions.value)
        timer.expectedRecordRevision = 1

        await timer.send(.view(.scenePhaseChanged(.active)), saving: true) {
            $0.isInBackground = false
            $0.clockGeneration = 3
        }
        await store.finish()

        #expect(!store.state.hasRecordFailed)
        #expect(timer.writes.value == [RecordWrite(record: record, revision: 1), RecordWrite(record: record, revision: 2)])
        #expect(timer.releasedAssertions.value == timer.assertions.value)
    }

    @Test
    func test_persist_cancelledWrite_releasesTheAssertionWithoutReportingFailure() async {
        let timer = TimerHarness(.fixture(.paused))
        let record = WorkoutRunRecord(workoutID: timerWorkoutID, run: timer.store.state.run)
        timer.store.dependencies.workoutRunRecord.write = { _, _ in throw CancellationError() }

        await timer.store.send(.view(.scenePhaseChanged(.background))) {
            $0.isInBackground = true
            $0.clockGeneration = 2
            $0.recordSync = .pending(revision: 1, record: record)
        }
        await timer.store.finish()

        #expect(!timer.store.state.hasRecordFailed)
        #expect(timer.assertions.value.count == 1)
        #expect(timer.releasedAssertions.value == timer.assertions.value)
    }

    @Test
    func test_close_finishedRun_clearsAfterEndingTheSessionAndDismissing() async throws {
        let timer = TimerHarness(.fixture(.finished))
        let operations = LockIsolated<[String]>([])
        timer.store.dependencies.timerSession.end = { owner in
            operations.withValue { $0.append("end") }
            #expect(owner == timerID)
        }
        timer.store.dependencies.dismiss = DismissEffect { operations.withValue { $0.append("dismiss") } }
        let writes = timer.writes
        timer.store.dependencies.workoutRunRecord.write = { record, revision in
            writes.withValue { $0.append(RecordWrite(record: record, revision: revision)) }
            operations.withValue { $0.append("write-\(revision)") }
            #expect(record == nil)
        }

        await timer.send(.view(.closeButtonTapped), saving: true) {
            $0.clockGeneration = 2
            $0.isClosing = true
        }
        await timer.store.finish()

        let order = operations.value
        let ended = try #require(order.firstIndex(of: "end"))
        let dismissed = try #require(order.firstIndex(of: "dismiss"))
        let cleared = try #require(order.firstIndex(of: "write-2"))
        #expect(ended < dismissed)
        #expect(dismissed < cleared)
        #expect(timer.releasedAssertions.value.count == 2)
        #expect(Set(timer.releasedAssertions.value) == Set(timer.assertions.value))
    }
}
