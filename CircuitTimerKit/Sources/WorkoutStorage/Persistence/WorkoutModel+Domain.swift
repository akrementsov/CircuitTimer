import Foundation
import SwiftData
import WorkoutDomain

/// Why a stored workout cannot be shown without losing or changing data.
enum UnreadableWorkoutRecord: Error, Equatable {
    case missingWorkoutID
    case missingStageID
    case duplicateStageID(UUID)
    case unknownSectionToken(String)
    case unknownIntensityToken(String)
    case stagesOutsideLimits(WorkoutSectionKind)
    case roundsOutsideLimits(Int)
}

extension WorkoutModel {
    /// Reads the workout exactly as stored.
    ///
    /// Reading never normalizes: a record that normalization would change is reported as unreadable
    /// instead, so no stored stage disappears silently and the next save cannot delete it. The app
    /// always writes normalized data, so this only catches corruption and records from newer versions.
    func toDomain() throws(UnreadableWorkoutRecord) -> Workout {
        guard let workoutID else { throw .missingWorkoutID }

        var sections: [WorkoutSectionKind: [Stage]] = [:]
        var stageIDs: Set<UUID> = []
        // The relationship keeps no order; `persistentModelID` breaks ties between equal `order` values.
        let models = (stages ?? []).sorted { ($0.order, $0.persistentModelID) < ($1.order, $1.persistentModelID) }
        for model in models {
            guard let stageID = model.stageID else { throw .missingStageID }
            guard stageIDs.insert(stageID).inserted else { throw .duplicateStageID(stageID) }
            guard let section = WorkoutSectionKind(storageToken: model.section) else {
                throw .unknownSectionToken(model.section)
            }
            guard let intensity = Stage.Intensity(storageToken: model.intensity) else {
                throw .unknownIntensityToken(model.intensity)
            }
            let stage = Stage(id: stageID, name: model.name, duration: .milliseconds(model.durationMs), intensity: intensity)
            sections[section, default: []].append(stage)
        }

        for (section, sectionStages) in sections where WorkoutLimits.normalizedStages(sectionStages) != sectionStages {
            throw .stagesOutsideLimits(section)
        }
        guard WorkoutLimits.normalizedTrainingRounds(trainingRounds) == trainingRounds else {
            throw .roundsOutsideLimits(trainingRounds)
        }

        return Workout(
            id: workoutID,
            name: name,
            warmUp: sections[.warmUp] ?? [],
            training: sections[.training] ?? [],
            trainingRounds: trainingRounds,
            coolDown: sections[.coolDown] ?? [],
            pauseAfterWarmUp: pauseAfterWarmUp,
            pauseAfterTraining: pauseAfterTraining
        )
    }

    /// Writes a normalized copy of `workout`.
    ///
    /// Stages are matched by identifier within this workout only and updated in place, which keeps
    /// sync conflicts small in CT-5. Stages that are gone are deleted explicitly: removing them from
    /// the relationship alone is not guaranteed to delete them.
    func update(from workout: Workout, in context: ModelContext) {
        assign(workout.name, to: \.name)
        assign(WorkoutLimits.normalizedTrainingRounds(workout.trainingRounds), to: \.trainingRounds)
        assign(workout.pauseAfterWarmUp, to: \.pauseAfterWarmUp)
        assign(workout.pauseAfterTraining, to: \.pauseAfterTraining)

        let current = stages ?? []
        var reusable = Dictionary(
            current.compactMap { model in model.stageID.map { ($0, model) } },
            uniquingKeysWith: { first, _ in first }
        )
        var kept: [StageModel] = []
        for section in WorkoutSectionKind.allCases {
            for (index, stage) in WorkoutLimits.normalizedStages(workout[section]).enumerated() {
                let model = reusable.removeValue(forKey: stage.id) ?? makeStage(id: stage.id, in: context)
                model.assign(section.storageToken, to: \.section)
                model.assign(index, to: \.order)
                model.assign(stage.name, to: \.name)
                model.assign(Int(stage.duration.inMilliseconds), to: \.durationMs)
                model.assign(stage.intensity.storageToken, to: \.intensity)
                kept.append(model)
            }
        }

        let keptIDs = Set(kept.map(ObjectIdentifier.init))
        for model in current where !keptIDs.contains(ObjectIdentifier(model)) {
            context.delete(model)
        }
        // The relationship keeps no order, so only a different set of stages is a change.
        if Set(current.map(ObjectIdentifier.init)) != Set(kept.map(ObjectIdentifier.init)) {
            stages = kept
        }
    }

    private func makeStage(id: UUID, in context: ModelContext) -> StageModel {
        let model = StageModel(stageID: id)
        context.insert(model)
        return model
    }
}
