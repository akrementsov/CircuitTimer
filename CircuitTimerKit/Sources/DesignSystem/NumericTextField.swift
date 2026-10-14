import CoreText
import Foundation
import os
import SwiftUI
import UIKit

/// A centered numeric field with character-level insertion points. The callback accepts, formats or rejects an edit
/// synchronously, including the caret's UTF-16 offset in the formatted text.
public struct NumericTextField: UIViewRepresentable {
    private let text: String
    private let placeholder: String
    private let isFocused: Bool
    private let onEdit: (String, Int) -> (text: String, caretOffset: Int)?
    private let onFocusChange: (Bool) -> Void

    public init(
        text: String,
        placeholder: String,
        isFocused: Bool,
        onEdit: @escaping (String, Int) -> (text: String, caretOffset: Int)?,
        onFocusChange: @escaping (Bool) -> Void
    ) {
        self.text = text
        self.placeholder = placeholder
        self.isFocused = isFocused
        self.onEdit = onEdit
        self.onFocusChange = onFocusChange
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public func makeUIView(context: Context) -> UITextField { context.coordinator.makeField() }

    public func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        field.isEnabled = context.environment.isEnabled
        if field.text != text { field.text = text }
        if isFocused, !field.isFirstResponder {
            field.becomeFirstResponder()
        } else if !isFocused, field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    @MainActor
    public final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: NumericTextField

        init(_ parent: NumericTextField) { self.parent = parent }

        func makeField() -> NativeNumericField {
            let field = NativeNumericField()
            field.delegate = self
            field.keyboardType = .asciiCapableNumberPad
            field.autocorrectionType = .no
            field.textAlignment = .center
            field.textColor = UIColor(Color.text(.primary))
            field.tintColor = UIColor(Color.brand)
            field.adjustsFontForContentSizeCategory = true
            field.font = Self.bodyFont()
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            field.attributedPlaceholder = NSAttributedString(
                string: parent.placeholder,
                attributes: [.foregroundColor: UIColor(Color.text(.secondary)), .paragraphStyle: paragraph]
            )
            field.text = parent.text
            return field
        }

        public func textFieldDidBeginEditing(_ textField: UITextField) { parent.onFocusChange(true) }

        public func textFieldDidEndEditing(_ textField: UITextField) { parent.onFocusChange(false) }

        public func textField(
            _ field: UITextField,
            shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            let oldText = field.text ?? ""
            guard let editRange = Range(range, in: oldText) else {
                Logger.designSystem.error("The numeric field received an invalid edit range.")
                return false
            }
            let candidate = oldText.replacingCharacters(in: editRange, with: string)
            let insertionOffset = range.location + string.utf16.count
            // A rejected edit leaves both the text and the exact pre-edit selection untouched, even with repeats.
            guard let edit = parent.onEdit(candidate, insertionOffset) else { return false }

            field.text = edit.text
            guard
                let position = field.position(from: field.beginningOfDocument, offset: edit.caretOffset),
                let selection = field.textRange(from: position, to: position)
            else {
                Logger.designSystem.error("Could not restore the numeric field's selection after formatting.")
                return false
            }
            field.selectedTextRange = selection
            return false
        }

        private static func bodyFont() -> UIFont {
            let font = UIFont.token(.body)
            let descriptor = font.fontDescriptor.addingAttributes([
                .featureSettings: [
                    [
                        UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
                        UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector,
                    ],
                ],
            ])
            return UIFont(descriptor: descriptor, size: .zero)
        }
    }
}
