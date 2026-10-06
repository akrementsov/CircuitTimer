@testable import WorkoutStorage

import Foundation
import SwiftData
import Testing
import WorkoutDomain

@Suite
struct WorkoutStoreWritingTests {
    private let bogusSection: (WorkoutModel) -> Void = { $0.sortedStages[0].section = "bogus" }

    @Test
    func test_save_newWorkout_appendsAfterLastOrderKeepingOthers() async throws {
        let (store, container) = try makeEmptyStore()
        try insertRecord(makeWorkout(1), order: 5, in: container)
        try insertRecord(makeWorkout(2), order: 7, in: container)

        try await store.save(makeWorkout(3))

        let records = try storedRecords(in: ModelContext(container))
        #expect(records.map(\.name) == ["Workout 1", "Workout 2", "Workout 3"])
        #expect(records.map(\.order) == [5, 7, 8])
    }

    @Test
    func test_save_emptyStore_startsOrderAtZero() async throws {
        let (store, container) = try makeEmptyStore()

        try await store.save(makeWorkout(1))

        #expect(try storedRecords(in: ModelContext(container)).map(\.order) == [0])
    }

    @Test
    func test_save_lastOrderAtMaximum_renumbersBeforeAppending() async throws {
        let (store, container) = try makeEmptyStore()
        try insertRecord(makeWorkout(1), order: .max, in: container)
        try insertRecord(makeWorkout(2), order: 3, in: container)

        try await store.save(makeWorkout(3))

        let records = try storedRecords(in: ModelContext(container))
        #expect(records.map(\.name) == ["Workout 2", "Workout 1", "Workout 3"])
        #expect(records.map(\.order) == [0, 1, 2])
    }

    @Test
    func test_save_existingWorkout_updatesStagesInPlace() async throws {
        let (store, container) = try makeEmptyStore()
        let original = Workout(
            id: UUID(fixture: 1),
            name: "Before",
            warmUp: [makeStage(1)],
            training: [makeStage(2), makeStage(3)]
        )
        try await store.save(original)
        let keptStageID = try stageModelID(UUID(fixture: 1), in: container)
        var edited = original
        edited.name = "After"
        edited.trainingRounds = 3
        edited.pauseAfterWarmUp = true
        edited.warmUp[0].name = "Renamed"
        edited.training = [makeStage(4)]
        edited.coolDown = [makeStage(3, .rest)]

        try await store.save(edited)

        #expect(try await store.fetchAll().workouts == [edited])
        #expect(try count(WorkoutModel.self, in: container) == 1)
        #expect(try count(StageModel.self, in: container) == 3)
        #expect(try stageModelID(UUID(fixture: 1), in: container) == keptStageID)
    }

    @Test
    func test_save_unnormalizedWorkout_storesNormalizedCopy() async throws {
        let (store, _) = try makeEmptyStore()
        let tooMany = (1...(WorkoutLimits.maxStagesPerSection + 1)).map { makeStage($0) }
        var workout = makeWorkout(1, training: [makeStage(900, seconds: 0)] + tooMany)
        workout.trainingRounds = WorkoutLimits.maxTrainingRounds + 50

        try await store.save(workout)

        let stored = try #require(try await store.fetchAll().workouts.first)
        #expect(stored.training == Array(tooMany.prefix(WorkoutLimits.maxStagesPerSection)))
        #expect(stored.trainingRounds == WorkoutLimits.maxTrainingRounds)
    }

    @Test
    func test_update_unchangedWorkout_leavesContextUnchanged() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let workout = makeWorkout(1, training: [makeStage(1), makeStage(2)])
        let model = WorkoutModel(workoutID: workout.id)
        context.insert(model)
        model.update(from: workout, in: context)
        try context.save()

        model.update(from: workout, in: context)
        #expect(!context.hasChanges)

