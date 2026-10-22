@testable import CloudSync

import CloudKit
import Foundation
import Testing

struct CloudSyncClassificationTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let error: NSError?
        let verdict: CloudSyncClassification.Verdict
    }

    static let cases: [Case] = [
        Case(testDescription: "quota exceeded", error: ckError(.quotaExceeded), verdict: .quotaExceeded),
        Case(testDescription: "not authenticated", error: ckError(.notAuthenticated), verdict: .recheckAccount),
        Case(testDescription: "account unavailable", error: ckError(.accountTemporarilyUnavailable), verdict: .recheckAccount),
        Case(testDescription: "network unavailable", error: ckError(.networkUnavailable), verdict: .transient),
        Case(testDescription: "network failure", error: ckError(.networkFailure), verdict: .transient),
        Case(testDescription: "service unavailable", error: ckError(.serviceUnavailable), verdict: .transient),
        Case(testDescription: "rate limited", error: ckError(.requestRateLimited), verdict: .transient),
        Case(testDescription: "zone busy", error: ckError(.zoneBusy), verdict: .transient),
        Case(testDescription: "server record changed", error: ckError(.serverRecordChanged), verdict: .transient),
        Case(testDescription: "cancelled", error: ckError(.operationCancelled), verdict: .cancelled),
        Case(testDescription: "Cocoa 134400", error: cocoaError(134_400), verdict: .recheckAccount),
        Case(testDescription: "Cocoa 134406", error: cocoaError(134_406), verdict: .recheckAccount),
        Case(testDescription: "Cocoa 134419", error: cocoaError(134_419), verdict: .transient),
        Case(testDescription: "Cocoa 134417", error: cocoaError(134_417), verdict: .transient),
        Case(
            testDescription: "CKError underlying another domain",
            error: NSError(domain: "Other", code: 1, userInfo: [NSUnderlyingErrorKey: ckError(.quotaExceeded)]),
            verdict: .quotaExceeded
        ),
        Case(testDescription: "no error", error: nil, verdict: .failed),
        Case(testDescription: "unknown domain", error: NSError(domain: "Other", code: 1), verdict: .failed),
        Case(testDescription: "unknown CloudKit code", error: ckError(.internalError), verdict: .failed),
        Case(
            testDescription: "partial failure of batch items only",
            error: partialFailure([.batchRequestFailed, .batchRequestFailed]),
            verdict: .transient
        ),
        Case(testDescription: "partial failure without items", error: ckError(.partialFailure), verdict: .failed),
        Case(
            testDescription: "quota among items",
            error: partialFailure([.batchRequestFailed, .quotaExceeded, .networkFailure]),
            verdict: .quotaExceeded
        ),
        Case(
            testDescription: "quota beats not authenticated",
            error: partialFailure([.notAuthenticated, .quotaExceeded]),
            verdict: .quotaExceeded
        ),
        Case(
            testDescription: "cancelled with transient",
            error: partialFailure([.operationCancelled, .networkFailure]),
            verdict: .transient
        ),
        Case(
            testDescription: "transient with unknown code",
            error: partialFailure([.networkFailure, .internalError]),
            verdict: .failed
        ),
        Case(
            testDescription: "Cocoa 134400 wrapping a CKError",
            error: cocoaError(134_400, underlying: ckError(.networkFailure)),
            verdict: .transient
        ),
    ]

    @Test(arguments: cases)
    func test_verdict_error_classifiesByWhatTheUserIsTold(_ testCase: Case) {
        #expect(CloudSyncClassification.verdict(for: testCase.error) == testCase.verdict)
    }

    private static func ckError(_ code: CKError.Code) -> NSError {
        CKError(code) as NSError
    }

    private static func cocoaError(_ code: Int, underlying: NSError? = nil) -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: code, userInfo: underlying.map { [NSUnderlyingErrorKey: $0] } ?? [:])
    }

    private static func partialFailure(_ codes: [CKError.Code]) -> NSError {
        let items = Dictionary(uniqueKeysWithValues: codes.enumerated().map { index, code in
            (CKRecord.ID(recordName: "record-\(index)"), ckError(code))
        })
        return CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: items]) as NSError
    }
}
