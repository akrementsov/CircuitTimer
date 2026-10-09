import DesignSystem
import SwiftUI

/// Where a list row sits in its card: only the card's outer corners are rounded.
enum CardRowPosition {
    case top
    case middle
    case bottom
    case single

    /// The last row of a card also carries the gap to the next card.
    var endsCard: Bool {
        switch self {
            case .top, .middle: false
            case .bottom, .single: true
        }
    }
}

extension View {
    /// A list row drawn as one part of a card, edge to edge; the content sets its own padding.
    /// The last card of the list leaves no gap under it: nothing follows it.
    func cardRow(_ position: CardRowPosition, endsList: Bool = false) -> some View {
        let gap: CGFloat = position.endsCard && !endsList ? .token(spacing: .m) : .zero
        return padding(.bottom, gap)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(CardRowBackground(position: position, gap: gap))
    }

    /// A list row outside any card, on the screen color.
    func screenRow() -> some View {
        listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            // A plain list paints rows with the system background, and a clear color is not a token.
            .listRowBackground(Rectangle().fill(.surface(.screen)))
    }
}

/// The card's part behind one row. The gap under the last row stays unpainted, so the screen shows through it.
private struct CardRowBackground: View {
    let position: CardRowPosition
    let gap: CGFloat

    var body: some View {
        UnevenRoundedRectangle(cornerRadii: cornerRadii, style: .continuous)
            .fill(.surface(.card))
            .padding(.bottom, gap)
    }

    private var cornerRadii: RectangleCornerRadii {
        let radius: CGFloat = .token(radius: .m)
        let top: CGFloat = position == .top || position == .single ? radius : .zero
        let bottom: CGFloat = position.endsCard ? radius : .zero
        return RectangleCornerRadii(topLeading: top, bottomLeading: bottom, bottomTrailing: bottom, topTrailing: top)
    }
}
