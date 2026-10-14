@testable import DesignSystem

import Testing
import UIKit

@MainActor
@Suite
struct RowTextEditingGestureTests {
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
private final class FieldTouch: UITouch {
    private let touchedView: UIView

    init(view: UIView) {
        touchedView = view
        super.init()
    }

    override var view: UIView? { touchedView }

    override func location(in view: UIView?) -> CGPoint { .zero }
}
