import DesignSystem
import SwiftUI

/// A pause between sections: a switch while editing; read-only, only a pause that plays shows, its title centered and
/// no switch, like the original cell. The title slides between the center and the leading edge as the switch fades,
/// and the switch keeps its place, so the card keeps its height.
struct PauseCard: View {
    @Binding var isOn: Bool
    let isEditable: Bool
    let label: Text

    @State private var switchWidth: CGFloat = .zero

    var body: some View {
        EditorCard {
            HStack {
                Spacer(minLength: .zero)
                Toggle(isOn: $isOn) { label }
                    .labelsHidden()
                    .tint(.switchOn)
                    .accessibilityHint(Text("editor.pause.hint", bundle: .module))
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { switchWidth = $0 }
                    .opacity(isEditable ? 1 : 0)
                    .allowsHitTesting(isEditable)
                    .disabled(!isEditable)
                    .accessibilityHidden(!isEditable)
            }
            .overlay {
                label
                    .font(.token(.body))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: isEditable ? .leading : .center)
                    .padding(.trailing, isEditable ? switchWidth + .token(spacing: .xs) : .zero)
                    // Over the switch's row: taps go through to it.
                    .allowsHitTesting(false)
                    // The switch carries the title while editing.
                    .accessibilityHidden(isEditable)
            }
            .foregroundStyle(.text(.primary))
            .padding(.token(spacing: .l))
        }
    }
}
