# AGENTS.md

Rules for anyone — human or AI agent — changing CircuitTimer. `CLAUDE.md` only points here.

## Core rules

1. **Platform:** iOS 17+, Swift 6 language mode with complete strict concurrency, Xcode 26.5.
2. **Versions:** read them from `CircuitTimerKit/Package.resolved`; never assume an API exists.
3. **Design system:** UI uses `DesignSystem` tokens only. The app is dark only (`UIUserInterfaceStyle = Dark`): color tokens carry the original app's palette, one universal value each, and every package `#Preview` sets `.preferredColorScheme(.dark)`; how the widget and Live Activity follow the system theme is decided in CT-4. Literal or system colors and fonts (`Color.red`, `.foregroundStyle(.secondary)`, `.font(.headline)`, `UIColor`) fail lint outside `Sources/DesignSystem/`. The app's `AccentColor` asset and the fill of `LaunchLogo.svg` mirror the `Brand` token, and `LaunchBackground` mirrors `.surface(.screen)`; change them together.
   - Fonts ship in `Sources/DesignSystem/Resources/Fonts/` with their licence and are registered at runtime from `Bundle.module`; `Font.custom` lives only in `DesignSystem`.
4. **Dependencies:** reach the outside world through `@Dependency` clients. No singletons, no static mutable state.
5. **Navigation:** state-driven — `@Presents` + `@Reducer enum Destination` for modals, `StackState` + `@Reducer enum Path` for pushes. A feature never knows its container; it talks up only through `delegate` actions. A pushed screen that must not close unasked hides the system back button: a SwiftUI pop reaches the reducer as `popFrom`, which removes the element without a veto.
6. **Every commit passes `make verify-clean`.**

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

One local package, `CircuitTimerKit`; every module is a library product, so the package scheme builds all of them. The app target in `CircuitTimer.xcodeproj` only composes `AppFeature`.

| Module | Depends on | Owns |
|---|---|---|
| `WorkoutDomain` | Foundation | Workout model, `WorkoutLimits`, `WorkoutSchedule`, `WorkoutRun`, `TimeMath` |
| `DesignSystem` | SwiftUI | Spacing, radius, size, typography and color tokens; clock text; screen chrome |
| `WorkoutStorage` | `WorkoutDomain`, Dependencies, SwiftData | `WorkoutStorageClient` and its SwiftData store |
| `WorkoutEditorFeature` | `DesignSystem`, `Workout*`, ComposableArchitecture | The workout editor: a draft saved or discarded as a whole |
| `WorkoutTimerFeature` | `DesignSystem`, `WorkoutDomain`, ComposableArchitecture | The timer screen: countdowns, the clock loops over a `WorkoutRun`, `TimerSessionClient` |
| `SettingsFeature` | `DesignSystem`, ComposableArchitecture | The Settings tab: its navigation stack, About with the app version, the legal pages |
| `AppFeature` | all of the above, ComposableArchitecture | Root feature: the tab bar, the workout list, pushing the editor onto the Workouts stack, presenting the timer full screen; composes Settings |

Layering:

- `*Feature` → `DesignSystem`, `Workout*`. A feature never imports another feature; composition happens in `AppFeature`.
- `SettingsFeature` needs no workout module and imports none.
- `WorkoutTimerFeature` imports no storage module: `AppFeature` hands it a `WorkoutSchedule`.
- `Workout*` never imports TCA or SwiftUI. `WorkoutDomain` depends on none of our modules.
- Planned: `WorkoutActivity` (CT-4, ActivityKit + `WorkoutDomain`) with a compact `ContentState` — a Live Activity state is limited to about 4 KB, so it never carries a whole `WorkoutRun`; a widget extension target that depends on `WorkoutActivity` and `DesignSystem`.

## Essential commands

| Command | What it does |
|---|---|
| `make lint` | SwiftLint in strict mode (`SWIFTLINT=` to use a specific binary) |
| `make test` | Builds and tests the package with warnings as errors |
| `make build-app` | Builds the app for the simulator without signing |
| `make check-resolved` | Fails if the package and project lockfiles pin different versions |
| `make resolve` | Re-resolves both lockfiles |
| `make ci` | `lint`, `check-resolved`, `test`, `build-app` |
| `make verify-clean` | Runs `make ci` on a fresh clone of exactly `HEAD` — run before every commit |
| `make archive BUILD_NUMBER=…` | Archives the Release app without signing |
| `make upload ASC_KEY_PATH=… ASC_KEY_ID=… ASC_ISSUER_ID=…` | Signs the archive in the cloud and uploads it to App Store Connect |

`SWIFTLINT` must be an absolute path or a command on `PATH`: `verify-clean` runs inside a temporary clone.

## Delivery

- A tag `v<MARKETING_VERSION>` (or `v<MARKETING_VERSION>-<suffix>` for another build of the same version) on a commit of `main` whose CI passed runs `testflight.yml`, which archives and uploads to TestFlight. The build number is the UTC start time, `YYMMDD.HHMMSS`.
- The archive is unsigned: an App Store Connect API key signs only at export, with a cloud-managed distribution certificate, so the key needs the Admin role. CT-4 and CT-5 must check that the exported app keeps their entitlements.
- `ExportOptions.plist` repeats the team ID from `App.xcconfig`; change both together.
- `claude-review.yml` reviews a pull request from this repository with `claude -p` through the pinned superpowers plugin (its `requesting-code-review` skill) when it is opened, reopened or marked ready for review, and again on the `claude-review` label, which the run removes; every review is a new comment that names the reviewed commit; the prompt is `.github/claude-review.md`. It needs the `ANTHROPIC_API_KEY` secret from the Console organization that receives the Max plan's monthly API credits. It is not a required check.

