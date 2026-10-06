@testable import WorkoutDomain

import Foundation
import Testing

@Suite
struct WorkoutScheduleTests {
    @Test
    func test_init_fullWorkout_buildsExpectedStagesAndSegments() {
        let workout = Workout(
            id: UUID(fixture: 0),
            warmUp: [makeStage(1, .seconds(20)), makeStage(2, .seconds(10), .rest)],
            training: [makeStage(3, .seconds(30)), makeStage(4, .seconds(15), .rest)],
            trainingRounds: 3,
            coolDown: [makeStage(5, .seconds(60), .rest)],
            pauseAfterWarmUp: true,
            pauseAfterTraining: true
        )

        let schedule = WorkoutSchedule(workout: workout)

        #expect(schedule.stages == [
            expected(0, stage: 1, .work, .warmUp, span: 0..<20),
            expected(1, stage: 2, .rest, .warmUp, span: 20..<30),
            expected(2, stage: nil, .pause, .warmUp, span: 30..<30),
            expected(3, stage: 3, .work, .training(1), span: 30..<60),
            expected(4, stage: 4, .rest, .training(1), span: 60..<75),
            expected(5, stage: 3, .work, .training(2), span: 75..<105),
            expected(6, stage: 4, .rest, .training(2), span: 105..<120),
            expected(7, stage: 3, .work, .training(3), span: 120..<150),
            expected(8, stage: 4, .rest, .training(3), span: 150..<165),
            expected(9, stage: nil, .pause, .training(3), span: 165..<165),
            expected(10, stage: 5, .rest, .coolDown, span: 165..<225),
        ])
        #expect(schedule.segments == [
            ScheduleSegment(section: .warmUp, round: 1, range: .seconds(0)..<(.seconds(30))),
            ScheduleSegment(section: .training, round: 1, range: .seconds(30)..<(.seconds(75))),
            ScheduleSegment(section: .training, round: 2, range: .seconds(75)..<(.seconds(120))),
            ScheduleSegment(section: .training, round: 3, range: .seconds(120)..<(.seconds(165))),
            ScheduleSegment(section: .coolDown, round: 1, range: .seconds(165)..<(.seconds(225))),
        ])
        #expect(schedule.totalDuration == .seconds(225))
    }

    @Test(arguments: PauseCase.all)
    func test_init_pauseFlags_keepPausesOnlyBetweenNonEmptyParts(_ pauseCase: PauseCase) {
        let schedule = WorkoutSchedule(workout: pauseCase.workout)

        let pauses = schedule.stages.filter { $0.kind == .pause }.map(\.section)
        #expect(pauses == pauseCase.expectedPausesAfter)
        #expect(schedule.stages.first?.kind != .pause)
        #expect(schedule.stages.last?.kind != .pause)
        for (current, next) in zip(schedule.stages, schedule.stages.dropFirst()) {
            #expect(!(current.kind == .pause && next.kind == .pause))
        }
        if pauseCase.expectedEmpty {
            #expect(schedule.stages.isEmpty)
            #expect(schedule.segments.isEmpty)
            #expect(schedule.totalDuration == .zero)
        }
    }

    @Test
    func test_nextAfter_stagesOfThisSchedule_returnFollowingStage() throws {
        let stages = WorkoutSchedule(workout: makePausedWorkout()).stages
        let schedule = WorkoutSchedule(workout: makePausedWorkout())

        #expect(schedule.next(after: stages[0]) == stages[1])
        #expect(schedule.next(after: stages[1])?.kind == .pause)
        #expect(schedule.next(after: stages[2]) == stages[3])
        #expect(schedule.next(after: try #require(stages.last)) == nil)
    }

    @Test
    func test_nextAfter_foreignOrInvalidStage_returnsNil() throws {
        let schedule = WorkoutSchedule(workout: makePausedWorkout())
        let other = WorkoutSchedule(workout: Workout(id: UUID(fixture: 1), warmUp: [makeStage(7, .seconds(3)), makeStage(8, .seconds(3))]))
        let first = try #require(schedule.stages.first)

        #expect(schedule.next(after: other.stages[0]) == nil)
        #expect(schedule.next(after: withIndex(first, -1)) == nil)
        #expect(schedule.next(after: withIndex(first, 99)) == nil)
        #expect(WorkoutSchedule(workout: Workout(id: UUID(fixture: 2))).next(after: first) == nil)
    }

    @Test(arguments: [
        (Duration.seconds(5), 0.0),
        (.seconds(10), 0.0),
        (.milliseconds(12_500), 0.25),
        (.seconds(15), 0.5),
        (.seconds(20), 1.0),
        (.seconds(25), 1.0),
        (.seconds(-5), 0.0),
        (.seconds(Int64.max), 1.0),
    ])
    func test_segmentProgress_isFractionClampedToUnitRange(elapsed: Duration, expected: Double) {
        let segment = ScheduleSegment(section: .training, round: 1, range: .seconds(10)..<(.seconds(20)))

        #expect(segment.progress(at: elapsed) == expected)
    }

    /// Where an expected stage sits: its section and round, with three training rounds.
    private struct Place {
        let section: WorkoutSectionKind
        let round: Int
        let roundCount: Int

        static let warmUp = Place(section: .warmUp, round: 1, roundCount: 1)
        static let coolDown = Place(section: .coolDown, round: 1, roundCount: 1)

        static func training(_ round: Int) -> Place {
            Place(section: .training, round: round, roundCount: 3)
        }
    }

    private func expected(
        _ index: Int,
        stage number: Int?,
        _ kind: ScheduledStage.Kind,
        _ place: Place,
        span seconds: Range<Int64>
    ) -> ScheduledStage {
        ScheduledStage(
            index: index,
            stageID: number.map { UUID(fixture: $0) },
            name: number.map { "Stage \($0)" },
            kind: kind,
            section: place.section,
            round: place.round,
            roundCount: place.roundCount,
            start: .seconds(seconds.lowerBound),
            duration: .seconds(seconds.upperBound - seconds.lowerBound)
        )
    }

    private func withIndex(_ stage: ScheduledStage, _ index: Int) -> ScheduledStage {
        ScheduledStage(
            index: index,
            stageID: stage.stageID,
            name: stage.name,
            kind: stage.kind,
            section: stage.section,
            round: stage.round,
            roundCount: stage.roundCount,
            start: stage.start,
            duration: stage.duration
        )
    }
}

