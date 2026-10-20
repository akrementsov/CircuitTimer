import ComposableArchitecture
import Foundation
import SnapshotCapture
import WorkoutDomain

enum SnapshotFixtures {
    static func workouts(language: SnapshotLanguage) -> IdentifiedArrayOf<Workout> {
        let longest = (0..<WorkoutLimits.maxStagesPerSection).map { index in
            Stage(id: UUID(100 + index), name: "", duration: WorkoutLimits.maxStageDuration, intensity: .work)
        }
        return [
            editorWorkout(language: language),
            Workout(
                id: UUID(2),
                name: language == .english
                    ? "A workout with a name far too long to fit on one line of the list"
                    : "Тренировка с очень длинным названием, которое не помещается в одну строку",
                training: [Stage(id: UUID(20), name: "", duration: .seconds(75), intensity: .work)]
            ),
            Workout(
                id: UUID(3),
                name: language == .english ? "Short" : "Короткая",
                training: [Stage(id: UUID(30), name: "", duration: .seconds(75), intensity: .work)]
            ),
            Workout(
                id: UUID(4),
                name: language == .english ? "Longest" : "Самая длинная",
                training: longest,
                trainingRounds: WorkoutLimits.maxTrainingRounds
            ),
        ]
    }

    static func editorWorkout(language: SnapshotLanguage) -> Workout {
        let english = language == .english
        return Workout(
            id: UUID(1),
            name: english ? "Morning HIIT" : "Утренний HIIT",
            warmUp: [
                Stage(id: UUID(10), name: english ? "Jumping jacks" : "Прыжки", duration: .seconds(60), intensity: .work),
                Stage(id: UUID(11), name: english ? "Arm circles" : "Вращения руками", duration: .seconds(30), intensity: .rest),
            ],
            training: [
                Stage(id: UUID(12), name: english ? "Burpees" : "Бёрпи", duration: .seconds(40), intensity: .work),
                Stage(id: UUID(13), name: "", duration: .seconds(20), intensity: .rest),
                Stage(id: UUID(14), name: english ? "Squats" : "Приседания", duration: .seconds(40), intensity: .work),
                Stage(id: UUID(15), name: english ? "Rest" : "Отдых", duration: .seconds(20), intensity: .rest),
            ],
            trainingRounds: 3,
            coolDown: [
                Stage(id: UUID(16), name: english ? "Stretching" : "Растяжка", duration: .seconds(120), intensity: .rest),
            ],
            pauseAfterWarmUp: true
        )
    }
}
