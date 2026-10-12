import SwiftUI
import UIKit

/// What a swipe plaque does, which sets its fill.
public enum SwipePlaqueRole: Sendable {
    /// A red plaque, as the original app's delete.
    case destructive
    /// A plaque next to a destructive one that changes nothing for good.
    case secondary
}

/// The plaque's size, after the row it opens from, as in the original app.
public enum SwipePlaqueStyle: Sendable {
    /// A row inside a card: a smaller plaque.
    case row
    /// A row that is a card of its own: a plaque with the card's corners.
    case card
}

/// One plaque a swiped row uncovers. Its label is the caller's localized text; at accessibility text sizes the plaque
/// shows the icon instead, so that two plaques still fit beside a narrow row.
public struct SwipePlaqueAction: Identifiable {
    public let id: String
    let role: SwipePlaqueRole
    let label: Text
    let icon: Image
    let action: @MainActor () -> Void

    public init(id: String, role: SwipePlaqueRole, label: Text, icon: Image, action: @escaping @MainActor () -> Void) {
        self.id = id
        self.role = role
        self.label = label
        self.icon = icon
        self.action = action
    }
}

/// Where a row swiped to the left rests. The row never moves right of its place, and a full swipe only opens it: an
/// action takes a tap on its plaque, as in the original app. Left to right only: the app has no right-to-left
/// localization.
struct SwipeReveal: Equatable {
    /// How far an open row moves: the plaques and the gap between them and the row.
    let revealWidth: CGFloat

    init(groupWidth: CGFloat) {
        revealWidth = groupWidth + .token(spacing: .l)
    }

    /// The row's offset for a horizontal translation; past the open position it follows the finger at a third of
    /// its speed.
    func offset(translation: CGFloat, startsOpen: Bool) -> CGFloat {
        let raw = translation - (startsOpen ? revealWidth : .zero)
        if raw >= .zero {
            return .zero
        }
        if raw >= -revealWidth {
            return raw
        }
        return -revealWidth + (raw + revealWidth) / 3
    }

    /// Opens when the row would come to rest past half of the plaques.
    func settlesOpen(predictedEndTranslation: CGFloat, startsOpen: Bool) -> Bool {
        offset(translation: predictedEndTranslation, startsOpen: startsOpen) < -revealWidth / 2
    }
}

/// The direction a drag is taken for, decided once at its start: a vertical drag belongs to the scroll view.
enum SwipeAxis: Equatable {
    case horizontal
    case vertical

    init(translation: CGSize) {
        self = abs(translation.width) > abs(translation.height) ? .horizontal : .vertical
    }
}

extension View {
    /// Swiping the row left uncovers its plaques, in the order of `actions` with the last at the trailing edge, as in
    /// the original app. An open row takes no taps of its own: a tap on it closes it. The plaques are hidden from
    /// assistive technologies, so the row offers the same actions itself.
    public func swipePlaques(
        isOpen: Binding<Bool>,
        isEnabled: Bool,
        style: SwipePlaqueStyle,
        actions: [SwipePlaqueAction]
    ) -> some View {
        modifier(SwipePlaques(isOpen: isOpen, isEnabled: isEnabled, style: style, actions: actions))
    }
}

private struct SwipePlaques: ViewModifier {
    @Binding var isOpen: Bool
    let isEnabled: Bool
    let style: SwipePlaqueStyle
    let actions: [SwipePlaqueAction]