## Toolchain

- CI pins Xcode 26.5. After switching Xcode run `make resolve` and `make check-resolved`, then commit **both** `Package.resolved` files: newer Swift tools pick different package manifests and resolve a different graph.
- Warnings are errors everywhere we control them. The app target sets `SWIFT_TREAT_WARNINGS_AS_ERRORS`. The package turns on `.treatAllWarnings(as: .error)` only when `CIRCUITTIMER_STRICT_WARNINGS=1`, which `make test` and `make build-package` set: when the app builds the package as a dependency, Xcode passes `-suppress-warnings`, and the two flags conflict. Strict and non-strict builds use separate DerivedData because the evaluated manifest is cached there.
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
- The workout editor is the `editor` case of `AppFeature.Path` on the Workouts stack. It hides the system back button, which also turns off the edge and content back gestures on iOS 17 and 26, so it leaves only through `backButtonTapped`; a Workouts tab re-tap sends it the same action.
- The workout timer is the `timer` case of `AppFeature.Destination`, a full-screen cover. Like the editor it closes itself with `dismiss()`, the accepted exception to talking up only through `delegate` actions. Every close path first ends the screen's `TimerSessionClient` session, so a clock loop that starts after the teardown returns before it sleeps.
- Long-running or replaceable effects get a `CancelID`; reloads use `cancelInFlight: true`.
- Catch `CancellationError` before the generic `catch` — cancellation is not a failure.
- Clocks, dates and UUIDs come from `@Dependency` (`continuousClock`, `date`, `uuid`); lint rejects `Date()` and `UUID()`.
- Bridge callback APIs through an `AsyncStream` that the effect stays suspended on; never let `send` escape the effect.
- Add only the action groups a feature needs (the root feature has no `Delegate`).

## Time

- UI must call `WorkoutRun.tick(at:)` and then `snapshot(at:)` on every update; `snapshot` alone never commits progress.
- Never convert between `Date` and `Duration` outside `TimeMath`.
- `rebase(at:keepingTotalElapsed:)` is the recovery point after a backward clock change.
- The timer runs at most one clock loop, a 3-2-1 countdown or a tick loop. Each loop carries a generation in its cancel id and in every action it sends; an action from an older generation only cancels its own loop.
- A loop only sleeps and wakes; the reducer measures and commits. Before every tick and user action it checks the clock anchor, a wall date and a `continuousClock` instant read together and refreshed on every tick, through `TimeMath`'s public `Date.elapsed(since:)`. A backward jump rebases the run to the progress the monotonic clock vouches for; a forward jump is logged and kept, like time in the background.
- `snapshot` without `tick` appears in two places only: the tick loop's own copy of the run, which schedules wake-ups and is never shown or committed, and the state's initial snapshot at `.distantPast` of a run that is idle or finished.
- A tick loop that ends while the committed run still runs reports `isFinal`, and the reducer starts a new one.
- One clock instance per timer session: a `MonotonicInstant` checks only the type of its instant.

## Domain limits

Anything that edits a workout applies `WorkoutLimits.normalizedStages(_:)` and `normalizedTrainingRounds(_:)`, and UI limits match `WorkoutLimits`. Otherwise the user would see stages that never reach the schedule.

A stage name may be empty; anything that displays a stage shows its intensity name instead. Storage keeps the empty name, so the fallback follows the current language.

## Identifiers

Public initializers take `id` explicitly; features get identifiers from `@Dependency(\.uuid)`. Deterministic `UUID(uuid:)` is fine in samples and tests.

## Persistence (CT-2, CT-5)

- Domain types never become `@Model` types; persistence maps to and from them.
- Durations are stored as `Int` milliseconds.
- CloudKit sync: no `@Attribute(.unique)`; every property optional or defaulted; relationships optional; stage order kept in an explicit `order` field.
- A saved run is `WorkoutRunRecord` v1 with explicit `CodingKeys`: `schemaVersion`, `workoutID`, `scheduleFingerprint`, `phase`, `positionMs`, `cursor`, `sinceEpochMs`. The fingerprint is a SHA-256 of the normalized schedule structure (index, section, round, round count, kind, stage id, duration in ms; not the name). On restore, rebuild the schedule and drop the record if the fingerprint differs or `cursor` is out of range.

## Errors

Log with `os.Logger` and move the UI to an explicit state. Do not log expected outcomes such as cancellation.

## Tests

- Swift Testing (`@Test`, `#expect`, `#require`); `@MainActor` suites for features.
- `TestStore` is exhaustive by default; override dependencies per test; use `TestClock`, never real sleeps.
- Name tests `test_method_state_expected`.
- Declare a test target only together with a committed source file: SwiftPM rejects a declared target whose directory is missing on a clean checkout. Test targets use the same `strictSettings`.
- `WorkoutRun` keeps `position` and `cursor` readable through `@testable import` so tests can check its invariants.

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

## Git

- Branch `CT-<n>-short-slug` from `main`; commits `CT-<n>: Imperative description`. A milestone split into slices uses `CT-<milestone>-<n>` instead of `CT-<n>` (`CT-UI-1-dark-tokens`, `CT-UI-1: …`).
- One logical change per commit, and every commit passes `make verify-clean`.
- Amend only the last commit before moving on; fix older commits with a separate `CT-<n>: Fix …` commit.
- `main` changes only through pull requests, which are squash-merged once `lint` and `build-test` pass. The PR title becomes the commit subject, so it follows the same `CT-<n>: Imperative description` format.
