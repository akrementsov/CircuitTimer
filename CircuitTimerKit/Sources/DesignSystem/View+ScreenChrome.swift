import SwiftUI

extension View {
    /// Fills the whole screen, centered content included, with the screen color under an opaque
    /// navigation bar of the same color, so scrolled content never shows through the bar.
    /// Sets no tint: system alerts keep the accent color.
    public func screenChrome() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollContentBackground(.hidden)
            .background(.surface(.screen))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.surface(.screen), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
    }
}
