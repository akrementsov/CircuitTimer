import ComposableArchitecture
import DesignSystem
import SwiftUI

@ViewAction(for: SettingsFeature.self)
struct AboutView: View {
    let store: StoreOf<SettingsFeature>
    let version: String?

    var body: some View {
        SettingsScroll {
            ForEach(LegalDocument.allCases, id: \.self) { document in
                Button {
                    send(.legalDocumentTapped(document))
                } label: {
                    SettingsCard(document.title, style: .active)
                }
                .buttonStyle(.settingsCard)
            }
            SettingsCard(Text("about.version \(version ?? Self.missingVersion)", bundle: .module), style: .inactive)
                // Legacy puts the version section 24 below the legal cards; the stack already adds 12.
                .padding(.top, .token(spacing: .m))
        }
        .navigationTitle(Text("settings.about", bundle: .module))
        .screenChrome()
    }

    private static let missingVersion = "—"
}
