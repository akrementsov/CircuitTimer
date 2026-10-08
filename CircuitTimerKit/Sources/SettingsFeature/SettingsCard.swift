import DesignSystem
import SwiftUI

/// A legacy settings cell: a full-width rounded card with up to two lines of text and no accessory.
struct SettingsCard: View {
    enum Style {
        case active
        /// Information that cannot be tapped.
        case inactive
    }

    let title: Text
    let style: Style

    init(_ title: Text, style: Style) {
        self.title = title
        self.style = style
    }

    var body: some View {
        title
            .font(.token(.body))
            .lineLimit(2)
            .truncationMode(.tail)
            .foregroundStyle(foreground)
            .padding(.token(spacing: .l))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: .token(radius: .m), style: .continuous))
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

/// Cards 12 apart with 12 above the first and below the last, as the legacy screens lay them out.
struct SettingsScroll<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: .token(spacing: .m)) {
                content
            }
            .padding(.horizontal, .token(spacing: .l))
        }
        .contentMargins(.vertical, .token(spacing: .m), for: .scrollContent)
        .scrollIndicators(.hidden)
    }
}
