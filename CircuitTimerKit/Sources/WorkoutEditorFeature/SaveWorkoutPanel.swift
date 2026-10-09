import DesignSystem
import SwiftUI

// TODO: [CT-3] Move the panel and its button style to DesignSystem together with Start workout, their second user;
// TitleAndTimeRow and the card rows go with them, and the hint's material, the shadow radius and the pressed
// opacity become tokens.
/// The save hint and the full-width Save workout button, floating over the editor's content:
/// Liquid Glass on iOS 26, the solid brand button with the original shadow before.
struct SaveWorkoutPanel: View {
    let showsHint: Bool
    let isSaving: Bool
    let canSave: Bool
    let onSave: () -> Void

    var body: some View {
        VStack(spacing: .token(spacing: .xs)) {
            if showsHint {
                Text("editor.saveHint", bundle: .module)
                    .font(.token(.footnote))
                    .foregroundStyle(.text(.secondary))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, .token(spacing: .m))
                    .padding(.vertical, .token(spacing: .xs))
                    // The hint floats over the cards too; it needs a backing to stay readable.
                    .floatingBacking(in: RoundedRectangle(cornerRadius: .token(radius: .m), style: .continuous))
            }
            Button(action: onSave) {
                if isSaving {
                    ProgressView()
                        .tint(.text(.onAccent))
                } else {
                    Text("editor.saveWorkout", bundle: .module)
                }
            }
            .buttonStyle(SaveWorkoutButtonStyle())
            // The spinner replaces the title while saving; VoiceOver says what is going on instead.
            .accessibilityLabel(isSaving ? Text("editor.saving", bundle: .module) : Text("editor.saveWorkout", bundle: .module))
            // Saving keeps the button disabled, in the inactive color, behind its spinner: busy, not tappable.
            .disabled(!canSave)
        }
        .glassGroup()
        .padding(.horizontal, .token(spacing: .l))
        .padding(.top, .token(spacing: .m))
        .padding(.bottom, .token(spacing: .xs))
    }
}

private struct SaveWorkoutButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SaveWorkoutButton(configuration: configuration)
    }
}

/// Reads `isEnabled`, which a button style itself cannot.
private struct SaveWorkoutButton: View {
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
                // The original button's shadow: the screen color at half opacity.
                .shadow(color: .surface(.screen).opacity(0.5), radius: Self.shadowRadius)
                .opacity(configuration.isPressed ? Self.pressedOpacity : 1)
        }
    }

    private static let shadowRadius: CGFloat = 5
    /// A pressed button dims a little, like a system button's highlight.
    private static let pressedOpacity = 0.8
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
