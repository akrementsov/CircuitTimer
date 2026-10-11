import SwiftUI

/// A scroll view of cards whose rows swipe and reorder: it measures where the content and the visible area are, scrolls
/// by itself while a lifted row is held near an edge, closes an open swipe when the content scrolls or a gap is tapped,
/// and hands `interaction` to the rows inside. `content` gets the proxy for the screen's own scrolling.
public struct CardScrollView<ID: Hashable, Content: View>: View {
    let interaction: RowInteraction<ID>
    let topMargin: CGFloat
    let content: (ScrollViewProxy) -> Content

    public init(
        interaction: RowInteraction<ID>,
        topMargin: CGFloat,
        @ViewBuilder content: @escaping (ScrollViewProxy) -> Content
    ) {
        self.interaction = interaction
        self.topMargin = topMargin
        self.content = content
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                content(proxy)
                    .coordinateSpace(.named(RowContentSpace.name))
                    // A tap in a gap between the cards closes an open swipe too.
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        TapGesture().onEnded { interaction.closeSwipe() },
                        including: interaction.swipedID != nil ? .all : .subviews
                    )
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { contentMoved(to: $0) }
                    .background { AutoScrollDriver(velocity: interaction.autoScrollVelocity) }
            }
            .scrollIndicators(.hidden)
            .contentMargins(.top, topMargin, for: .scrollContent)
            // A lifted row owns the finger; the screen scrolls only by itself near an edge.
            .scrollDisabled(interaction.liftedID != nil)
            // The scroll view is laid out inside the safe area, between the bars and above the bottom panel and the
            // keyboard; its content only draws under them.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rect in
                interaction.visibleRect = rect
                interaction.geometry.visibleRect = rect
            }
        }
        .modifier(ScrolledBarBackground(isScrolled: interaction.isScrolled))
        .environment(interaction)
        .onChange(of: interaction.swipedID) { interaction.swipeAnchorMinY = interaction.geometry.contentFrame.minY }
    }

    private func contentMoved(to frame: CGRect) {
        interaction.geometry.contentFrame = frame
        // Scrolling closes an open swipe, as in the original app.
        if interaction.swipedID != nil, let anchor = interaction.swipeAnchorMinY, abs(frame.minY - anchor) > .token(spacing: .xs) {
            interaction.closeSwipe()
        }
        let isScrolled = frame.minY < interaction.geometry.visibleRect.minY + topMargin - 1
        if isScrolled != interaction.isScrolled {
            interaction.isScrolled = isScrolled
        }
    }
}

/// The scroll content of a `CardScrollView`: rows measured in it keep their frames while the screen scrolls.
enum RowContentSpace {
    static let name = "cardScrollContent"
}

/// Before iOS 26 the navigation bar turns translucent over scrolled content only for a list; over a scroll view with
/// the screen's background it stays clear and the title runs over the rows, so the screen turns the bar's background on
/// itself. iOS 26 draws its own scroll edge effect.
private struct ScrolledBarBackground: ViewModifier {
    let isScrolled: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
        } else {
            content.toolbarBackground(isScrolled ? .visible : .hidden, for: .navigationBar)
        }
    }
}
