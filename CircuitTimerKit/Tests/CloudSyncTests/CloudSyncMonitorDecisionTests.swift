@testable import CloudSync

import CloudKit
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct CloudSyncMonitorDecisionTests {
    struct Launch: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let preference: Bool
        let container: String?
        let opened: Bool?
        let mirrored: String?
        let status: CloudSyncStatus
        let readsContainer: Bool
    }

    static let launches: [Launch] = [
        Launch(
            testDescription: "on with a container",
            preference: true,
            container: MonitorHarness.container,
            opened: nil,
            mirrored: MonitorHarness.container,
            status: CloudSyncStatus(isRequested: true, isMirroring: nil, problem: nil),
            readsContainer: true
        ),
        Launch(
            testDescription: "off",
            preference: false,
            container: MonitorHarness.container,
            opened: nil,
            mirrored: nil,
            status: CloudSyncStatus(isRequested: false, isMirroring: nil, problem: nil),
            readsContainer: false
        ),
        Launch(
            testDescription: "on without a container",
            preference: true,
            container: nil,
            opened: nil,
            mirrored: nil,
            status: CloudSyncStatus(isRequested: true, isMirroring: nil, problem: .syncFailed),
            readsContainer: true
        ),
        Launch(
            testDescription: "on, opened locally",
            preference: true,
            container: MonitorHarness.container,
            opened: false,
            mirrored: MonitorHarness.container,
            status: CloudSyncStatus(isRequested: true, isMirroring: false, problem: .syncFailed),
            readsContainer: true
        ),
        Launch(
            testDescription: "off, opened locally",
            preference: false,
            container: MonitorHarness.container,
            opened: false,
            mirrored: nil,
            status: CloudSyncStatus(isRequested: false, isMirroring: false, problem: nil),
            readsContainer: false
        ),
    ]

    @Test(arguments: launches)
    func test_mirroredContainer_preferenceContainerAndOpening_decidesAndReports(_ launch: Launch) async {
        let harness = MonitorHarness(preference: launch.preference, container: launch.container)

        #expect(harness.monitor.mirroredContainer() == launch.mirrored)
        if let opened = launch.opened {
            harness.monitor.storeOpened(isMirroring: opened)
        }

        #expect(harness.monitor.mirroredContainer() == launch.mirrored)
        #expect(await harness.monitor.status().next() == launch.status)
        #expect(harness.containerReads.value == (launch.readsContainer ? 1 : 0))
    }

    @Test(arguments: [true, false])
    func test_mirroredContainer_preferenceChangedAfterDecision_keepsDecision(isOn: Bool) async {
        let harness = MonitorHarness(preference: isOn)
        let decided = harness.monitor.mirroredContainer()

        harness.preference.setValue(!isOn)

        #expect(decided == (isOn ? MonitorHarness.container : nil))
        #expect(harness.monitor.mirroredContainer() == decided)
        #expect(await harness.monitor.status().next()?.isRequested == isOn)
        #expect(harness.preferenceReads.value == 1)
    }

    @Test
    func test_decision_concurrentFirstCalls_readsPreferenceOnce() async {
        let harness = MonitorHarness()

        await withTaskGroup(of: Void.self) { group in
            for index in 0 ..< 20 {
                group.addTask {
                    if index.isMultiple(of: 2) {
                        _ = harness.monitor.mirroredContainer()
                    } else {
                        _ = await harness.monitor.status().next()
                    }
                }
            }
        }

        #expect(harness.preferenceReads.value == 1)
        #expect(harness.containerReads.value == 1)
    }

    @Test
    func test_status_subscribers_getCurrentStatusFirstThenEachChange() async throws {
        let harness = MonitorHarness()
        let first = harness.monitor.status()
        #expect(await first.next() == CloudSyncStatus(isRequested: true, isMirroring: nil, problem: nil))

        harness.monitor.storeOpened(isMirroring: true)
        #expect(await first.next() == MonitorHarness.mirroring(nil))
        try await harness.accounts.next().answer.resume(returning: .noAccount)
        #expect(await first.next() == MonitorHarness.mirroring(.noAccount))

        let second = harness.monitor.status()
        #expect(await second.next() == MonitorHarness.mirroring(.noAccount))

        harness.fail(.setup, error: CKError(.notAuthenticated))
        try await harness.accounts.next().answer.resume(returning: .available)
        #expect(await first.next() == MonitorHarness.mirroring(nil))
        #expect(await second.next() == MonitorHarness.mirroring(nil))
    }
}
