@testable import PurchaseFeature

import ComposableArchitecture
import Purchases
import SnapshotCapture
import SwiftUI
import Testing
import UIKit

extension SnapshotTests {
    @MainActor
    @Suite
    struct PurchaseSnapshotTests {
        /// A price in another storefront's format: the sheet shows the App Store's `displayPrice` as it comes.
        @Test(arguments: SnapshotTextSize.currentCases())
        func test_purchase_workoutLimit_matchesReference(textSize: SnapshotTextSize) async throws {
            try await assertPurchaseSnapshot(textSize: textSize) {
                .shown(.limit(.workoutLimit), price: FullVersionOffer(displayPrice: "€1,29"))
            }
        }

        @Test(arguments: SnapshotTextSize.currentCases())
        func test_purchase_purchasing_matchesReference(textSize: SnapshotTextSize) async throws {
            try await assertPurchaseSnapshot(textSize: textSize) {
                var state = PurchaseFeature.State.shown(.browse)
                state.operation = .purchasing
                return state
            }
        }

        @Test(arguments: SnapshotTextSize.currentCases())
        func test_purchase_restoring_matchesReference(textSize: SnapshotTextSize) async throws {
            try await assertPurchaseSnapshot(textSize: textSize) {
                var state = PurchaseFeature.State.shown(.restore)
                state.operation = .restoring
                return state
            }
        }

        @Test(arguments: SnapshotTextSize.currentCases())
        func test_purchase_awaitingApproval_matchesReference(textSize: SnapshotTextSize) async throws {
            try await assertPurchaseSnapshot(textSize: textSize) {
                var state = PurchaseFeature.State.shown(.browse)
                state.isPending = true
                return state
            }
        }

        @Test(arguments: SnapshotTextSize.currentCases())
        func test_purchase_storeUnavailable_matchesReference(textSize: SnapshotTextSize) async throws {
            try await assertPurchaseSnapshot(textSize: textSize) {
                var state = PurchaseFeature.State.shown(.browse)
                state.offer = .unavailable
                return state
            }
        }

        @Test(arguments: SnapshotTextSize.currentCases())
        func test_purchase_purchased_matchesReference(textSize: SnapshotTextSize) async throws {
            try await assertPurchaseSnapshot(textSize: textSize) {
                var state = PurchaseFeature.State.shown(.browse)
                state.status = .full
                state.didUnlockHere = true
                return state
            }
        }
    }
}

extension PurchaseFeature.State {
    /// The sheet once it has appeared and StoreKit has answered `.free`.
    fileprivate static func shown(
        _ entry: PurchaseFeature.Entry,
        price: FullVersionOffer = FullVersionOffer(displayPrice: "$0.99")
    ) -> Self {
        var state = Self(entry: entry)
        state.hasStarted = true
        state.offer = .loaded(price)
        state.status = .free
        return state
    }
}

/// Draws `PurchaseView` as the window's root: `assertAppSnapshot` refuses a presented destination, and a sheet does not
/// draw in the first frame. The state has appeared already, so the view's `.task` changes nothing.
@MainActor
private func assertPurchaseSnapshot(
    textSize: SnapshotTextSize,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    function: StaticString = #function,
    line: UInt = #line,
    column: UInt = #column,
    state: () -> PurchaseFeature.State
) async throws {
    let testName = function.description.prefix { $0 != "(" }
    try await assertFirstFrameSnapshot(
        textSize: textSize,
        testName: String(testName),
        filePath: filePath,
        sourceLocation: SourceLocation(fileID: fileID.description, filePath: filePath.description, line: Int(line), column: Int(column))
    ) { variant in
        withDependencies(SnapshotDependencies.prepare) {
            let store = Store(initialState: state()) { PurchaseFeature() }
            let controller = UIHostingController(
                rootView: PurchaseView(store: store)
                    .environment(\.locale, variant.locale)
                    .environment(\.dynamicTypeSize, variant.dynamicTypeSize)
                    .preferredColorScheme(.dark)
            )
            return SnapshotRoot(controller: controller, tabBar: .none)
        }
    }
}
