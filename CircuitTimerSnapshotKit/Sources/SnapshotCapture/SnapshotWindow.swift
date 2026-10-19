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
        let version = ProcessInfo.processInfo.operatingSystemVersion
        guard version.majorVersion == 27, version.minorVersion == 0, version.patchVersion == 0 else {
            throw SnapshotCaptureFailure("Snapshots require the iOS 27.0 simulator.")
        }
        let scene = try await activeScene()
        guard scene.coordinateSpace.bounds.size == SnapshotViewport.size, scene.screen.scale == SnapshotViewport.scale else {
            throw SnapshotCaptureFailure("Snapshots require a 402×874 pt scene at 3x.")
        }
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
        guard window.safeAreaInsets == SnapshotViewport.safeArea else {
            throw SnapshotCaptureFailure("Snapshots require safe area insets of 62/34 pt; got \(window.safeAreaInsets).")
        }
        switch root.tabBar {
            case .none: break
            case .shown:
                guard tabBar?.isHidden == false else { throw SnapshotCaptureFailure("The tab bar must be shown.") }
            case .hidden:
                guard tabBar?.isHidden == true else { throw SnapshotCaptureFailure("The tab bar must be hidden.") }
        }
        var succeeded = false
        let format = UIGraphicsImageRendererFormat(for: traits)
        if ProcessInfo.processInfo.environment["SNAPSHOT_RASTER_STANDARD_RANGE"] == "1" {
            format.preferredRange = .standard
        }
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            succeeded = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let raster = image.cgImage, raster.width == Int(SnapshotViewport.pixelSize.width),
              raster.height == Int(SnapshotViewport.pixelSize.height) else {
            throw SnapshotCaptureFailure("The snapshot raster must be 1206×2622 px.")
        }
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
                throw SnapshotCaptureFailure("No foreground-active window scene within the process's 10-second startup budget.")
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
