import DesignSystem
import SwiftUI

struct SettingsSwitchCard: View {
    let title: Text
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            title
                .font(.token(.body))
                .foregroundStyle(.text(.primary))
                .lineLimit(2)
        }
        .tint(.switchOn)
        .padding(.horizontal, .token(spacing: .l))
        .padding(.vertical, .token(spacing: .s))
        .background(.surface(.card), in: RoundedRectangle(cornerRadius: .token(radius: .m), style: .continuous))
    }
}
