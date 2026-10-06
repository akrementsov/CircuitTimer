@testable import WorkoutDomain

import Foundation
import Testing

@Suite
struct WorkoutLimitsTests {
    @Test(arguments: [
        (Duration.zero, nil),
        (.seconds(-1), nil),
        (.microseconds(999), nil),
        (.milliseconds(1), .milliseconds(1)),
        (.microseconds(1_900), .milliseconds(1)),
        (.seconds(5_999), .seconds(5_999)),
        (.seconds(6_000), .seconds(5_999)),
        (.seconds(Int64.max), .seconds(5_999)),
    ] as [(Duration, Duration?)])
    func test_normalizedStages_duration_isDroppedQuantizedOrClamped(input: Duration, expected: Duration?) {
        let normalized = WorkoutLimits.normalizedStages([makeStage(1, input)])

        #expect(normalized.map(\.duration) == (expected.map { [$0] } ?? []))
    }

    @Test
    func test_normalizedStages_validStage_isKeptUnchanged() {
        let stage = makeStage(1, .seconds(30), .rest)

        #expect(WorkoutLimits.normalizedStages([stage]) == [stage])
    }

    @Test
    func test_normalizedStages_subMillisecondStagesBeforeLimit_doNotTakeSlots() {
        let tooShort = (1...5).map { makeStage($0, .microseconds(500)) }
        let real = (6...56).map { makeStage($0, .seconds(1)) }

        let normalized = WorkoutLimits.normalizedStages(tooShort + real)

        #expect(normalized.map(\.id) == real.prefix(WorkoutLimits.maxStagesPerSection).map(\.id))
    }

    @Test(arguments: [
        (Int.min, 0),
        (-1, 0),
        (0, 0),
        (1, 1),
        (99, 99),
        (100, 99),
        (Int.max, 99),
    ])
    func test_normalizedTrainingRounds_isClampedToLimits(input: Int, expected: Int) {
        #expect(WorkoutLimits.normalizedTrainingRounds(input) == expected)
    }

    @Test
    func test_totalDuration_randomWorkouts_matchesScheduleAndScheduleIsContiguous() {
        var generator = SeededGenerator(seed: 0xC1C1)
        for iteration in 0..<500 {
            let workout = Workout.random(using: &generator, rounds: -5...200)
            let schedule = WorkoutSchedule(workout: workout)

            #expect(workout.totalDuration == schedule.totalDuration, "iteration \(iteration)")
            #expect(schedule.totalDuration == (schedule.stages.last?.end ?? .zero), "iteration \(iteration)")
            var expectedStart = Duration.zero
            for (index, stage) in schedule.stages.enumerated() {
                #expect(stage.index == index, "iteration \(iteration)")
                #expect(stage.start == expectedStart, "iteration \(iteration)")
                if stage.kind == .pause {
                    #expect(stage.duration == .zero, "iteration \(iteration)")
                } else {
                    #expect(stage.duration.isWholeMilliseconds, "iteration \(iteration)")
                    #expect(stage.duration >= .milliseconds(1), "iteration \(iteration)")
                    #expect(stage.duration <= WorkoutLimits.maxStageDuration, "iteration \(iteration)")
                }
                expectedStart = stage.end
            }
        }
    }
}
