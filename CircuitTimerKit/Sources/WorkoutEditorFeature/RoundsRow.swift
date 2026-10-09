import DesignSystem
import SwiftUI
import WorkoutDomain

/// The training's rounds with − and + at the edges, like the original app's stepper.
struct RoundsRow: View {
    let rounds: Int
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: .token(spacing: .l)) {
            stepButton(systemImage: "minus.square.fill", isEnabled: rounds > 1) { onChange(rounds - 1) }
            Text("editor.rounds \(rounds)", bundle: .module)
                .font(.token(.body))
                .foregroundStyle(.text(.primary))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
            stepButton(systemImage: "plus.app.fill", isEnabled: rounds < WorkoutLimits.maxTrainingRounds) { onChange(rounds + 1) }
        }
        .padding(.horizontal, .token(spacing: .l))
        .padding(.vertical, .token(spacing: .l))
        .background(.surface(.field), in: RoundedRectangle(cornerRadius: .token(radius: .m), style: .continuous))
        // VoiceOver adjusts the whole row; the buttons are its visual parts.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("editor.rounds.label", bundle: .module))
        .accessibilityValue(Text("editor.rounds \(rounds)", bundle: .module))
        .accessibilityAdjustableAction { direction in
            switch direction {
                case .increment: onChange(rounds + 1)
                case .decrement: onChange(rounds - 1)
                @unknown default: break
            }
        }
    }

    private func stepButton(systemImage: String, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .imageScale(.large)
                .foregroundStyle(isEnabled ? .brand : .brandInactive)
        }
        .buttonStyle(.borderless)
        .disabled(!isEnabled)
    }
}
