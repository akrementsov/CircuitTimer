import ComposableArchitecture
import DesignSystem
import SwiftUI

@ViewAction(for: SettingsFeature.self)
public struct SettingsView: View {
    @Bindable public var store: StoreOf<SettingsFeature>

    public init(store: StoreOf<SettingsFeature>) {
        self.store = store
    }

    public var body: some View {
        NavigationStack(path: $store.scope(\.path, action: \.path)) {
            SettingsScroll {
                Button {
                    send(.aboutTapped)
                } label: {
                    SettingsCard(Text("settings.about", bundle: .module), style: .active)
                }
                .buttonStyle(.settingsCard)
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
