import ComposableArchitecture
import Foundation
import Testing

private let timerPreferenceTraceKeys = [
    "signalSound", "signalVibration", "signalSpokenStageNames",
    "signalBackgroundNotifications", "timerKeepScreenOn", "iCloudSync",
]

struct TimerPreferenceTraceTests {
    @Test
    func test_report_lifecycle_keepsIdentityAndOrderedEventsThenReleases() throws {
        let defaults = UserDefaults.inMemory
        var trace: TimerPreferenceTrace? = TimerPreferenceTrace(defaults, label: "lifecycle")
        weak let releasedTrace = trace
        trace?.mark("first marker")
        trace?.mark("second marker")

        let report = try #require(trace?.report)
        #expect(report.hasPrefix("test=lifecycle store=\(ObjectIdentifier(defaults)) suite="))
        let begin = try #require(report.range(of: " begin"))
        let first = try #require(report.range(of: " first marker"))
        let second = try #require(report.range(of: " second marker"))
        #expect(begin.lowerBound < first.lowerBound)
        #expect(first.lowerBound < second.lowerBound)

        trace = nil
        #expect(releasedTrace == nil)
        for key in timerPreferenceTraceKeys {
            defaults.set(true, forKey: key)
            #expect(defaults.object(forKey: key) as? Bool == true)
        }
    }

    @Test(arguments: timerPreferenceTraceKeys)
    func test_observeValue_changedPreference_recordsItsValuesAndIgnoresOtherKeys(key: String) throws {
        let defaults = UserDefaults.inMemory
        let trace = TimerPreferenceTrace(defaults, label: key)
        defer { withExtendedLifetime(trace) {} }

        defaults.set(false, forKey: key)
        #expect(trace.report.contains(" KVO key=\(key) "))
        let before = defaults.object(forKey: key)
        #expect(before as? Bool == false)
        defaults.set(true, forKey: key)
        let after = defaults.object(forKey: key)
        #expect(after as? Bool == true)

        let change = try #require(trace.report.split(separator: "\n").last { $0.contains(" KVO key=\(key) ") })
        #expect(change.contains("old=\(String(describing: before)) new=\(String(describing: after)) "))
        #expect(change.contains(" stack="))
        let beforeOtherKey = trace.report
        defaults.set(true, forKey: "unrelatedPreference")
        #expect(trace.report == beforeOtherKey)
    }

    @Test
    func test_report_concurrentEvents_keepsAllMarkersAndWholeSnapshots() async {
        // NSUserDefaults.h permits sharing this thread-safe object; the SDK has no Sendable conformance.
        nonisolated(unsafe) let defaults = UserDefaults.inMemory
        defaults.set(false, forKey: "signalSound")
        let trace = TimerPreferenceTrace(defaults, label: "concurrent")
        defer { withExtendedLifetime(trace) {} }
        let results = await withTaskGroup(
            of: (reports: [String], writerIsMainThread: Bool?).self,
            returning: (reports: [String], writerIsMainThread: Bool?).self
        ) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    // TestStore redirects Swift tasks globally; GCD keeps this writer off main.
                    DispatchQueue.global().async {
                        continuation.resume(returning: writePreferenceTraceChanges(in: defaults, to: trace))
                    }
                }
            }
            for worker in 0..<4 {
                group.addTask {
                    var reports: [String] = []
                    for event in 0..<20 {
                        trace.mark("marker-\(worker)-\(event)")
                        reports.append(trace.report)
                    }
                    return (reports, nil)
                }
            }
            var reports: [String] = []
            var writerIsMainThread: Bool?
            for await result in group {
                reports.append(contentsOf: result.reports)
                if let isMainThread = result.writerIsMainThread {
                    writerIsMainThread = isMainThread
                }
            }
            return (reports, writerIsMainThread)
        }

        #expect(results.writerIsMainThread == false)
        let invalidSnapshot = results.reports.firstIndex { !preferenceTraceIsWhole($0) }
        #expect(invalidSnapshot == nil)
        let finalReport = trace.report
        #expect(preferenceTraceIsWhole(finalReport))
        let entries = finalReport.split(separator: "\n").dropFirst()
        let markers = entries.compactMap { $0.split(separator: " ").last }.filter { $0.hasPrefix("marker-") }
        let expectedMarkers = Set((0..<4).flatMap { worker in (0..<20).map { "marker-\(worker)-\($0)" } })
        #expect(Set(markers.map(String.init)) == expectedMarkers)
        #expect(markers.count == expectedMarkers.count)
        let changes = entries.filter { $0.contains(" KVO key=signalSound ") }
        #expect(!changes.isEmpty)
        #expect(changes.allSatisfy { $0.contains("main=false KVO key=signalSound ") })
    }
}

private func preferenceTraceIsWhole(_ report: String) -> Bool {
    let entries = report.split(separator: "\n").dropFirst()
    let indices = entries.compactMap { $0.split(separator: " ", maxSplits: 1).first }.compactMap { Int($0) }
    return !entries.isEmpty && indices == Array(0..<entries.count)
}

// There is no suspension between identifying the writer thread and recording its writes.
private func writePreferenceTraceChanges(
    in defaults: UserDefaults,
    to trace: TimerPreferenceTrace
) -> (reports: [String], writerIsMainThread: Bool?) {
    let isMainThread = Thread.isMainThread
    var reports: [String] = []
    for value in 0..<20 {
        defaults.set(value.isMultiple(of: 2), forKey: "signalSound")
        reports.append(trace.report)
    }
    return (reports, isMainThread)
}
