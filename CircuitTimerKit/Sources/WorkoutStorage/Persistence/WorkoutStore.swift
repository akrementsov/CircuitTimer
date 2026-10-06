import Foundation
import os
import SwiftData
import WorkoutDomain

/// Owns the model context. Every write either saves completely or rolls back.
@ModelActor
actor WorkoutStore {
    private static let sampleSeedKey = "sample-workout-v1"
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CircuitTimer", category: "WorkoutStore")

    private var isSampleSeedChecked = false

    func fetchAll() throws -> StoredWorkouts {
        try seedSampleIfNeeded()

        let records = primaryRecords(in: try allSorted())
        return StoredWorkouts(
            workouts: records.primaries.map(\.workout),
            unreadableCount: records.unreadableCount,
            hiddenDuplicateCount: records.hiddenDuplicateCount
        )
    }

    /// Updates the visible record of `workout`, or appends a new one.
    func save(_ workout: Workout) throws {
        try write {
            if let model = primaryRecords(in: try allSorted()).model(for: workout.id) {
                model.update(from: workout, in: modelContext)
            } else {
                try append(workout)
            }
        }
    }

    /// Inserts `workout` right after the visible record of `anchorID`; appends it when there is none.
    func insert(_ workout: Workout, after anchorID: Workout.ID) throws -> WorkoutWriteOutcome {
        try write {
            let all = try allSorted()
            guard
                let anchor = primaryRecords(in: all).model(for: anchorID),
                let anchorIndex = all.firstIndex(where: { $0 === anchor })
            else {
                try append(workout)
                return .storeDiverged
            }

            let model = makeModel(for: workout)
            var ordered = all
            ordered.insert(model, at: anchorIndex + 1)
            renumber(ordered)
            return .applied
        }
    }

    /// Deletes the visible record of `id` only. Hidden copies stay: the user deletes exactly what they see.
    func delete(_ id: Workout.ID) throws -> WorkoutWriteOutcome {
        try write {
            let all = try allSorted()
            guard let model = primaryRecords(in: all).model(for: id) else { return .storeDiverged }

            modelContext.delete(model)
            let hasOtherCopies = all.contains { $0.workoutID == id && $0 !== model }
            return hasOtherCopies ? .storeDiverged : .applied
        }
    }

    /// Orders the visible records as `ids`; records the caller did not list keep their relative order after them.
    func reorder(_ ids: [Workout.ID]) throws -> WorkoutWriteOutcome {
        try write {
            let all = try allSorted()
            let records = primaryRecords(in: all)

            var placed: [WorkoutModel] = []
            var placedIDs: Set<ObjectIdentifier> = []
            for id in ids {
                guard let model = records.model(for: id), placedIDs.insert(ObjectIdentifier(model)).inserted else { continue }
                placed.append(model)
            }
            renumber(placed + all.filter { !placedIDs.contains(ObjectIdentifier($0)) })

            let visibleIDs = Set(records.primaries.map(\.workout.id))
            return visibleIDs == Set(ids) ? .applied : .storeDiverged
        }
    }

    private func write<Result>(_ body: () throws -> Result) throws -> Result {
        do {
            let result = try body()
            try modelContext.save()
            return result
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func seedSampleIfNeeded() throws {
        guard !isSampleSeedChecked else { return }

        try write {
            let key = Self.sampleSeedKey
            let markers = try modelContext.fetchCount(FetchDescriptor<SeedMarkerModel>(predicate: #Predicate { $0.key == key }))
            guard markers == 0 else { return }

            let sample = Workout.sample
            let sampleID: UUID? = sample.id
            let existing = try modelContext.fetchCount(
                FetchDescriptor<WorkoutModel>(predicate: #Predicate { $0.workoutID == sampleID })
            )
            if existing == 0 {
                try append(sample)
            }
            modelContext.insert(SeedMarkerModel(key: key))
        }
        isSampleSeedChecked = true
    }

    private func append(_ workout: Workout) throws {
        // Computed before the new model is inserted, so it never counts itself.
        let order = try nextOrder()
        makeModel(for: workout).order = order
    }

    private func makeModel(for workout: Workout) -> WorkoutModel {
        let model = WorkoutModel(workoutID: workout.id)
        modelContext.insert(model)
        model.update(from: workout, in: modelContext)
        return model
    }

    private func nextOrder() throws -> Int {
        let all = try allSorted()
        guard let last = all.last else { return 0 }

        let (next, overflow) = last.order.addingReportingOverflow(1)
        guard overflow else { return next }

        renumber(all)
        return all.count
    }

    private func renumber(_ ordered: [WorkoutModel]) {
        for (index, model) in ordered.enumerated() where model.order != index {
            model.order = index
        }
    }

    private func allSorted() throws -> [WorkoutModel] {
        try modelContext.fetch(FetchDescriptor<WorkoutModel>())
            .sorted { ($0.order, $0.persistentModelID) < ($1.order, $1.persistentModelID) }
    }

    /// Picks the visible record of every workout: the first readable one in stored order.
    /// Reads and writes go through it, so an edit always lands in the record the user sees.
    private func primaryRecords(in sorted: [WorkoutModel]) -> PrimaryRecords {
        var records = PrimaryRecords()
        var groups: [UUID: [WorkoutModel]] = [:]
        var groupOrder: [UUID] = []
        for model in sorted {
            guard let id = model.workoutID else {
                Self.logger.error("Skipping a stored workout without an identifier")
                records.unreadableCount += 1
                continue
            }
            if groups[id] == nil {
                groupOrder.append(id)
            }
            groups[id, default: []].append(model)
        }

        for id in groupOrder {
            let group = groups[id] ?? []
            guard let primary = firstReadable(in: group) else {
                records.unreadableCount += 1
                continue
            }
            records.primaries.append(primary)
            records.hiddenDuplicateCount += group.count - 1
        }
        let position = Dictionary(uniqueKeysWithValues: sorted.enumerated().map { (ObjectIdentifier($1), $0) })
        records.primaries.sort { position[ObjectIdentifier($0.model), default: 0] < position[ObjectIdentifier($1.model), default: 0] }
        return records
    }

    private func firstReadable(in group: [WorkoutModel]) -> (model: WorkoutModel, workout: Workout)? {
        for model in group {
            do {
                return (model, try model.toDomain())
            } catch {
                Self.logger.error("Skipping an unreadable stored workout: \(String(describing: error), privacy: .public)")
            }
        }
        return nil
    }
}

private struct PrimaryRecords {
    var primaries: [(model: WorkoutModel, workout: Workout)] = []
    var unreadableCount = 0
    var hiddenDuplicateCount = 0

    func model(for id: Workout.ID) -> WorkoutModel? {
        primaries.first { $0.workout.id == id }?.model
    }
}
