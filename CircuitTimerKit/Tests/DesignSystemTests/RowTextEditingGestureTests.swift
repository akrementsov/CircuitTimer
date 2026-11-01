@testable import DesignSystem

import Foundation
import Testing
import UIKit

@MainActor
@Suite
struct RowTextEditingGestureTests {
    @Test
    func test_longPress_finalTouch_updatesPositionBeforeDrop() {
        let finalPoint = CGPoint(x: 50, y: 120)
        var latestPoint: CGPoint?
        var droppedAt: CGPoint?
        let coordinator = ScrollViewLongPress(
            isEnabled: true,
            pressDuration: 0.35,
            accepts: { _ in true },
            onLift: { _ in },
            onFingerMove: { latestPoint = $0 },
            onDrop: { droppedAt = latestPoint },
            onCancel: {}
        ).makeCoordinator()

        // Invoke the registered UIKit target with an ended recognizer: its final point need not have appeared in
        // a preceding .changed event. Dropping first would commit the previous point (or none at all).
        coordinator.handle(StatedLongPress(state: .ended, point: finalPoint))

        #expect(droppedAt == finalPoint)
    }

    /// A busy main thread can report the lift after the finger has moved over the next row: the row under the touch's
    /// start is the one that lifts, and the finger's travel counts from there.
    @Test
    func test_longPress_beganAfterTheFingerMoved_liftsFromWhereTheTouchCameDown() {
        let start = CGPoint(x: 50, y: 100)
        let moved = CGPoint(x: 50, y: 150)
        var events: [String] = []
        let coordinator = ScrollViewLongPress(
            isEnabled: true,
            pressDuration: 0.35,
            accepts: { _ in true },
            onLift: { events.append("lift \($0.y)") },
            onFingerMove: { events.append("move \($0.y)") },
            onDrop: {},
            onCancel: {}
        ).makeCoordinator()

        #expect(coordinator.gestureRecognizer(coordinator.recognizer, shouldReceive: FieldTouch(view: UIView(), point: start)))
        coordinator.handle(StatedLongPress(state: .began, point: moved))

        #expect(events == ["lift 100.0", "move 150.0"])
    }

    @Test(arguments: [false, true])
    func test_longPress_numericField_doesNotLiftRow(touchesChild: Bool) {
        let field = NativeNumericField()
        let child = UIView()
        field.addSubview(child)
        let coordinator = makeCoordinator()
        let touch = FieldTouch(view: touchesChild ? child : field)

        #expect(!coordinator.gestureRecognizer(coordinator.recognizer, shouldReceive: touch))
    }

    @Test
    func test_longPress_rowFreeSpace_canLiftRow() {
        let coordinator = makeCoordinator()
        let touch = FieldTouch(view: UIView())

        #expect(coordinator.gestureRecognizer(coordinator.recognizer, shouldReceive: touch))
    }

    private func makeCoordinator() -> ScrollViewLongPress.Coordinator {
        ScrollViewLongPress(
            isEnabled: true,
            pressDuration: 0.35,
            accepts: { _ in true },
            onLift: { _ in },
            onFingerMove: { _ in },
            onDrop: {},
            onCancel: {}
        ).makeCoordinator()
    }

    @Test(arguments: [false, true])
    func test_horizontalPan_numericField_doesNotSwipeRow(touchesChild: Bool) {
        guard #available(iOS 18, *) else { return }
        let field = NativeNumericField()
        let child = UIView()
        field.addSubview(child)
        let delegate: any UIGestureRecognizerDelegate = HorizontalPanRecognizer.Coordinator()
        let touch = FieldTouch(view: touchesChild ? child : field)

        let receivesTouch = delegate.gestureRecognizer?(UIPanGestureRecognizer(), shouldReceive: touch) ?? true

        #expect(!receivesTouch)
    }

    @Test
    func test_horizontalPan_rowFreeSpace_canSwipeRow() {
        guard #available(iOS 18, *) else { return }
        let delegate: any UIGestureRecognizerDelegate = HorizontalPanRecognizer.Coordinator()
        let touch = FieldTouch(view: UIView())

        let receivesTouch = delegate.gestureRecognizer?(UIPanGestureRecognizer(), shouldReceive: touch) ?? true

        #expect(receivesTouch)
    }
}

@MainActor
private final class StatedLongPress: UILongPressGestureRecognizer {
    private let fixedState: UIGestureRecognizer.State
    private let point: CGPoint

    init(state: UIGestureRecognizer.State, point: CGPoint) {
        fixedState = state
        self.point = point
        super.init(target: nil, action: nil)
    }

    override var state: UIGestureRecognizer.State {
        get { fixedState }
        set {}
    }

    override func location(in view: UIView?) -> CGPoint { point }
}

@MainActor
private final class FieldTouch: UITouch {
    private let touchedView: UIView
    private let point: CGPoint

    init(view: UIView, point: CGPoint = .zero) {
        touchedView = view
        self.point = point
        super.init()
    }

    override var view: UIView? { touchedView }

    override func location(in view: UIView?) -> CGPoint { point }
}
