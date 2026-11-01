import Foundation
import os

extension Logger {
    static let watchLink = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CircuitTimer", category: "WatchLink")
}
