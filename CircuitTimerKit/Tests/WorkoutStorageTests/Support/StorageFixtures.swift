@testable import WorkoutStorage

import Foundation
import SwiftData
import WorkoutDomain

/// The schema and migration plan the app uses, kept in memory.
func makeContainer() throws -> ModelContainer {
    try .workouts(isStoredInMemoryOnly: true)
}

extension UUID {
    /// Deterministic identifiers for fixtures.
    init(fixture number: Int) {
        let high = UInt8(truncatingIfNeeded: number >> 8)
        let low = UInt8(truncatingIfNeeded: number)
        self.init(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, high, low))
    }
}

func makeStage(_ number: Int, seconds: Int = 10, _ intensity: Stage.Intensity = .work) -> Stage {
    Stage(id: UUID(fixture: number), name: "Stage \(number)", duration: .seconds(seconds), intensity: intensity)
}

func makeWorkout(_ number: Int, name: String? = nil, training: [Stage]? = nil) -> Workout {
    Workout(id: UUID(fixture: number), name: name ?? "Workout \(number)", training: training ?? [makeStage(number * 100)])
}

/// Writes a record the way another writer would, outside `WorkoutStore`, so tests can set up
/// copies and damaged records the store never produces itself.
func insertRecord(
    _ workout: Workout,
    order: Int,
    in container: ModelContainer,
    damage: (WorkoutModel) -> Void = { _ in }
) throws {
    let context = ModelContext(container)
    let model = WorkoutModel(workoutID: workout.id)
    context.insert(model)
    model.update(from: workout, in: context)
    model.order = order
    damage(model)
    try context.save()
}

/// Marks the sample as already seeded, so a test starts from an empty list.
func insertSeedMarker(in container: ModelContainer) throws {
    let context = ModelContext(container)
    context.insert(SeedMarkerModel(key: "sample-workout-v1"))
    try context.save()
}

/// A store over an empty list: the sample counts as seeded.
func makeEmptyStore(saveContext: (@Sendable (ModelContext) throws -> Void)? = nil) throws -> (WorkoutStore, ModelContainer) {
    let container = try makeContainer()
    try insertSeedMarker(in: container)
    let store = saveContext.map { WorkoutStore(modelContainer: container, saveContext: $0) }
        ?? WorkoutStore(modelContainer: container)
    return (store, container)
}

/// Names of all stored workout records, visible or not, in stored order.
func storedNames(in container: ModelContainer) throws -> [String] {
    try storedRecords(in: ModelContext(container)).map(\.name)
}

func storedRecords(in context: ModelContext) throws -> [WorkoutModel] {
    try context.fetch(FetchDescriptor<WorkoutModel>())
        .sorted { ($0.order, $0.persistentModelID) < ($1.order, $1.persistentModelID) }
}

func count<Model: PersistentModel>(_ type: Model.Type, in container: ModelContainer) throws -> Int {
    try ModelContext(container).fetchCount(FetchDescriptor<Model>())
}

/// Lets a test fail the store's save point on demand.
final class SaveSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var isFailing = false

    var fails: Bool {
        get { lock.withLock { isFailing } }
        set { lock.withLock { isFailing = newValue } }
    }

    func save(_ context: ModelContext) throws {
        if fails {
            throw SaveFailure()
        }
        try context.save()
    }
}

struct SaveFailure: Error {}
