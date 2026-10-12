import SwiftUI
import UIKit

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
}

/// Scrolls the enclosing scroll view by `velocity` points per frame while it isn't zero: a zero-size view inside the
/// content that moves the UIKit scroll view's offset on every display frame, kept within its ends. `scrollTo` with a
/// computed anchor can't do it: on iOS 17 a scroll view under a tab bar drops the anchor after a few frames and stops.
struct AutoScrollDriver: UIViewRepresentable {
    let velocity: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> ProbeView {
        ProbeView(coordinator: context.coordinator)
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        context.coordinator.velocity = velocity
    }

    static func dismantleUIView(_ view: ProbeView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var scrollView: UIScrollView?
        private var displayLink: CADisplayLink?
        private var lastTimestamp: CFTimeInterval?

        var velocity: CGFloat = .zero {
            didSet {
                if velocity == .zero {
                    stop()
                } else if displayLink == nil {
                    let link = CADisplayLink(target: self, selector: #selector(step))
                    link.add(to: .main, forMode: .common)
                    displayLink = link
                }
            }
        }

        func stop() {
            displayLink?.invalidate()
            displayLink = nil
            lastTimestamp = nil
        }

        @objc private func step(_ link: CADisplayLink) {
            // Points per frame at 60 frames a second, whatever the display's rate; a stalled main thread catches up
            // by a few frames at most instead of jumping.
            let frames = lastTimestamp.map { min(CGFloat((link.timestamp - $0) * 60), 3) } ?? 1
            lastTimestamp = link.timestamp
            guard let scrollView else { return }

            let inset = scrollView.adjustedContentInset
            let top = -inset.top
            let bottom = max(top, scrollView.contentSize.height + inset.bottom - scrollView.bounds.height)
            let offsetY = min(max(scrollView.contentOffset.y + velocity * frames, top), bottom)
            if offsetY != scrollView.contentOffset.y {
                scrollView.contentOffset.y = offsetY
            }
        }
    }

    final class ProbeView: UIView {
        private let coordinator: Coordinator

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("ProbeView is created in code only")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator.scrollView = sequence(first: superview) { $0?.superview }.lazy.compactMap { $0 as? UIScrollView }.first
        }
    }
}
