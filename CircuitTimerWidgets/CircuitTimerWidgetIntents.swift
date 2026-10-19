import AppIntents
import WorkoutActivity

// WorkoutActivity is linked statically and its metadata is merged here. Re-exporting it breaks lookup on iOS 17.
struct CircuitTimerWidgetIntents: AppIntentsPackage {}
