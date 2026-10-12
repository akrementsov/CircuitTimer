import DesignSystem
import SwiftUI

/// The training's rounds with − and + at the edges, like the original app's stepper. Read-only the signs fade out and
/// the row takes the inactive field color, like the original cell.
struct RoundsRow: View {
    let rounds: Int
    let range: ClosedRange<Int>
    let isEditable: Bool
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
        // The plaque moves with the row, and only its color switches at once, like the original cell's.
        .background {
            RoundedRectangle(cornerRadius: .token(radius: .m), style: .continuous)
                .animation(nil) { $0.foregroundStyle(isEditable ? .surface(.field) : .surface(.fieldInactive)) }
        }
        .contentTransition(.identity)
        // Assistive technologies get one system stepper instead of the row's parts: the − and + glyphs would
        // otherwise surface under their symbol names. Past a limit nothing is sent, as with the disabled buttons:
        // a send would still end the editing of a field. Read-only, the count alone. The branch is inside the
        // representation, so the row itself stays the same view in both phases.
        .accessibilityRepresentation {
            if isEditable {
                Stepper(value: Binding(get: { rounds }, set: { if $0 != rounds { onChange($0) } }), in: range) {
                    Text("editor.rounds.label", bundle: .module)
                }
                .accessibilityValue(Text("editor.rounds \(rounds)", bundle: .module))
            } else {
                Text("editor.rounds \(rounds)", bundle: .module)
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
        // Hidden but kept in the layout, so the row keeps its height when the screen turns editable.
        .opacity(isEditable ? 1 : 0)
        .allowsHitTesting(isEditable)
    }
}
