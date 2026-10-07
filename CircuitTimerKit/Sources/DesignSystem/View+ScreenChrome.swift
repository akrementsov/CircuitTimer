import SwiftUI

extension View {
    /// Fills the whole screen, centered content included, with the screen color, and paints the
    /// navigation bar area with the same color so scrolled content never shows through the bar.
    /// Sets no tint: system alerts keep the accent color.
    public func screenChrome() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollContentBackground(.hidden)
            .background(.surface(.screen))
            // A visible bar background draws a hairline under the bar before iOS 26, and SwiftUI cannot
            // remove it; the bar background stays hidden and this strip covers the bar area instead.
            .overlay(alignment: .top) {
                // A zero-height anchor at the top of the content; its background grows up through the bar.
                Rectangle()
                    .fill(.clear)
                    .frame(height: .zero)
                    .background(alignment: .bottom) {
                        Rectangle()
                            .fill(.surface(.screen))
                            .ignoresSafeArea(edges: .top)
                    }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
    }
}
