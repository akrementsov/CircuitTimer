import DesignSystem
import SwiftUI

/// Empty until the texts are written, as in the design.
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
