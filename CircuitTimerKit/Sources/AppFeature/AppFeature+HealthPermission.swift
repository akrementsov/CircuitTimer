import ComposableArchitecture
import Foundation
import WorkoutDomain
import WorkoutHealth

extension AppFeature {
    /// The Health stage of a first Start, after notifications. It never shows an alert of its own: whatever Health
    /// answers, or if it cannot be asked, the timer opens; only the workout session depends on the answer.
    func prepareHealthPermission(_ workout: Workout, editorID: StackElementID, _ state: inout State) -> Effect<Action> {
        // An outstanding request still holds its sheet; asking again would only wait behind it.
        guard !state.isHealthRequestOutstanding, state.healthAccess != .unavailable, state.healthAccess != .determined
        else { return openTimer(workout, editorID: editorID, &state) }

        var intent = state.startIntent ?? StartIntent(generation: state.startGeneration + 1, editorID: editorID, workout: workout)
        intent.stage = .health
        state.startGeneration = intent.generation
        state.startIntent = intent
        // A cached `notDetermined` may have been answered in Settings since.
        state.healthAccess = nil
        return .merge(readHealthAccess(intent.generation), healthStallTimer(state))
    }

    private func readHealthAccess(_ generation: Int) -> Effect<Action> {
        .run { [workoutHealth] send in
            do {
                let access = try await workoutHealth.access()
                await send(.internal(.healthAccessQueried(generation: generation, access)))
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error("Reading Health access failed: \(String(reflecting: error), privacy: .public)")
                await send(.internal(.healthAccessQueried(generation: generation, nil)))
            }
        }
        .cancellable(id: CancelID.healthPermission, cancelInFlight: true)
    }

    func healthAccessQueried(_ access: HealthAccess?, generation: Int, _ state: inout State) -> Effect<Action> {
        guard let intent = state.startIntent, intent.generation == generation, intent.stage == .health else {
            return .none
        }
        // A failed read is not cached, so the next Start reads again.
        guard let access else { return openTimer(intent.workout, editorID: intent.editorID, &state) }

        state.healthAccess = access
        guard access == .notDetermined else { return openTimer(intent.workout, editorID: intent.editorID, &state) }

        return requestHealthAccess(&state)
    }

    /// Asks only an active scene: from the background the sheet would wait unseen. The request has no cancel ID:
    /// once the sheet shows, only its answer clears `isHealthRequestOutstanding`. The stall timer starts again with
    /// the sheet.
    private func requestHealthAccess(_ state: inout State) -> Effect<Action> {
        guard state.isSceneActive, !state.isHealthRequestOutstanding, state.healthAccess == .notDetermined,
              let intent = state.startIntent, intent.stage == .health else { return .none }

        state.isHealthRequestOutstanding = true
        let generation = intent.generation
        return .merge(
            .run { [workoutHealth] send in
                do {
                    try await workoutHealth.requestAuthorization()
                    await send(.internal(.healthPermissionAnswered(generation: generation, succeeded: true)))
                } catch is CancellationError {
                    return
                } catch {
                    Self.logger.error("Requesting Health access failed: \(String(reflecting: error), privacy: .public)")
                    await send(.internal(.healthPermissionAnswered(generation: generation, succeeded: false)))
                }
            },
            healthStallTimer(state)
        )
    }

    /// A Health stage that does not finish within 10 seconds of an active scene, reading the access or waiting for
    /// the sheet, frees Start; the intent stays, so a late answer still opens the timer, and a new Start opens it
    /// without Health.
    private func healthStallTimer(_ state: State) -> Effect<Action> {
        guard state.isSceneActive, let intent = state.startIntent, intent.stage == .health, !intent.hasStalled else {
            return .none
        }

        return .run { [clock] send in
            try await clock.sleep(for: .seconds(10))
            await send(.internal(.healthRequestStalled(generation: intent.generation)))
        }
        .cancellable(id: CancelID.healthRequestStall, cancelInFlight: true)
    }

    func healthRequestStalled(generation: Int, _ state: inout State) -> Effect<Action> {
        guard let intent = state.startIntent, intent.generation == generation, intent.stage == .health else {
            return .none
        }
        state.startIntent?.hasStalled = true
        state.path[id: intent.editorID, case: \.editor]?.cancelStart()
        return .none
    }

    /// A late answer, after the user left or started without Health, only updates the cache.
    func healthPermissionAnswered(succeeded: Bool, generation: Int, _ state: inout State) -> Effect<Action> {
        state.isHealthRequestOutstanding = false
        // iOS never says whether writing was allowed; an answered sheet is all the app learns.
        if succeeded { state.healthAccess = .determined }
        guard let intent = state.startIntent, intent.generation == generation, intent.stage == .health else {
            return .none
        }
        return openTimer(intent.workout, editorID: intent.editorID, &state)
    }

    /// A Start that reached Health while the scene was inactive asks once it is active again; a sheet already showing,
    /// or a read still under way, gets a new stall timer.
    func healthSceneActivated(_ state: inout State) -> Effect<Action> {
        guard !state.isHealthRequestOutstanding, state.healthAccess == .notDetermined else { return healthStallTimer(state) }

        return requestHealthAccess(&state)
    }
}
