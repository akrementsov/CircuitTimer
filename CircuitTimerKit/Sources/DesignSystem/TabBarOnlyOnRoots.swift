import SwiftUI

extension View {
    /// For a `TabView` whose navigation stacks show the tab bar only on their roots, together with
    /// `tabBarOnlyOnRoot(isPushed:)` on each root. Measured outside the tabs, the screen's own bottom inset reaches the
    /// pushed screens, where a bottom panel stands on it before iOS 26; no root has a bottom panel.
    public func tabBarOnlyOnRoots() -> some View {
        modifier(ScreenBottomInsetProvider())
    }

    /// For a navigation stack's root inside a tab: the tab bar shows only there, as in the original app, and leaves and
    /// comes back with the root. `isPushed` is whether the stack holds a screen above the root.
    public func tabBarOnlyOnRoot(isPushed: Bool) -> some View {
        modifier(TabBarOnlyOnRoot(isPushed: isPushed))
    }
}

extension EnvironmentValues {
    /// The screen's own bottom inset, the home indicator's, for a bottom panel on a pushed screen without the tab bar.
    /// `nil` leaves the panel on the safe area.
    @Entry var bottomPanelBaseInset: CGFloat?
}

private struct ScreenBottomInsetProvider: ViewModifier {
    @State private var screenBottomInset: CGFloat = .zero

    func body(content: Content) -> some View {
        content
            .environment(\.bottomPanelBaseInset, screenBottomInset)
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { screenBottomInset = $0 }
    }
}

private struct TabBarOnlyOnRoot: ViewModifier {
    let isPushed: Bool

    @State private var isHidden = false

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            // SwiftUI's tab bar ignores `hidesBottomBarWhenPushed` here and fades in place when hidden.
            content.background {
                TabBarRidesWithRoot()
                    .frame(width: 0, height: 0)
            }
        } else {
            // Hidden from the root, not by the pushed screen: hidden there, it would come back only after a pop. In
            // its own transaction, so a push that waits for a pending write hides the bar smoothly too.
            content
                .toolbar(isHidden ? .hidden : .visible, for: .tabBar)
                .onChange(of: isPushed, initial: true) { _, isPushed in
                    withAnimation(.default) { isHidden = isPushed }
                }
        }
    }
}
