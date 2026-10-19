import os
import SwiftUI
import UIKit

/// Where the rows sit while one of them is dragged. Heights are in the order of the rows, with `spacing` between
/// neighbours.
struct ReorderGeometry: Equatable {
    let heights: [CGFloat]
    let from: Int
    let spacing: CGFloat

    init(heights: [CGFloat], from: Int, spacing: CGFloat = .zero) {
        self.heights = heights
        self.from = from
        self.spacing = spacing
    }

    /// The lifted row's offset kept between the first and the last place: it never leaves its rows.
    var offsetRange: ClosedRange<CGFloat> {
        let top = top(of: from)
        let below = heights[(from + 1)...].reduce(.zero, +) + CGFloat(heights.count - 1 - from) * spacing
        return -top...max(-top, below)
    }

    func clampedOffset(_ offset: CGFloat) -> CGFloat {
        min(max(offset, offsetRange.lowerBound), offsetRange.upperBound)
    }

    /// Drawing and dropping use the same scroll content frame: content moving up adds to the finger's travel.
    func offset(fingerTravel: CGFloat, contentMinYAtLift: CGFloat, contentMinY: CGFloat) -> CGFloat {
        clampedOffset(fingerTravel + contentMinYAtLift - contentMinY)
    }

    /// The place the lifted row would take: it passes a neighbour once its edge crosses the neighbour's middle.
    func destination(for offset: CGFloat) -> Int {
        let top = top(of: from) + offset
        let bottom = top + heights[from]
        var destination = from
        while destination + 1 < heights.count, bottom > middle(of: destination + 1) {
            destination += 1
        }
        if destination == from {
            while destination > 0, top < middle(of: destination - 1) {
                destination -= 1
            }
        }
        return destination
    }

    /// How far a row that is not lifted moves aside to make room at `destination`.
    func shift(ofRowAt index: Int, destination: Int) -> CGFloat {
        if from < destination, (from + 1...destination).contains(index) {
            -(heights[from] + spacing)
        } else if destination < from, (destination..<from).contains(index) {
            heights[from] + spacing
        } else {
            .zero
        }
    }

    /// The `onMove` offset that puts the row at `from` at index `destination`: it counts places before the row is
    /// removed.
    static func moveOffset(from: Int, destination: Int) -> Int {
        destination > from ? destination + 1 : destination
    }

    private func top(of index: Int) -> CGFloat {
        heights[..<index].reduce(.zero, +) + CGFloat(index) * spacing
    }

    private func middle(of index: Int) -> CGFloat {
        top(of: index) + heights[index] / 2
    }
}

/// Rows reordered by a long press and a drag, as in the original app: the card stays in place, the neighbours make
/// room, and the row settles at once when it is let go. Near an edge of the visible area the screen scrolls by
/// itself. Works only inside a `CardScrollView`, and every row must be laid out: a lazy container would leave rows
/// unmeasured and nothing would lift.
public struct ReorderableRows<Item: Identifiable, Row: View>: View {
    let items: [Item]
    let spacing: CGFloat
    let isEnabled: Bool
    let canLift: (Item) -> Bool
    /// A tap on a row's free space, outside its own controls.
    let onRowTap: ((Item) -> Void)?
    let onMove: (_ from: Int, _ offset: Int) -> Void
    /// The row of an item at its place in `items`.
    let row: (_ item: Item, _ index: Int) -> Row

    /// Rows' places in the scroll content, which don't move while it scrolls.
    @State private var frames: [Item.ID: CGRect] = [:]
    @State private var drag: ReorderDrag<Item.ID>?
    /// The lifted row's latest computed offset. A plain reference: it changes on every frame the screen scrolls by
    /// itself, and redrawing every row for it would stall a long list.
    @State private var liftedOffset = LiftedOffset()
    @Environment(RowInteraction<Item.ID>.self) private var interaction: RowInteraction<Item.ID>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static var liftScale: CGFloat { 1.03 }
    private static var pressDuration: Double { 0.35 }
    /// Layout settles in fractions of a point; only a larger change means the rows changed under the drag.
    private static var sizeTolerance: CGFloat { 0.5 }

