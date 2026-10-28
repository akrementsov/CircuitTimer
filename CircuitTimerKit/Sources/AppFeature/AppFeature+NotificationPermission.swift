import BackgroundNotifications
import ComposableArchitecture
import Foundation
import WorkoutDomain

extension AppFeature {
    public enum PermissionStallChoice: Equatable, Sendable {
        case startNow
        case wait
    }

    func prepareNotificationPermission(_ workout: Workout, editorID: StackElementID, _ state: inout State) -> Effect<Action> {
        guard state.isBackgroundNotificationsOn, state.notificationAccess?.isDetermined != true else {
            return prepareHealthPermission(workout, editorID: editorID, &state)
        }
        state.startGeneration += 1
        let generation = state.startGeneration
        state.startIntent = StartIntent(generation: generation, editorID: editorID, workout: workout)
        return readStartAccess(generation)
    }

    private func readStartAccess(_ generation: Int) -> Effect<Action> {
        .run { [backgroundNotifications] send in
            do {
                let access = try await backgroundNotifications.access()
                await send(.internal(.notificationAccessQueried(generation: generation, access)))
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error("Reading notification permission failed: \(String(reflecting: error), privacy: .public)")
                await send(.internal(.notificationAccessQueried(generation: generation, nil)))
            }
        }
        .cancellable(id: CancelID.notificationPermission, cancelInFlight: true)
    }

    func notificationAccessQueried(_ access: NotificationAccess?, generation: Int, _ state: inout State) -> Effect<Action> {
        guard state.startIntent?.generation == generation, state.startIntent?.stage == .notifications else { return .none }
        guard let access else {
            state.destination = .permissionStalled(.permissionStalled)
            return .none
        }
        if access.isDetermined {
            state.notificationAccess = access
            return confirmStartIntent(generation, &state)
        }
        state.startIntent?.isAwaitingAuthorization = true
        return .merge(
            .run { [backgroundNotifications] send in
                do {
                    let access = try await backgroundNotifications.requestAuthorization()
                    await send(.internal(.notificationPermissionAnswered(generation: generation, access)))
                } catch is CancellationError {
                    return
                } catch {
                    Self.logger.error("Requesting notification permission failed: \(String(reflecting: error), privacy: .public)")
                    await send(.internal(.notificationPermissionAnswered(generation: generation, nil)))
                }
            }
            .cancellable(id: CancelID.notificationPermission, cancelInFlight: true),
            permissionStallTimer(state)
        )
    }

    func notificationPermissionAnswered(_ access: NotificationAccess?, generation: Int, _ state: inout State) -> Effect<Action> {
        guard generation == state.startGeneration else { return .none }
        if let access, access.isDetermined { state.notificationAccess = access }
        guard state.startIntent?.generation == generation, state.startIntent?.stage == .notifications else { return .none }
        if state.destination?.is(\.permissionStalled) == true {
            state.destination = nil
            return .merge(.cancel(id: CancelID.notificationPermissionStall), delayedStart(generation))
        }
        return confirmStartIntent(generation, &state)
    }

    func permissionStallTimer(_ state: State) -> Effect<Action> {
        guard state.isSceneActive, state.destination == nil, let intent = state.startIntent, intent.stage == .notifications
        else { return .none }
        return .run { [clock] send in
            try await clock.sleep(for: .seconds(10))
            await send(.internal(.notificationPermissionStalled(generation: intent.generation)))
        }
        .cancellable(id: CancelID.notificationPermissionStall, cancelInFlight: true)
    }

    func permissionStallChosen(_ choice: PermissionStallChoice, _ state: inout State) -> Effect<Action> {
        guard let intent = state.startIntent, intent.stage == .notifications else { return .none }
        switch choice {
            case .startNow:
                return delayedStart(intent.generation)
            case .wait:
                // The presentation reducer removes the alert before this action restarts its deadline.
                return .run { send in await send(.internal(.notificationPermissionWait)) }
        }
    }

    private func delayedStart(_ generation: Int) -> Effect<Action> {
        .run { send in await send(.internal(.startIntentConfirmed(generation: generation))) }
    }

    func confirmStartIntent(_ generation: Int, _ state: inout State) -> Effect<Action> {
        guard let intent = state.startIntent, intent.generation == generation, intent.stage == .notifications else {
            return .none
        }
        guard state.destination == nil, isCurrentStart(intent.workout, editorID: intent.editorID, state) else {
            return cancelStartIntent(&state)
        }
        // An outstanding system prompt may still answer after Start now; it can update the cache,
        // but the intent has left this stage, so the answer cannot open a second timer.
        return .merge(
            .cancel(id: CancelID.notificationPermissionStall),
            prepareHealthPermission(intent.workout, editorID: intent.editorID, &state)
        )
    }

    func waitForNotificationPermission(_ state: State) -> Effect<Action> {
        guard let intent = state.startIntent, intent.stage == .notifications else { return .none }
        // A failed query has no live authorization callback to wait for.
        return intent.isAwaitingAuthorization ? permissionStallTimer(state) : readStartAccess(intent.generation)
    }

    func cleanupNotifications(reportSuccess: Bool = false) -> Effect<Action> {
        .run { [backgroundNotifications] send in
            do {
                let cleaned = try await backgroundNotifications.removeOrphans()
                if reportSuccess || !cleaned { await send(.internal(.notificationCleanupFinished(cleaned))) }
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error("Cleaning old notifications failed: \(String(reflecting: error), privacy: .public)")
                await send(.internal(.notificationCleanupFinished(false)))
            }
        }
        .cancellable(id: CancelID.notificationCleanup, cancelInFlight: true)
    }
}

extension AlertState where Action == AppFeature.PermissionStallChoice {
    static var permissionStalled: Self {
        AlertState {
            TextState("workouts.permissionStalled.title", bundle: .module)
        } actions: {
            ButtonState(action: .startNow) { TextState("workouts.permissionStalled.startNow", bundle: .module) }
            ButtonState(role: .cancel, action: .wait) { TextState("workouts.permissionStalled.wait", bundle: .module) }
        } message: {
            TextState("workouts.permissionStalled.message", bundle: .module)
        }
    }
}
