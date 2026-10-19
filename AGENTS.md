# AGENTS.md

Rules for anyone — human or AI agent — changing CircuitTimer. `CLAUDE.md` only points here.

## Core rules

1. **Platform:** iOS 17+, Swift 6 language mode with complete strict concurrency, Xcode 27.1.
2. **Versions:** read them from `CircuitTimerKit/Package.resolved`; never assume an API exists.
3. **Design system:** UI uses `DesignSystem` tokens only. The app is dark only (`UIUserInterfaceStyle = Dark`): color tokens carry the original app's palette, one universal value each, and every package `#Preview` sets `.preferredColorScheme(.dark)`; the Live Activity keeps the same dark palette whatever the system theme. Literal or system colors and fonts (`Color.red`, `.foregroundStyle(.secondary)`, `.font(.headline)`, `UIColor`) fail lint outside `Sources/DesignSystem/`. The app's `AccentColor` asset and the fill of `LaunchLogo.svg` mirror the `Brand` token, and `LaunchBackground` mirrors `.surface(.screen)`; change them together.
   - Fonts ship in `Sources/DesignSystem/Resources/Fonts/` with their license and are registered at runtime from `Bundle.module`; `Font.custom` lives only in `DesignSystem`.
4. **Dependencies:** reach the outside world through `@Dependency` clients, read by key path. No singletons, no static mutable state. A new client, key or storage strategy also gets a value that is not live in `AppScenario.prepare` (see UI tests); `make lint` fails without one, as long as a key's declaration keeps `DependencyKey` on its first line. It cannot see our own `SharedKey`s: a new one needs its default store replaced there by hand.
5. **Navigation:** state-driven — `@Presents` + `@Reducer enum Destination` for modals, `StackState` + `@Reducer enum Path` for pushes. A feature never knows its container; it talks up only through `delegate` actions. A pushed screen that must not close unasked hides the system back button: a SwiftUI pop reaches the reducer as `popFrom`, which removes the element without a veto.
6. **Every commit passes `make verify-clean`.** A squash-merged pull request may run it at milestones instead; its last commit always passes it.

## Engineering principles

- **High cohesion, low coupling.** A module owns one context and is reached through a narrow interface.
- **Earn every abstraction.** Add a layer only for a need you can name today; prefer duplication over the wrong abstraction.
- **Cut indirection, not file count.** Remove forwarding-only wrappers; keep the split by concern.
- **Build on what exists.** Reuse the project's mechanism instead of a hand-rolled copy.
- **Handle every error explicitly.** Loud for developers (`os.Logger`), graceful for users (a visible state). Never an empty `catch`, never a dropped `try?`.
- **Pin behavior with tests before changing it.** A test must fail when the behavior it guards breaks.
- **Debug from evidence.** Reproduce, observe the real values, fix the cause, add a regression test.
- **Read what goes stale.** Check versioned API facts in the source instead of recalling them.

## Module map

One local package, `CircuitTimerKit`; every module is a library product, so the package scheme builds all of them. The app target in `CircuitTimer.xcodeproj` composes `AppFeature`, configures TipKit and calls the injected `BackgroundNotificationClient.installForegroundSuppression` at launch. In Debug it builds the store from a UI test scenario of `AppScenarios` when the launch asks for one. The UI test target `CircuitTimerUITests` in the same project links only `UITestContract`. The app imports `BackgroundNotifications`, and in Debug `AppScenarios` and `UITestContract`; TCA reexports Dependencies for the hook. The widget extension `CircuitTimerWidgets` draws the Live Activity from `WorkoutActivity` and `DesignSystem` only; lint covers it like the package.

