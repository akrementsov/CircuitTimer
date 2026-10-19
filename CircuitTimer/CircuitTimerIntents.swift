import AppIntents
import WorkoutActivity

struct CircuitTimerIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [WorkoutActivityIntents.self] }
}
