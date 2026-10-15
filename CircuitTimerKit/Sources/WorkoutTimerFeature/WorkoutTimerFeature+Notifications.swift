import BackgroundNotifications
import ComposableArchitecture
import Foundation
import WorkoutDomain

extension WorkoutTimerFeature {
    struct NotificationProjection: Equatable, Sendable {
        struct Event: Equatable, Sendable {
            let key: String
            let epochMs: Int64
        }

        let events: [Event]
        let language: String
        let isAudible: Bool
        let hasMore: Bool
    }

    struct NotificationState: Equatable, Sendable {
        var access: NotificationAccess?
        var accessGeneration = 0
        var projection: NotificationProjection?
        var revision = 0
        var lastAttempt: MonotonicInstant?
        var needsRetry = false
        var hasSchedulingFailed = false
    }

    /// Only keys live in state; localized requests belong to the effect and the scheduler.
    func syncNotifications(_ state: inout State, after action: Action, at now: Date) -> Effect<Action> {
        // A result cannot retry itself. Ticks, another user action or an active scene provide the next opportunity.
        if case .internal(.notificationsSynced) = action { return .none }
        guard state.clockGeneration > 0 else { return .none }

        let active = action == .view(.scenePhaseChanged(.active))
        let refresh = action == .view(.task) || active || action == .view(.notificationPreferencesChanged)
        var effects: [Effect<Action>] = []
        if refresh {
            if state.isBackgroundNotificationsOn {
                effects.append(readNotificationAccess(&state))
            } else if state.notifications.accessGeneration > 0 {
                state.notifications.accessGeneration += 1
                state.notifications.access = nil
                effects.append(.cancel(id: CancelID.notificationAccess))
            }
            if active, state.isBackgroundNotificationsOn {
                effects.append(.run { [backgroundNotifications, id = state.id] _ in
                    await backgroundNotifications.removeDelivered(id)
                })
            }
        }
        // Explicitly disabled fixtures need no notification work; a previously submitted plan still needs clearing.
        guard state.isBackgroundNotificationsOn || state.notifications.projection != nil else { return .merge(effects) }

        // `preferredLocales` is the ordered content-language preference, independent of regional formatting.
        let language = state.isBackgroundNotificationsOn
            ? preferredLocales.first?.identifier ?? "en"
            : state.notifications.projection?.language ?? "en"
        let projection = state.notificationProjection(at: now, language: language)
        let changed = projection != state.notifications.projection
        let retryDue = state.notifications.lastAttempt?.duration(toNowOf: clock).map { $0 >= .seconds(10) } ?? true
        guard changed || active || (state.notifications.needsRetry && retryDue) else { return .merge(effects) }

        state.notifications.projection = projection
        state.notifications.revision += 1
        state.notifications.lastAttempt = MonotonicInstant(now: clock)
        let revision = state.notifications.revision
        let requests = state.notificationRequests(at: now, language: language)
        effects.append(.run { [backgroundNotifications, id = state.id] send in
            do {
                let report = try await backgroundNotifications.sync(id, revision, requests)
                await send(.internal(.notificationsSynced(revision: revision, report: report)))
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error("Background notification scheduling failed: \(String(reflecting: error), privacy: .public)")
                await send(.internal(.notificationsSynced(revision: revision, report: nil)))
            }
        })
        return .merge(effects)
    }

    private func readNotificationAccess(_ state: inout State) -> Effect<Action> {
        state.notifications.accessGeneration += 1
        let generation = state.notifications.accessGeneration
        return .run { [backgroundNotifications] send in
            do {
                let access = try await backgroundNotifications.access()
                await send(.internal(.notificationAccessLoaded(generation: generation, access)))
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error("Reading notification access failed: \(String(reflecting: error), privacy: .public)")
                await send(.internal(.notificationAccessLoaded(generation: generation, nil)))
            }
        }
        .cancellable(id: CancelID.notificationAccess, cancelInFlight: true)
    }

    func notificationsSynced(revision: Int, report: NotificationSyncReport?, _ state: inout State) {
        guard revision == state.notifications.revision, report?.superseded != true else { return }

        let clean = report?.isClean == true
        state.notifications.needsRetry = !clean
        if !clean {
            state.notifications.hasSchedulingFailed = true
        } else if state.notifications.projection?.events.isEmpty == false {
            // Removing requests proves cleanup, but cannot prove that future scheduling recovered.
            state.notifications.hasSchedulingFailed = false
        }
    }
}

extension WorkoutTimerFeature.State {
    func notificationProjection(at now: Date, language: String) -> WorkoutTimerFeature.NotificationProjection {
        let upcoming = run.upcomingTransitions(at: now, limit: 32)
        let enabled = isBackgroundNotificationsOn && countdown == nil && notifications.access?.canDeliver != false
        let events: [WorkoutTimerFeature.NotificationProjection.Event] = enabled ? upcoming.events.map { transition in
            let key: String = switch transition.kind {
                case let .stageStarted(stage): "stage.\(stage.index)"
                case .finished: "finish"
            }
            return WorkoutTimerFeature.NotificationProjection.Event(key: key, epochMs: transition.epochMs)
        } : []
        return WorkoutTimerFeature.NotificationProjection(
            events: events,
            language: language,
            isAudible: isSoundOn,
            hasMore: enabled && upcoming.hasMore
        )
    }

    func notificationRequests(at now: Date, language: String) -> [ScheduledNotification] {
        let projection = notificationProjection(at: now, language: language)
        guard !projection.events.isEmpty else { return [] }

        let upcoming = run.upcomingTransitions(at: now, limit: 32)
        return upcoming.events.enumerated().map { index, transition in
            var body: String = switch transition.kind {
                case let .stageStarted(stage):
                    String(localized: "timer.notifications.stage \(Self.displayName(stage))", bundle: .module)
                case .finished:
                    String(localized: "timer.notifications.finished", bundle: .module)
            }
            if upcoming.hasMore, index == upcoming.events.count - 1 {
                body += " " + String(localized: "timer.notifications.reopen", bundle: .module)
            }
            return ScheduledNotification(
                key: projection.events[index].key,
                fireDate: transition.date,
                title: title,
                body: body,
                isAudible: isSoundOn
            )
        }
    }

    /// Permission status takes priority only within this notification footnote.
    var notificationFootnote: String? {
        guard isBackgroundNotificationsOn else { return "timer.notifications.off" }
        guard let access = notifications.access else { return "timer.notifications.unknown" }
        if access.authorization == .notDetermined { return "timer.notifications.notAsked" }
        if access.authorization == .denied { return "timer.notifications.denied" }
        if !access.showsAlerts { return "timer.notifications.alertsOff" }
        if notifications.hasSchedulingFailed { return "timer.notifications.failed" }
        return "timer.notifications.coverage"
    }
}
