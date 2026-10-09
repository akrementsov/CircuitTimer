import SwiftUI

extension DesignSystem.Token {
    /// Text sized from the box the layout gives it, like the original app's timer; it does not follow Dynamic Type.
    public enum DisplayTypography: Sendable, CaseIterable {
        /// The time left in the workout: SF compressed.
        case totalClock
        /// A stage name on a timer card: SF bold.
        case stageName
    }
}

extension Font {
    /// `.font(.token(.stageName, fitting: proxy.size))`
    public static func token(_ style: DesignSystem.Token.DisplayTypography, fitting box: CGSize) -> Font {
        let size = style.pointSize(fitting: box)
        return switch style {
            case .totalClock:
                .system(size: size, weight: .regular).width(.compressed)
            case .stageName:
                .system(size: size, weight: .bold)
        }
    }
}

extension DesignSystem.Token.DisplayTypography {
    /// The original app's ratios to the box height; 1.19336 em is the line height of the system font.
    func pointSize(fitting box: CGSize) -> CGFloat {
        switch self {
            case .totalClock:
                box.height * 1.69369 / 1.19336
            case .stageName:
                box.height / 1.19336
        }
    }
}
