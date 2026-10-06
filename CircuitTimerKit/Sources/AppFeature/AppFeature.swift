import ComposableArchitecture
import Foundation
import os
import WorkoutDomain
import WorkoutStorage

@Reducer
public struct AppFeature: Sendable {
    @ObservableState
    public struct State: Equatable, Sendable {
        public var workouts: Content = .idle

        public init() {}
    }

    public enum Content: Equatable, Sendable {
        case idle
        case loading
        case loaded([Workout])
        case failed
    }

    public enum Action: ViewAction, Equatable, Sendable {
        case view(View)
        case `internal`(Internal)

        @CasePathable
        public enum View: Equatable, Sendable {
            case task
            case retryButtonTapped
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

    @Dependency(\.workoutStorage) private var workoutStorage

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
                case let .view(action):
                    reduce(into: &state, action)
                case let .internal(action):
                    reduce(into: &state, action)
            }
        }
    }

    private func reduce(into state: inout State, _ action: Action.View) -> Effect<Action> {
        switch action {
            case .task:
                guard state.workouts == .idle else { return .none }

                return loadWorkouts(&state)
            case .retryButtonTapped:
                return loadWorkouts(&state)
        }
    }

    private func reduce(into state: inout State, _ action: Action.Internal) -> Effect<Action> {
        switch action {
            case let .workoutsLoaded(stored):
                state.workouts = .loaded(stored.workouts)
                return .none
            case .workoutsLoadingFailed:
                state.workouts = .failed
                return .none
        }
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