struct PauseCase: Sendable, CustomStringConvertible {
    enum Part: Sendable {
        case warmUp
        case training
        case subMillisecondTraining
        case coolDown
    }

    let description: String
    let parts: Set<Part>
    let rounds: Int
    let flags: Bool
    let expectedPausesAfter: [WorkoutSectionKind]

    var expectedEmpty: Bool {
        parts.isEmpty
    }

    init(_ description: String, _ parts: Set<Part>, rounds: Int = 2, flags: Bool = true, pausesAfter: [WorkoutSectionKind]) {
        self.description = description
        self.parts = parts
        self.rounds = rounds
        self.flags = flags
        expectedPausesAfter = pausesAfter
    }

    var workout: Workout {
        Workout(
            id: UUID(fixture: 0),
            warmUp: parts.contains(.warmUp) ? [makeStage(1, .seconds(10))] : [],
            training: trainingStages,
            trainingRounds: rounds,
            coolDown: parts.contains(.coolDown) ? [makeStage(3, .seconds(10), .rest)] : [],
            pauseAfterWarmUp: flags,
            pauseAfterTraining: flags
        )
    }

    private var trainingStages: [Stage] {
        if parts.contains(.training) {
            return [makeStage(2, .seconds(10))]
        }
        if parts.contains(.subMillisecondTraining) {
            return [makeStage(2, .microseconds(400))]
        }
        return []
    }

    static let all: [PauseCase] = [
        PauseCase("all parts", [.warmUp, .training, .coolDown], pausesAfter: [.warmUp, .training]),
        PauseCase("flags off", [.warmUp, .training, .coolDown], flags: false, pausesAfter: []),
        PauseCase("no warm-up", [.training, .coolDown], pausesAfter: [.training]),
        PauseCase("warm-up only", [.warmUp], pausesAfter: []),
        PauseCase("no training", [.warmUp, .coolDown], pausesAfter: [.warmUp]),
        PauseCase("zero rounds", [.warmUp, .training, .coolDown], rounds: 0, pausesAfter: [.warmUp]),
        PauseCase("sub-millisecond training", [.warmUp, .subMillisecondTraining, .coolDown], rounds: 5, pausesAfter: [.warmUp]),
        PauseCase("no cool-down", [.warmUp, .training], pausesAfter: [.warmUp]),
        PauseCase("empty workout", [], pausesAfter: []),
    ]
}