    public init(
        items: [Item],
        spacing: CGFloat,
        isEnabled: Bool,
        canLift: @escaping (Item) -> Bool,
        onRowTap: ((Item) -> Void)?,
        onMove: @escaping (_ from: Int, _ offset: Int) -> Void,
        @ViewBuilder row: @escaping (_ item: Item, _ index: Int) -> Row
    ) {
        self.items = items
        self.spacing = spacing
        self.isEnabled = isEnabled
        self.canLift = canLift
        self.onRowTap = onRowTap
        self.onMove = onMove
        self.row = row
    }

    public var body: some View {
        let canDrag = isEnabled && interaction != nil
        VStack(spacing: spacing) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let isLifted = drag?.id == item.id
                row(item, index)
                    // The lifted row's controls let go of the finger, so letting it go over them presses nothing.
                    .disabled(isLifted)
                    .modifier(
                        LiftedRowTracker(
                            isLifted: isLifted,
                            scale: isLifted ? Self.liftScale : 1,
                            shift: shift(ofRowAt: index),
                            fingerTravel: isLifted ? drag?.fingerTravel ?? .zero : .zero,
                            geometry: isLifted ? drag?.geometry : nil,
                            contentGeometry: interaction?.geometry,
                            contentMinYAtLift: drag?.contentMinYAtLift ?? .zero,
                            onPositionChange: updateDragPosition
                        )
                    )
                    .gesture(TapGesture().onEnded { onRowTap?(item) }, including: onRowTap != nil ? .all : .subviews)
                    // Outside the tracker: the place the row takes, not where it is drawn scaled and moved.
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(RowContentSpace.name)) } action: {
                        rowMeasured(item.id, frame: $0)
                    }
                    .zIndex(isLifted ? 1 : 0)
                    .transition(.opacity)
            }
        }
        .background {
            ScrollViewLongPress(
                isEnabled: canDrag,
                pressDuration: Self.pressDuration,
                accepts: { liftableItem(at: $0) != nil },
                onLift: { point in
                    if let item = liftableItem(at: point) {
                        lift(item)
                        fingerMoved(to: point.y)
                    }
                },
                onFingerMove: { fingerMoved(to: $0.y) },
                onDrop: drop,
                onCancel: cancel
            )
        }
        .onAppear {
            if interaction == nil {
                Logger.designSystem.error("ReorderableRows outside a CardScrollView: rows can't be lifted")
            }
        }
        .onDisappear { cancel() }
        .onChange(of: items.map(\.id)) { _, ids in
            frames = frames.filter { ids.contains($0.key) }
            // The rows changed under the drag: it moves nothing.
            if let drag, drag.ids != ids {
                cancel()
            }
        }
        .onChange(of: isEnabled) { _, isEnabled in
            if !isEnabled {
                cancel()
            }
        }
        .sensoryFeedback(.impact, trigger: drag?.id) { _, id in id != nil }
        .sensoryFeedback(.selection, trigger: drag?.destination) { old, new in old != nil && new != nil }
    }

    private func rowMeasured(_ id: Item.ID, frame: CGRect) {
        frames[id] = frame
        guard let drag, let index = drag.ids.firstIndex(of: id), index < drag.sizes.count else { return }

        let size = drag.sizes[index]
        if abs(size.width - frame.width) > Self.sizeTolerance || abs(size.height - frame.height) > Self.sizeTolerance {
            cancel()
        }
    }

    /// The row under a point of the global space that a long press may lift.
    private func liftableItem(at point: CGPoint) -> Item? {
        guard isEnabled, let interaction else { return nil }

        let origin = interaction.geometry.contentFrame.origin
        let contentPoint = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        return items.first { item in
            canLift(item) && frames[item.id]?.contains(contentPoint) == true
        }
    }

    private func shift(ofRowAt index: Int) -> CGFloat {
        guard let drag else { return .zero }

        return drag.geometry.shift(ofRowAt: index, destination: drag.destination)
    }

    private func lift(_ item: Item) {
        // Sizes come one frame after the rows change; a lift waits until every row has been measured.
        let sizes = items.map { frames[$0.id]?.size ?? .zero }
        guard
            drag == nil, isEnabled, let interaction, canLift(item), items.count > 1,
            sizes.allSatisfy({ $0.height > .zero }),
            let from = items.firstIndex(where: { $0.id == item.id })
        else { return }

        let geometry = ReorderGeometry(heights: sizes.map(\.height), from: from, spacing: spacing)
        liftedOffset.value = .zero
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
            drag = ReorderDrag(
                id: item.id,
                ids: items.map(\.id),
                sizes: sizes,
                geometry: geometry,
                contentMinYAtLift: interaction.geometry.contentFrame.minY
            )
            interaction.liftedID = item.id
        }
    }

    private func fingerMoved(to fingerY: CGFloat) {
        guard drag != nil else { return }

        if drag?.fingerYAtLift == nil {
            drag?.fingerYAtLift = fingerY
        }
        drag?.fingerY = fingerY
        // This update must stay synchronous: SwiftUI's geometry/onChange callbacks can arrive after the finger
        // has already lifted, especially for short stage rows.
        updateDragPosition()
    }

    private func updateDragPosition() {
        guard let current = drag, let interaction else { return }

        let offset = current.geometry.offset(
            fingerTravel: current.fingerTravel,
            contentMinYAtLift: current.contentMinYAtLift,
            contentMinY: interaction.geometry.contentFrame.minY
        )
        liftedOffset.value = offset
        let destination = current.geometry.destination(for: offset)
        if destination != current.destination {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                drag?.destination = destination
            }
        }
        updateVelocity()
    }

    private func updateVelocity() {
        guard let drag, let fingerY = drag.fingerY, let interaction else { return }

        var velocity = EdgeAutoScroll.velocity(fingerY: fingerY, visibleRect: interaction.geometry.visibleRect)
        // At the last place the row stops; scrolling on would only move the card away under the finger.
        let range = drag.geometry.offsetRange
        let isAtTop = velocity < .zero && liftedOffset.value <= range.lowerBound
        let isAtBottom = velocity > .zero && liftedOffset.value >= range.upperBound
        if isAtTop || isAtBottom {
            velocity = .zero
        }
        if velocity != interaction.autoScrollVelocity {
            interaction.autoScrollVelocity = velocity
        }
    }

    private func drop() {
        guard let drag else { return }

        let ids = items.map(\.id)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            // The rows changed under the drag: it moves nothing.
            if ids == drag.ids, drag.destination != drag.geometry.from {
                onMove(drag.geometry.from, ReorderGeometry.moveOffset(from: drag.geometry.from, destination: drag.destination))
            }
            self.drag = nil
            interaction?.liftedID = nil
        }
        interaction?.autoScrollVelocity = .zero
    }

    private func cancel() {
        guard drag != nil else { return }

        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            drag = nil
            interaction?.liftedID = nil
        }
        interaction?.autoScrollVelocity = .zero
    }
}

