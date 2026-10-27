@testable import WorkoutStorage

import DependenciesTestSupport
import Foundation
import SwiftData
import Testing
import WorkoutDomain

// Migrated records take their copy identifiers from the store.
@Suite(.dependency(\.uuid, .incrementing))
struct WorkoutMigrationTests {
    @Test
    func test_open_v1StoreFile_migratesToV2KeepingWorkoutsAndStages() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: ProcessInfo.processInfo.globallyUniqueString,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { removeDirectory(directory) }
        let url = directory.appending(path: "Workouts.store")
        let first = Workout(
            id: UUID(fixture: 1),
            name: "First",
            warmUp: [makeStage(1, seconds: 60)],
            training: [makeStage(2), makeStage(3, seconds: 20, .rest)],
            trainingRounds: 3,
            coolDown: [makeStage(4, seconds: 90, .rest)],
            pauseAfterWarmUp: true
        )
        let second = makeWorkout(2)
        try await writeV1Store(at: url, workouts: [first, second])

        let container = try await openV2Store(at: url)
        let stored = try await WorkoutStore(modelContainer: container).fetchAll()

        #expect(stored == StoredWorkouts(workouts: [first, second]))
        #expect(try markerKeys(in: container) == ["sample-workout-v1"])
        let records = try storedRecords(in: ModelContext(container))
        #expect(records.allSatisfy { $0.copyID != nil && !$0.isFreshSample })
    }

    /// Writes the workouts as the app before CT-5 stored them, with the sample already seeded.
    @MainActor
    private func writeV1Store(at url: URL, workouts: [Workout]) throws {
        let schema = Schema(versionedSchema: WorkoutSchemaV1.self)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let context = ModelContext(container)
        context.insert(WorkoutSchemaV1.SeedMarkerModel(key: "sample-workout-v1"))
        for (order, workout) in workouts.enumerated() {
            let model = WorkoutSchemaV1.WorkoutModel(workoutID: workout.id)
            model.name = workout.name
            model.order = order
            model.trainingRounds = workout.trainingRounds
            model.pauseAfterWarmUp = workout.pauseAfterWarmUp
            model.pauseAfterTraining = workout.pauseAfterTraining
            context.insert(model)
            for section in WorkoutSectionKind.allCases {
                for (index, stage) in workout[section].enumerated() {
                    let stageModel = WorkoutSchemaV1.StageModel(stageID: stage.id)
                    stageModel.name = stage.name
                    stageModel.durationMs = Int(stage.duration.inMilliseconds)
                    stageModel.intensity = stage.intensity.storageToken
                    stageModel.section = section.storageToken
                    stageModel.order = index
                    context.insert(stageModel)
                    stageModel.workout = model
                }
            }
        }
        try context.save()
    }

    @MainActor
    private func openV2Store(at url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: WorkoutSchemaV2.self)
        return try ModelContainer(
            for: schema,
            migrationPlan: WorkoutMigrationPlan.self,
            configurations: ModelConfiguration(schema: schema, url: url)
        )
    }

    private func removeDirectory(_ directory: URL) {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Issue.record(error, "Failed to remove the temporary store")
        }
    }
}