        var renamed = workout
        renamed.name = "Renamed"
        model.update(from: renamed, in: context)
        #expect(model.hasChanges)
        #expect((model.stages ?? []).allSatisfy { !$0.hasChanges })
    }

    @Test
    func test_save_workoutWithHiddenCopy_editsVisibleRecordOnly() async throws {
        let (store, container) = try makeEmptyStore()
        let shared = makeStage(1)
        try insertRecord(makeWorkout(1, name: "Visible", training: [shared]), order: 0, in: container)
        try insertRecord(makeWorkout(1, name: "Copy", training: [shared]), order: 1, in: container)
        try insertRecord(makeWorkout(2, name: "Other", training: [shared]), order: 2, in: container)
        var edited = makeWorkout(1, name: "Edited", training: [shared])
        edited.training[0].name = "Renamed"

        try await store.save(edited)

        let records = try storedRecords(in: ModelContext(container))
        #expect(records.map(\.name) == ["Edited", "Copy", "Other"])
        #expect(records.map { $0.sortedStages[0].name } == ["Renamed", "Stage 1", "Stage 1"])
    }

    @Test
    func test_save_idWithOnlyDamagedRecord_appendsNewRecordAndKeepsDamaged() async throws {
        let (store, container) = try makeEmptyStore()
        try insertRecord(makeWorkout(1, name: "Damaged"), order: 0, in: container, damage: bogusSection)

        try await store.save(makeWorkout(1, name: "Fresh"))

        let stored = try await store.fetchAll()
        #expect(stored.workouts.map(\.name) == ["Fresh"])
        #expect(stored.hiddenRecordCount == 1)
        #expect(try storedRecords(in: ModelContext(container)).first?.sortedStages.first?.section == "bogus")
    }

    @Test
    func test_saveAndInsert_repeatedStageIDs_rejectWithoutWriting() async throws {
        let (store, container) = try makeEmptyStore()
        try await store.save(makeWorkout(1))
        let sameSection = makeWorkout(2, training: [makeStage(5), makeStage(5)])
        let acrossSections = Workout(id: UUID(fixture: 3), warmUp: [makeStage(6)], training: [makeStage(6)])

        for workout in [sameSection, acrossSections] {
            await #expect(throws: WorkoutStoreError.repeatedStageIDs) { try await store.save(workout) }
            await #expect(throws: WorkoutStoreError.repeatedStageIDs) {
                _ = try await store.insert(workout, after: UUID(fixture: 1))
            }
        }

        #expect(try storedNames(in: container) == ["Workout 1"])
    }

    @Test
    func test_insert_afterVisibleAnchor_placesNewRightAfterAnchorAndItsCopies() async throws {
        struct InsertCase {
            let layout: [(Int, String)]
            let anchor: Int
            let expected: [String]
        }
        let cases = [
            InsertCase(layout: [(1, "A"), (2, "B"), (3, "C")], anchor: 1, expected: ["A", "New", "B", "C"]),
            InsertCase(layout: [(1, "A"), (2, "B"), (3, "C"), (1, "A copy")], anchor: 1, expected: ["A", "A copy", "New", "B", "C"]),
            InsertCase(layout: [(1, "A"), (2, "B")], anchor: 2, expected: ["A", "B", "New"]),
            InsertCase(layout: [(3, "C"), (1, "A"), (3, "C copy"), (2, "B")], anchor: 1, expected: ["C", "A", "New", "C copy", "B"]),
        ]

        for insertCase in cases {
            let (store, container) = try makeEmptyStore()
            for (order, (number, name)) in insertCase.layout.enumerated() {
                try insertRecord(makeWorkout(number, name: name), order: order, in: container)
            }

            let outcome = try await store.insert(makeWorkout(9, name: "New"), after: UUID(fixture: insertCase.anchor))

            #expect(outcome == .applied)
            let records = try storedRecords(in: ModelContext(container))
            #expect(records.map(\.name) == insertCase.expected)
            #expect(records.map(\.order) == Array(0..<insertCase.expected.count))
        }
    }

    @Test
    func test_insert_withoutVisibleAnchor_appendsAndReportsDivergence() async throws {
        let (store, container) = try makeEmptyStore()
        try insertRecord(makeWorkout(1, name: "A"), order: 0, in: container)
        try insertRecord(makeWorkout(2, name: "Damaged"), order: 1, in: container, damage: bogusSection)

        let missingAnchor = try await store.insert(makeWorkout(8, name: "First"), after: UUID(fixture: 99))
        let hiddenAnchor = try await store.insert(makeWorkout(9, name: "Second"), after: UUID(fixture: 2))

        #expect(missingAnchor == .storeDiverged)
        #expect(hiddenAnchor == .storeDiverged)
        #expect(try storedNames(in: container) == ["A", "Damaged", "First", "Second"])
    }

    @Test
    func test_delete_visibleWorkoutWithoutCopies_removesItAndItsStages() async throws {
        let (store, container) = try makeEmptyStore()
        try await store.save(makeWorkout(1, training: [makeStage(1), makeStage(2)]))
        try await store.save(makeWorkout(2))

        let outcome = try await store.delete(UUID(fixture: 1))

        #expect(outcome == .applied)
        #expect(try await store.fetchAll().workouts.map(\.name) == ["Workout 2"])
        #expect(try count(StageModel.self, in: container) == 1)
    }

    @Test
    func test_delete_notVisible_changesNothingAndReportsDivergence() async throws {
        let (store, container) = try makeEmptyStore()
        try insertRecord(makeWorkout(1, name: "Damaged"), order: 0, in: container, damage: bogusSection)

        #expect(try await store.delete(UUID(fixture: 99)) == .storeDiverged)
        #expect(try await store.delete(UUID(fixture: 1)) == .storeDiverged)
        #expect(try storedNames(in: container) == ["Damaged"])
    }

    @Test
    func test_delete_visibleWorkoutWithCopy_deletesVisibleOnlyAndReportsDivergence() async throws {
        let (store, container) = try makeEmptyStore()
        try insertRecord(makeWorkout(1, name: "Visible"), order: 0, in: container)
        try insertRecord(makeWorkout(1, name: "Copy"), order: 1, in: container)

        let outcome = try await store.delete(UUID(fixture: 1))

        #expect(outcome == .storeDiverged)
        #expect(try await store.fetchAll().workouts.map(\.name) == ["Copy"])
    }

    @Test
    func test_reorder_exactVisibleSet_keepsCopiesWithTheirWorkoutAndOthersAfter() async throws {
        let (store, container) = try makeEmptyStore()
        try insertRecord(makeWorkout(1, name: "A"), order: 0, in: container)
        try insertRecord(makeWorkout(4, name: "Damaged"), order: 1, in: container, damage: bogusSection)
        try insertRecord(makeWorkout(2, name: "B"), order: 2, in: container)
        try insertRecord(makeWorkout(1, name: "A copy"), order: 3, in: container)
        try insertRecord(makeWorkout(3, name: "C"), order: 4, in: container)

        let outcome = try await store.reorder([UUID(fixture: 3), UUID(fixture: 1), UUID(fixture: 2)])

        #expect(outcome == .applied)
        #expect(try storedNames(in: container) == ["C", "A", "A copy", "B", "Damaged"])
        #expect(try storedRecords(in: ModelContext(container)).last?.sortedStages.first?.section == "bogus")
    }

    @Test
    func test_reorder_setMismatch_reportsDivergence() async throws {
        struct ReorderCase {
            let ids: [UUID]
            let expected: WorkoutWriteOutcome
        }
        let idA = UUID(fixture: 1)
        let idB = UUID(fixture: 2)
        let cases = [
            ReorderCase(ids: [idB, idA, idA], expected: .applied),
            ReorderCase(ids: [idB], expected: .storeDiverged),
            ReorderCase(ids: [idB, idA, UUID(fixture: 99)], expected: .storeDiverged),
        ]

        for reorderCase in cases {
            let (store, container) = try makeEmptyStore()
            try insertRecord(makeWorkout(1, name: "A"), order: 0, in: container)
            try insertRecord(makeWorkout(2, name: "B"), order: 1, in: container)

            #expect(try await store.reorder(reorderCase.ids) == reorderCase.expected)
            #expect(try storedNames(in: container) == ["B", "A"])
        }

        let (emptyStore, _) = try makeEmptyStore()
        #expect(try await emptyStore.reorder([]) == .applied)
    }

    @Test
    func test_insert_withDamagedRecord_changesOnlyItsOrder() async throws {
        let (store, container) = try makeEmptyStore()
        try insertRecord(makeWorkout(1, name: "A"), order: 0, in: container)
        try insertRecord(makeWorkout(2, name: "Damaged"), order: 1, in: container, damage: bogusSection)

        _ = try await store.insert(makeWorkout(3, name: "New"), after: UUID(fixture: 1))

        let damaged = try #require(try storedRecords(in: ModelContext(container)).last)
        #expect(damaged.name == "Damaged")
        #expect(damaged.order == 2)
        #expect(damaged.sortedStages.map(\.section) == ["bogus"])
    }

    enum Operation: String, CaseIterable, Sendable {
        case saveNew, saveExisting, insert, delete, reorder
    }

    @Test(arguments: Operation.allCases)
    func test_write_saveFails_rollsBackToPreviousState(operation: Operation) async throws {
        let saveSwitch = SaveSwitch()
        let (store, container) = try makeEmptyStore(saveContext: saveSwitch.save)
        try await store.save(makeWorkout(1, name: "A"))
        try await store.save(makeWorkout(2, name: "B"))
        let before = try await store.fetchAll()
        saveSwitch.fails = true

        await #expect(throws: SaveFailure.self) {
            switch operation {
                case .saveNew: try await store.save(makeWorkout(3))
                case .saveExisting: try await store.save(makeWorkout(1, name: "Renamed"))
                case .insert: _ = try await store.insert(makeWorkout(3), after: UUID(fixture: 1))
                case .delete: _ = try await store.delete(UUID(fixture: 1))
                case .reorder: _ = try await store.reorder([UUID(fixture: 2), UUID(fixture: 1)])
            }
        }

        saveSwitch.fails = false
        #expect(try await store.fetchAll() == before)
        #expect(try storedNames(in: container) == ["A", "B"])
    }

    private func stageModelID(_ stageID: UUID, in container: ModelContainer) throws -> PersistentIdentifier? {
        let id: UUID? = stageID
        return try ModelContext(container).fetch(FetchDescriptor<StageModel>(predicate: #Predicate { $0.stageID == id })).first?
            .persistentModelID
    }
}
