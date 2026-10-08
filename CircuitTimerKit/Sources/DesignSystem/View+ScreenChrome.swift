import SwiftUI

extension View {
    /// Fills the whole screen, centered content included, with the screen color and uses an inline title.
    /// The navigation bar stays the system one: Liquid Glass with the scroll edge effect on iOS 26,
    /// a translucent material over scrolled content before. Sets no tint: system alerts keep the accent color.
    public func screenChrome() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollContentBackground(.hidden)
            .background(.surface(.screen))
            .navigationBarTitleDisplayMode(.inline)
    }
}
