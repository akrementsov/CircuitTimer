import SwiftUI

/// The app's stopwatch logo in the brand color, as on the launch screen. Decorative: the text next to it names the
/// screen.
public struct AppLogo: View {
    public init() {}

    public var body: some View {
        Image("AppLogo", bundle: .module)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: .token(size: .logo))
            .foregroundStyle(.brand)
            .accessibilityHidden(true)
    }
}

#Preview {
    AppLogo()
        .padding()
        .background(.surface(.screen))
        .preferredColorScheme(.dark)
}
