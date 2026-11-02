import DesignSystem
import SwiftUI

/// The iCloud switch without the full version: a dimmed switch that stays off, with a lock next to its title. A tap
/// asks for the purchase instead of switching, so it is a button for VoiceOver too.
struct SettingsLockedSwitchCard: View {
    let title: Text
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: .token(radius: .m), style: .continuous)
        Button(action: action) {
            HStack(spacing: .token(spacing: .xs)) {
                title
                    .font(.token(.body))
                    .foregroundStyle(.text(.primary))
                    .lineLimit(2)
                Image(systemName: "lock.fill")
                    .font(.token(.footnote))
                    .foregroundStyle(.text(.secondary))
                Spacer(minLength: .token(spacing: .m))
                // Drawn only: the card takes the tap.
                Toggle(isOn: .constant(false)) { EmptyView() }
                    .labelsHidden()
                    .tint(.switchOn)
                    .disabled(true)
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, .token(spacing: .l))
            .padding(.vertical, .token(spacing: .s))
            .background(.surface(.card), in: shape)
            .contentShape(shape)
        }
        .buttonStyle(.settingsCard)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(Text("settings.iCloud.locked.value", bundle: .module))
        .accessibilityHint(Text("settings.iCloud.locked.hint", bundle: .module))
        .accessibilityAddTraits(.isButton)
    }
}
