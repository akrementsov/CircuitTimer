import SwiftUI
import WorkoutDomain

/// Minutes and seconds wheels; together they cover exactly `0…WorkoutLimits.maxStageDuration`.
struct StageDurationPicker: View {
    let duration: Duration
    let onChange: (Duration) -> Void

    var body: some View {
        let (minutes, seconds) = duration.minutesAndSeconds
        HStack(spacing: .zero) {
            Picker(selection: Binding(get: { minutes }, set: { onChange(.seconds($0 * 60 + seconds)) })) {
                ForEach(0...99, id: \.self) { value in
                    Text("editor.duration.minutes \(value)", bundle: .module).tag(value)
                }
            } label: {
                Text("editor.duration.minutesLabel", bundle: .module)
            }
            Picker(selection: Binding(get: { seconds }, set: { onChange(.seconds(minutes * 60 + $0)) })) {
                ForEach(0...59, id: \.self) { value in
                    Text("editor.duration.seconds \(value)", bundle: .module).tag(value)
                }
            } label: {
                Text("editor.duration.secondsLabel", bundle: .module)
            }
        }
        .pickerStyle(.wheel)
    }
}

extension Duration {
    /// Whole minutes and the remaining seconds; milliseconds are dropped.
    var minutesAndSeconds: (minutes: Int, seconds: Int) {
        let total = Int(components.seconds)
        return (total / 60, total % 60)
    }
}
