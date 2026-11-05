import ComposableArchitecture
import WatchLink
import WorkoutDomain

extension AppFeature {
    static let watchStartLifetime: Duration = .seconds(30)

    /// A process may receive WCSession requests before its root and scene phase are ready.
    func observeWatchStarts() -> Effect<Action> {
        .run { [watchCompanion] send in
            for await request in await watchCompanion.startRequests() {
                await send(.internal(.watchStartRequested(request)))
            }
        }
        .cancellable(id: CancelID.watchStartRequests, cancelInFlight: true)
    }

    func watchStartRequested(_ request: WatchStartRequest, _ state: inout State) -> Effect<Action> {
        guard state.hasScenePhase, state.isSceneActive else { return answerWatchStart(request.id, .openPhoneApp) }
        let takesOver = state.startIntent?.isStalledHealth == true
        guard state.destination == nil, state.purchaseRequest == nil, !state.hasPendingMutationAlert,
              state.startIntent == nil || takesOver, state.runRestore == .resolved,
              state.pendingMutations.isEmpty, !state.needsReload, !state.isReloading, state.deferredScreen == nil,
              state.path.allSatisfy({ element in
                  guard case let .editor(editor) = element else { return false }
                  return editor.phase == .viewing && editor.destination == nil && !editor.isSaving && !editor.isStarting
              })
        else { return answerWatchStart(request.id, .busy) }
        guard case let .loaded(workouts) = state.workouts else { return answerWatchStart(request.id, .listUnavailable) }
        guard let workout = workouts[id: request.workoutID] else { return answerWatchStart(request.id, .gone) }
        guard workout.isPlayable else { return answerWatchStart(request.id, .notPlayable) }
        guard WorkoutSchedule(workout: workout).fingerprint == request.scheduleFingerprint else {
            return answerWatchStart(request.id, .changed)
        }

        // A stalled Health Start has already freed its button. Taking over ends its late continuation even if the
        // short admission ticket expires before the app can answer; the new intent is never run without admission.
        let stopPrevious = takesOver ? discardStartIntent(&state) : .none
        state.startGeneration += 1
        let intent = StartIntent(
            generation: state.startGeneration,
            origin: .watch(requestID: request.id),
            workout: workout,
            stage: .admitting,
            skipsHealth: takesOver,
            acceptedAt: MonotonicInstant(now: clock)
        )
        state.startIntent = intent
        let asksOnPhone = (state.isBackgroundNotificationsOn && state.notificationAccess?.isDetermined != true)
            || (!takesOver && !state.isHealthRequestOutstanding && state.healthAccess != .unavailable && state.healthAccess != .determined)
        return .merge(
            stopPrevious,
            watchStartDeadline(intent),
            .run { [watchCompanion] send in
                let admitted = await watchCompanion.startHandled(request.id, .accepted(asksOnPhone: asksOnPhone))
                await send(.internal(.watchStartAdmitted(generation: intent.generation, admitted)))
            }
        )
    }

    private func answerWatchStart(_ requestID: Int, _ result: WatchStartResult) -> Effect<Action> {
        .run { [watchCompanion] _ in
            if await !watchCompanion.startHandled(requestID, result) {
                Self.logger.notice("A watch Start rejection arrived after its admission ticket closed")
            }
        }
    }

    func watchStartAdmitted(_ admitted: Bool, generation: Int, _ state: inout State) -> Effect<Action> {
        guard let intent = state.startIntent, intent.generation == generation, intent.stage == .admitting else { return .none }
        guard admitted, startCanContinue(intent, state) else {
            Self.logger.notice("A watch Start was not admitted or was no longer current")
            return cancelStartIntent(&state)
        }
        return prepareNotificationPermission(intent.workout, origin: intent.origin, &state)
    }

    func watchStartExpired(_ generation: Int, _ state: inout State) -> Effect<Action> {
        guard let intent = state.startIntent, intent.origin.isWatch, intent.generation == generation else { return .none }
        Self.logger.notice("A watch Start reached its lifetime without opening a timer")
        return cancelStartIntent(&state)
    }

    private func watchStartDeadline(_ intent: StartIntent) -> Effect<Action> {
        .run { [clock] send in
            let elapsed = intent.acceptedAt?.duration(toNowOf: clock) ?? Self.watchStartLifetime
            do {
                try await clock.sleep(for: max(.zero, Self.watchStartLifetime - elapsed))
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error("A watch Start deadline failed: \(String(reflecting: error), privacy: .public)")
            }
            await send(.internal(.watchStartExpired(generation: intent.generation)))
        }
        .cancellable(id: CancelID.watchStartDeadline, cancelInFlight: true)
    }

    func isWatchStartExpired(_ intent: StartIntent) -> Bool {
        guard intent.origin.isWatch else { return false }
        guard let elapsed = intent.acceptedAt?.duration(toNowOf: clock), elapsed >= .zero else {
            Self.logger.error("A watch Start lost its monotonic deadline")
            return true
        }
        return elapsed >= Self.watchStartLifetime
    }

    /// Callback and presentation guards share the reducer's final check; a delayed timeout action is no loophole.
    func startCanContinue(_ intent: StartIntent, _ state: State) -> Bool {
        !isWatchStartExpired(intent) && isCurrentStart(intent.workout, origin: intent.origin, state)
            && (state.destination == nil || state.destination?.is(\.permissionStalled) == true)
    }
}
