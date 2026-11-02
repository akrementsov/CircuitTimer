import ComposableArchitecture
import DesignSystem
import Purchases
import SwiftUI
import UITestContract

@ViewAction(for: SettingsFeature.self)
public struct SettingsView: View {
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
                .accessibilityIdentifier(AccessibilityID.Settings.sound)
                SettingsSwitchCard(
                    title: Text("settings.signals.vibration", bundle: .module),
                    isOn: Binding(get: { store.isVibrationOn }, set: { send(.vibrationToggled($0)) })
                )
                .accessibilityIdentifier(AccessibilityID.Settings.vibration)
                SettingsSwitchCard(
                    title: Text("settings.signals.speech", bundle: .module),
                    isOn: Binding(get: { store.isSpeechOn }, set: { send(.speechToggled($0)) })
                )
                .accessibilityIdentifier(AccessibilityID.Settings.speech)
                SettingsSwitchCard(
                    title: Text("settings.notifications.toggle", bundle: .module),
                    isOn: Binding(get: { store.isBackgroundNotificationsOn }, set: { send(.backgroundNotificationsToggled($0)) })
                )
                .accessibilityIdentifier(AccessibilityID.Settings.backgroundNotifications)
                SettingsSwitchCard(
                    title: Text("settings.screen.keepOn", bundle: .module),
                    isOn: Binding(get: { store.isKeepScreenOn }, set: { send(.keepScreenOnToggled($0)) })
                )
                .accessibilityIdentifier(AccessibilityID.Settings.keepScreenOn)
                if store.fullVersion == .full {
                    SettingsSwitchCard(
                        title: Text("settings.iCloud.toggle", bundle: .module),
                        isOn: Binding(get: { store.isICloudSyncOn }, set: { send(.iCloudSyncToggled($0)) })
                    )
                    .accessibilityIdentifier(AccessibilityID.Settings.iCloudSync)
                } else {
                    SettingsLockedSwitchCard(title: Text("settings.iCloud.toggle", bundle: .module)) {
                        send(.lockedICloudSyncTapped)
                    }
                    .accessibilityIdentifier(AccessibilityID.Settings.iCloudSync)
                }
                if let footnote = store.cloudSyncFootnote {
                    Text(LocalizedStringKey(footnote), bundle: .module)
                        .font(.token(.footnote))
                        .foregroundStyle(.text(.secondary))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, .token(spacing: .m))
                }
                fullVersionRows
                Button {
                    send(.aboutTapped)
                } label: {
                    SettingsCard(Text("settings.about", bundle: .module), style: .active)
                }
                .buttonStyle(.settingsCard)
                .accessibilityIdentifier(AccessibilityID.Settings.about)
            }
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
    }

    /// Buy and Restore until the full version is owned, then one row that says so; nothing while StoreKit has not
    /// answered.
    @ViewBuilder
    private var fullVersionRows: some View {
        switch store.fullVersion {
            case .unknown:
                EmptyView()
            case .free:
                Button {
                    send(.buyTapped)
                } label: {
                    SettingsCard(Text("settings.purchase.buy", bundle: .module), style: .active)
                }
                .buttonStyle(.settingsCard)
                .accessibilityIdentifier(AccessibilityID.Settings.buyFullVersion)
                Button {
                    send(.restoreTapped)
                } label: {
                    SettingsCard(Text("settings.purchase.restore", bundle: .module), style: .active)
                }
                .buttonStyle(.settingsCard)
                .accessibilityIdentifier(AccessibilityID.Settings.restorePurchases)
            case .full:
                SettingsCard(
                    Text("settings.purchase.fullVersion", bundle: .module),
                    value: Text("settings.purchase.purchased", bundle: .module),
                    style: .inactive
                )
                .accessibilityIdentifier(AccessibilityID.Settings.fullVersionPurchased)
        }
    }
}

/// Previews name screens through this enum: a `#Preview` body cannot see the `Path.State` cases the macro generates.
private enum PreviewScreen {
    case settings
    case about(version: String?)
    case privacyPolicy
}

@MainActor
private func previewStore(_ screen: PreviewScreen, fullVersion: FullVersionStatus = .full) -> StoreOf<SettingsFeature> {
    var state = SettingsFeature.State()
    state.fullVersion = fullVersion
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

#Preview("Settings: locked") {
    SettingsView(store: previewStore(.settings, fullVersion: .free))
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
