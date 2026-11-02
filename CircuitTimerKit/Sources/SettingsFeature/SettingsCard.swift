import DesignSystem
import SwiftUI

/// A legacy settings cell: a full-width rounded card with up to two lines of text and, optionally, a value at the
/// trailing edge.
struct SettingsCard: View {
    enum Style {
        case active
        /// Information that cannot be tapped.
        case inactive
    }

    let title: Text
    let value: Text?
    let style: Style

    init(_ title: Text, value: Text? = nil, style: Style) {
        self.title = title
        self.value = value
        self.style = style
    }

    var body: some View {
        HStack(spacing: .token(spacing: .m)) {
            title
                .lineLimit(2)
                .truncationMode(.tail)
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let value {
                value
                    .foregroundStyle(.text(.secondary))
            }
        }
        .font(.token(.body))
        .padding(.token(spacing: .l))
        .background(background, in: RoundedRectangle(cornerRadius: .token(radius: .m), style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var foreground: Color {
        switch style {
            case .active:
                .text(.primary)
            case .inactive:
                .text(.secondary)
        }
    }

    private var background: Color {
        switch style {
            case .active:
                .surface(.card)
            case .inactive:
                .surface(.cardInactive)
        }
    }
}

/// The card does not dim while pressed, like the legacy cell.
struct SettingsCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

extension ButtonStyle where Self == SettingsCardButtonStyle {
    static var settingsCard: Self { SettingsCardButtonStyle() }
}
