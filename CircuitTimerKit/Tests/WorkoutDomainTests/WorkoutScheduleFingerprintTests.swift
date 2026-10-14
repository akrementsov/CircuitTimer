@testable import WorkoutDomain

import Foundation
import Testing

@Suite
struct WorkoutScheduleFingerprintTests {
    @Test
    func test_fingerprint_canonicalV1Schedule_matchesKnownSHA256() {
        // Independent SHA-256 of the documented v1 canonical string, including the manual pause.
        #expect(WorkoutSchedule(workout: makePausedWorkout()).fingerprint
            == "d34615e03122aabf03d7b8c5c39a60150c33b4ed71a622a0308ef9b17db3c4ca")
        #expect(WorkoutSchedule(workout: Workout(id: UUID(fixture: 1))).fingerprint
            == "673fa0a2c12cd3958d14ffb4a99be05dcf359297905365174b86e0b81f26108e")
    }

    @Test
    func test_fingerprint_renamedWorkoutAndStages_keepsIdentity() {
        let workout = makePausedWorkout()
        var renamed = workout
        renamed.name = "Renamed"
        renamed.warmUp[0].name = "Another name"
        renamed.training[0].name = ""
        #expect(WorkoutSchedule(workout: renamed).fingerprint == WorkoutSchedule(workout: workout).fingerprint)
    }

    @Test(arguments: ["duration", "kind", "id", "order", "rounds", "pause", "section"])
    func test_fingerprint_changedStructure_changesIdentity(change: String) {
        let workout = makePausedWorkout()
        var changed = workout
        switch change {
            case "duration": changed.training[0].duration = .seconds(11)
            case "kind": changed.training[0].intensity = .rest
            case "id": changed.training[0] = makeStage(99, .seconds(10))
            case "order": changed.warmUp.reverse()
            case "rounds": changed.trainingRounds = 2
            case "pause": changed.pauseAfterWarmUp = false
            default:
                changed.coolDown = changed.training
                changed.training = []
        }
        #expect(WorkoutSchedule(workout: changed).fingerprint != WorkoutSchedule(workout: workout).fingerprint)
    }

    @Test
    func test_fingerprint_nonPlayingStage_ignoresNormalizationInput() {
        let workout = makePausedWorkout()
        var changed = workout
        changed.training.append(makeStage(99, .zero))
        changed.training.append(makeStage(100, .microseconds(999)))
        #expect(WorkoutSchedule(workout: changed).fingerprint == WorkoutSchedule(workout: workout).fingerprint)
    }

    @Test
    func test_fingerprint_overLimitsAndFractionalDurations_hashesNormalizedSchedule() {
        let stages = (1...WorkoutLimits.maxStagesPerSection).map { makeStage($0, .seconds(6_000)) }
        let raw = Workout(
            id: UUID(fixture: 1),
            training: stages + [makeStage(99, .seconds(10))],
            trainingRounds: WorkoutLimits.maxTrainingRounds + 1
        )
        let normalized = Workout(
            id: raw.id,
            training: WorkoutLimits.normalizedStages(stages),
            trainingRounds: WorkoutLimits.maxTrainingRounds
        )
        #expect(WorkoutSchedule(workout: raw).fingerprint == WorkoutSchedule(workout: normalized).fingerprint)

        var fractional = makePausedWorkout()
        fractional.training[0].duration += .microseconds(999)
        #expect(WorkoutSchedule(workout: fractional).fingerprint == WorkoutSchedule(workout: makePausedWorkout()).fingerprint)
    }
}
