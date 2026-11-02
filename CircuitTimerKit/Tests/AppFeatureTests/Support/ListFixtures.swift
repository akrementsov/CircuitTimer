@testable import AppFeature
@testable import WorkoutTimerFeature

import BackgroundExecution
import BackgroundNotifications
import CloudSync
import ComposableArchitecture
import Foundation
import WatchLink
import WorkoutActivity
import WorkoutDomain
import WorkoutHealth

func loaded(_ workouts: [Workout]) -> AppFeature.State {
    var state = AppFeature.State()
    state.workouts = .loaded(IdentifiedArray(uniqueElements: workouts))
    return state
}

/// What the app published to the watch, in the order the effects ran, and how many revisions the reducer took.
struct WatchPublications: Sendable {
    let published = LockIsolated<[WatchPublication]>([])
    let revisions = LockIsolated(0)
    /// The runs the timer published and the owners whose runs ended, in order.
    let runs = LockIsolated<[WatchRun]>([])
    let ended = LockIsolated<[UUID]>([])
}

struct WatchPublication: Equatable, Sendable {
    let revision: Int
    let catalog: CatalogState
}

/// `healthAccess` starts as already read, so a Start opens the timer without the Health stage; a test of that stage
/// passes `nil`. Every store records what it publishes to the watch; a test of the publication passes `watch`.
@MainActor
func makeStore(
    _ state: AppFeature.State,
    notificationsEnabled: Bool = false,
    healthAccess: HealthAccess? = .unavailable,
    watch: WatchPublications = WatchPublications(),
    dependencies: (inout DependencyValues) -> Void = { _ in }
) -> TestStoreOf<AppFeature> {
    var state = state
    state.settings.$isBackgroundNotificationsOn.withLock { $0 = notificationsEnabled }
    state.healthAccess = healthAccess
    let revisions = LockIsolated(0)
    return TestStore(initialState: state) {
        AppFeature()
    } withDependencies: {
        $0.liveActivity = .previewValue
        $0.cues = .previewValue
        $0.cloudSync = .previewValue
        $0.workoutHealth = .previewValue
        $0.backgroundNotifications.removeOrphans = { true }
        $0.backgroundNotifications.end = { _ in }
        $0.uuid = .incrementing
        // Read when a closed timer ends its Health session.
        $0.date = .constant(Date(timeIntervalSince1970: 0))
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
        $0.watchCompanion.nextRevision = {
            watch.revisions.withValue {
                $0 += 1
                return $0
            }
        }
        $0.watchCompanion.publishCatalog = { revision, catalog in
            watch.published.withValue { $0.append(WatchPublication(revision: revision, catalog: catalog)) }
        }
        $0.watchCompanion.publishRun = { _, run in watch.runs.withValue { $0.append(run) } }
        $0.watchCompanion.end = { owner in watch.ended.withValue { $0.append(owner) } }
        $0.watchCompanion.controlRequests = { _ in AsyncStream { $0.finish() } }
        $0.watchCompanion.refreshHandled = { _, _, _ in }
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
