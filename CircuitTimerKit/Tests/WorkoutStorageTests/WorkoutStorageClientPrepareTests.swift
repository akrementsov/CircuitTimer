@testable import WorkoutStorage

import Dependencies
import DependenciesTestSupport
import Foundation
import SwiftData
import Testing
import WorkoutDomain

// Stored records take their copy identifiers from the store.
@Suite(.dependency(\.uuid, .incrementing), .timeLimit(.minutes(1)))
struct WorkoutStorageClientPrepareTests {
    @Test
    func test_swiftData_eachOperation_waitsForPrepareBeforeTouchingTheStoreThatOpensOnce() async throws {
        let container = try await makeContainer()
        let opens = LockIsolated(0)
        let provider = WorkoutStoreProvider {
            opens.withValue { $0 += 1 }
            return container
        }
        let gate = PrepareGate()
        let client = WorkoutStorageClient.swiftData(provider: provider) { await gate.pass() }
        let stored: @Sendable () async throws -> [Workout.ID] = { try await provider.store().fetchAll().workouts.map(\.id) }

        let fetch = Task { try await client.fetchAll() }
        await gate.untilWaiting()
        #expect(opens.value == 0)
        gate.allowOne()
        let sample = try #require(try await fetch.value.workouts.first)
        #expect(opens.value == 1)

        let first = makeWorkout(1)
        let save = Task { try await client.save(first) }
        await gate.untilWaiting()
        #expect(try await stored() == [sample.id])
        gate.allowOne()
        #expect(try await save.value == .saved)
        #expect(try await stored() == [sample.id, first.id])

        let second = makeWorkout(2)
        let insert = Task { try await client.insert(second, sample.id) }
        await gate.untilWaiting()
        #expect(try await stored() == [sample.id, first.id])
        gate.allowOne()
        #expect(try await insert.value == .applied)
        #expect(try await stored() == [sample.id, second.id, first.id])

        let reorder = Task { try await client.reorder([first.id, second.id, sample.id]) }
        await gate.untilWaiting()
        #expect(try await stored() == [sample.id, second.id, first.id])
        gate.allowOne()
        #expect(try await reorder.value == .applied)
        #expect(try await stored() == [first.id, second.id, sample.id])

        let delete = Task { try await client.delete(second.id) }
        await gate.untilWaiting()
        #expect(try await stored() == [first.id, second.id, sample.id])
        gate.allowOne()
        #expect(try await delete.value == .applied)
        #expect(try await stored() == [first.id, sample.id])

        #expect(gate.passes == 5)
        #expect(opens.value == 1)
    }
}

/// `prepare`, held until the test lets each call through.
private final class PrepareGate: Sendable {
    private struct State {
        var waiting: [CheckedContinuation<Void, Never>] = []
        var passes = 0
    }

    private let state = LockIsolated(State())

    var passes: Int { state.value.passes }

    func pass() async {
        await withCheckedContinuation { continuation in
            state.withValue {
                $0.passes += 1
                $0.waiting.append(continuation)
            }
        }
    }

    /// Returns once a call waits on the gate.
    func untilWaiting() async {
        while state.value.waiting.isEmpty {
            await Task.yield()
        }
    }

    func allowOne() {
        let next = state.withValue { $0.waiting.removeFirst() }
        next.resume()
    }
}
