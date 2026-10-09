import DesignSystem
import SwiftUI

/// The bottom panel with the save hint and the full-width Save workout button, on a blur like the original app's.
/// Moves to DesignSystem together with Start workout (CT-3), its second user.
struct SaveWorkoutPanel: View {
    let showsHint: Bool
    let isSaving: Bool
    let canSave: Bool
    let onSave: () -> Void
    let onEscape: () -> Void

    var body: some View {
        VStack(spacing: .token(spacing: .xs)) {
            if showsHint {
                Text("editor.saveHint", bundle: .module)
                    .font(.token(.footnote))
                    .foregroundStyle(.text(.secondary))
                    .multilineTextAlignment(.center)
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
            .disabled(!canSave)
            // The original button's shadow: the screen color at half opacity.
            .shadow(color: .surface(.screen).opacity(0.5), radius: Self.shadowRadius)
        }
        .padding(.horizontal, .token(spacing: .l))
        .padding(.top, .token(spacing: .m))
        .padding(.bottom, .token(spacing: .xs))
        .background {
            Rectangle()
                .fill(.regularMaterial)
                .opacity(0.8)
                .ignoresSafeArea(edges: .bottom)
        }
        .accessibilityAction(.escape, onEscape)
    }

    private static let shadowRadius: CGFloat = 5
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
        configuration.label
            .font(.token(.button))
            .foregroundStyle(.text(.onAccent))
            .frame(maxWidth: .infinity, minHeight: .token(size: .row))
            .background(isEnabled ? .brand : .brandInactive, in: RoundedRectangle(cornerRadius: .token(radius: .m), style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
