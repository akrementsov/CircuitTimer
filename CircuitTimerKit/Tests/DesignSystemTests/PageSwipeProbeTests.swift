@testable import DesignSystem

import Testing
import UIKit

@MainActor
@Suite
struct PageSwipeProbeTests {
    @Test
    func test_attach_viewInsideTab_putsThePanOnTheTabsView() {
        let tabs = TabStack()
        let coordinator = makeCoordinator()

        coordinator.attach(from: tabs.probe)

        #expect(coordinator.recognizer.view === tabs.tab.view)
        #expect(PageSwipeProbe.Coordinator.navigationController(in: tabs.tab) === tabs.navigation)
    }

    @Test
    func test_attach_viewOutsideAnyTab_installsNothing() {
        let host = UIViewController()
        let probe = UIView()
        host.view.addSubview(probe)
        let coordinator = makeCoordinator()

        coordinator.attach(from: probe)

        #expect(coordinator.recognizer.view == nil)
        #expect(coordinator.restingRoot == nil)
    }

    @Test
    func test_detach_attached_removesThePan() {
        let tabs = TabStack()
        let coordinator = makeCoordinator()
        coordinator.attach(from: tabs.probe)

        coordinator.detach()

        #expect(coordinator.recognizer.view == nil)
        #expect(coordinator.restingRoot == nil)
    }

    @Test
    func test_restingRoot_rootOnTopOrPushed_isTheRootOnlyOnTop() {
        let tabs = TabStack()
        let coordinator = makeCoordinator()
        coordinator.attach(from: tabs.probe)
        #expect(coordinator.restingRoot === tabs.root)

        tabs.navigation.pushViewController(UIViewController(), animated: false)
        #expect(coordinator.restingRoot == nil)

        tabs.navigation.popViewController(animated: false)
        #expect(coordinator.restingRoot === tabs.root)
    }

    @Test(arguments: [false, true])
    func test_shouldReceive_switch_refusesTheTouch(touchesChild: Bool) {
        let toggle = UISwitch()
        let child = UIView()
        toggle.addSubview(child)
        let coordinator = makeCoordinator()

        let receives = coordinator.gestureRecognizer(
            UIPanGestureRecognizer(),
            shouldReceive: ViewTouch(view: touchesChild ? child : toggle)
        )

        #expect(!receives)
    }

    @Test
    func test_shouldReceive_numericField_refusesTheTouch() {
        let coordinator = makeCoordinator()

        #expect(!coordinator.gestureRecognizer(UIPanGestureRecognizer(), shouldReceive: ViewTouch(view: NativeNumericField())))
    }

    @Test
    func test_shouldReceive_plainView_takesTheTouch() {
        let coordinator = makeCoordinator()

        #expect(coordinator.gestureRecognizer(UIPanGestureRecognizer(), shouldReceive: ViewTouch(view: UIView())))
    }

    private func makeCoordinator() -> PageSwipeProbe.Coordinator {
        PageSwipeProbe(forward: {}, backward: {}).makeCoordinator()
    }
}

/// A tab bar controller whose tab holds a navigation stack, as SwiftUI builds one, with a probe in the tab's view.
@MainActor
private struct TabStack {
    let tabBar = UITabBarController()
    let tab = UIViewController()
    let root = UIViewController()
    let navigation: UINavigationController
    let probe = UIView()

    init() {
        navigation = UINavigationController(rootViewController: root)
        tab.addChild(navigation)
        tab.view.addSubview(navigation.view)
        navigation.didMove(toParent: tab)
        tab.view.addSubview(probe)
        tabBar.viewControllers = [tab]
    }
}

private final class ViewTouch: UITouch {
    private let touchedView: UIView

    init(view: UIView) {
        touchedView = view
        super.init()
    }

    override var view: UIView? { touchedView }
}
