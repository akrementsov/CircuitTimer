@testable import WorkoutStorage

import Foundation
import SwiftData
import Testing
import WorkoutDomain

@Suite
struct WorkoutStoreSeedingTests {
    @Test
    func test_fetchAll_emptyStore_seedsSampleAndMarker() async throws {
        let container = try makeContainer()
        let store = WorkoutStore(modelContainer: container)

        let stored = try await store.fetchAll()

        #expect(stored == StoredWorkouts(workouts: [.sample]))
        #expect(try count(SeedMarkerModel.self, in: container) == 1)
    }

    @Test
    func test_fetchAll_repeatedAndFromNewStore_seedsOnce() async throws {
        let container = try makeContainer()
        let store = WorkoutStore(modelContainer: container)

        _ = try await store.fetchAll()
        _ = try await store.fetchAll()
        let fromNewStore = try await WorkoutStore(modelContainer: container).fetchAll()

        #expect(fromNewStore.workouts == [.sample])
        #expect(try count(WorkoutModel.self, in: container) == 1)
        #expect(try count(SeedMarkerModel.self, in: container) == 1)
    }

    @Test
    func test_fetchAll_sampleDeleted_doesNotSeedAgain() async throws {
        let container = try makeContainer()
        let store = WorkoutStore(modelContainer: container)
        _ = try await store.fetchAll()

        _ = try await store.delete(Workout.sample.id)

        #expect(try await store.fetchAll().workouts.isEmpty)
        #expect(try await WorkoutStore(modelContainer: container).fetchAll().workouts.isEmpty)
    }

    @Test
    func test_fetchAll_sampleIDStoredWithoutMarker_writesMarkerWithoutDuplicate() async throws {
        let container = try makeContainer()
        var mine = Workout.sample
        mine.name = "Mine"
        try insertRecord(mine, order: 0, in: container)

        let stored = try await WorkoutStore(modelContainer: container).fetchAll()

        #expect(stored.workouts.map(\.name) == ["Mine"])
        #expect(try count(SeedMarkerModel.self, in: container) == 1)
    }

    @Test
    func test_fetchAll_seedingFailsWithNothingToShow_throws() async throws {
        let emptyContainer = try makeContainer()
        let damagedContainer = try makeContainer()
        try insertRecord(makeWorkout(1), order: 0, in: damagedContainer) { $0.workoutID = nil }
        let saveSwitch = SaveSwitch()
        saveSwitch.fails = true

        for container in [emptyContainer, damagedContainer] {
            let store = WorkoutStore(modelContainer: container, saveContext: saveSwitch.save)
            await #expect(throws: SaveFailure.self) { try await store.fetchAll() }
        }
    }

    @Test
    func test_fetchAll_seedingFailsWithWorkoutsToShow_loadsThemAndRetriesSeeding() async throws {
        let container = try makeContainer()
        try insertRecord(makeWorkout(1), order: 0, in: container)
        let saveSwitch = SaveSwitch()
        saveSwitch.fails = true
        let store = WorkoutStore(modelContainer: container, saveContext: saveSwitch.save)

        let firstRead = try await store.fetchAll()
        saveSwitch.fails = false
        let secondRead = try await store.fetchAll()

        #expect(firstRead.workouts == [makeWorkout(1)])
        #expect(secondRead.workouts == [makeWorkout(1), .sample])
    }

    @Test
    func test_fetchAll_seedingFails_leavesNoSampleOrMarker() async throws {
        let container = try makeContainer()
        let saveSwitch = SaveSwitch()
        saveSwitch.fails = true
        let store = WorkoutStore(modelContainer: container, saveContext: saveSwitch.save)

        await #expect(throws: SaveFailure.self) { try await store.fetchAll() }

        #expect(try count(WorkoutModel.self, in: container) == 0)
        #expect(try count(SeedMarkerModel.self, in: container) == 0)
    }

    @Test
    func test_fetchAll_concurrentReadsOnFreshStore_seedsOnce() async throws {
        let container = try makeContainer()
        let store = WorkoutStore(modelContainer: container)

        try await withThrowingTaskGroup(of: StoredWorkouts.self) { group in
            for _ in 0..<5 {
                group.addTask { try await store.fetchAll() }
            }
            for try await stored in group {
                #expect(stored.workouts == [.sample])
            }
        }

        #expect(try count(WorkoutModel.self, in: container) == 1)
        #expect(try count(SeedMarkerModel.self, in: container) == 1)
    }

    @Test
    func test_sample_identifiers_matchPersistedConstants() throws {
        let sample = Workout.sample
        let stageIDs = WorkoutSectionKind.allCases.flatMap { sample[$0].map(\.id.uuidString) }

        #expect(sample.id.uuidString == "384B5AE9-D6A4-42AC-965A-7330AAB7DEBE")
        #expect(stageIDs == [
            "97591245-641D-4EE3-85F2-14E31BD1F34E",
            "E307355F-B704-4A69-8E30-6B6E9097E869",
            "37E3FAF1-E113-4AAD-B22C-96025AB1FB05",
            "C98DD565-57EA-4692-AFC9-117207FBE6D5",
            "7D34786F-6408-432B-BD21-61E4E54D4589",
            "8035AD73-BFD9-4C09-B345-C924DA0F486C",
            "8B58B69C-8993-43B1-BAB8-3F951C00AD6B",
        ])
    }
}
