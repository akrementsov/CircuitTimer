import SwiftUI

extension View {
    /// Fills the whole screen, centered content included, with the screen color and uses an inline title.
    /// The navigation bar stays the system one: Liquid Glass with the scroll edge effect on iOS 26,
    /// a translucent material over scrolled content before. Sets no tint: system alerts keep the accent color.
    /// Back buttons show only the chevron, like the legacy bar.
    public func screenChrome() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollContentBackground(.hidden)
            .background(.surface(.screen))
            .navigationBarTitleDisplayMode(.inline)
            .modifier(ChevronOnlyBackButton())
    }
}

private struct ChevronOnlyBackButton: ViewModifier {
    func body(content: Content) -> some View {
        // iOS 26 already draws a chevron-only back button, and the editor role there
        // would move the screen's title to the leading edge.
        if #available(iOS 26, *) {
            content
        } else {
            content.toolbarRole(.editor)
        }
    }
}
