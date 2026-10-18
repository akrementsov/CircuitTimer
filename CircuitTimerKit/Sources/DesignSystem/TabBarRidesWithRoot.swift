import os
import SwiftUI
import UIKit

/// On iOS 26 the tab bar leaves with the stack's root screen, as a UIKit push carries it away. A zero-size child of
/// the root screen pins a picture of the bar to the root's view when a push starts, so it slides out with the root and
/// back in on the pop, and hides the real bar through UIKit. The glass bar glows when it shows and settles for a moment
/// after it moves, so the picture covers it until it is still.
@available(iOS 26, *)
struct TabBarRidesWithRoot: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Probe {
        Probe()
    }

    func updateUIViewController(_ controller: Probe, context: Context) {}

    final class Probe: UIViewController {
        /// How long the bar's glass takes to settle after it shows or moves.
        private static let glassSettleDuration: TimeInterval = 0.7
        /// The real bar draws on the next frame; the picture covers its place until then.
        private static let nextFrameDelay: TimeInterval = 0.05
        /// How far above the bar the list's scroll edge effect reaches; it also settles after the bar shows.
        private static let edgeEffectReach: CGFloat = 72

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

            defer { root.tabBarController?.setTabBarHidden(true, animated: false) }
            // A push right after a pop finds the last picture still over the settling bar; it belongs to that pop.
            removeSnapshot()
            guard let tabBar = root.tabBarController?.tabBar, let window = root.view.window else { return }

            // From the window: a view snapshot leaves the bar's glass out.
            let barFrame = tabBar.convert(tabBar.bounds, to: window)
            let top = barFrame.minY - Self.edgeEffectReach
            let frame = CGRect(x: 0, y: top, width: window.bounds.width, height: window.bounds.maxY - top)
            guard let image = window.resizableSnapshotView(from: frame, afterScreenUpdates: false, withCapInsets: .zero) else {
                Logger.designSystem.error("No picture of the tab bar; it fades in place on this push")
                return
            }

            image.frame = window.convert(frame, to: root.view)
            // Over the real bar for a moment after the pop; taps go through to it.
            image.isUserInteractionEnabled = false
            // In the root's own view, which the push moves. UIKit warns about a snapshot in a hosting controller's view;
            // accepted, as the picture must ride with the root.
            root.view.addSubview(image)
            snapshot = image
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            guard
                let tabBarController = rootController?.tabBarController,
                let coordinator = transitionCoordinator,
                snapshot != nil,
                // A pop under a full-screen cover: lifted onto the window, the picture would show over the cover.
                !Self.isCovered(tabBarController)
            else {
                finish()
                return
            }

            // The bar shows at once but off screen, where its appearing glow goes unseen, while the picture rides in
            // with the root. When the root lands, the bar steps into place under the picture, lifted onto the window
            // until the bar's glass settles from the jump.
            let tabBar = tabBarController.tabBar
            tabBarController.setTabBarHidden(false, animated: false)
            tabBar.transform = CGAffineTransform(translationX: -3 * tabBar.bounds.width, y: 0)
            coordinator.animate(alongsideTransition: nil) { [weak self] context in
                guard let self else { return }

                if context.isCancelled {
                    tabBar.transform = .identity
                    tabBarController.setTabBarHidden(true, animated: false)
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

        private static func isCovered(_ controller: UIViewController) -> Bool {
            guard let presented = controller.presentedViewController else { return false }

            return presented.modalPresentationStyle == .fullScreen || presented.modalPresentationStyle == .overFullScreen
        }

        private func finish() {
            rootController?.tabBarController?.setTabBarHidden(false, animated: false)
            perform(#selector(removeSnapshot), with: nil, afterDelay: Self.nextFrameDelay)
        }

        @objc private func removeSnapshot() {
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(removeSnapshot), object: nil)
            snapshot?.removeFromSuperview()
            snapshot = nil
        }
    }
}
