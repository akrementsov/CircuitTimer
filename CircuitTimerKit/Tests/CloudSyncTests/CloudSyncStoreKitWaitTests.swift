@testable import CloudSync

import Dependencies
import Purchases
import Testing

struct CloudSyncStoreKitWaitTests {
    @Test(arguments: [(false, "iCloud.test"), (true, nil)] as [(Bool, String?)])
    func test_waitForStoreKit_switchOffOrNoContainer_asksNothing(isOn: Bool, containerID: String?) async {
        let asked = LockIsolated<[Duration]>([])

        await CloudSyncClient.waitForStoreKit(isICloudSyncOn: isOn, containerID: containerID) { timeout in
            asked.withValue { $0.append(timeout) }
            return .full
        }

        #expect(asked.value.isEmpty)
    }

    @Test(arguments: [FullVersionStatus.full, .unknown])
    func test_waitForStoreKit_switchOnWithAContainer_asksForAtMostASecond(answer: FullVersionStatus) async {
        let asked = LockIsolated<[Duration]>([])

        await CloudSyncClient.waitForStoreKit(isICloudSyncOn: true, containerID: "iCloud.test") { timeout in
            asked.withValue { $0.append(timeout) }
            return answer
        }

        #expect(asked.value == [.seconds(1)])
    }
}
