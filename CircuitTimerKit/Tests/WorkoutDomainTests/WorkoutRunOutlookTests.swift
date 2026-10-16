@testable import WorkoutDomain

import Foundation
import Testing

@Suite
struct WorkoutRunOutlookTests {
    /// Work 10 s, rest 5 s, work 10 s — no manual pause.
    private static func makeOpenWorkout() -> Workout {
        Workout(
            id: UUID(fixture: 901),
            warmUp: [makeStage(1, .seconds(10)), makeStage(2, .seconds(5), .rest), makeStage(3, .seconds(10))]
        )
    }

    @Test
    func test_outlook_runningStage_returnsWholeMillisecondBoundaries() throws {
        var run = makeRun(Self.makeOpenWorkout())
        run.start(at: origin)

        let outlook = try #require(run.outlook(at: moment(3)))

        #expect(outlook.stageStart == origin)
        #expect(outlook.stageEnd == moment(10))
        #expect(outlook.nextStageEnd == moment(15))
        for date in [outlook.stageStart, outlook.stageEnd, outlook.nextStageEnd].compactMap(\.self) {
            #expect(date == date.flooredToMilliseconds())
        }
    }

    @Test(arguments: [false, true])
    func test_outlook_pastStageEnd_describesTheStageReached(isTickedFirst: Bool) throws {
        var run = makeRun(Self.makeOpenWorkout())
        run.start(at: origin)
        if isTickedFirst {
            run.tick(at: moment(12))
        }

        let outlook = try #require(run.outlook(at: moment(12)))

        #expect(outlook == WorkoutRun.Outlook(stageStart: moment(10), stageEnd: moment(15), nextStageEnd: moment(25)))
    }

    @Test
    func test_outlook_afterReanchoringTick_staysEqual() throws {
        var run = makeRun(Self.makeOpenWorkout())
        run.start(at: origin)
        let before = try #require(run.outlook(at: moment(3)))

        run.tick(at: moment(4.25))

        #expect(run.outlook(at: moment(5.5)) == before)
    }

    @Test(arguments: OutlooklessRun.allCases)
    func test_outlook_notRunning_isNil(state: OutlooklessRun) {
        #expect(state.run().outlook(at: moment(100)) == nil)
    }

    @Test
    func test_outlook_nextStageIsManualPauseOrNone_hasNoNextStageEnd() throws {
        var paused = makeRun(makePausedWorkout())
        paused.start(at: origin)
        var open = makeRun(Self.makeOpenWorkout())
        open.start(at: origin)

        let beforePause = try #require(paused.outlook(at: moment(12)))
        let lastStage = try #require(open.outlook(at: moment(20)))

        #expect(beforePause.stageEnd == moment(15))
        #expect(beforePause.nextStageEnd == nil)
        #expect(lastStage.stageEnd == moment(25))
        #expect(lastStage.nextStageEnd == nil)
    }
}

enum OutlooklessRun: CaseIterable, Sendable {
    case idle
    case paused
    case awaitingUser
    case finished

    func run() -> WorkoutRun {
        var run = makeRun(makePausedWorkout())
        switch self {
            case .idle:
                break
            case .paused:
                run.start(at: origin)
                run.pause(at: moment(3))
            case .awaitingUser:
                run.start(at: origin)
                run.tick(at: moment(16))
            case .finished:
                run.start(at: origin)
                run.tick(at: moment(16))
                run.resume(at: moment(20))
                run.tick(at: moment(40))
        }
        return run
    }
}
