import ComposableArchitecture
import DesignSystem
import SwiftUI

@ViewAction(for: SettingsFeature.self)
public struct SettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable public var store: StoreOf<SettingsFeature>

    public init(store: StoreOf<SettingsFeature>) {
        self.store = store
    }

    public var body: some View {
        NavigationStack(path: $store.scope(\.path, action: \.path)) {
            SettingsScroll {
                SettingsSwitchCard(
                    title: Text("settings.signals.sound", bundle: .module),
                    isOn: Binding(get: { store.isSoundOn }, set: { send(.soundToggled($0)) })
                )
                SettingsSwitchCard(
                    title: Text("settings.signals.vibration", bundle: .module),
                    isOn: Binding(get: { store.isVibrationOn }, set: { send(.vibrationToggled($0)) })
                )
                SettingsSwitchCard(
                    title: Text("settings.signals.speech", bundle: .module),
                    isOn: Binding(get: { store.isSpeechOn }, set: { send(.speechToggled($0)) })
                )
                Text("settings.signals.footnote", bundle: .module)
                    .font(.token(.footnote))
                    .foregroundStyle(.text(.secondary))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, .token(spacing: .m))
                SettingsSwitchCard(
                    title: Text("settings.notifications.toggle", bundle: .module),
                    isOn: Binding(get: { store.isBackgroundNotificationsOn }, set: { send(.backgroundNotificationsToggled($0)) })
                )
                notificationStatus
                SettingsSwitchCard(
                    title: Text("settings.screen.keepOn", bundle: .module),
                    isOn: Binding(get: { store.isKeepScreenOn }, set: { send(.keepScreenOnToggled($0)) })
                )
                Button {
                    send(.aboutTapped)
                } label: {
                    SettingsCard(Text("settings.about", bundle: .module), style: .active)
                }
                .buttonStyle(.settingsCard)
            }
            .onAppear { send(.appeared) }
            .navigationTitle(Text("settings.title", bundle: .module))
            .screenChrome()
        } destination: { pathStore in
            switch pathStore.case {
                case let .about(version):
                    AboutView(store: store, version: version)
                case let .legalDocument(document):
                    LegalDocumentView(document: document)
            }
        }
        // The back buttons are white, like the legacy bar; the tab bar keeps the accent.
        .tint(.text(.primary))
        .task { send(.task) }
        .onChange(of: scenePhase, initial: true) { _, phase in send(.scenePhaseChanged(phase)) }
    }

    private var notificationStatus: some View {
        VStack(alignment: .leading, spacing: .token(spacing: .s)) {
            Text(LocalizedStringKey(store.notificationFootnote), bundle: .module)
            if store.openSettingsFailed {
                Text("settings.notifications.openFailed", bundle: .module)
            }
            Button {
                send(.openNotificationSettingsTapped)
            } label: {
                Text("settings.notifications.openSettings", bundle: .module)
                    .foregroundStyle(.text(.primary))
            }
        }
        .font(.token(.footnote))
        .foregroundStyle(.text(.secondary))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, .token(spacing: .m))
    }
}

/// Previews name screens through this enum: a `#Preview` body cannot see the `Path.State` cases the macro generates.
private enum PreviewScreen {
    case settings
    case about(version: String?)
    case privacyPolicy
}

@MainActor
private func previewStore(_ screen: PreviewScreen) -> StoreOf<SettingsFeature> {
    var state = SettingsFeature.State()
    switch screen {
        case .settings:
            break
        case let .about(version):
            state.path.append(.about(version: version))
        case .privacyPolicy:
            state.path.append(.about(version: "0.1.0"))
            state.path.append(.legalDocument(.privacyPolicy))
    }
    return Store(initialState: state) { SettingsFeature() }
}

#Preview("Settings") {
    SettingsView(store: previewStore(.settings))
        .preferredColorScheme(.dark)
}

#Preview("About") {
    SettingsView(store: previewStore(.about(version: "0.1.0")))
        .preferredColorScheme(.dark)
}

#Preview("About without version") {
    SettingsView(store: previewStore(.about(version: nil)))
        .preferredColorScheme(.dark)
}

#Preview("Privacy policy") {
    SettingsView(store: previewStore(.privacyPolicy))
        .preferredColorScheme(.dark)
}
