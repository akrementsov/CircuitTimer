import os
import SwiftUI
import UIKit

extension View {
    /// On a tab's navigation stack: a horizontal swipe on the stack's root turns to the next tab (`forward`, the finger
    /// moving left) or the previous one (`backward`), as a tap on it would. Pushed screens keep their own gestures. The
    /// swipe yields to the swipe and the lift of a row under the finger and never starts on a switch.
    public func onPageSwipe(
        forward: @escaping @MainActor () -> Void,
        backward: @escaping @MainActor () -> Void
    ) -> some View {
        background {
            PageSwipeProbe(forward: forward, backward: backward)
                .frame(width: 0, height: 0)
        }
    }
}

/// Where a pan would come to rest after the finger lifts: the share of a second the velocity carries it, as SwiftUI's
/// predicted translation roughly does.
enum PanProjection {
    static let duration: CGFloat = 0.25

    static func predictedEnd(translation: CGFloat, velocity: CGFloat) -> CGFloat {
        translation + velocity * duration
    }
}

enum PageSwipeDirection: Equatable {
    case forward
    case backward
}

/// A swipe turns the page when it would come to rest more than a third of the screen away, sideways.
enum PageSwipeDecision {
    static func direction(predictedEnd: CGSize, width: CGFloat) -> PageSwipeDirection? {
        guard width > .zero, abs(predictedEnd.width) > abs(predictedEnd.height), abs(predictedEnd.width) > width / 3 else {
            return nil
        }

        return predictedEnd.width < .zero ? .forward : .backward
    }
}

/// A zero-size view that puts a UIKit pan on its tab's view, which holds the navigation bar with its title and the whole
/// screen: a SwiftUI gesture on the root's content never reaches the bar.
private struct PageSwipeProbe: UIViewRepresentable {
    let forward: @MainActor () -> Void
    let backward: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> ProbeView {
        ProbeView(coordinator: context.coordinator)
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleUIView(_ view: ProbeView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PageSwipeProbe
        private let recognizer = UIPanGestureRecognizer()
        /// The tab's own controller, a child of the tab bar controller.
        private weak var tab: UIViewController?

        init(parent: PageSwipeProbe) {
            self.parent = parent
            super.init()
            recognizer.addTarget(self, action: #selector(handle))
            recognizer.delegate = self
        }

        func attach(from probe: UIView) {
            detach()
            guard let tab = Self.tabController(of: probe) else {
                Logger.designSystem.error("No tab around the page swipe; tabs switch only by tap")
                return
            }

            self.tab = tab
            tab.view.addGestureRecognizer(recognizer)
        }

        func detach() {
            recognizer.view?.removeGestureRecognizer(recognizer)
            tab = nil
        }

        /// The tab's stack root, while it is on top and nothing moves: a swipe never leaves a pushed screen or one being
        /// pushed or popped.
        private var restingRoot: UIViewController? {
            guard
                let navigation = tab.flatMap(Self.navigationController(in:)),
                let root = navigation.viewControllers.first,
                navigation.topViewController === root,
                navigation.transitionCoordinator == nil
            else { return nil }

            return root
        }

        @objc private func handle(_ recognizer: UIPanGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view, restingRoot != nil else { return }

            let translation = recognizer.translation(in: view)
            let velocity = recognizer.velocity(in: view)
            let predictedEnd = CGSize(
                width: PanProjection.predictedEnd(translation: translation.x, velocity: velocity.x),
                height: PanProjection.predictedEnd(translation: translation.y, velocity: velocity.y)
            )
            switch PageSwipeDecision.direction(predictedEnd: predictedEnd, width: view.bounds.width) {
                case .forward:
                    parent.forward()
                case .backward:
                    parent.backward()
                case nil:
                    break
            }
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // A switch slides under the finger; a numeric field moves its caret.
            guard let view = touch.view else { return true }

            return !view.isInsideNumericField && !sequence(first: view, next: \.superview).contains { $0 is UISwitch }
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer, restingRoot != nil else { return false }

            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }

        /// A row under the finger swipes or lifts first; the page turns only when neither takes the touch.
        func gestureRecognizer(
            _ recognizer: UIGestureRecognizer,
            shouldRequireFailureOf other: UIGestureRecognizer
        ) -> Bool {
            if other.delegate is ScrollViewLongPress.Coordinator {
                return true
            }
            if #available(iOS 18, *) {
                return other.delegate is HorizontalPanRecognizer.Coordinator
            }
            return false
        }

        private static func tabController(of view: UIView) -> UIViewController? {
            let nearest = sequence(first: view as UIResponder, next: \.next).lazy.compactMap { $0 as? UIViewController }.first
            guard let nearest else { return nil }

            return sequence(first: nearest, next: \.parent).first { $0.parent is UITabBarController }
        }

        private static func navigationController(in controller: UIViewController) -> UINavigationController? {
            if let navigation = controller as? UINavigationController {
                return navigation
            }
            return controller.children.lazy.compactMap(navigationController(in:)).first
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
            if window == nil {
                coordinator.detach()
            } else {
                coordinator.attach(from: self)
            }
        }
    }
}
