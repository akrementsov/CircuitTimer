@testable import AppScenarios

import Dependencies
import Foundation
import Testing
import WorkoutDomain
import WorkoutStorage

#if DEBUG
struct ScenarioStorageTests {
    @Test
    func test_fetchAll_givenWorkouts_keepsTheirOrder() async throws {
        let workouts = [makeWorkout(3), makeWorkout(1), makeWorkout(2)]

        let stored = try await WorkoutStorageClient.scenario(workouts).fetchAll()

        #expect(stored == StoredWorkouts(workouts: workouts))
    }

    @Test
    func test_save_existingID_replacesInPlace() async throws {
        let storage = WorkoutStorageClient.scenario([makeWorkout(1), makeWorkout(2), makeWorkout(3)])
        let renamed = makeWorkout(2, name: "Renamed")

        try await storage.save(renamed)

        #expect(try await storage.fetchAll().workouts == [makeWorkout(1), renamed, makeWorkout(3)])
    }

    @Test
    func test_save_newID_appends() async throws {
        let storage = WorkoutStorageClient.scenario([makeWorkout(1)])

        try await storage.save(makeWorkout(2))

        #expect(try await storage.fetchAll().workouts == [makeWorkout(1), makeWorkout(2)])
    }

    @Test
    func test_save_emptyList_storesFirstWorkout() async throws {
        let storage = WorkoutStorageClient.scenario([])

        try await storage.save(makeWorkout(1))

        #expect(try await storage.fetchAll().workouts == [makeWorkout(1)])
    }

    @Test
    func test_save_oneStorage_leavesAnotherUnchanged() async throws {
        let one = WorkoutStorageClient.scenario([makeWorkout(1)])
        let another = WorkoutStorageClient.scenario([makeWorkout(1)])

        try await one.save(makeWorkout(2))

        #expect(try await another.fetchAll().workouts == [makeWorkout(1)])
    }

    @Test
    func test_save_concurrentNewWorkouts_keepsEveryOne() async throws {
        let storage = WorkoutStorageClient.scenario([])
        let workouts = (1...100).map { makeWorkout($0) }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for workout in workouts {
                group.addTask { try await storage.save(workout) }
            }
            try await group.waitForAll()
        }

        let stored = try await storage.fetchAll().workouts
        #expect(stored.count == workouts.count)
        #expect(Set(stored) == Set(workouts))
    }

    @Test
    func test_save_concurrentVersionsOfOneWorkout_keepsOne() async throws {
        let storage = WorkoutStorageClient.scenario([])
        let versions = (1...100).map { makeWorkout(1, name: "Version \($0)") }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for version in versions {
                group.addTask { try await storage.save(version) }
            }
            try await group.waitForAll()
        }

        let stored = try await storage.fetchAll().workouts
        #expect(stored.count == 1)
        #expect(stored.allSatisfy(versions.contains))
    }

    private func makeWorkout(_ number: Int, name: String? = nil) -> Workout {
        Workout(
            id: UUID(number),
            name: name ?? "Workout \(number)",
            training: [Stage(id: UUID(1_000 + number), name: "", duration: .seconds(30), intensity: .work)]
        )
    }
}
#endif