    @State private var groupWidth: CGFloat = .zero
    @State private var drag: SwipeDrag?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        let reveal = SwipeReveal(groupWidth: groupWidth)
        let offset = offset(in: reveal)
        ZStack {
            content
                .offset(x: offset)
                .allowsHitTesting(!isOpen)
                // On iOS 17 the drag runs alongside the row's buttons, which keep the touch: letting it go would press
                // the one it started on.
                .disabled(drag != nil)
        }
        .contentShape(Rectangle())
        .gesture(TapGesture().onEnded { close() }, including: isOpen ? .gesture : .subviews)
        .overlay(alignment: .trailing) {
            plaques
                .offset(x: reveal.revealWidth + offset)
                // Closed, they wait past the row's trailing edge, where a card's clip hides them from sight but not
                // from touches.
                .allowsHitTesting(isOpen)
        }
        .modifier(
            HorizontalDrag(
                isEnabled: isEnabled,
                onChanged: dragChanged,
                onEnded: { dragEnded(predictedEndTranslation: $0, reveal: reveal) },
                onCancelled: dragCancelled
            )
        )
        .onChange(of: isEnabled) { _, isEnabled in
            if !isEnabled {
                close()
            }
        }
    }

    private var plaques: some View {
        HStack(spacing: .token(spacing: .xs)) {
            ForEach(actions) { action in
                plaque(action)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { groupWidth = $0 }
        // Assistive technologies reach the actions through the row's own.
        .accessibilityHidden(true)
    }

    private func plaque(_ action: SwipePlaqueAction) -> some View {
        Button {
            // One transaction with the action, so the row settles together with what the action changes.
            withAnimation(settleAnimation) {
                isOpen = false
                drag = nil
                action.action()
            }
        } label: {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    action.icon
                        .font(.token(.icon))
                } else {
                    action.label
                        .font(.token(.body))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.text(.primary))
            .fixedSize()
            .padding(.horizontal, horizontalInset)
            .frame(maxHeight: .infinity)
            .background(fill(action.role), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var horizontalInset: CGFloat {
        switch style {
            case .row: .token(spacing: .m)
            case .card: .token(spacing: .l)
        }
    }

    private var cornerRadius: CGFloat {
        switch style {
            case .row: .token(radius: .s)
            case .card: .token(radius: .m)
        }
    }

    private func fill(_ role: SwipePlaqueRole) -> Color {
        switch role {
            case .destructive: .danger
            case .secondary: .secondaryAction
        }
    }

    private var settleAnimation: Animation? {
        reduceMotion ? nil : .snappy(duration: 0.25)
    }

    private func offset(in reveal: SwipeReveal) -> CGFloat {
        if let drag, drag.axis == .horizontal {
            reveal.offset(translation: drag.translation, startsOpen: isOpen)
        } else if isOpen {
            -reveal.revealWidth
        } else {
            .zero
        }
    }

    private func dragChanged(_ translation: CGSize) {
        // A pan begins before it has moved: the direction waits for the first movement.
        guard drag != nil || translation != .zero else { return }

        let axis = drag?.axis ?? SwipeAxis(translation: translation)
        if drag == nil, axis == .vertical, isOpen {
            close()
        }
        drag = SwipeDrag(axis: axis, translation: translation.width)
    }

    private func dragEnded(predictedEndTranslation: CGFloat, reveal: SwipeReveal) {
        guard drag?.axis == .horizontal else {
            drag = nil
            return
        }

        let opens = reveal.settlesOpen(predictedEndTranslation: predictedEndTranslation, startsOpen: isOpen)
        withAnimation(settleAnimation) {
            isOpen = opens
            drag = nil
        }
    }

    /// The scroll view took the drag over.
    private func dragCancelled() {
        guard drag != nil else { return }

        withAnimation(settleAnimation) { drag = nil }
    }

    private func close() {
        guard isOpen || drag != nil else { return }

        withAnimation(settleAnimation) {
            isOpen = false
            drag = nil
        }
    }
}

private struct SwipeDrag: Equatable {
    let axis: SwipeAxis
    let translation: CGFloat
}

/// A drag across the row that leaves vertical drags to the scroll view. From iOS 18 a SwiftUI drag gesture inside a
/// scroll view keeps it from scrolling, so there the drag is a UIKit pan that begins only when it moves sideways.
private struct HorizontalDrag: ViewModifier {
    let isEnabled: Bool
    let onChanged: (CGSize) -> Void
    /// Receives the horizontal translation the row would come to rest at.
    let onEnded: (CGFloat) -> Void
    let onCancelled: () -> Void

    @GestureState private var isTracking = false

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.gesture(
                HorizontalPanRecognizer(isEnabled: isEnabled, onChanged: onChanged, onEnded: onEnded, onCancelled: onCancelled)
            )
        } else {
            content
                .simultaneousGesture(
                    // Far enough that a tap or the start of a scroll never moves the row.
                    DragGesture(minimumDistance: 12)
                        .updating($isTracking) { _, isTracking, _ in isTracking = true }
                        .onChanged { onChanged($0.translation) }
                        .onEnded { onEnded($0.predictedEndTranslation.width) },
                    including: isEnabled ? .all : .subviews
                )
                .onChange(of: isTracking) { _, isTracking in
                    // A drag the scroll view took over ends without `onEnded`.
                    if !isTracking {
                        onCancelled()
                    }
                }
        }
    }
}

@available(iOS 18, *)
private struct HorizontalPanRecognizer: UIGestureRecognizerRepresentable {
    let isEnabled: Bool
    let onChanged: (CGSize) -> Void
    let onEnded: (CGFloat) -> Void
    let onCancelled: () -> Void

    /// How far the row would travel after the finger lifts: the share of a second the velocity carries it, as
    /// SwiftUI's predicted translation roughly does.
    private static let projection: CGFloat = 0.25

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view)
        switch recognizer.state {
            case .began, .changed:
                onChanged(CGSize(width: translation.x, height: translation.y))
            case .ended:
                onEnded(translation.x + recognizer.velocity(in: recognizer.view).x * Self.projection)
            case .cancelled, .failed:
                onCancelled()
            default:
                break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return true }

            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }

        /// Alongside the row's buttons, which on iOS 26 hold the touch from its start, but never alongside a scroll:
        /// a sideways drag doesn't scroll. The swiped row's content is disabled, so letting go presses nothing.
        func gestureRecognizer(
            _ recognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            !(other.view is UIScrollView)
        }
    }
}

