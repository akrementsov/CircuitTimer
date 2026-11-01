import Foundation
import os

extension Logger {
    static let purchases = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CircuitTimer", category: "Purchases")
}
