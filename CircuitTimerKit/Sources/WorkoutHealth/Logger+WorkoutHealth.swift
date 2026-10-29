import Foundation
import os

extension Logger {
    static let workoutHealth = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CircuitTimer", category: "WorkoutHealth")
}
