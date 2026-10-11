import SwiftUI

/// How fast the screen scrolls while a lifted row is held near the top or the bottom of the visible area, in points
/// per frame: negative scrolls up, positive down.
enum EdgeAutoScroll {
    static let maxStep: CGFloat = 8
    private static let levels: CGFloat = 4

    /// `fingerY` and `visibleRect` are in the global space; the visible rect leaves out the bars, the bottom panel and
    /// the keyboard, so a zone never hides behind them.
    static func velocity(fingerY: CGFloat, visibleRect: CGRect) -> CGFloat {
        let depth: CGFloat = .token(size: .row)
        guard visibleRect.height > depth * 2 else { return .zero }

        let intoTop = visibleRect.minY + depth - fingerY
        if intoTop > .zero {
            return -step(intoTop / depth)
        }
        let intoBottom = fingerY - (visibleRect.maxY - depth)
        if intoBottom > .zero {
            return step(intoBottom / depth)
        }
        return .zero
    }

    /// Deeper into a zone is faster, in a few steps, so the speed doesn't flicker with a trembling finger.
    private static func step(_ fraction: CGFloat) -> CGFloat {
        let level = (min(fraction, 1) * levels).rounded(.up)
        return maxStep * level / levels
    }
}

/// The content's place in the visible area of the scroll view, both in the global space.
struct ScrollContentGeometry: Equatable, Sendable {
    var contentFrame: CGRect = .zero
    var visibleRect: CGRect = .zero
    /// The scroll view's top content margin: `scrollTo` lines anchors up below it.
    var topMargin: CGFloat = .zero

    /// The anchor that scrolls the content by `step` points: `scrollTo` lines up the anchor's point in the content
    /// with the same point of the visible area under the top margin, and every anchor from 0 to 1 is a valid offset.
    func anchor(scrollingBy step: CGFloat) -> UnitPoint? {
        let overflow = visibleRect.height - topMargin - contentFrame.height
        guard overflow < .zero else { return nil }

        let top = contentFrame.minY - (visibleRect.minY + topMargin) - step
        return UnitPoint(x: 0.5, y: min(max(top / overflow, 0), 1))
    }
}

/// Scrolls by the interaction's velocity on every frame while it isn't zero, through `target`: the id of the whole
/// content. A timeline, because a view has no other clock that is not a task; `scrollTo` goes out from `onChange`,
/// never while the view is being built.
struct AutoScrollDriver<ID: Hashable, Target: Hashable>: View {
    let target: Target
    let interaction: RowInteraction<ID>
    let proxy: ScrollViewProxy

    var body: some View {
        let velocity = interaction.autoScrollVelocity
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: velocity == .zero)) { context in
            Rectangle()
                .fill(.surface(.screen))
                .opacity(0)
                .onChange(of: context.date) {
                    guard velocity != .zero, let anchor = interaction.geometry.anchor(scrollingBy: velocity) else { return }

                    proxy.scrollTo(target, anchor: anchor)
                }
        }
        .frame(width: .zero, height: .zero)
        .accessibilityHidden(true)
    }
}
