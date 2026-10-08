import DesignSystem
import SwiftUI

public enum LegalDocument: Hashable, Sendable, CaseIterable {
    case privacyPolicy
    case userAgreement
}

// TODO: [CT-7] Write the legal texts before the first external build; the pages are empty, as in the design.
struct LegalDocumentView: View {
    let document: LegalDocument

    var body: some View {
        ScrollView {}
            .navigationTitle(document.title)
            .screenChrome()
    }
}

extension LegalDocument {
    var title: Text {
        switch self {
            case .privacyPolicy:
                Text("about.privacyPolicy", bundle: .module)
            case .userAgreement:
                Text("about.userAgreement", bundle: .module)
        }
    }
}
