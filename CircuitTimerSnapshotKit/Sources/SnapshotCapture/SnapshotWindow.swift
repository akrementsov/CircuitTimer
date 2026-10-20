import Foundation
import UIKit

@MainActor
enum SnapshotWindow {
    // One startup budget for the process, including both mounts, without mutable shared state.
    private static let activationDeadline = ContinuousClock.now.advanced(by: .seconds(10))

    static func firstFrame(
        variant: SnapshotVariant,
        makeRoot: (SnapshotVariant) throws -> SnapshotRoot
    ) async throws -> (image: UIImage, succeeded: Bool) {
        try SnapshotViewport.validateRuntime(ProcessInfo.processInfo.operatingSystemVersion)
        let scene = try await activeScene()
        try SnapshotViewport.validateScene(size: scene.coordinateSpace.bounds.size, scale: scene.screen.scale)
        let root = try makeRoot(variant)
        let traits = variant.traits(over: SnapshotViewport.configuration.traits)
        let controller = root.controller
        controller.traitOverrides.userInterfaceStyle = .dark
        controller.traitOverrides.preferredContentSizeCategory = variant.textSize.contentSizeCategory
        controller.traitOverrides.horizontalSizeClass = traits.horizontalSizeClass
        controller.traitOverrides.verticalSizeClass = traits.verticalSizeClass
        controller.traitOverrides.displayScale = SnapshotViewport.scale

        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(frame: CGRect(origin: .zero, size: SnapshotViewport.size))
        defer {
            window.isHidden = true
            window.rootViewController = nil
            window.windowScene = nil
            previousKey?.makeKey()
        }
        window.overrideUserInterfaceStyle = .dark
        window.traitOverrides.userInterfaceStyle = .dark
        window.traitOverrides.preferredContentSizeCategory = variant.textSize.contentSizeCategory
        window.traitOverrides.horizontalSizeClass = traits.horizontalSizeClass
        window.traitOverrides.verticalSizeClass = traits.verticalSizeClass
        window.traitOverrides.displayScale = SnapshotViewport.scale
        window.windowScene = scene
        window.frame = CGRect(origin: .zero, size: SnapshotViewport.size)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        let tabBar = try prepareTabBar(root.tabBar, in: controller)

        await runLoopTurn()
        try Task.checkCancellation()
        window.layoutIfNeeded()
        try SnapshotViewport.validateSafeArea(window.safeAreaInsets)
        switch root.tabBar {
            case .none: break
            case .shown:
                guard tabBar?.isHidden == false else { throw SnapshotCaptureFailure("The tab bar must be shown.") }
            case .hidden:
                guard tabBar?.isHidden == true else { throw SnapshotCaptureFailure("The tab bar must be hidden.") }
        }
        var succeeded = false
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: UIGraphicsImageRendererFormat(for: traits)).image { _ in
            succeeded = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try SnapshotViewport.validateRaster(image.cgImage)
        return (image, succeeded)
    }

    private static func activeScene() async throws -> UIWindowScene {
        let deadline = activationDeadline
        while true {
            try Task.checkCancellation()
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) {
                return scene
            }
            guard ContinuousClock.now < deadline else {
                throw SnapshotCaptureFailure("No foreground-active window scene; the process's 10-second activation budget is exhausted.")
            }
            await runLoopTurn()
        }
    }

    private static func runLoopTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            RunLoop.main.perform { continuation.resume() }
        }
    }

    private static func prepareTabBar(_ expectation: TabBarExpectation, in root: UIViewController) throws -> UITabBar? {
        let depth: Int
        let hidden: Bool
        switch expectation {
            case .none: return nil
            case let .shown(selectedStackDepth): depth = selectedStackDepth; hidden = false
            case let .hidden(selectedStackDepth): depth = selectedStackDepth; hidden = true
        }
        guard let tab = descendant(UITabBarController.self, in: root), let selected = tab.selectedViewController,
              let navigation = descendant(UINavigationController.self, in: selected) else {
            throw SnapshotCaptureFailure("The snapshot root has no selected tab navigation stack.")
        }
        guard navigation.viewControllers.count == depth else {
            throw SnapshotCaptureFailure("Expected selected stack depth \(depth); got \(navigation.viewControllers.count).")
        }
        if hidden {
            if #available(iOS 18, *) {
                tab.setTabBarHidden(true, animated: false)
            } else {
                throw SnapshotCaptureFailure("Hiding the snapshot tab bar requires iOS 18 or later.")
            }
        }
        return tab.tabBar
    }

    private static func descendant<Controller: UIViewController>(_ type: Controller.Type, in parent: UIViewController) -> Controller? {
        if let match = parent as? Controller { return match }
        for child in parent.children {
            if let match = descendant(type, in: child) { return match }
        }
        return nil
    }
}