@MainActor
private final class LiftedOffset {
    var value: CGFloat = .zero
}

private struct ReorderDrag<ID: Hashable>: Equatable {
    let id: ID
    /// The rows and their sizes at the lift: a change to either cancels the drag.
    let ids: [ID]
    let sizes: [CGSize]
    let geometry: ReorderGeometry
    let contentMinYAtLift: CGFloat
    var destination: Int
    var fingerYAtLift: CGFloat?
    var fingerY: CGFloat?

    init(id: ID, ids: [ID], sizes: [CGSize], geometry: ReorderGeometry, contentMinYAtLift: CGFloat) {
        self.id = id
        self.ids = ids
        self.sizes = sizes
        self.geometry = geometry
        self.contentMinYAtLift = contentMinYAtLift
        destination = geometry.from
    }

    var fingerTravel: CGFloat {
        guard let fingerYAtLift, let fingerY else { return .zero }

        return fingerY - fingerYAtLift
    }
}

/// The lift: a zero-size view that puts a UIKit long press on the scroll view around it. SwiftUI gestures can't lift a
/// row inside a scroll view: from iOS 18 a drag gesture keeps the scroll view from scrolling and a long press on the row
/// loses to the row's buttons, and on iOS 17 the swipe's drag inside the row takes the touch from a lifted row. The
/// press starts only where `accepts` takes the point, and a scroll that moves first makes it fail, as on any scroll
/// view. Points are in the global space, which doesn't move when the screen scrolls under a resting finger.
struct ScrollViewLongPress: UIViewRepresentable {
    let isEnabled: Bool
    let pressDuration: Double
    let accepts: (CGPoint) -> Bool
    let onLift: (CGPoint) -> Void
    let onFingerMove: (CGPoint) -> Void
    let onDrop: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> ProbeView {
        ProbeView(recognizer: context.coordinator.recognizer)
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.recognizer.isEnabled = isEnabled
        context.coordinator.recognizer.minimumPressDuration = pressDuration
    }

