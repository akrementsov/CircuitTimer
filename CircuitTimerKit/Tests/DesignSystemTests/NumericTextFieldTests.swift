@testable import DesignSystem

import Foundation
import Testing
import UIKit

@MainActor
@Suite
struct NumericTextFieldTests {
    @Test(arguments: [1, 4])
    func test_tokenizer_betweenDigits_allowsInsertionAtTappedCharacter(offset: Int) throws {
        let field = NativeNumericField()
        field.text = "01:00"
        let position = try #require(field.position(from: field.beginningOfDocument, offset: offset))

        for storageDirection in [UITextStorageDirection.forward, .backward] {
            let direction = UITextDirection(rawValue: storageDirection.rawValue)
            #expect(field.tokenizer.isPosition(position, atBoundary: .word, inDirection: direction))
            let unit = try #require(field.tokenizer.rangeEnclosingPosition(position, with: .word, inDirection: direction))
            #expect(field.offset(from: unit.start, to: unit.end) == 1)
        }
    }

    @Test
    func test_tokenizer_documentSelection_keepsWholeDuration() throws {
        let field = NativeNumericField()
        field.text = "01:00"
        let position = try #require(field.position(from: field.beginningOfDocument, offset: 1))
        let direction = UITextDirection(rawValue: UITextStorageDirection.forward.rawValue)
        let range = try #require(field.tokenizer.rangeEnclosingPosition(position, with: .document, inDirection: direction))

        #expect(field.offset(from: field.beginningOfDocument, to: range.start) == 0)
        #expect(field.offset(from: field.beginningOfDocument, to: range.end) == 5)
    }

    @Test
    func test_edit_separatorInserted_keepsCaretAfterTypedDigit() throws {
        var received: String?
        let input = NumericTextField(
            text: "12",
            placeholder: "00:00",
            isFocused: false,
            onEdit: { candidate, caret in
                received = candidate
                #expect(caret == 3)
                return ("12:3", 4)
            },
            onFocusChange: { _ in }
        )
        let coordinator = input.makeCoordinator()
        let field = coordinator.makeField()
        let end = try #require(field.position(from: field.beginningOfDocument, offset: 2))
        field.selectedTextRange = field.textRange(from: end, to: end)

        let nativeEdit = coordinator.textField(field, shouldChangeCharactersIn: NSRange(location: 2, length: 0), replacementString: "3")

        #expect(!nativeEdit)
        #expect(received == "123")
        #expect(field.text == "12:3")
        let selection = try #require(field.selectedTextRange)
        #expect(field.offset(from: field.beginningOfDocument, to: selection.start) == 4)
        #expect(field.offset(from: field.beginningOfDocument, to: selection.end) == 4)
    }

    @Test
    func test_edit_normalizedDigitAndSeparator_keepsCaretAfterInsertedDigit() throws {
        let input = NumericTextField(
            text: "12:3",
            placeholder: "00:00",
            isFocused: false,
            onEdit: { candidate, caret in
                #expect(candidate == "1٤2:3")
                #expect(caret == 2)
                return ("14:23", 2)
            },
            onFocusChange: { _ in }
        )
        let coordinator = input.makeCoordinator()
        let field = coordinator.makeField()

        let nativeEdit = coordinator.textField(field, shouldChangeCharactersIn: NSRange(location: 1, length: 0), replacementString: "٤")

        #expect(!nativeEdit)
        #expect(field.text == "14:23")
        let selection = try #require(field.selectedTextRange)
        #expect(field.offset(from: field.beginningOfDocument, to: selection.start) == 2)
        #expect(field.offset(from: field.beginningOfDocument, to: selection.end) == 2)
    }

    @Test(arguments: [
        RejectedInsertion(text: "12:34", offset: 2, digit: "5"),
        RejectedInsertion(text: "01:00", offset: 0, digit: "0"),
    ])
    func test_edit_rejectedDigit_preservesTextAndCaret(example: RejectedInsertion) throws {
        let input = NumericTextField(
            text: example.text,
            placeholder: "00:00",
            isFocused: false,
            onEdit: { _, _ in nil },
            onFocusChange: { _ in }
        )
        let coordinator = input.makeCoordinator()
        let field = coordinator.makeField()
        let end = try #require(field.position(from: field.beginningOfDocument, offset: example.offset))
        field.selectedTextRange = field.textRange(from: end, to: end)

        let nativeEdit = coordinator.textField(
            field,
            shouldChangeCharactersIn: NSRange(location: example.offset, length: 0),
            replacementString: example.digit
        )

        #expect(!nativeEdit)
        #expect(field.text == example.text)
        let selection = try #require(field.selectedTextRange)
        #expect(field.offset(from: field.beginningOfDocument, to: selection.start) == example.offset)
        #expect(field.offset(from: field.beginningOfDocument, to: selection.end) == example.offset)
    }

    struct RejectedInsertion: Sendable {
        let text: String
        let offset: Int
        let digit: String
    }
}
