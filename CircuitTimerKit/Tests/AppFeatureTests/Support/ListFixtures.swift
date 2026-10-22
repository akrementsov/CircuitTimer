@testable import AppFeature
@testable import WorkoutTimerFeature

import BackgroundExecution
import BackgroundNotifications
import CloudSync
import ComposableArchitecture
import Foundation
import WorkoutActivity
import WorkoutDomain

func loaded(_ workouts: [Workout]) -> AppFeature.State {
    var state = AppFeature.State()
    state.workouts = .loaded(IdentifiedArray(uniqueElements: workouts))
    return state
}

@MainActor
func makeStore(
    _ state: AppFeature.State,
    notificationsEnabled: Bool = false,
    dependencies: (inout DependencyValues) -> Void = { _ in }
) -> TestStoreOf<AppFeature> {
    state.settings.$isBackgroundNotificationsOn.withLock { $0 = notificationsEnabled }
    let revisions = LockIsolated(0)
    return TestStore(initialState: state) {
        AppFeature()
    } withDependencies: {
        $0.liveActivity = .previewValue
        $0.cues = .previewValue
        $0.cloudSync = .previewValue
        $0.backgroundNotifications.removeOrphans = { true }
        $0.backgroundNotifications.end = { _ in }
        $0.uuid = .incrementing
        $0.continuousClock = TestClock<Duration>()
        $0.backgroundTask = BackgroundTaskClient(begin: { _ in .invalid }, end: { _ in })
        $0.workoutRunRecord.load = { nil }
        $0.workoutRunRecord.nextRevision = {
            revisions.withValue {
                $0 += 1
                return $0
            }
        }
        $0.workoutRunRecord.write = { _, _ in }
        dependencies(&$0)
    }
}

/// Holds a stubbed storage call in flight until the test opens it, so the test can act in between.
struct Gate: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    func wait() async {
        for await _ in stream {}
    }

    func open() {
        continuation.finish()
    }
}

func makeStage(_ number: Int, _ intensity: Stage.Intensity = .work) -> Stage {
    Stage(id: UUID(fixture: number), name: "Stage \(number)", duration: .seconds(10), intensity: intensity)
}

func makeWorkout(_ number: Int, name: String? = nil) -> Workout {
    Workout(id: UUID(fixture: number), name: name ?? "Workout \(number)", training: [makeStage(number * 100)])
}

extension UUID {
    /// Deterministic identifiers for fixtures; they never collide with `UUIDGenerator.incrementing`.
    init(fixture number: Int) {
        let high = UInt8(truncatingIfNeeded: number >> 8)
        let low = UInt8(truncatingIfNeeded: number)
        self.init(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, high, low))
    }
}
