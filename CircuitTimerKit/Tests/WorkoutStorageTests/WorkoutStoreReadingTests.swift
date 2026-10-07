@testable import WorkoutStorage

import Foundation
import SwiftData
import Testing
import WorkoutDomain

@Suite
struct WorkoutStoreReadingTests {
    /// A way a stored record can be damaged, and the field that proves it was left as it is.
    struct Damage: CustomTestStringConvertible, Sendable {
        let testDescription: String
        let apply: @Sendable (WorkoutModel) -> Void
    }

    static let damages: [Damage] = [
        Damage(testDescription: "missing workout id") { $0.workoutID = nil },
        Damage(testDescription: "missing stage id") { $0.sortedStages[0].stageID = nil },
        Damage(testDescription: "repeated stage id") { $0.sortedStages[1].stageID = $0.sortedStages[0].stageID },
        Damage(testDescription: "unknown section token") { $0.sortedStages[0].section = "bogus" },
        Damage(testDescription: "unknown intensity token") { $0.sortedStages[0].intensity = "bogus" },
        Damage(testDescription: "zero-length stage") { $0.sortedStages[0].durationMs = 0 },
        Damage(testDescription: "stage over the limit") { $0.sortedStages[0].durationMs = 6_000_000 },
        Damage(testDescription: "negative rounds") { $0.trainingRounds = -1 },
        Damage(testDescription: "rounds over the limit") { $0.trainingRounds = WorkoutLimits.maxTrainingRounds + 1 },
    ]

    @Test
    func test_saveThenFetch_fullWorkout_readsBackEqual() async throws {
        let (store, _) = try makeEmptyStore()
        let workout = Workout(
            id: UUID(fixture: 1),
            name: "Full",
            warmUp: [makeStage(1, seconds: 60), makeStage(2, seconds: 30, .rest)],
            training: [Stage(id: UUID(fixture: 3), name: "Precise", duration: .milliseconds(1_500), intensity: .work)],
            trainingRounds: 4,
            coolDown: [makeStage(4, seconds: 90, .rest)],
            pauseAfterWarmUp: true,
            pauseAfterTraining: true
        )

        try await store.save(workout)

        #expect(try await store.fetchAll().workouts == [workout])
    }

    @Test
    func test_storageTokens_roundTripAndKeepLiterals() {
        let sections = Dictionary(uniqueKeysWithValues: WorkoutSectionKind.allCases.map { ($0.storageToken, $0) })
        let intensities = Dictionary(uniqueKeysWithValues: Stage.Intensity.allCases.map { ($0.storageToken, $0) })

        #expect(sections == ["warmUp": .warmUp, "training": .training, "coolDown": .coolDown])
        #expect(intensities == ["work": .work, "rest": .rest])
        #expect(WorkoutSectionKind.allCases.allSatisfy { WorkoutSectionKind(storageToken: $0.storageToken) == $0 })
        #expect(Stage.Intensity.allCases.allSatisfy { Stage.Intensity(storageToken: $0.storageToken) == $0 })
    }

    @Test
    func test_fetchAll_recordWithoutStagesOrTraining_isReadable() async throws {
        let (store, container) = try makeEmptyStore()
        try insertRecord(makeWorkout(1, training: []), order: 0, in: container) { $0.stages = nil }
        try insertRecord(Workout(id: UUID(fixture: 2), name: "No training", trainingRounds: 3), order: 1, in: container)

        let stored = try await store.fetchAll()

        #expect(stored.workouts.map(\.name) == ["Workout 1", "No training"])
        #expect(stored.workouts[1].trainingRounds == 3)
        #expect(stored.hiddenRecordCount == 0)
    }

    @Test(arguments: damages)
    func test_fetchAll_damagedRecord_isHiddenAndLeftAsStored(damage: Damage) async throws {
        let (store, container) = try makeEmptyStore()
        let workout = makeWorkout(1, training: [makeStage(1), makeStage(2)])
        try insertRecord(workout, order: 0, in: container, damage: damage.apply)
        let before = try snapshot(of: container)

        let stored = try await store.fetchAll()

        #expect(stored == StoredWorkouts(workouts: [], hiddenRecordCount: 1))
        #expect(try snapshot(of: container) == before)
    }

