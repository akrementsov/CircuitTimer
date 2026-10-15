import BackgroundNotifications
import ComposableArchitecture
import Foundation
import SwiftUI
import WorkoutDomain

extension AppFeature {
    struct StartIntent: Equatable, Sendable {
        let generation: Int
        let editorID: StackElementID
        let workout: Workout
        var isAwaitingAuthorization = false
    }

    public enum PermissionStallChoice: Equatable, Sendable {
        case startNow
        case wait
    }

    func prepareNotificationPermission(_ workout: Workout, _ state: inout State) -> Effect<Action> {
        guard state.isBackgroundNotificationsOn, state.notificationAccess?.isDetermined != true else {
            state.destination = .timer(timerState(for: workout))
            return .none
        }
        guard state.startIntent == nil, let editorID = state.path.ids.last else { return .none }

        state.notificationPermissionGeneration += 1
        let generation = state.notificationPermissionGeneration
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
        guard state.startIntent?.generation == generation else { return .none }
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
        guard generation == state.notificationPermissionGeneration else { return .none }
        if let access, access.isDetermined { state.notificationAccess = access }
        guard state.startIntent?.generation == generation else { return .none }
        if state.destination?.is(\.permissionStalled) == true {
            state.destination = nil
            return .merge(.cancel(id: CancelID.notificationPermissionStall), delayedStart(generation))
        }
        return confirmStartIntent(generation, &state)
    }

    func permissionStallTimer(_ state: State) -> Effect<Action> {
        guard state.isSceneActive, state.destination == nil, let intent = state.startIntent else { return .none }
        return .run { [clock] send in
            try await clock.sleep(for: .seconds(10))
            await send(.internal(.notificationPermissionStalled(generation: intent.generation)))
        }
        .cancellable(id: CancelID.notificationPermissionStall, cancelInFlight: true)
    }

    func permissionStallChosen(_ choice: PermissionStallChoice, _ state: inout State) -> Effect<Action> {
        guard let intent = state.startIntent else { return .none }
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
        guard let intent = state.startIntent, intent.generation == generation else { return .none }
        guard state.destination == nil, isCurrentStartIntent(intent, state) else {
            return cancelStartIntent(&state)
        }
        state.startIntent = nil
        state.destination = .timer(timerState(for: intent.workout))
        // An outstanding system prompt may still answer after Start now; it can update the cache,
        // but the absent intent prevents it from creating a second timer.
        return .cancel(id: CancelID.notificationPermissionStall)
    }

    func isCurrentStartIntent(_ intent: StartIntent, _ state: State) -> Bool {
        guard state.selectedTab == .workouts, state.path.ids.last == intent.editorID,
              let editor = state.path[id: intent.editorID, case: \.editor] else { return false }
        return editor.phase == .viewing && editor.workout == intent.workout
    }

    func cancelStartIntent(_ state: inout State) -> Effect<Action> {
        guard let intent = state.startIntent else { return .none }
        state.path[id: intent.editorID, case: \.editor]?.cancelStart()
        state.startIntent = nil
        state.notificationPermissionGeneration += 1
        return .merge(.cancel(id: CancelID.notificationPermission), .cancel(id: CancelID.notificationPermissionStall))
    }

    func waitForNotificationPermission(_ state: State) -> Effect<Action> {
        guard let intent = state.startIntent else { return .none }
        // A failed query has no live authorization callback to wait for.
        return intent.isAwaitingAuthorization ? permissionStallTimer(state) : readStartAccess(intent.generation)
    }

    func notificationSceneChanged(_ phase: ScenePhase, _ state: inout State) -> Effect<Action> {
        state.isSceneActive = phase == .active
        guard phase == .active else { return .cancel(id: CancelID.notificationPermissionStall) }
        return .merge(
            permissionStallTimer(state),
            state.isNotificationCleanupStalled ? cleanupNotifications(reportSuccess: true) : .none
        )
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
