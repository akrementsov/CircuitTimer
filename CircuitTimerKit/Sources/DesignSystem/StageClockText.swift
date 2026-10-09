import CoreText
import os
import SwiftUI
import UIKit

/// The stage clock, `01:15`, or a countdown digit, as large as the offered box allows.
///
/// The digits are fitted to the box rather than following Dynamic Type: the clock is the timer's main content and
/// already fills its card. The text stays put while the seconds change, and its cap centre sits on the box centre.
public struct StageClockText: View {
    enum Face {
        case leagueGothic
        case system
    }

    private let text: String
    private let face: Face

    public init(_ text: String) {
        self.init(text, face: .current)
    }

    init(_ text: String, face: Face) {
        self.text = text
        self.face = face
    }

    public var body: some View {
        GeometryReader { proxy in
            let metrics = face.metrics
            let size = metrics.fontSize(fitting: proxy.size)
            // The visible text hangs from the leading edge of a centred template that changes only with the
            // minutes, so the clock does not shift every second.
            Text(template)
                .lineLimit(1)
                .fixedSize()
                .hidden()
                .overlay(alignment: .leading) {
                    Text(text)
                        .lineLimit(1)
                        .fixedSize()
                }
                .font(face.font(size: size))
                .alignmentGuide(VerticalAlignment.center) { $0[.firstTextBaseline] - size * metrics.capHeight / 2 }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The minutes repeated, `01:01` for `01:15`, or the text itself when it has no colon.
    private var template: String {
        guard let colon = text.firstIndex(of: ":") else { return text }

        let minutes = text[..<colon]
        return "\(minutes):\(minutes)"
    }
}

extension StageClockText.Face {
    /// League Gothic when CoreText finds the registered font by name; the system face otherwise.
    static var current: Self {
        leagueGothicMetrics == nil ? .system : .leagueGothic
    }

    var metrics: ClockFaceMetrics {
        switch self {
            case .leagueGothic:
                Self.leagueGothicMetrics ?? Self.systemMetrics
            case .system:
                Self.systemMetrics
        }
    }

    func font(size: CGFloat) -> Font {
        switch self {
            case .leagueGothic:
                .custom(LeagueGothic.postScriptName, fixedSize: size)
            case .system:
                .system(size: size)
        }
    }

    // `CTFontCreateWithName` silently substitutes another font for a name it cannot find, which would size the
    // clock from the wrong metrics.
    private static let leagueGothicMetrics: ClockFaceMetrics? = {
        guard LeagueGothic.isAvailable else { return nil }

        let font = CTFontCreateWithName(LeagueGothic.postScriptName as CFString, referenceSize, nil)
        let found = CTFontCopyPostScriptName(font) as String
        guard found == LeagueGothic.postScriptName else {
            logger.error("CoreText returned \(found, privacy: .public) for League Gothic; the stage clock uses the system font")
            return nil
        }
        return ClockFaceMetrics(font: font)
    }()

    // Measured at a display size: at text sizes the system font uses its text optical size, which is wider.
    private static let systemMetrics = ClockFaceMetrics(font: UIFont.systemFont(ofSize: referenceSize) as CTFont)

    private static let referenceSize: CGFloat = 100

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CircuitTimer", category: "DesignSystem")
}

/// What sizing the stage clock needs from a font, in em.
struct ClockFaceMetrics: Equatable {
    /// Room for kerning and rounding that the advances do not show.
    static let widthMargin: CGFloat = 1.03

    let capHeight: CGFloat
    /// `":"` and four of the widest digit: the widest the visible text can reach past the centred template's
    /// leading edge, `2 × visible − template`, for any minutes.
    let anchoredWidth: CGFloat

    init(font: CTFont) {
        let size = CTFontGetSize(font)
        let widestDigit = "0123456789".map { Self.advance(of: $0, in: font) }.max() ?? 0
        capHeight = CTFontGetCapHeight(font) / size
        anchoredWidth = (Self.advance(of: ":", in: font) + 4 * widestDigit) / size
    }

    /// The largest font size whose cap height fits the box height and whose clock fits its width.
    func fontSize(fitting box: CGSize) -> CGFloat {
        guard capHeight > 0, anchoredWidth > 0 else { return 0 }

        return max(0, min(box.height / capHeight, box.width / (anchoredWidth * Self.widthMargin)))
    }

    private static func advance(of character: Character, in font: CTFont) -> CGFloat {
        var characters = Array(String(character).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count) else { return 0 }

        return CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, nil, glyphs.count)
    }
}

/// About the clock box of the timer card on the smallest and the largest supported iPhone.
private let previewBoxes = [CGSize(width: 300, height: 110), CGSize(width: 380, height: 155)]

private struct StageClockPreview: View {
    let face: StageClockText.Face

    var body: some View {
        ScrollView {
            VStack(spacing: .token(spacing: .l)) {
                ForEach(["11:22", "22:22", "99:59", "3"], id: \.self) { text in
                    ForEach(previewBoxes.indices, id: \.self) { index in
                        StageClockText(text, face: face)
                            .frame(width: previewBoxes[index].width, height: previewBoxes[index].height)
                            .background(.stage(.work))
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(.text(.onAccent))
        .background(.surface(.screen))
    }
}

#Preview("League Gothic") {
    StageClockPreview(face: .leagueGothic)
        .preferredColorScheme(.dark)
}

#Preview("System face") {
    StageClockPreview(face: .system)
        .preferredColorScheme(.dark)
}
