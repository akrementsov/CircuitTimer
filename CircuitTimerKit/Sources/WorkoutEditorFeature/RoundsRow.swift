import DesignSystem
import SwiftUI

/// The training's rounds with − and + at the edges, like the original app's stepper.
struct RoundsRow: View {
    let rounds: Int
    let range: ClosedRange<Int>
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: .token(spacing: .l)) {
            stepButton(systemImage: "minus.square.fill", isEnabled: rounds > range.lowerBound) { onChange(rounds - 1) }
            Text("editor.rounds \(rounds)", bundle: .module)
                .font(.token(.body))
                .foregroundStyle(.text(.primary))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
            stepButton(systemImage: "plus.app.fill", isEnabled: rounds < range.upperBound) { onChange(rounds + 1) }
        }
        .padding(.token(spacing: .l))
        .background(.surface(.field), in: RoundedRectangle(cornerRadius: .token(radius: .m), style: .continuous))
        // VoiceOver adjusts the whole row; the buttons are its visual parts.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("editor.rounds.label", bundle: .module))
        .accessibilityValue(Text("editor.rounds \(rounds)", bundle: .module))
        // Past a limit nothing is sent, as with the disabled buttons: a send would still end the editing of a field.
        .accessibilityAdjustableAction { direction in
            switch direction {
                case .increment where rounds < range.upperBound: onChange(rounds + 1)
                case .decrement where rounds > range.lowerBound: onChange(rounds - 1)
                default: break
            }
        }
    }

    private func stepButton(systemImage: String, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .imageScale(.large)
                // A black sign on the square, as in the design, instead of a cut-out showing the row behind it.
                .symbolRenderingMode(.palette)
                .foregroundStyle(.text(.onAccent), isEnabled ? .brand : .brandInactive)
        }
        .buttonStyle(.borderless)
        .disabled(!isEnabled)
    }
}
