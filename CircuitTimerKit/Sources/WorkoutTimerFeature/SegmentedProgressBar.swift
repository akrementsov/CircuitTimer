import DesignSystem
import SwiftUI

/// Whole-workout progress, one segment per round of each section. The bar runs edge to edge, so its outer ends
/// stay square and only the ends between segments are rounded.
struct SegmentedProgressBar: View {
    let segments: [WorkoutTimerFeature.State.ProgressSegment]

    var body: some View {
        Canvas { context, size in
            let totalWeight = segments.reduce(0) { $0 + $1.weight }
            guard totalWeight > 0 else { return }

            let gaps = CGFloat(max(segments.count - 1, 0))
            // Many short rounds would leave no bar between the gaps, so the gaps take at most a quarter of it.
            let gap = min(.token(spacing: .xxs), size.width / 4 / max(gaps, 1))
            let available = size.width - gap * gaps
            var offset: CGFloat = .zero
            for (index, segment) in segments.enumerated() {
                let width = available * segment.weight / totalWeight
                let rect = CGRect(x: offset, y: .zero, width: width, height: size.height)
                let shape = Self.shape(in: rect, isFirst: index == 0, isLast: index == segments.count - 1)
                context.fill(shape, with: .color(.surface(.field)))
                if segment.fill > 0 {
                    let done = CGRect(x: offset, y: .zero, width: width * segment.fill, height: size.height)
                    context.drawLayer { layer in
                        layer.clip(to: shape)
                        layer.fill(Path(done), with: .color(.brand))
                    }
                }
                offset += width + gap
            }
        }
        .accessibilityHidden(true)
    }

    private static func shape(in rect: CGRect, isFirst: Bool, isLast: Bool) -> Path {
        let radius = min(rect.height / 2, rect.width / 2)
        let leading: CGFloat = isFirst ? .zero : radius
        let trailing: CGFloat = isLast ? .zero : radius
        let radii = RectangleCornerRadii(topLeading: leading, bottomLeading: leading, bottomTrailing: trailing, topTrailing: trailing)
        return UnevenRoundedRectangle(cornerRadii: radii).path(in: rect)
    }
}
