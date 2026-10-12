import SwiftUI
import UIKit

/// On iOS 26 the tab bar leaves with the stack's root screen, as a UIKit push carries it away. A zero-size child of the root screen pins a
/// picture of the bar to the root's view when a push starts, so it slides out with the root and back in on the pop,
/// and hides the real bar through UIKit. The glass bar glows when it shows and settles for a moment after it moves, so
/// the picture covers it until it is still.
struct TabBarRidesWithRoot: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Probe {
        Probe()
    }

    func updateUIViewController(_ controller: Probe, context: Context) {}

    final class Probe: UIViewController {
        private var snapshot: UIView?

        /// The root screen's controller: the probe's ancestor the navigation controller holds.
        private var rootController: UIViewController? {
            var current: UIViewController? = self
            while let controller = current, !(controller.parent is UINavigationController) {
                current = controller.parent
            }
            return current
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            // Only a push: a tab switch hides the root too, but leaves it on top of its stack.
            guard let root = rootController, let navigation = root.navigationController, navigation.topViewController !== root
            else { return }

            defer { setTabBarHidden(true) }
            guard let tabBar = root.tabBarController?.tabBar, snapshot == nil, let window = root.view.window else { return }

            // From the window: a view snapshot leaves the bar's glass out. The picture reaches above the bar over the
            // list's scroll edge effect, which also settles after the bar shows.
            let barFrame = tabBar.convert(tabBar.bounds, to: window)
            let top = barFrame.minY - Self.edgeEffectReach
            let frame = CGRect(x: 0, y: top, width: window.bounds.width, height: window.bounds.maxY - top)
            guard let image = window.resizableSnapshotView(from: frame, afterScreenUpdates: false, withCapInsets: .zero) else { return }

            image.frame = window.convert(frame, to: root.view)
            // Over the real bar for a moment after the pop; taps go through to it.
            image.isUserInteractionEnabled = false
            root.view.addSubview(image)
            snapshot = image
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            guard let coordinator = transitionCoordinator, snapshot != nil, let tabBar = rootController?.tabBarController?.tabBar
            else {
                finish()
                return
            }

            // The bar shows at once but off screen, where its appearing glow goes unseen, while the picture rides in
            // with the root. When the root lands, the bar steps into place under the picture, lifted onto the window
            // until the bar's glass settles from the jump.
            setTabBarHidden(false)
            tabBar.transform = CGAffineTransform(translationX: -3 * tabBar.bounds.width, y: 0)
            coordinator.animate(alongsideTransition: nil) { [weak self] context in
                guard let self else { return }

                if context.isCancelled {
                    tabBar.transform = .identity
                    setTabBarHidden(true)
                    return
                }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                if let snapshot, let window = view.window, let superview = snapshot.superview {
                    snapshot.frame = superview.convert(snapshot.frame, to: window)
                    window.addSubview(snapshot)
                }
                tabBar.transform = .identity
                CATransaction.commit()
                perform(#selector(removeSnapshot), with: nil, afterDelay: Self.glassSettleDuration)
            }
        }

        private static var glassSettleDuration: TimeInterval { 0.7 }
        private static var edgeEffectReach: CGFloat { 72 }

        private func finish() {
            setTabBarHidden(false)
            removeSnapshotSoon()
        }

        /// The real bar draws on the next frame; the picture covers its place until then.
        private func removeSnapshotSoon() {
            perform(#selector(removeSnapshot), with: nil, afterDelay: 0.05)
        }

        @objc private func removeSnapshot() {
            snapshot?.removeFromSuperview()
            snapshot = nil
        }

        private func setTabBarHidden(_ isHidden: Bool) {
            guard let tabBarController = rootController?.tabBarController else { return }

            if #available(iOS 18, *) {
                tabBarController.setTabBarHidden(isHidden, animated: false)
            } else {
                tabBarController.tabBar.isHidden = isHidden
            }
        }
    }
}
