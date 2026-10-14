@testable import WorkoutEditorFeature

import ComposableArchitecture
import Foundation
import SwiftUI
import Testing
import UIKit
import WorkoutDomain

@MainActor
@Suite(.serialized)
struct StageDurationFocusTests {
    @Test
    func test_edit_consecutiveDigits_commitsBeforeBlurAndRejectsFifthDigit() async throws {
        let store = editorStore(makeWorkout())
        let window = await show(NavigationStack { WorkoutEditorView(store: store) })
        defer { window.isHidden = true }
        let field = try #require(textFields(in: window).first { $0.keyboardType == .asciiCapableNumberPad })
        #expect(field.becomeFirstResponder())
        await settleRendering()
        let delegate = try #require(field.delegate)

        #expect(delegate.textField?(field, shouldChangeCharactersIn: NSRange(location: 0, length: 5), replacementString: "12") == false)
        #expect(store.state.draft.warmUp[0].duration == .seconds(720))
        #expect(delegate.textField?(field, shouldChangeCharactersIn: NSRange(location: 2, length: 0), replacementString: "3") == false)
        #expect(store.state.draft.warmUp[0].duration == .seconds(750))
        #expect(delegate.textField?(field, shouldChangeCharactersIn: NSRange(location: 4, length: 0), replacementString: "4") == false)

        #expect(field.isFirstResponder)
        #expect(field.text == "12:34")
        #expect(store.state.draft.warmUp[0].duration == .seconds(754))
        #expect(delegate.textField?(field, shouldChangeCharactersIn: NSRange(location: 5, length: 0), replacementString: "5") == false)
        #expect(field.text == "12:34")
        #expect(store.state.draft.warmUp[0].duration == .seconds(754))
        let selection = try #require(field.selectedTextRange)
        #expect(field.offset(from: field.beginningOfDocument, to: selection.start) == 5)
    }

    @Test
    func test_edit_storedFraction_preservesUntouchedValueAndCommitsExplicitZero() async throws {
        var workout = makeWorkout()
        workout.warmUp[0].duration = .milliseconds(500)
        let store = editorStore(workout)
        let window = await show(NavigationStack { WorkoutEditorView(store: store) })
        defer { window.isHidden = true }
        let field = try #require(textFields(in: window).first { $0.keyboardType == .asciiCapableNumberPad && $0.text == "00:00" })

        #expect(field.becomeFirstResponder())
        await settleRendering()
        #expect(window.endEditing(true))
        await settleRendering()
        #expect(store.state.draft.warmUp[0].duration == .milliseconds(500))

        #expect(field.becomeFirstResponder())
        await settleRendering()
        let delegate = try #require(field.delegate)
        #expect(delegate.textField?(field, shouldChangeCharactersIn: NSRange(location: 0, length: 5), replacementString: "0000") == false)
        #expect(store.state.draft.warmUp[0].duration == .zero)
    }

    @Test
    func test_focus_editorWithMultipleFields_keepsSingleResponder() async throws {
        var workout = makeWorkout()
        workout.warmUp.append(makeStage(11, seconds: 20))
        let store = editorStore(workout)
        let window = await show(NavigationStack { WorkoutEditorView(store: store) })
        defer { window.isHidden = true }
        let fields = textFields(in: window)
        let durations = fields.filter { $0.keyboardType == .asciiCapableNumberPad }
        let first = try #require(durations.first)
        let second = try #require(durations.dropFirst().first)
        let name = try #require(fields.first { $0.text == workout.name })

        for (step, field) in [first, second, name, first].enumerated() {
            #expect(field.becomeFirstResponder())
            await settleRendering()
            let current = textFields(in: window)
            let active = current.filter { $0.isFirstResponder }.map { $0.text ?? "" }.joined(separator: ",")
            let isPresent = current.contains { $0 === field }
            #expect(field.isFirstResponder, "Step \(step): requested \(field.text ?? ""), present \(isPresent), active \(active)")
            #expect(fields.filter(\.isFirstResponder).count == 1)
        }

        #expect(window.endEditing(true))
        await settleRendering()
        let hasResponder = fields.contains { $0.isFirstResponder }
        #expect(!hasResponder)
    }

    @Test
    func test_focus_nativeDurationField_staysSynchronizedWithEditor() async throws {
        let stage = Stage(
            id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)),
            name: "Warm-up",
            duration: .seconds(60),
            intensity: .work
        )
        let probe = FocusProbe()
        let window = await show(FocusHost(stage: stage, probe: probe), width: 320, height: 640)
        defer { window.isHidden = true }
        let field = try #require(textFields(in: window).first)

        #expect(field.becomeFirstResponder())
        await settleRendering()

        #expect(field.isFirstResponder)
        #expect(probe.focus == .stageDuration(stage.id))

        let clearFocus = try #require(probe.clearFocus)
        clearFocus()
        await settleRendering()
        #expect(!field.isFirstResponder)
        #expect(probe.focus == nil)
    }

    private func editorStore(_ workout: Workout) -> StoreOf<WorkoutEditorFeature> {
        Store(initialState: editingState(workout)) {
            WorkoutEditorFeature()
        } withDependencies: {
            $0.continuousClock = TestClock()
        }
    }

    private func show<Content: View>(_ content: Content, width: CGFloat = 390, height: CGFloat = 844) async -> UIWindow {
        let controller = UIHostingController(rootView: content)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        await settleRendering()
        return window
    }

    private func textFields(in view: UIView) -> [UITextField] {
        (view as? UITextField).map { [$0] } ?? view.subviews.flatMap { textFields(in: $0) }
    }

    private func settleRendering() async {
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                RunLoop.main.perform { continuation.resume() }
            }
        }
    }
}

@MainActor
private final class FocusProbe {
    var focus: EditorField?
    var clearFocus: (() -> Void)?
}

private struct FocusHost: View {
    let stage: Stage
    let probe: FocusProbe
    @State private var focus: Stage.ID?

    var body: some View {
        StageDurationField(stage: stage, focus: $focus, hint: nil, onTextChange: { _ in })
            .onChange(of: focus) { _, value in probe.focus = value.map(EditorField.stageDuration) }
            .onAppear { probe.clearFocus = { focus = nil } }
    }
}
