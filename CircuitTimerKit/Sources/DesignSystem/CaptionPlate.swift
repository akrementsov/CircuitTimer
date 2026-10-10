import SwiftUI

/// A centered caption on a field plate inside a card, such as the training's round count on a read-only screen.
public struct CaptionPlate: View {
    private let text: Text

    public init(_ text: Text) {
        self.text = text
    }

    public var body: some View {
        text
            .font(.token(.body))
            .foregroundStyle(.text(.primary))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.token(spacing: .l))
            .background(.surface(.field), in: RoundedRectangle(cornerRadius: .token(radius: .m), style: .continuous))
    }
}
