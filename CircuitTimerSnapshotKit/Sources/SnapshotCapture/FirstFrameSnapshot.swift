import Foundation
import os
import SnapshotTesting
import Testing
import UIKit

public enum TabBarExpectation: Sendable {
    case none
    case shown(selectedStackDepth: Int)
    case hidden(selectedStackDepth: Int)
}

@MainActor
public struct SnapshotRoot {
    public let controller: UIViewController
    public let tabBar: TabBarExpectation

    public init(controller: UIViewController, tabBar: TabBarExpectation) {
        self.controller = controller
        self.tabBar = tabBar
    }
}

@MainActor
public func assertFirstFrameSnapshot(
    textSize: SnapshotTextSize,
    testName: String,
    filePath: StaticString,
    sourceLocation: SourceLocation,
    makeRoot: (SnapshotVariant) throws -> SnapshotRoot
) async throws {
    let processLanguage = Locale.preferredLanguages.first.flatMap {
        Locale.Language(identifier: $0).languageCode?.identifier
    } ?? "unknown"
    var key = "\(testName).\(processLanguage)-\(textSize.rawValue)"
    let reference = SnapshotReference(filePath: filePath, testName: testName, variantName: "\(processLanguage)-\(textSize.rawValue)")
    let journal = SnapshotJournal()
    var attempt = "first"

    do {
        let variant = SnapshotVariant(language: try SnapshotLanguage.current(), textSize: textSize)
        try textSize.validateProcess()
        key = "\(testName).\(variant.name)"
        try reference.validateNames()
        let mode = try SnapshotReference.recordMode()
        let previous = try reference.load()
        let strategy = SnapshotImageComparison.strategy
        let diffing = strategy.diffing
        let first = try await SnapshotWindow.firstFrame(variant: variant, makeRoot: makeRoot)
        if first.succeeded, let previous, diffing.diffV2(previous.image, first.image) == nil {
            try journal.append(key: key, path: reference.relativePath, attempt: attempt, outcome: "passed")
            return
        }

        attempt = "second"
        let second = try await SnapshotWindow.firstFrame(variant: variant, makeRoot: makeRoot)
        guard second.succeeded else {
            throw SnapshotCaptureFailure("drawHierarchy failed on the second mount.")
        }
        let secondData = diffing.toData(second.image)
        let message = verifySnapshot(
            of: second.image,
            as: strategy,
            named: variant.name,
            record: mode,
            snapshotDirectory: reference.directory.path,
            file: filePath,
            testName: testName,
            line: UInt(sourceLocation.line),
            column: UInt(sourceLocation.column)
        )
        let outcome: String
        if message == nil {
            outcome = "passed"
        } else if mode == .failed, let recorded = try reference.load(),
                  recorded.data != previous?.data, recorded.data == secondData {
            outcome = "recorded"
        } else {
            outcome = "failed"
        }
        try journal.append(key: key, path: reference.relativePath, attempt: attempt, outcome: outcome)
        if let message {
            Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation)
        }
    } catch is CancellationError {
        try journal.append(key: key, path: reference.relativePath, attempt: attempt, outcome: "error")
        throw CancellationError()
    } catch {
        SnapshotCaptureFailure.logger.error("Snapshot failed: \(String(reflecting: error), privacy: .public)")
        do {
            try journal.append(key: key, path: reference.relativePath, attempt: attempt, outcome: "error")
        } catch let journalError {
            throw SnapshotCaptureFailure("\(error) Capture journal also failed: \(journalError)")
        }
        throw error
    }
}

struct SnapshotCaptureFailure: Error, CustomStringConvertible {
    static let logger = Logger(subsystem: "CircuitTimerSnapshotKit", category: "Capture")
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var description: String {
        "\(message) Runtime: \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }
}
