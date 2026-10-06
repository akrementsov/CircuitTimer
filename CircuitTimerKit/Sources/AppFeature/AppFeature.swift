import ComposableArchitecture
import Foundation
import os
import WorkoutDomain
import WorkoutEditorFeature
import WorkoutStorage

@Reducer
public struct AppFeature: Sendable {
    @Reducer
    public enum Destination {
        case editor(WorkoutEditorFeature)
    }

    @ObservableState
    public struct State: Equatable, Sendable {
        public var workouts: Content = .idle
        /// Stored records the list cannot show: unreadable workouts and extra copies of shown ones.
        public var hiddenRecordCount = 0
        @Presents public var destination: Destination.State?

        public init() {}
    }

    public enum Content: Equatable, Sendable {
        case idle
        case loading
        case loaded(IdentifiedArrayOf<Workout>)
        case failed
    }

    public enum Action: ViewAction, Equatable, Sendable {
        case view(View)
        case `internal`(Internal)
        case destination(PresentationAction<Destination.Action>)

        @CasePathable
        public enum View: Equatable, Sendable {
            case task
            case retryButtonTapped
            case addButtonTapped
            case workoutTapped(Workout.ID)
        }

        @CasePathable
        public enum Internal: Equatable, Sendable {
            case workoutsLoaded(StoredWorkouts)
            case workoutsLoadingFailed
        }
    }

    private enum CancelID {
        case load
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CircuitTimer", category: "AppFeature")

    @Dependency(\.uuid) private var uuid
    @Dependency(\.workoutStorage) private var workoutStorage

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
                case let .view(action):
                    reduce(into: &state, action)
                case let .internal(action):
                    reduce(into: &state, action)
                case let .destination(.presented(.editor(.delegate(.saved(workout))))):
                    workoutSaved(workout, &state)
                case .destination:
                    .none
            }
        }
        .ifLet(\.$destination, action: \.destination)
    }

    private func reduce(into state: inout State, _ action: Action.View) -> Effect<Action> {
        switch action {
            case .task:
                guard state.workouts == .idle else { return .none }

                return loadWorkouts(&state)
            case .retryButtonTapped:
                return loadWorkouts(&state)
            case .addButtonTapped:
                state.destination = .editor(WorkoutEditorFeature.State(newWorkoutID: uuid(), firstStageID: uuid()))
                return .none
            case let .workoutTapped(id):
                guard case let .loaded(workouts) = state.workouts, let workout = workouts[id: id] else { return .none }

                state.destination = .editor(WorkoutEditorFeature.State(editing: workout))
                return .none
        }
    }

    private func reduce(into state: inout State, _ action: Action.Internal) -> Effect<Action> {
        switch action {
            case let .workoutsLoaded(stored):
                // Storage already returns unique identifiers; uniquing keeps a contract slip from crashing the list.
                state.workouts = .loaded(IdentifiedArray(stored.workouts, uniquingIDsWith: { first, _ in first }))
                state.hiddenRecordCount = stored.unreadableCount + stored.hiddenDuplicateCount
                return .none
            case .workoutsLoadingFailed:
                state.workouts = .failed
                return .none
        }
    }

    /// Storage appends a new workout, so a new one goes to the end here too.
    private func workoutSaved(_ workout: Workout, _ state: inout State) -> Effect<Action> {
        guard case var .loaded(workouts) = state.workouts else { return loadWorkouts(&state) }

        workouts[id: workout.id] = workout
        state.workouts = .loaded(workouts)
        return .none
    }

    private func loadWorkouts(_ state: inout State) -> Effect<Action> {
        state.workouts = .loading
        return .run { [workoutStorage] send in
            do {
                let stored = try await workoutStorage.fetchAll()
                await send(.internal(.workoutsLoaded(stored)))
            } catch is CancellationError {
                // Superseded by a newer load; not a failure.
                return
            } catch {
                Self.logger.error("Failed to load workouts: \(String(reflecting: error), privacy: .public)")
                await send(.internal(.workoutsLoadingFailed))
            }
        }
        .cancellable(id: CancelID.load, cancelInFlight: true)
    }
}

extension AppFeature.Destination.State: Equatable, Sendable {}
extension AppFeature.Destination.Action: Equatable, Sendable {}
