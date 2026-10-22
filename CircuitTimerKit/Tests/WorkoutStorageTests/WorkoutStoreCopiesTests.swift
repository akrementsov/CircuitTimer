@testable import WorkoutStorage

import Dependencies
import DependenciesTestSupport
import Foundation
import SwiftData
import Testing
import WorkoutDomain

// Stored records take their copy identifiers from the store.
@Suite(.dependency(\.uuid, .incrementing))
struct WorkoutStoreCopiesTests {
    /// Copies of one workout as devices write them, and the one that must show.
    struct RankCase: CustomTestStringConvertible, Sendable {
        let testDescription: String
        let copies: [Copy]
        let visible: String
    }

    struct Copy: Sendable {
        let name: String
        let copyID: Int
        let isFreshSample: Bool
    }

    static let rankCases: [RankCase] = [
        RankCase(
            testDescription: "lower copy id wins",
            copies: [Copy(name: "High", copyID: 20, isFreshSample: false), Copy(name: "Low", copyID: 10, isFreshSample: false)],
            visible: "Low"
        ),
        RankCase(
            testDescription: "edited copy beats fresh sample",
            copies: [Copy(name: "Fresh", copyID: 10, isFreshSample: true), Copy(name: "Edited", copyID: 20, isFreshSample: false)],
            visible: "Edited"
        ),
        RankCase(
            testDescription: "two fresh copies",
            copies: [Copy(name: "Fresh high", copyID: 20, isFreshSample: true), Copy(name: "Fresh low", copyID: 10, isFreshSample: true)],
            visible: "Fresh low"
        ),
    ]

    @Test(.dependency(\.uuid, .incrementing))
    func test_fetchAll_recordsWithoutCopyID_assignsThemFromDependencyAndReadsInOrder() async throws {
        let container = try await makeContainer()
        try insertSeedMarker(in: container)
        try insertRecord(makeWorkout(2), order: 0, in: container)
        try insertRecord(makeWorkout(1), order: 1, in: container)
        let store = WorkoutStore(modelContainer: container)

        let stored = try await store.fetchAll()

        #expect(stored == StoredWorkouts(workouts: [makeWorkout(2), makeWorkout(1)]))
        let copyIDs = try storedRecords(in: ModelContext(container)).map(\.copyID)
        #expect(Set(copyIDs) == [UUID(0), UUID(1)])
    }

    @Test(arguments: rankCases, [false, true])
    func test_fetchAll_copiesOfOneWorkout_showsLowestCopyRankWhateverStoredOrder(rankCase: RankCase, reversed: Bool) async throws {
        let (store, container) = try await makeEmptyStore()
        let copies = reversed ? rankCase.copies.reversed() : rankCase.copies
        for (order, copy) in copies.enumerated() {
            try insertRecord(makeWorkout(1, name: copy.name), order: order, in: container) { model in
                model.copyID = UUID(fixture: copy.copyID)
                model.isFreshSample = copy.isFreshSample
            }
        }

        let stored = try await store.fetchAll()

        #expect(stored.workouts.map(\.name) == [rankCase.visible])
        #expect(stored.hiddenRecordCount == 0)
        #expect(try count(WorkoutModel.self, in: container) == 2)
    }

    @Test
    func test_fetchAll_winnerStoredAfterLoserWithOthersBetween_showsWinnerAtItsPosition() async throws {
        let (store, container) = try await makeEmptyStore()
        try insertRecord(makeWorkout(1, name: "Loser"), order: 0, in: container) { $0.copyID = UUID(fixture: 20) }
        try insertRecord(makeWorkout(2, name: "B"), order: 1, in: container) { $0.copyID = UUID(fixture: 30) }
        try insertRecord(makeWorkout(3, name: "C"), order: 2, in: container) { $0.copyID = UUID(fixture: 31) }
        try insertRecord(makeWorkout(1, name: "Winner"), order: 3, in: container) { $0.copyID = UUID(fixture: 10) }

        let stored = try await store.fetchAll()

        #expect(stored == StoredWorkouts(workouts: [makeWorkout(2, name: "B"), makeWorkout(3, name: "C"), makeWorkout(1, name: "Winner")]))
    }

    @Test
    func test_fetchAll_lateCopiesOfDeletedWorkout_removesThemAndIgnoresMalformedMarker() async throws {
        let (store, container) = try await makeEmptyStore()
        _ = try await store.save(makeWorkout(1))
        _ = try await store.save(makeWorkout(2))
        _ = try await store.delete(UUID(fixture: 1))
        try insertRecord(makeWorkout(1, name: "Late"), order: 5, in: container)
        try insertRecord(makeWorkout(1, name: "Late damaged"), order: 6, in: container) { $0.sortedStages[0].section = "bogus" }
        try insertMarker("deleted:not-a-uuid", in: container)

        let stored = try await store.fetchAll()

        #expect(stored == StoredWorkouts(workouts: [makeWorkout(2)]))
        #expect(try storedNames(in: container) == ["Workout 2"])
    }

    @Test
    func test_fetchAll_removingDeletedCopyFails_readsAndRetriesOnNextRead() async throws {
        let saveSwitch = SaveSwitch()
        let (store, container) = try await makeEmptyStore(saveContext: saveSwitch.save)
        _ = try await store.save(makeWorkout(1))
        _ = try await store.save(makeWorkout(2))
        _ = try await store.delete(UUID(fixture: 1))
        // Its stages are never read before the removal, which a failed save must survive.
        try insertRecord(makeWorkout(1, name: "Late"), order: 5, in: container) { $0.copyID = UUID(fixture: 10) }
        saveSwitch.fails = true

        let failedRead = try await store.fetchAll()

        #expect(failedRead == StoredWorkouts(workouts: [makeWorkout(2)]))
        #expect(try storedNames(in: container) == ["Workout 2", "Late"])

        saveSwitch.fails = false
        let retriedRead = try await store.fetchAll()

        #expect(retriedRead == failedRead)
        #expect(try storedNames(in: container) == ["Workout 2"])
    }

    // Above every fixture identifier, so the copy that gets it still loses once it has one.
    @Test(.dependency(\.uuid, .constant(UUID(0xFFFF_FFFF_FFFF))))
    func test_fetchAll_assigningCopyIDFails_readsAndRetriesOnNextRead() async throws {
        let saveSwitch = SaveSwitch()
        let (store, container) = try await makeEmptyStore(saveContext: saveSwitch.save)
        // Stored first, so only its missing copy identifier makes it lose to the other copy.
        try insertRecord(makeWorkout(1, name: "Without"), order: 0, in: container)
        try insertRecord(makeWorkout(1, name: "With"), order: 1, in: container) { $0.copyID = UUID(fixture: 10) }
        saveSwitch.fails = true

        let failedRead = try await store.fetchAll()

        #expect(failedRead == StoredWorkouts(workouts: [makeWorkout(1, name: "With")]))
        #expect(try storedRecords(in: ModelContext(container)).map(\.copyID) == [nil, UUID(fixture: 10)])

        saveSwitch.fails = false
        let retriedRead = try await store.fetchAll()

        #expect(retriedRead == failedRead)
        #expect(try storedRecords(in: ModelContext(container)).map(\.copyID) == [UUID(0xFFFF_FFFF_FFFF), UUID(fixture: 10)])
    }
}
