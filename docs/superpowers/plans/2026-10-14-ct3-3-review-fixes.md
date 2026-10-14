# CT-3-3 review fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Close the three remaining review findings in PR #14.
**Architecture:** Preserve a pending restored record until cover appearance. Extract the existing background assertion client into BackgroundExecution. Preserve the writer actor's atomic turns on a dedicated queue executor.
**Tech Stack:** Swift 6, SwiftUI, TCA 1.26.2, Dependencies 1.17.1, Foundation/Dispatch/UIKit, Swift Testing.
**Spec:** ../specs/2026-10-14-ct3-3-review-fixes.md

## Global Constraints

- iOS 17+, Swift 6 complete strict concurrency, Xcode 26.5.
- Existing String Catalogs only, English and Russian; DesignSystem tokens only.
- No changes to saved-record schema, dependency versions or SwiftData persistence.
- Preserve the user's scheme edits and .DS_Store; work in the existing feature worktree.
- Required final verification: make ci and make verify-clean of exact final HEAD; update the existing PR through gh.

## Review Focus

- Repeated cover failures keep the accepted record and let the user retry.
- Retry measures elapsed time at its tap and uses a new owner identifier.
- Finish after a failed cover clears once; failure stays visible.
- A delayed failure action must not replace an already presented destination.
- Newer failed file writes block older ones, and a removed directory is recreated.

### Task 1: Cover recovery

**Files:** AppFeature.swift, AppFeature+RunRestore.swift, AppFeature/Resources/Localizable.xcstrings, Tests/AppFeatureTests/AppFeatureRunRestoreTests.swift.
**Interfaces:** Existing ResumeRunChoice and record client; introduce RunRestore.presenting(StoredRunRecord), retain existing timerPresentationFailed action.
- [ ] Extend exhaustive tests to cover failure -> Retry -> second cover, a second failure, successful appearance, Finish and failed Finish. Watch the recovery assertion fail before changing product code.
- [ ] Keep .presenting(stored) until timerCoverAppeared, then .resolved. Before appearance dismissal restores .offered(stored); deferred failure presents a resumeRun alert with Retry/Finish, guarded against replacing another destination.
- [ ] Add EN/RU retry copy and replace restart instructions. Existing Continue/finished/fresh-timer scenarios still pass.

### Task 2: Shared background assertions

**Files:** Package.swift, Sources/BackgroundExecution/BackgroundTaskClient.swift, dependent feature and fixture imports, AGENTS.md module map.
**Interfaces:** BackgroundTaskClient.begin: @Sendable (String) -> BackgroundTaskToken; end: @Sendable (BackgroundTaskToken) async -> Void.
- [ ] Move the existing client and token without behavioral changes; use Dependencies and DependenciesMacros.
- [ ] Add direct target dependencies/imports for both consumers and tests which access the token through @testable.
- [ ] Verify strict compilation and the existing assertion-release tests.

### Task 3: Writer execution

**Files:** RunRecordFile.swift; WorkoutRunRecordFileTests.swift.
**Interfaces:** Preserve RunRecordFile.write(_:revision:) throws in one synchronous actor turn and WorkoutRunRecordClient.write async throws.
- [ ] Verify executor API availability from the installed Swift SDK. Add a focused executor assertion and a real-file removed-directory recovery regression, observing the missing executor failure before implementation.
- [ ] Use the SDK’s iOS 17 DispatchSerialQueue as the actor’s dedicated serial executor; no custom executor type is needed. Keep revision advancement before I/O and retain all error handling. Reapply backup exclusion after actual directory recreation.
- [ ] Run real-file ordering/failure tests and supported iOS 17.5 file tests.

### Task 4: Delivery

- [ ] Review the combined diff and update timer-engine documentation.
- [ ] Run make ci; commit logical fixes under CT-3-3 milestone policy, preserving user files.
- [ ] Run make verify-clean on a fresh clone of final HEAD.
- [ ] Push and update PR #14 through gh, preserving approved screenshots; confirm final GitHub lint/build-test results.
