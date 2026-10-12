import SwiftUI

extension View {
    /// A plain `List` of card rows on the screen color, inset from the screen's edges. Rows set their own heights
    /// and backgrounds with `cardRow(_:endsList:)` and `screenRow()`.
    public func cardList() -> some View {
        listStyle(.plain)
            .scrollIndicators(.hidden)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, .token(spacing: .m), for: .scrollContent)
            // Rows set their own heights; the system minimum would stretch the thin ones.
            .environment(\.defaultMinListRowHeight, .zero)
            // Rows are cut at the cards' sides, while the content still scrolls under the bars.
            .mask { Rectangle().ignoresSafeArea(edges: .vertical) }
            .padding(.horizontal, .token(spacing: .l))
            // Under the keyboard too: its rounded top corners would show the black window behind the screen.
            .background { Rectangle().fill(.surface(.screen)).ignoresSafeArea() }
    }
}