    @Test
    func test_fetchAll_tooManyStages_isHidden() async throws {
        let (store, container) = try makeEmptyStore()
        let stages = (1...WorkoutLimits.maxStagesPerSection).map { makeStage($0) }
        try insertRecord(makeWorkout(1, training: stages), order: 0, in: container) { model in
            let extra = StageModel(stageID: UUID(fixture: 999))
            extra.section = "training"
            extra.intensity = "work"
            extra.durationMs = 10_000
            extra.order = stages.count
            model.stages?.append(extra)
        }

        #expect(try await store.fetchAll() == StoredWorkouts(workouts: [], hiddenRecordCount: 1))
    }

    @Test
    func test_fetchAll_stageOrderAndTies_followStoredOrderDeterministically() async throws {
        let (store, container) = try makeEmptyStore()
        let workout = makeWorkout(1, training: [makeStage(1), makeStage(2), makeStage(3)])
        try insertRecord(workout, order: 0, in: container) { model in
            for stage in model.sortedStages {
                stage.order = stage.stageID == UUID(fixture: 1) ? 1 : 0
            }
        }
        try insertRecord(makeWorkout(2), order: 7, in: container)
        try insertRecord(makeWorkout(3), order: 7, in: container)

        let first = try await store.fetchAll()
        let second = try await store.fetchAll()

        #expect(first == second)
        #expect(first.workouts[0].training.last?.id == UUID(fixture: 1))
        #expect(first.workouts.map(\.name).first == "Workout 1")
    }

    @Test
    func test_fetchAll_copiesOfOneWorkout_showFirstReadable() async throws {
        let id = 1
        let damage: (WorkoutModel) -> Void = { $0.sortedStages[0].section = "bogus" }

        let bothReadable = try await readCopies(of: id, damagingFirst: false, damagingSecond: false, damage: damage)
        let firstDamaged = try await readCopies(of: id, damagingFirst: true, damagingSecond: false, damage: damage)
        let bothDamaged = try await readCopies(of: id, damagingFirst: true, damagingSecond: true, damage: damage)

        #expect(bothReadable.workouts.map(\.name) == ["First"])
        #expect(bothReadable.hiddenRecordCount == 1)
        #expect(firstDamaged.workouts.map(\.name) == ["Second"])
        #expect(firstDamaged.hiddenRecordCount == 1)
        #expect(bothDamaged == StoredWorkouts(workouts: [], hiddenRecordCount: 2))
    }

    private func readCopies(
        of number: Int,
        damagingFirst: Bool,
        damagingSecond: Bool,
        damage: @escaping (WorkoutModel) -> Void
    ) async throws -> StoredWorkouts {
        let (store, container) = try makeEmptyStore()
        try insertRecord(makeWorkout(number, name: "First"), order: 0, in: container) { if damagingFirst { damage($0) } }
        try insertRecord(makeWorkout(number, name: "Second"), order: 1, in: container) { if damagingSecond { damage($0) } }
        return try await store.fetchAll()
    }

    /// Every stored field of every record, to prove reading changed nothing.
    private func snapshot(of container: ModelContainer) throws -> [String] {
        try storedRecords(in: ModelContext(container)).map { model in
            let stages = model.sortedStages.map { "\($0.stageID?.uuidString ?? "nil")|\($0.section)|\($0.intensity)|\($0.durationMs)" }
            return "\(model.workoutID?.uuidString ?? "nil")|\(model.name)|\(model.trainingRounds)|\(stages)"
        }
    }
}

extension WorkoutModel {
    /// Stages in a stable order for setting up damage; the relationship itself keeps none.
    var sortedStages: [StageModel] {
        (stages ?? []).sorted { ($0.section, $0.order) < ($1.section, $1.order) }
    }
}
