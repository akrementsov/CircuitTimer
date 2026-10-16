@testable import WorkoutActivity

import Foundation
import Testing
import WorkoutDomain

@Suite
struct ContentStateTests {
    @Test
    func test_init_runningStage_carriesItsBoundariesAndTheNextStage() {
        var run = makeRun(makePausedWorkout())
        run.start(at: origin)

        let content = Content(run: run, at: moment(3))

        #expect(content.phase == .running(Attributes.Running(
            stage: .work(),
            stageStart: origin,
            stageEnd: moment(10),
            next: .stage(.rest(), end: moment(15))
        )))
    }

    @Test(arguments: [
        (makeOpenWorkout(), 20.0, Attributes.Next.finish),
        (makePausedWorkout(), 12.0, .manualPause),
    ])
    func test_init_runningStage_withoutATimedNextStage_namesWhatComes(workout: Workout, seconds: Double, expected: Attributes.Next) {
        var run = makeRun(workout)
        run.start(at: origin)

        guard case let .running(running) = Content(run: run, at: moment(seconds)).phase else {
            Issue.record("Expected a running phase")
            return
        }
        #expect(running.next == expected)
    }

    @Test
    func test_init_idleRun_getsReadyForTheFirstStageInFull() {
        let content = Content(run: makeRun(makePausedWorkout()), at: origin)

        #expect(content.phase == .getReady(first: Attributes.HeldStage(stage: .work(), remainingMilliseconds: 10_000)))
    }

    @Test
    func test_init_pausedRun_holdsWhatIsLeftOfTheStage() {
        var run = makeRun(makePausedWorkout())
        run.start(at: origin)
        run.pause(at: moment(3))

        #expect(Content(run: run, at: moment(30)).phase == .paused(Attributes.HeldStage(stage: .work(), remainingMilliseconds: 7_000)))
    }

    @Test
    func test_init_manualPause_awaitsTheUserWithTheNextStageInFull() {
        var run = makeRun(makePausedWorkout())
        run.start(at: origin)

        let content = Content(run: run, at: moment(16))

        #expect(content.phase == .awaitingUser(next: Attributes.HeldStage(stage: .work("Lunges"), remainingMilliseconds: 10_000)))
    }

    @Test(arguments: FinishedRun.allCases)
    func test_init_overRun_isFinished(run: FinishedRun) {
        #expect(Content(run: run.run(), at: moment(30)).phase == .finished)
    }

    @Test
    func test_init_stageNames_areCarriedAsStored() {
        var run = makeRun(makeOpenWorkout())
        run.start(at: origin)

        guard case let .running(running) = Content(run: run, at: moment(12)).phase else {
            Issue.record("Expected a running phase")
            return
        }
        #expect(running.stage == Attributes.Stage(kind: .rest, name: "  "))
        #expect(running.next == .stage(.work("Lunges"), end: moment(25)))
    }

    @Test
    func test_init_exactlyAtAStageBoundary_isAlreadyTheNextStage() {
        var run = makeRun(makePausedWorkout())
        run.start(at: origin)

        guard case let .running(running) = Content(run: run, at: moment(10)).phase else {
            Issue.record("Expected a running phase")
            return
        }
        #expect(running.stage == .rest())
        #expect(running.stageStart == moment(10))
    }

    @Test
    func test_staleDate_isTheStageEndOnlyWhileRunning() {
        var run = makeRun(makePausedWorkout())
        #expect(Content(run: run, at: origin).staleDate == nil)

        run.start(at: origin)
        #expect(Content(run: run, at: moment(3)).staleDate == moment(10))

        run.pause(at: moment(3))
        #expect(Content(run: run, at: moment(4)).staleDate == nil)
        #expect(Content.finished.staleDate == nil)

        var waiting = makeRun(makePausedWorkout())
        waiting.start(at: origin)
        #expect(Content(run: waiting, at: moment(16)).staleDate == nil)
    }

    @Test
    func test_encodedSize_longestRealisticNames_fitTheLimit() throws {
        let cyrillic = String(repeating: "Ж", count: WorkoutLimits.maxNameLength)
        let emoji = String(repeating: "👨‍👩‍👧‍👦", count: WorkoutLimits.maxNameLength)
        let content = Content(phase: .running(Attributes.Running(
            stage: .work(cyrillic),
            stageStart: origin,
            stageEnd: moment(10),
            next: .stage(.rest(cyrillic), end: moment(15))
        )))

        let size = try Attributes(workoutName: cyrillic).encodedSize(with: content)
        let emojiSize = try Attributes(workoutName: emoji).encodedSize(with: content)

        let encoder = JSONEncoder()
        #expect(size == (try encoder.encode(Attributes(workoutName: cyrillic)).count + encoder.encode(content).count))
        #expect(size <= Attributes.encodedSizeLimit)
        #expect(emojiSize <= Attributes.encodedSizeLimit)
    }
}

enum FinishedRun: CaseIterable, Sendable {
    case finished
    case pastTheEnd
    case emptySchedule

    func run() -> WorkoutRun {
        switch self {
            case .finished:
                var run = makeRun(makeOpenWorkout())
                run.start(at: origin)
                run.tick(at: moment(30))
                return run
            case .pastTheEnd:
                var run = makeRun(makeOpenWorkout())
                run.start(at: origin)
                return run
            case .emptySchedule:
                return makeRun(Workout(id: UUID(fixture: 902)))
        }
    }
}
