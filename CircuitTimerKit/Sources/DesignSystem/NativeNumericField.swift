import UIKit

/// Numeric groups are not words: tapping between two digits must keep the insertion point there.
final class NativeNumericField: UITextField {
    private var characterTokenizer: NumericTokenizer?

    override var tokenizer: any UITextInputTokenizer {
        if let characterTokenizer { return characterTokenizer }
        let tokenizer = NumericTokenizer(input: self, base: super.tokenizer)
        characterTokenizer = tokenizer
        return tokenizer
    }
}

extension UIView {
    /// TextKit may deliver a selection touch to an internal text view instead of the field itself.
    var isInsideNumericField: Bool {
        sequence(first: self) { $0.superview }.contains { $0 is NativeNumericField }
    }
}

private final class NumericTokenizer: NSObject, UITextInputTokenizer {
    private weak var input: UITextField?
    private let base: any UITextInputTokenizer

    init(input: UITextField, base: any UITextInputTokenizer) {
        self.input = input
        self.base = base
    }

    func rangeEnclosingPosition(
        _ position: UITextPosition,
        with granularity: UITextGranularity,
        inDirection direction: UITextDirection
    ) -> UITextRange? {
        guard granularity == .word else {
            return base.rangeEnclosingPosition(position, with: granularity, inDirection: direction)
        }
        return characterRange(at: position, direction: direction)
    }

    func isPosition(
        _ position: UITextPosition,
        atBoundary granularity: UITextGranularity,
        inDirection direction: UITextDirection
    ) -> Bool {
        guard granularity == .word else {
            return base.isPosition(position, atBoundary: granularity, inDirection: direction)
        }
        guard let input else { return false }
        let offset = input.offset(from: input.beginningOfDocument, to: position)
        return boundaries(of: input.text ?? "").contains(offset)
    }

    func position(
        from position: UITextPosition,
        toBoundary granularity: UITextGranularity,
        inDirection direction: UITextDirection
    ) -> UITextPosition? {
        guard granularity == .word else {
            return base.position(from: position, toBoundary: granularity, inDirection: direction)
        }
        guard let input else { return nil }
        let offset = input.offset(from: input.beginningOfDocument, to: position)
        let boundaries = boundaries(of: input.text ?? "")
        let next = isBackward(direction) ? boundaries.last(where: { $0 < offset }) : boundaries.first(where: { $0 > offset })
        guard let next else { return nil }
        return input.position(from: input.beginningOfDocument, offset: next)
    }

    func isPosition(
        _ position: UITextPosition,
        withinTextUnit granularity: UITextGranularity,
        inDirection direction: UITextDirection
    ) -> Bool {
        guard granularity == .word else {
            return base.isPosition(position, withinTextUnit: granularity, inDirection: direction)
        }
        return characterRange(at: position, direction: direction) != nil
    }

    private func characterRange(at position: UITextPosition, direction: UITextDirection) -> UITextRange? {
        guard let input else { return nil }
        let offset = input.offset(from: input.beginningOfDocument, to: position)
        let boundaries = boundaries(of: input.text ?? "")
        let index = isBackward(direction)
            ? boundaries.lastIndex(where: { $0 < offset })
            : boundaries.lastIndex(where: { $0 <= offset })
        guard let index, index + 1 < boundaries.count else { return nil }
        guard
            let start = input.position(from: input.beginningOfDocument, offset: boundaries[index]),
            let end = input.position(from: input.beginningOfDocument, offset: boundaries[index + 1])
        else { return nil }
        return input.textRange(from: start, to: end)
    }

    // Unlike character positions in TextKit, a digit boundary does not depend on forward/backward affinity.
    private func boundaries(of text: String) -> [Int] {
        text.indices.map { $0.utf16Offset(in: text) } + [text.utf16.count]
    }

    private func isBackward(_ direction: UITextDirection) -> Bool {
        direction.rawValue == UITextStorageDirection.backward.rawValue
            || direction.rawValue == UITextLayoutDirection.left.rawValue
    }
}