| Module | Depends on | Owns |
|---|---|---|
| `BackgroundExecution` | Dependencies, DependenciesMacros, Foundation, UIKit, os | `BackgroundTaskClient` and its token for bounded background work |
| `BackgroundNotifications` | Dependencies, DependenciesMacros, Foundation, UserNotifications, UIKit, os | Owner-scoped local notification queue, permission access, early foreground delegate and orphan cleanup |
| `WorkoutDomain` | Foundation, CryptoKit | Workout model, `WorkoutLimits`, `WorkoutSchedule` and its fingerprint, `WorkoutRun` and its `Outlook`, `TimeMath` |
| `WorkoutActivity` | `WorkoutDomain`, Dependencies, DependenciesMacros, Foundation, ActivityKit, os | The Live Activity: its attributes and a compact `ContentState` built from a settled run, `WorkoutActivityDisplay` (what the Lock Screen and the Dynamic Island show), `LiveActivityClient` and its coordinator |
| `DesignSystem` | SwiftUI, UIKit, CoreText | Spacing, radius, size, typography and color tokens; clock text; the stage clock view in the bundled League Gothic; screen chrome; card rows and the bottom action panel; row swipe plaques and drag reorder with edge auto-scroll in `CardScrollView`; the tab bar kept to the stacks' roots; the swipe between tabs on a stack's root; the Live Activity's typography |
| `WorkoutStorage` | `WorkoutDomain`, Dependencies, SwiftData | `WorkoutStorageClient` and its SwiftData store; `WorkoutRunRecordClient` and the run record file |
| `UITestContract` | — | Accessibility identifiers shared by the app and its UI tests; in Debug also the scenario names, the launch keys and the fixture names the tests read |
| `WorkoutEditorFeature` | `DesignSystem`, `UITestContract`, `Workout*`, ComposableArchitecture, TipKit | The workout screen: a saved workout read-only with Start, and the editor of a draft saved or discarded as a whole; stage durations typed as MM:SS; a dimmed Save explained by an alert, VoiceOver and a one-time tip with its `SaveTipClient` |
| `WorkoutTimerFeature` | `BackgroundNotifications`, `BackgroundExecution`, `DesignSystem`, `TimerPreferences`, `UITestContract`, `WorkoutActivity`, `WorkoutDomain`, `WorkoutStorage`, ComposableArchitecture, UIKit | The timer screen: foreground tones, haptics and spoken stage names; countdowns, the clock loops over a `WorkoutRun`, `TimerSessionClient`, saving its run under `BackgroundTaskClient`; syncing its Live Activity; its own stack with the stage list |
| `TimerPreferences` | Sharing | The Sound, Vibration, Speak names, Background notifications and Keep screen on toggles: `@Shared(.appStorage)` keys, on by default |
| `SettingsFeature` | `BackgroundNotifications`, `DesignSystem`, `TimerPreferences`, ComposableArchitecture | The Settings tab: signal toggles, its navigation stack, About with the app version, the legal pages |
| `AppFeature` | all of the above, ComposableArchitecture | Root feature: the tab bar, the workout list, pushing the workout screen onto the Workouts stack, presenting the timer full screen on its Start, or after a relaunch when the user continues a saved run; composes Settings |
| `AppScenarios` | `BackgroundExecution`, `BackgroundNotifications`, `SettingsFeature`, `UITestContract`, `WorkoutActivity`, `WorkoutDomain`, `WorkoutEditorFeature`, `WorkoutStorage`, `WorkoutTimerFeature`, Dependencies, Foundation, Sharing | Debug only: each UI test scenario's dependencies, none of them live, and its workouts |

Layering:

- `*Feature` → `DesignSystem`, `Workout*`, `TimerPreferences`, `BackgroundExecution`, `BackgroundNotifications`. A feature never imports another feature; composition happens in `AppFeature`.
- Features import `UITestContract` only for accessibility identifiers. `AppScenarios` is all under `#if DEBUG`, so Release links it empty; only the app imports it, in Debug, and it imports features only for their clients.
- `BackgroundExecution` owns background-task assertions shared by `AppFeature` and `WorkoutTimerFeature`; it imports no feature, TCA, or workout module.
- `BackgroundNotifications` imports no feature, TCA or workout module; the app, Settings and timer use only its dependency client.
- `AppFeature` reads `TimerPreferences` to gate the first Start permission request.
- `SettingsFeature` needs no workout module and imports none.
- `TimerPreferences` depends only on Sharing: Settings writes the timer preferences and the timer reads them, so neither feature imports the other.
- `WorkoutTimerFeature` reads no workouts: `AppFeature` hands it a `WorkoutSchedule`. Of `WorkoutStorage` it uses only `WorkoutRunRecordClient`, to save its own run.
- `Workout*` never imports TCA or SwiftUI. `WorkoutDomain` depends on none of our modules.
- `WorkoutActivity` imports `WorkoutDomain` and no feature, TCA or SwiftUI. iOS limits an activity's attributes and state to 4 KB together, so `ContentState` carries a stage, its boundary dates and the next stage, never a whole `WorkoutRun`. The timer syncs it, `AppFeature` ends what earlier processes left, and `CircuitTimerWidgets` only draws it.

## Essential commands

