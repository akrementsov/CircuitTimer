/// A workout flattened into the order the timer plays it:
/// warm-up → [pause] → training × rounds → [pause] → cool-down.
///
/// Building never fails: input is normalized by `WorkoutLimits`, empty sections produce
/// nothing, and a manual pause is kept only between two non-empty parts.
public struct WorkoutSchedule: Hashable, Sendable {
    public let stages: [ScheduledStage]
    public let segments: [ScheduleSegment]
    public let totalDuration: Duration

    public init(workout: Workout) {
        let warmUp = WorkoutLimits.normalizedStages(workout.warmUp)
        let training = WorkoutLimits.normalizedStages(workout.training)
        let rounds = training.isEmpty ? 0 : WorkoutLimits.normalizedTrainingRounds(workout.trainingRounds)
        let coolDown = WorkoutLimits.normalizedStages(workout.coolDown)

        var builder = Builder()
        builder.appendRound(warmUp, section: .warmUp, round: 1, roundCount: 1)
        if workout.pauseAfterWarmUp, workout.canPauseAfterWarmUp {
            builder.appendPause(after: .warmUp, round: 1, roundCount: 1)
        }
        for round in stride(from: 1, through: rounds, by: 1) {
            builder.appendRound(training, section: .training, round: round, roundCount: rounds)
        }
        if workout.pauseAfterTraining, workout.canPauseAfterTraining {
            builder.appendPause(after: .training, round: rounds, roundCount: rounds)
        }
        builder.appendRound(coolDown, section: .coolDown, round: 1, roundCount: 1)

        stages = builder.stages
        segments = builder.segments
        totalDuration = builder.position
    }

    /// The stage after `stage`, or `nil` for the last one or a stage from another schedule.
    public func next(after stage: ScheduledStage) -> ScheduledStage? {
        guard stages.indices.contains(stage.index), stages[stage.index] == stage else { return nil }

        let index = stage.index + 1
        return stages.indices.contains(index) ? stages[index] : nil
    }
}

private struct Builder {
    private struct Placement {
        let section: WorkoutSectionKind
        let round: Int
        let roundCount: Int
    }

    var stages: [ScheduledStage] = []
    var segments: [ScheduleSegment] = []
    var position: Duration = .zero

    mutating func appendRound(_ sectionStages: [Stage], section: WorkoutSectionKind, round: Int, roundCount: Int) {
        guard !sectionStages.isEmpty else { return }

        let placement = Placement(section: section, round: round, roundCount: roundCount)
        let start = position
        for stage in sectionStages {
            append(stageID: stage.id, name: stage.name, kind: stage.intensity.scheduledKind, duration: stage.duration, at: placement)
        }
        segments.append(ScheduleSegment(section: section, round: round, range: start..<position))
    }

    mutating func appendPause(after section: WorkoutSectionKind, round: Int, roundCount: Int) {
        let placement = Placement(section: section, round: round, roundCount: roundCount)
        append(stageID: nil, name: nil, kind: .pause, duration: .zero, at: placement)
    }

    private mutating func append(
        stageID: Stage.ID?,
        name: String?,
        kind: ScheduledStage.Kind,
        duration: Duration,
        at placement: Placement
    ) {
        stages.append(
            ScheduledStage(
                index: stages.count,
                stageID: stageID,
                name: name,
                kind: kind,
                section: placement.section,
                round: placement.round,
                roundCount: placement.roundCount,
                start: position,
                duration: duration
            )
        )
        position += duration
    }
}

private extension Stage.Intensity {
    var scheduledKind: ScheduledStage.Kind {
        switch self {
            case .work:
                .work
            case .rest:
                .rest
        }
    }
}