#Preview("Card") {
    @Previewable @State var isOpen = false
    Text(verbatim: "A workout")
        .foregroundStyle(.text(.primary))
        .padding(.token(spacing: .l))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.surface(.card), in: RoundedRectangle(cornerRadius: .token(radius: .m), style: .continuous))
        .swipePlaques(
            isOpen: $isOpen,
            isEnabled: true,
            style: .card,
            actions: [
                SwipePlaqueAction(
                    id: "duplicate",
                    role: .secondary,
                    label: Text(verbatim: "Duplicate"),
                    icon: Image(systemName: "plus.square.on.square")
                ) {},
                SwipePlaqueAction(id: "delete", role: .destructive, label: Text(verbatim: "Delete"), icon: Image(systemName: "trash")) {},
            ]
        )
        .padding(.token(spacing: .l))
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.surface(.screen))
        .preferredColorScheme(.dark)
}

#Preview("Row") {
    @Previewable @State var openRow: Int?
    VStack(spacing: .zero) {
        ForEach(0..<2) { row in
            Text(verbatim: row == 0 ? "A row" : "A taller row\nwith two lines")
                .foregroundStyle(.text(.primary))
                .padding(.token(spacing: .m))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.surface(.field), in: RoundedRectangle(cornerRadius: .token(radius: .s), style: .continuous))
                .swipePlaques(
                    isOpen: Binding(get: { openRow == row }, set: { openRow = $0 ? row : nil }),
                    isEnabled: true,
                    style: .row,
                    actions: [
                        SwipePlaqueAction(
                            id: "delete",
                            role: .destructive,
                            label: Text(verbatim: "Delete"),
                            icon: Image(systemName: "trash")
                        ) {},
                    ]
                )
                .padding(.horizontal, .token(spacing: .l))
                .padding(.vertical, .token(spacing: .xxs))
        }
    }
    .padding(.vertical, .token(spacing: .m))
    .background(.surface(.card), in: RoundedRectangle(cornerRadius: .token(radius: .m), style: .continuous))
    .clipShape(RoundedRectangle(cornerRadius: .token(radius: .m), style: .continuous))
    .padding(.token(spacing: .l))
    .frame(maxHeight: .infinity, alignment: .top)
    .background(.surface(.screen))
    .preferredColorScheme(.dark)
}
