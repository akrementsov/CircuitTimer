import AppIntents
import WorkoutActivity

struct CircuitTimerWidgetIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [WorkoutActivityIntents.self] }
}
