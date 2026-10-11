import SwiftUI

/// The row interactions of one screen of cards: the swiped row, the lifted row and the scroll geometry they read. A
/// screen owns one and hands it to its `CardScrollView`, which passes it down to `ReorderableRows`.
@MainActor
@Observable
public final class RowInteraction<ID: Hashable> {
    /// The row whose plaques are open; at most one at a time.
    public var swipedID: ID?
    /// The row a long press lifted.
    public internal(set) var liftedID: ID?
    /// The scroll view's visible area in the global space: between the bars, above the bottom panel and the keyboard.
    public internal(set) var visibleRect: CGRect = .zero

    /// Points per frame the screen scrolls by itself while a lifted row is held near an edge.
    var autoScrollVelocity: CGFloat = .zero
    var isScrolled = false
    /// Read only when the screen scrolls by itself; written on every scrolled frame without redrawing anything.
    @ObservationIgnored var geometry = ScrollContentGeometry()
    /// Where the content was when a swipe opened; scrolling away from it closes the swipe.
    @ObservationIgnored var swipeAnchorMinY: CGFloat?

    public init() {}

    /// Open while `id` is the swiped row; opening it closes any other.
    public func swipeBinding(for id: ID) -> Binding<Bool> {
        Binding(
            get: { self.swipedID == id },
            set: { isOpen in
                if isOpen {
                    self.swipedID = id
                } else if self.swipedID == id {
                    self.swipedID = nil
                }
            }
        )
    }

    public func closeSwipe() {
        guard swipedID != nil else { return }

        withAnimation(.snappy(duration: 0.25)) { swipedID = nil }
    }
}
