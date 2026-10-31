import DesignSystem
import SwiftUI

/// The watch app's root. Until the iPhone has sent its workouts, it asks to open the app there.
public struct WatchRootView: View {
    public init() {}

    public var body: some View {
        ScrollView {
            VStack(spacing: .token(spacing: .xs)) {
                Text("watch.noCatalog.title", bundle: .module)
                    .font(.token(.screenTitle))
                    .foregroundStyle(.text(.primary))
                Text("watch.noCatalog.message", bundle: .module)
                    .font(.token(.note))
                    .foregroundStyle(.text(.secondary))
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
        }
        .background(.surface(.screen))
        .preferredColorScheme(.dark)
    }
}

#Preview {
    WatchRootView()
        .preferredColorScheme(.dark)
}