| Command | What it does |
|---|---|
| `make lint` | SwiftLint in strict mode (`SWIFTLINT=` to use a specific binary or command line, such as CI's `docker run`), then `scripts/check-scenario-dependencies.sh` |
| `make test-scripts` | Runs `scripts/tests/test-*.sh`: the scripts and the make targets around xcodebuild against fixtures and stand-ins for xcodebuild and xcrun, and the custom lint rules against Swift fixtures linted with `SWIFTLINT` |
| `make test` | Builds and tests the package with warnings as errors through `scripts/run-tests.sh`; the result bundle and log go to `.build/TestResults/Package-<run>.{xcresult,log}` and DerivedData to `.build/DerivedData/Package-<run>`, with `<run>` as in `make test-ui`, and a failed local run prints its failures |
| `make build-app` | Builds the app for the simulator without signing |
| `make build-ui-tests` | Builds the app with its UI tests for `DESTINATION` exactly as `make test-ui` does, into its DerivedData |
| `make check-resolved` | Fails if the package and project lockfiles pin different versions |
| `make resolve` | Re-resolves both lockfiles |
| `make test-ui` | Builds the app and runs its UI tests on `DESTINATION`; the result bundle and log go to `.build/TestResults/UITests-<run>.{xcresult,log}` and DerivedData to `.build/DerivedData/UITests-<run>`, where `TEST_RUN` (`iPhone-17-2-27.0` for `iPhone 17 #2` on 27.0) comes from `DESTINATION`. `UI_TEST_WORKERS` (1 by default) sets Xcode's parallel workers |
| `make ci` | `lint`, `test-scripts`, `check-resolved`, `test`, `build-ui-tests`, `test-ui` |
| `make verify-clean` | Runs `make ci` on a fresh clone of exactly `HEAD` — run before every commit, or at milestones in a squash-merged pull request |
| `make archive BUILD_NUMBER=…` | Archives the Release app without signing |
| `make check-release-app` | Fails if a file of the archived app names a UI test scenario's type, module, launch key or fixture |
| `make upload ASC_KEY_PATH=… ASC_KEY_ID=… ASC_ISSUER_ID=…` | Signs the archive in the cloud and uploads it to App Store Connect |

`SWIFTLINT` must be an absolute path or a command on `PATH`, optionally with arguments: `verify-clean` runs inside a temporary clone.

## Delivery

- A tag `v<MARKETING_VERSION>` (or `v<MARKETING_VERSION>-<suffix>` for another build of the same version) on a commit of `main` whose CI passed runs `testflight.yml`, which archives and uploads to TestFlight. The build number is the UTC start time, `YYMMDD.HHMMSS`.
- The archive is unsigned: an App Store Connect API key signs only at export, with a cloud-managed distribution certificate, so the key needs the Admin role. `testflight.yml` checks the archive for `NSSupportsLiveActivities`, the extension and, with `make check-release-app`, the absence of UI test scenarios, then confirms that the app and `CircuitTimerWidgets.appex` carry App Store signatures of the team in a separate signed IPA export, because the upload leaves no exported files to read (`scripts/verify-export-signing.py`, run with `python3 -I`). These checks run before the upload, so a wrong signature or a failed check stops the run with nothing uploaded and the reports kept as a run artifact; re-running it archives and uploads under a new build number. The upload signs again on its own, so a passing check is strong evidence about the uploaded build, not a proof. CT-5 extends the check with its entitlements.
- `Configs/App.xcconfig` holds the bundle IDs (`APP_BUNDLE_ID`, `WIDGETS_BUNDLE_ID`), `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` for both targets: App Store Connect flags an extension whose version differs from the app's.
- `ExportOptions.plist` repeats the team ID from `App.xcconfig`; change both together.
- `claude-review.yml` reviews a pull request from this repository with `claude -p` through the pinned superpowers plugin (its `requesting-code-review` skill) when it is opened, reopened or marked ready for review, and again on the `claude-review` label, which the run removes; every review is a new comment that names the reviewed commit; the prompt is `.github/claude-review.md`. It needs the `ANTHROPIC_API_KEY` secret from the Console organization that receives the Max plan's monthly API credits. It is not a required check.

## Toolchain

- CI pins Xcode 27.1 on the `xcode-27` runner image, still a GitHub preview. Tests run on the iOS 27.0 simulator that the image ships. CI boots the simulator before the tests, and `scripts/run-tests.sh` runs them once more when the test runner hangs before connecting and the result bundle holds no test, which the preview image's simulator sometimes does; a failing package test is not retried. After the package tests CI builds the app with its UI tests in a step of its own, also when they failed, and runs the UI tests on the same simulator. `scripts/report-test-results.sh` reports every bundle in `.build/TestResults/`: failures as annotations, tests that passed only on a retry as warnings, and in the step summary the 20 tests with the most own time. Tests run in parallel, so most of a test's total time is waiting for the others in its process; own time is estimated from the start and length of each test in the bundle's action log. A failed run, or one with a flaky test, keeps the bundles and logs as an artifact. Only runs on `main` save the package sources and DerivedData to the cache, and a Linux job then deletes all but the newest DerivedData cache, which keeps the repository under GitHub's 10 GB. The `lint` job runs on Ubuntu in SwiftLint's own Docker image, which has the SourceKit our custom rules need, so it takes none of the plan's five concurrent macOS jobs; it also runs `make test-scripts`, so the scripts' tests run with GNU tools and mawk as well. Scripts run with bash 3.2 and with BSD or GNU tools and mawk. After switching Xcode run `make resolve` and `make check-resolved`, then commit **both** `Package.resolved` files: newer Swift tools pick different package manifests and resolve a different graph.
- Warnings are errors everywhere we control them. The app target sets `SWIFT_TREAT_WARNINGS_AS_ERRORS`. The package turns on `.treatAllWarnings(as: .error)` only when `CIRCUITTIMER_STRICT_WARNINGS=1`, which `make test` and `make build-package` set: when the app builds the package as a dependency, Xcode passes `-suppress-warnings`, and the two flags conflict. Strict and non-strict builds use separate DerivedData because the evaluated manifest is cached there.
- Locally, tests and screen checks use only four simulators: `iPhone 17` (`DESTINATION`), `iPhone 17 #2` and `iPhone 17 #3` on iOS 27.0, and `iPhone 15` on iOS 17.5 for checks on the oldest supported iOS. One job runs on a device at a time; a parallel job takes a free one, for example `make test DESTINATION='platform=iOS Simulator,name=iPhone 17 #2,OS=27.0'`, or waits. Create no other simulators; if one of the four is missing, recreate exactly it.
- Parallel UI test workers (`UI_TEST_WORKERS` above 1) make Xcode clone the simulator, so `make test-ui` allows them only with `CI=true`. Locally, UI tests run in parallel only on different allowed simulators, each `make test-ui` with its own `DESTINATION`, and only after one run on each has finished alone: the first run resolves the shared package checkouts, which later runs only read.
- A failing UI test runs once more (`-retry-tests-on-failure -test-iterations 2`); one that passes only then is reported as flaky and keeps its result bundle as an artifact. Package tests get no retry. A UI test fails after 60 s, or after its own `executionTimeAllowance` up to 120 s.
- The launch screen lives in `Configs/Info.plist`, which Xcode merges with the generated `INFOPLIST_KEY_*` keys. The file is not a member of any target: Copy Bundle Resources would conflict with the generated plist.

## TCA

TCA is built with the `ComposableArchitecture2Deprecations` trait, so APIs going away in 2.0 are unavailable.

```swift
@Reducer
public struct SomeFeature: Sendable {
    @ObservableState
    public struct State: Equatable, Sendable {}

    public enum Action: ViewAction, Equatable, Sendable {
        case view(View)
        case `internal`(Internal)
        case delegate(Delegate)

        @CasePathable public enum View: Equatable, Sendable {}
        @CasePathable public enum Internal: Equatable, Sendable {}
        @CasePathable public enum Delegate: Equatable, Sendable {}
    }

    public var body: some ReducerOf<Self> { … }   // dispatches to `reduce(into:_:)` per action group
}
```

- Views are `@ViewAction(for:)` and only `send` actions; no logic in `body`.
- Presentation goes through `$store.scope(\.$destination, action: \.destination).<case>`. An alert without actions is a plain `case alert(AlertState<Never>)`; a confirmation dialog or an alert with actions is a `@ReducerCaseIgnored` case with a hand-written `Destination.Action`, otherwise the scoped binding drops the chosen action (see `WorkoutEditorFeature`).
- A pushed screen with no state or effects of its own is a `@ReducerCaseIgnored` `Path` case that carries its data; its view sends the stack owner's actions (see `SettingsFeature`).
- The workout editor is the `editor` case of `AppFeature.Path` on the Workouts stack. It hides the system back button, which also turns off the edge and content back gestures on iOS 17 and 26, so it leaves only through `backButtonTapped`; a Workouts tab re-tap sends it the same action, but only while it is read-only.
- The editor has phases: `new`, `viewing` (a saved workout, read-only) and `editing` (after the pencil). `workout` is the workout exactly as stored and is what plays; `original` is the base of the draft, with the rounds lifted into the editor's range. A save returns to `viewing`. Start sends `startRequested` with `workout`; `AppFeature` waits for notification permission when needed, validates the same viewing workout before presentation and calls `cancelStart()` if that intent is cancelled; it presents the timer only into an empty destination and empties the Workouts stack once the cover has appeared.
- The editor's Save flags read the comparable draft (names trimmed), so spaces around a name are no change; a changed stage that would not play keeps Save dimmed, and `saveBlocker` says why. A stage duration's typed text and its last accepted text live in `StageDurationField`, which sends each accepted edit synchronously from `NumericTextField`'s native edit callback, so Back and Save never miss the last digit; focus never reaches the reducer. The field's tokenizer treats each character as a word boundary, keeping taps between digits in place, and `StageDurationText` maps the caret through the MM:SS mask. Native duration fields use a view-local selected stage ID; only SwiftUI name fields register with `FocusState`, so each input has one responder owner. TipKit has three points: the app configures it, the view shows `SaveWorkoutTip`, and the reducer invalidates it through `SaveTipClient` after a tap on the dimmed Save, hiding it at once with `saveTipSuppressed`. The view sends `layoutChanged` from `.task(id: phase)` and when the keyboard goes; the reducer clears `hasSettled` and sets it again after `tipSettleDelay` on `continuousClock`, by generation, so the tip never points at Save while the screen moves. Tests that send `layoutChanged` use a `TestClock`. Leaving a name field sends `nameFieldLeft` or `stageNameFieldLeft`, and the reducer trims the name before a pending Back or Save arrives.
- The workout timer is the `timer` case of `AppFeature.Destination`, a full-screen cover. Like the editor it closes itself with `dismiss()`, the accepted exception to talking up only through `delegate` actions. Every close path first ends the screen's `TimerSessionClient` session, `CueClient` owner, notification owner and Live Activity owner, so a clock loop that starts after the teardown returns before it sleeps. The container never replaces or nils a presented timer; if anything else dismisses the cover, it ends all four owners afterwards, which drops the keep-awake vote, stops cue output and removes the activity.
- The timer owns its own stack, `WorkoutTimerStack`; the stage list is a `@ReducerCaseIgnored` case of `WorkoutTimerFeature.Path` that carries a `WorkoutOutline`. Opening it pauses a running stage or drops a 3-2-1, and leaving it keeps the run paused.
- Long-running or replaceable effects get a `CancelID`; reloads use `cancelInFlight: true`.
- Catch `CancellationError` before the generic `catch` — cancellation is not a failure.
- Clocks, dates and UUIDs come from `@Dependency` (`continuousClock`, `date`, `uuid`); lint rejects `Date()` and `UUID()`.
- Reducers call only synchronous generator dependencies: `uuid`, `date`, `continuousClock` (`now` for an anchor), `nextRevision` of the run record and of `liveActivity`. The single exception with an effect on the outside world is `backgroundTask.begin`, used by the timer and by `AppFeature` around record writes: a `.run` effect starts as a later main-actor task, and the app can be suspended before it runs, so the assertion is taken in the reducer and the effect returned in the same pass ends it. Don't copy this for anything else.
- Bridge callback APIs through an `AsyncStream` that the effect stays suspended on; never let `send` escape the effect.
- Add only the action groups a feature needs (the root feature has no `Delegate`).

## Screens

- A stack that keeps the tab bar to its root puts `tabBarOnlyOnRoot(isPushed:)` on the root, under `tabBarOnlyOnRoots()` on the `TabView`; the Workouts stack does. Before iOS 26 the root hides it through SwiftUI, as hidden by the pushed screen it would come back only after the pop, and a bottom panel on a pushed screen stands on the home indicator's inset so it doesn't drop when the bar goes at the end of the push; no root has a bottom panel. On iOS 26 SwiftUI's tab bar ignores `hidesBottomBarWhenPushed`, so `TabBarRidesWithRoot` carries a picture of the bar away with the root, hides the bar through UIKit and covers it for a moment after the pop while its glass settles. The picture lies in the root's own view, so it moves with it; UIKit logs that a `_UIReplicantView` in a `UIHostingController.view` is not supported, which is accepted. Measured on iOS 17.5 and 26.5 only, not on 18–25. With the bar gone from the workout screen, a Workouts tab re-tap no longer reaches it from the UI; the reducer still handles it.
- A horizontal swipe on a tab's root turns to the neighbouring tab, as a tap on it would: `onPageSwipe` on each tab's navigation stack puts a UIKit pan on the tab's controller view, so the navigation bar and the whole screen take it, while pushed screens keep their own gestures. It waits for the swipe and the lift of the row under the finger and never starts on a switch; the 12 pt gap between cards belongs to the nearest card through the touch tolerance. From iOS 18 it names the row's recognizers; before, the row's swipe is a SwiftUI drag, and SwiftUI holds the pan until that drag fails or takes the touch, which is measured, not expressed in our code. Measured on iOS 17.5, 18.5 and 26.5.
- `ReorderableRows` measures every row, so it never sits in a lazy container, and only inside a `CardScrollView`, the one place that injects `RowInteraction`.
- Swiped and reordered rows read only the items their list captured: a row that reads the store observes them on its own and is redrawn apart from the list while a drag settles, showing the wrong item.

## Time

- `keepScreenOn` is on by default. A timer prevents automatic screen lock only while this preference is on and its countdown or a timed stage is running; a paused, waiting or finished run lets the screen lock. Its awake vote follows preference changes without restarting the clock.
- UI must call `WorkoutRun.tick(at:)` and then `snapshot(at:)` on every update; `snapshot` alone never commits progress.
- Never convert between `Date` and `Duration` outside `TimeMath`.
- `rebase(at:keepingTotalElapsed:)` is the recovery point after a backward clock change.
- The timer runs at most one clock loop, a 3-2-1 countdown or a tick loop. Each loop carries a generation in its cancel id and in every action it sends; an action from an older generation only cancels its own loop.
- A loop only sleeps and wakes; the reducer measures and commits. Before every tick and user action it checks the clock anchor, a wall date and a `continuousClock` instant read together and refreshed on every tick, through `TimeMath`'s public `Date.elapsed(since:)`. A backward jump rebases the run to the progress the monotonic clock vouches for; a forward jump is logged and kept, like time in the background.
- `snapshot` without `tick` appears in two places only: the tick loop's own copy of the run, which schedules wake-ups and is never shown or committed, and the state's initial snapshot at `.distantPast` of a run that is idle or finished.
- A tick loop that ends while the committed run still runs reports `isFinal`, and the reducer starts a new one.
- One clock instance per timer session: a `MonotonicInstant` checks only the type of its instant.
- `WorkoutTimerStack` forwards `scenePhase`; the run continues through `.inactive` (Control Center and the App Switcher), while signals stop until `.active`. Leaving resets a 3-2-1 to its full length and runs no countdown until the app is back, then counts it from 3. A running run takes a fresh anchor as it leaves, so on return the same process's anchor measures the time away and a clock moved back is rebased. Every write is under a background-task assertion; what the file holds is the newest write that completed.
- Across a process restart only the record's `sinceEpochMs` survives: a clock moved back past it re-anchors at the saved position, a smaller backward move undercounts, a forward one counts as elapsed time (`docs/timer-engine.md` › Saved runs).

## Domain limits

Anything that edits a workout applies `WorkoutLimits.normalizedStages(_:)` and `normalizedTrainingRounds(_:)`, and UI limits match `WorkoutLimits`. Otherwise the user would see stages that never reach the schedule.

A stage name may be empty; anything that displays a stage shows its intensity name instead. Storage keeps the empty name, so the fallback follows the current language.

New input of a workout or stage name goes through `WorkoutLimits.limitedName(_:previous:)`: at most `maxNameLength` characters, an edit past it rejected whole. A longer name stored before the limit shows in full, also in the Live Activity, which never cuts a name by length; an activity over the 4 KB limit ends and the timer shows its footnote. While it remains over the limit, any edit is accepted only if it reduces the character count, including a replacement with unrelated shorter text; an edit of the same length or longer is rejected whole.

## UI tests

How to add one, step by step: README › UI tests.

- Accessibility identifiers come from `UITestContract`'s `AccessibilityID`, named `<screen>.<element>`; lint rejects any other argument of `.accessibilityIdentifier`. An element repeated in a list is named by its section and position, never by user data. Text the user typed and system elements are found by their text.
- A scenario is a case of `AppScenario` that the launch selects with `CT_APP_SCENARIO`. In Debug, `CircuitTimerApp` builds its store with `AppScenario.prepare`, which sets every client and key the app reads to a value that is not live. It stops the app on an unknown name, and outside the `preview` dependency context (`SWIFT_DEPENDENCIES_CONTEXT=preview`): `init` reads its clients from the process's context, not from the store. Release has no scenarios; `make check-release-app` checks the archive.
- Time stands still in a scenario: `continuousClock` is a `TestClock` that nothing advances, `date` is constant and `uuid` counts up, so a started timer stays on its first countdown digit. The timer's logic is tested with `TestStore` and `TestClock`, not through the UI.
- A scenario's workouts live in the process's memory (`WorkoutStorageClient.scenario`). Reading, saving and reordering work; insert and delete stop the app until a scenario needs them. Preferences go to `UserDefaults.inMemory`, a new suite at every launch.
- TipKit keeps its configured datastore on the device; the UI tests hide tips with the `-com.apple.TipKit.HideAllTips 1` launch argument.

## Identifiers

Public initializers take `id` explicitly; features get identifiers from `@Dependency(\.uuid)`. Deterministic `UUID(uuid:)` is fine in samples and tests.

## Persistence (CT-2, CT-5)

- Domain types never become `@Model` types; persistence maps to and from them.
- Durations are stored as `Int` milliseconds.
- CloudKit sync: no `@Attribute(.unique)`; every property optional or defaulted; relationships optional; stage order kept in an explicit `order` field.
- A saved run is `WorkoutRunRecord` v1 with explicit `CodingKeys`: `schemaVersion`, `workoutID`, `scheduleFingerprint`, `phase`, `positionMs`, `cursor`, `sinceEpochMs`. The fingerprint is a SHA-256 of the normalized schedule structure (index, section, round, round count, kind, stage id, duration in ms; not the name). On restore, rebuild the schedule and drop the record if the fingerprint differs or `cursor` is out of range.
- Run records live outside SwiftData: one JSON file in Application Support (`RunRecord/WorkoutRun.json`), excluded from backup on a best-effort basis. The body is exactly the v1 record.
- Writes go through one actor on a dedicated serial queue executor, in the order of a revision the reducer takes from `nextRevision()`; a failed write leaves the file as it was and is retried at the next sync, and until one succeeds the timer warns that the run may not come back or may come back in an earlier state. These writes have no `CancelID`: the revision orders them, and an in-flight write must finish. Reads open the file on their own queue.
- The timer writes its run on every clock sync — every operation, jump and change of status, and every time the app leaves the screen — but not on a tick that changes none of them, and clears it after the cover is dismissed; `AppFeature` clears it once more when the cover goes.
- At launch `AppFeature` cleans notification requests from previous process owners in parallel with reading the record; cleanup never delays the restore deadline. It reads the record, racing the read against a 2 s timeout, and then loads the workouts; the restore decision is made at the first load, before another screen can be opened. A run that ended while the app was gone, or a paused one older than 24 hours, is dropped silently. A record that cannot be restored (workout changed or gone, file corrupt, unreadable or from another version) shows one alert; only a corrupt file is removed. A stall while reading shows that alert before the app knows whether a file exists — accepted. Otherwise the list asks «Continue the workout “<name>”?»: Continue settles the run at the tap and opens the timer in its saved phase, after the alert has gone. The accepted record stays until the cover appears; if presentation fails, an error offers Retry (settled at the new tap, with a fresh timer owner) or Finish in the same session. Finish clears the record and says so if that fails. iOS keeps the scene session after an App Switcher swipe (seen on iOS 26.5 and 26.7.1), so the app cannot tell a force quit from a system kill or a crash: every process death asks, and a return from the background never does.

## Errors

Log with `os.Logger` and move the UI to an explicit state. Do not log expected outcomes such as cancellation.

## Tests

- Swift Testing (`@Test`, `#expect`, `#require`); `@MainActor` suites for features.
- `TestStore` is exhaustive by default; override dependencies per test; use `TestClock`, never real sleeps.
- Name tests `test_method_state_expected`.
- Declare a test target only together with a committed source file: SwiftPM rejects a declared target whose directory is missing on a clean checkout. Test targets use the same `strictSettings`.
- `WorkoutRun` keeps `position` and `cursor` readable through `@testable import` so tests can check its invariants.
- UI tests are the exception: a UI test target runs XCTest. A test is a `@MainActor final class <Area>UITests: XCTestCase` with a synchronous `setUp`, if any, and methods named `test_<start>_<action>_<expected>`. It starts with `let app = launch(.<scenario>)` and drives the app through Screens (`CircuitTimerUITests/Screens/`), which wait for the app and report failures at the test's line. Lint rejects `sleep`, waits outside `Screens/` and `Support/`, and `XCUIApplication()` outside `Support/Launch.swift`.
- UI tests share no state and depend on no order: each launches its own app into its scenario. Scenario data lives in the app's process; TipKit's datastore on the simulator is the one thing tests share; `launch` hides tips, and a test of a tip needs a launch option that resets the datastore and shows them.
- Only time depends on order: Xcode runs the classes by name, and `AppLaunchUITests` comes first, so the slow first launch on a fresh simulator falls on its short test. Keep it first; a class named before it takes that launch.

## Imports

Sorted, grouped by attributes: `@testable import` first, an empty line, then plain imports. Import Foundation explicitly where it is used.

## Files and comments

- No file headers; files start with imports.
- Comments are English and explain constraints that the code cannot. No history, no commented-out code.
- `// MARK:` only to group five or more related members.
- `TODO` and `FIXME` carry a ticket: `// TODO: [CT-123] …` or `// TODO: [CT-UI-2] …`.

## Lint exceptions

Disable a rule only for one line, with the reason on the line above:

```swift
// TimelineProvider receives no injected clock.
// swiftlint:disable:next no_direct_date
let now = Date()
```

## Localization

String Catalogs only: `Localizable.xcstrings` in each module that shows text (`Text("key", bundle: .module)`), semantic keys, English and Russian. The app's `InfoPlist.xcstrings` gives the main bundle a Russian localization — iOS needs it before it picks Russian strings from packages.

DesignSystem has no catalog: a feature passes its own strings into DesignSystem views as `Text("key", bundle: .module)`.

`CircuitTimerWidgets` has its own `Localizable.xcstrings` and reads it with `Text("key")`: in an extension the main bundle is the extension's.

## Git

- Branch `CT-<n>-short-slug` from `main`; commits `CT-<n>: Imperative description`. A milestone split into slices uses `CT-<milestone>-<n>` instead of `CT-<n>` (`CT-UI-1-dark-tokens`, `CT-UI-1: …`).
- One logical change per commit, and every commit passes `make verify-clean` (at milestones only in a squash-merged pull request, see core rule 6).
- Amend only the last commit before moving on; fix older commits with a separate `CT-<n>: Fix …` commit.
- `main` changes only through pull requests, which are squash-merged once `lint` and `build-test` pass. The PR title becomes the commit subject, so it follows the same `CT-<n>: Imperative description` format.

## Signals

- `TimerPreferences` keys never change and contain no dots; all signals are on by default.
- `CueEngine` owns the audio session and outputs on one private serial queue. State methods check `dispatchPrecondition`; never use `assumeIsolated`, which cannot verify that executor on iOS 17.
- Narrow exception to injected clocks: its 1.5-second idle deactivation uses an `AnySchedulerOf<DispatchQueue>` passed to the initializer, live on the engine queue. The deadline must survive cue task cancellation; no reducer timing depends on it.
- While the session is active and no output plays, one valid idle deadline is pending. Admission replaces it, successful output start invalidates it, and completion reschedules it. Errors keep it alive.
- A cancelled task stops waiting; a newer revision, owner-scoped suspend/end, resign-active or the idle deadline stops audio and releases ducking.
- Tones are reproducible 44.1 kHz mono PCM WAV resources; regenerate with `swift scripts/generate-cue-tones.swift` from the root.
- `SignalTrack` compares settled snapshots once per reducer action and emits at most one event: countdown digit, finish, new stage (with name), same-stage resume (without name), or the current last three seconds. No skipped event is replayed.
- A fresh or resumed countdown beeps its current digit once. A restored running run is a silent baseline; a restored paused run announces the stage on resume. Returning from an inactive scene marks the current stage as seen.
- Foreground signals run only in an active scene with the timer visible, outside its stage list and close alert. Leaving clears the baseline and haptic and suspends through the last cue revision.
- A VoiceOver-only cue preempts without activating audio, then posts a low-priority announcement only while active and uncancelled. Speech uses the app language; an absent voice reports a failure instead of falling back to another language. `Speech.xcstrings` owns Work/Rest/Pause.
- Each foreground switch gates only its output; Sound also gates the system sound of a background notification. Haptics are state revisions consumed by `.sensoryFeedback`; failure kinds are cleared only by a result proving that output recovered. Signal failures never stop the workout.

## Background notifications (CT-3-5)

- `signalBackgroundNotifications` is a separate, default-on preference. First Start requests alert/sound permission before creating the timer; Continue of a saved run never prompts. A delayed request offers Start now / Wait without treating a slow user as a failure.
- `BackgroundNotifications` holds one foreground delegate installed through its client in `CircuitTimerApp.init`. It suppresses the module's presentation in foreground; background delivery belongs to iOS.
- The timer projects at most 32 stage starts/finish events, ending at a manual pause, on every settled action. State stores only a compact key; payloads belong to effects/client. A truncated window adds an open-app notice to the last real event. No last-three-second background cues, speech or independent haptics.
- The client fences physical identifiers by owner/revision, protects active owners from late orphan reads, and removes stale add completions by their own ID. End installs a tombstone before dispatching removal. iOS does not acknowledge removal.
- A fresh pending snapshot verifies still-future coverage; imminent missing requests remain unconfirmed and are not replayed. Retry uses injected monotonic time (10 seconds), plus active-scene reconciliation. Cleanup waits at most 500 ms per caller and coalesces/rate-limits physical sweeps to 30 seconds.
- Already scheduled requests may fire after suspension or process death. The app cannot refill the window or repair clock changes until it runs again. Delivery time, Focus, silence, system sound and vibration follow iOS settings. Notification failures never stop a workout or hide record/audio/voice failures.

## Live Activity (CT-4)

- The timer syncs its Live Activity after every action once its clock has started, not only on a clock sync: a stage that ends on a tick reaches the Lock Screen without a record write or a new loop. `ContentState(run:at:)` ticks a copy and reads its snapshot and `outlook(at:)`. The start countdown reads as `getReady`, the resume countdown as `paused`.
- The content is the running stage with its boundary dates and the next stage with its end. `staleDate` is the stage end. The display counts the stage down by itself, and the next stage counts from the stage end by itself. Once iOS marks the content stale it shows the next stage and asks to open the app for anything after it. iOS redraws stale content no earlier than about two minutes after the last update (measured on iOS 17.5 and 26.5). A held stage shows a fixed time: `Text(timerInterval:pauseTime:)` with a future `pauseTime` does not hold, so there is no workout total.
- A counting `Text(timerInterval:)` has no width of its own and breaks a layout under `fixedSize`; the clocks take the width of a hidden template of League Gothic's widest digit and win over names.
- `LiveActivityCoordinator` owns everything else: one queue per owner that applies the newest revision on a loop a cancelled caller does not stop, content it already shows is never sent again, and a finished run ends the activity with the standard dismissal; its final card stays, also through later syncs, until `end(owner)`. The live transport keeps the activities this process requested, so an update or end reaches one that iOS has not listed yet. `end(owner)` installs a tombstone, removes the activity at once and waits at most 500 ms. The timer calls it on every close path before `dismiss()`, and `AppFeature` again when the cover goes another way. `endOrphans` runs at launch in parallel with reading the run record and never delays it.
- `sync` returns a `LiveActivityNotice` only when the footnote should change; the reducer accepts it only with a larger `serial`. Live Activities off before the timer's first activity: nothing shows and no footnote, and once they are turned on the next sync starts one. An activity that goes while it shows, removed by the user or ended by iOS when they are turned off, does not come back for that timer, also without a footnote. A failure no retry can fix (over 4 KB, unentitled, unsupported) ends the activity and keeps the footnote. Others retry on the next sync. An activity iOS has not listed 10 s after its request is ended and requested again on a later sync, so two never show.
- No background assertion, push server or audio mode. Accepted limits: the finished card stays until the timer closes or iOS removes it; an activity of a killed process stays until the next launch; StandBy, the watch Smart Stack (iOS 18) and CarPlay (iOS 26) show the same views without separate checks.
