import DesignSystem
import SwiftUI

/// Cards 12 apart with 12 above the first and below the last, as the legacy screens lay them out.
struct SettingsScroll<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: .token(spacing: .m)) {
                content
            }
            .padding(.horizontal, .token(spacing: .l))
        }
        .contentMargins(.vertical, .token(spacing: .m), for: .scrollContent)
        .scrollIndicators(.hidden)
    }
}
