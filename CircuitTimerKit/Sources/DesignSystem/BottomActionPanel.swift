import SwiftUI

/// An optional hint and a full-width action button floating over a screen's content:
/// Liquid Glass on iOS 26, the solid brand button with the original shadow before.
/// Place it with `bottomActionPanel(_:)`.
public struct BottomActionPanel: View {
    private let title: Text
    private let hint: Text?
    private let busyLabel: Text?
    private let isEnabled: Bool
    private let action: () -> Void

    public init(title: Text, hint: Text? = nil, isEnabled: Bool, action: @escaping () -> Void) {
        self.title = title
        self.hint = hint
        self.busyLabel = nil
        self.isEnabled = isEnabled
        self.action = action
    }

    /// A button that can be busy: a spinner replaces the title, and VoiceOver reads `busyLabel` instead.
    /// The caller keeps it disabled while it is busy.
    public init(title: Text, hint: Text? = nil, isBusy: Bool, busyLabel: Text, isEnabled: Bool, action: @escaping () -> Void) {
        self.title = title
        self.hint = hint
        self.busyLabel = isBusy ? busyLabel : nil
        self.isEnabled = isEnabled
        self.action = action
    }

    public var body: some View {
        VStack(spacing: .token(spacing: .xs)) {
            if let hint {
                hint
                    .font(.token(.footnote))
                    .foregroundStyle(.text(.secondary))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, .token(spacing: .m))
                    .padding(.vertical, .token(spacing: .xs))
                    // The hint floats over the cards too; it needs a backing to stay readable.
                    .floatingBacking(in: RoundedRectangle(cornerRadius: .token(radius: .m), style: .continuous))
            }
            Button(action: action) {
                if busyLabel != nil {
                    ProgressView()
                        .tint(.text(.onAccent))
                } else {
                    title
                }
            }
            .buttonStyle(ActionButtonStyle())
            .accessibilityLabel(busyLabel ?? title)
            // A busy button stays disabled, in the inactive color, behind its spinner: busy, not tappable.
            .disabled(!isEnabled)
        }
        .glassGroup()
        .padding(.horizontal, .token(spacing: .l))
        .padding(.top, .token(spacing: .m))
        .padding(.bottom, .token(spacing: .xs))
    }
}

extension View {
    /// Puts a bottom panel at the bottom of the screen, above the keyboard while a field is edited. A list scrolls
    /// under the panel, insets its content by it and scrolls a focused field above it; on iOS 26 with the system's
    /// scroll edge effect.
    public func bottomActionPanel<Panel: View>(@ViewBuilder _ panel: @escaping () -> Panel) -> some View {
        modifier(BottomActionPanelPlacement(panel: panel))
    }
}

private struct BottomActionPanelPlacement<Panel: View>: ViewModifier {
    let panel: () -> Panel

    func body(content: Content) -> some View {
        // Scrolling to a focused field brings only its text above the panel; the spacing keeps the field's own
        // padding and background clear of the button too.
        if #available(iOS 26, *) {
            content.safeAreaBar(edge: .bottom, spacing: .token(spacing: .xs), content: panel)
        } else {
            content.safeAreaInset(edge: .bottom, spacing: .token(spacing: .xs), content: panel)
        }
    }
}

private struct ActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ActionButton(configuration: configuration)
    }
}

/// Reads `isEnabled`, which a button style itself cannot.
private struct ActionButton: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: .token(radius: .m), style: .continuous)
        let label = configuration.label
            .font(.token(.button))
            .foregroundStyle(.text(.onAccent))
            .frame(maxWidth: .infinity, minHeight: .token(size: .row))
            .contentShape(shape)

        if #available(iOS 26, *) {
            // Interactive glass draws its own pressed state.
            label.glassEffect(.regular.tint(isEnabled ? .brand : .brandInactive).interactive(isEnabled), in: shape)
        } else {
            label
                .background(isEnabled ? .brand : .brandInactive, in: shape)
                .shadow(color: .surface(.screen).opacity(.token(opacity: .buttonShadow)), radius: .token(shadowRadius: .button))
                .opacity(configuration.isPressed ? .token(opacity: .pressed) : 1)
        }
    }
}

private extension View {
    /// On iOS 26 the hint and the button sample what is behind them together; with no spacing they stay separate
    /// plates instead of merging into one. There is no glass before iOS 26.
    @ViewBuilder
    func glassGroup() -> some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: .zero) { self }
        } else {
            self
        }
    }

    /// Glass on iOS 26, a material before it.
    @ViewBuilder
    func floatingBacking(in shape: some Shape) -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }
}
