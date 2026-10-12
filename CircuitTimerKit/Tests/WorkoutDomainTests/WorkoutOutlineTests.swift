@testable import WorkoutDomain

import Foundation
import Testing

@Suite
struct WorkoutOutlineTests {
    @Test
    func test_init_fullWorkout_summarizesEachSectionOnce() {
        let schedule = WorkoutSchedule(workout: Workout(
            id: UUID(fixture: 900),
            warmUp: [makeStage(1, .seconds(30))],
            training: [makeStage(2, .seconds(45)), makeStage(3, .seconds(30), .rest)],
            trainingRounds: 3,
            coolDown: [makeStage(4, .seconds(20))],
            pauseAfterWarmUp: true
        ))

        let outline = WorkoutOutline(schedule: schedule)

        #expect(outline.sections.map(\.kind) == [.warmUp, .training, .coolDown])
        #expect(outline.sections.map { $0.stages.map(\.stageID) } == [
            [UUID(fixture: 1)],
            [UUID(fixture: 2), UUID(fixture: 3)],
            [UUID(fixture: 4)],
        ])
        #expect(outline.sections.map(\.roundCount) == [1, 3, 1])
        #expect(outline.sections.map(\.duration) == [.seconds(30), .seconds(225), .seconds(20)])
        #expect(outline.totalDuration == schedule.totalDuration)
    }

    @Test
    func test_init_sectionsThatPlayNothing_areLeftOut() {
        let workout = Workout(
            id: UUID(fixture: 900),
            warmUp: [makeStage(1, .seconds(10))],
            training: [makeStage(2, .seconds(10))],
            trainingRounds: 0,
            coolDown: [makeStage(3, .zero)]
        )

        let outline = WorkoutOutline(schedule: WorkoutSchedule(workout: workout))

        #expect(outline.sections.map(\.kind) == [.warmUp])
        #expect(outline.totalDuration == .seconds(10))
    }

    @Test
    func test_init_emptyWorkout_hasNoSections() {
        let outline = WorkoutOutline(schedule: WorkoutSchedule(workout: Workout(id: UUID(fixture: 900))))

        #expect(outline.sections.isEmpty)
        #expect(outline.totalDuration == .zero)
    }

    @Test(arguments: [
        // The warm-up's pause also plays over an empty training, before a cool-down that plays.
        (Workout(
            id: UUID(fixture: 900),
            warmUp: [makeStage(1, .seconds(10))],
            coolDown: [makeStage(2, .seconds(10))],
            pauseAfterWarmUp: true
        ), [true, false]),
        (Workout(
            id: UUID(fixture: 900),
            warmUp: [makeStage(1, .seconds(10))],
            coolDown: [makeStage(2, .seconds(10))]
        ), [false, false]),
        (Workout(
            id: UUID(fixture: 900),
            training: [makeStage(1, .seconds(10))],
            coolDown: [makeStage(2, .seconds(10))],
            pauseAfterTraining: true
        ), [true, false]),
    ])
    func test_isFollowedByPause_pauseFlags_markTheSectionsThePausesFollow(workout: Workout, expected: [Bool]) {
        let outline = WorkoutOutline(schedule: WorkoutSchedule(workout: workout))

        #expect(outline.sections.map(\.isFollowedByPause) == expected)
    }
}
