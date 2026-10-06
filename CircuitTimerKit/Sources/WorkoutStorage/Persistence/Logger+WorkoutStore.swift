import Foundation
import os

extension Logger {
    static let workoutStore = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CircuitTimer", category: "WorkoutStore")
}