    static func dismantleUIView(_ view: ProbeView, coordinator: Coordinator) {
        coordinator.recognizer.view?.removeGestureRecognizer(coordinator.recognizer)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: ScrollViewLongPress
        let recognizer = UILongPressGestureRecognizer()

        init(parent: ScrollViewLongPress) {
            self.parent = parent
            super.init()
            recognizer.addTarget(self, action: #selector(handle))
            recognizer.delegate = self
        }

        @objc func handle(_ recognizer: UILongPressGestureRecognizer) {
            let point = recognizer.location(in: nil)
            switch recognizer.state {
                case .began:
                    parent.onLift(point)
                case .changed:
                    parent.onFingerMove(point)
                case .ended:
                    parent.onFingerMove(point)
                    parent.onDrop()
                case .cancelled, .failed:
                    parent.onCancel()
                default:
                    break
            }
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // TextKit's selection gestures own touches in the numeric field, including its internal text views.
            // A row lift starts earlier than selection and disables the field, interrupting the cursor drag.
            touch.view?.isInsideNumericField != true && parent.accepts(touch.location(in: nil))
        }

        /// Alongside the row's buttons, which on iOS 26 hold the touch from its start; a lifted row's buttons are
        /// disabled, so letting go over them presses nothing.
        func gestureRecognizer(
            _ recognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }

    final class ProbeView: UIView {
        private let recognizer: UIGestureRecognizer

        init(recognizer: UIGestureRecognizer) {
            self.recognizer = recognizer
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("ProbeView is created in code only")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            recognizer.view?.removeGestureRecognizer(recognizer)
            guard window != nil else { return }

            let scrollView = sequence(first: superview) { $0?.superview }.lazy.compactMap { $0 as? UIScrollView }.first
            scrollView?.addGestureRecognizer(recognizer)
        }
    }
}

/// Draws a row where the drag puts it. Every row carries it, so lifting a row doesn't change what the row is and
/// doesn't cancel the gesture that lifted it. The lifted row follows the finger in the global space: when the screen
/// scrolls under a resting finger, the row's place moves with the content, and the offset makes up for it.
private struct LiftedRowTracker: ViewModifier {
    let isLifted: Bool
    let scale: CGFloat
    let shift: CGFloat
    let fingerTravel: CGFloat
    let geometry: ReorderGeometry?
    let contentGeometry: ScrollContentGeometry?
    let contentMinYAtLift: CGFloat
    let onPositionChange: () -> Void

    func body(content: Content) -> some View {
        let liftedOffset = offset
        content
            .scaleEffect(scale)
            .offset(y: isLifted ? liftedOffset : shift)
            // Auto-scroll moves the content under a resting finger, without another fingerMoved callback.
            .onChange(of: isLifted ? liftedOffset : nil) { _, offset in
                if offset != nil {
                    onPositionChange()
                }
            }
    }

    private var offset: CGFloat {
        // Only the lifted row reads the observable frame; other rows keep their existing observation unchanged.
        guard isLifted, let geometry, let contentGeometry else { return .zero }

        return geometry.offset(
            fingerTravel: fingerTravel,
            contentMinYAtLift: contentMinYAtLift,
            contentMinY: contentGeometry.contentFrame.minY
        )
    }
}
