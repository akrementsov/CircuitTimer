import ComposableArchitecture

extension SettingsFeature {
    func readNotificationAccess(_ state: inout State) -> Effect<Action> {
        guard state.isBackgroundNotificationsOn else { return .none }

        state.notificationAccessGeneration += 1
        let generation = state.notificationAccessGeneration
        return .run { [backgroundNotifications] send in
            do {
                let access = try await backgroundNotifications.access()
                await send(.internal(.notificationAccessLoaded(generation: generation, access)))
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error("Reading notification settings failed: \(String(reflecting: error), privacy: .public)")
                await send(.internal(.notificationAccessLoaded(generation: generation, nil)))
            }
        }
        .cancellable(id: CancelID.notificationAccess, cancelInFlight: true)
    }
}

extension SettingsFeature.State {
    var notificationFootnote: String {
        guard isBackgroundNotificationsOn else { return "settings.notifications.off" }
        guard let notificationAccess else { return "settings.notifications.unknown" }
        if notificationAccess.authorization == .notDetermined { return "settings.notifications.notAsked" }
        if notificationAccess.authorization == .denied { return "settings.notifications.denied" }
        if !notificationAccess.showsAlerts { return "settings.notifications.alertsOff" }
        return "settings.notifications.coverage"
    }
}
