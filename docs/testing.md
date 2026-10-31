# Testing

How the tests are run and extended. The overview is in the [README](../README.md#testing); the rules are in AGENTS.md › [Tests](../AGENTS.md#tests), [UI tests](../AGENTS.md#ui-tests) and [Snapshot tests](../AGENTS.md#snapshot-tests).

Paths in this file: `Screens/` and `Support/` in UI tests are folders of `CircuitTimerUITests/`; `Support/` and `__Snapshots__/` in snapshot tests are folders of `CircuitTimerSnapshotTests/`.

## Commands

The main commands, `make test`, `make test-ui` and `make test-snapshots`, are in [README › Commands](../README.md#commands). These build or run one part:

| Command | What it does |
|---|---|
| `make build-ui-tests` | Builds the app with its UI tests, as `make test-ui` does |
| `make build-snapshots` | Builds the snapshot host and tests, as `make test-snapshots` does |
| `make test-snapshot-kit` | Tests the image comparison, references, journal and environment checks without an app host |
| `make test-snapshot-contracts` | Tests capture, recording, cancellation and window cleanup in the snapshot host, separately from the PNG matrix |
| `make record-snapshots` | Records missing references or those differing beyond the comparison bounds, on `iPhone 17` only |
| `make test-snapshot TEST=<function>` | Locally compares one snapshot variant; defaults to English and `large` text |
| `make record-snapshot TEST=<function>` | Locally records that variant if needed, then compares it again |

## UI tests

### How to add a UI test

1. **Scenario.** Use an existing case of `AppScenario` (`UITestContract`) or add one, with its workouts in `ScenarioWorkouts.swift` and its dependencies in `AppScenario.prepare` (`AppScenarios`). `make lint` fails when a dependency client, key or storage strategy is not set there, as long as a key's declaration keeps `DependencyKey` on its first line; that the value is not live is yours to check.
2. **Identifiers.** Give the elements the test needs an identifier from `AccessibilityID`, named `<screen>.<element>`; lint rejects any other. Text the user typed, such as a workout's name, and system elements, such as an alert's buttons, are found by their text.
3. **Screen.** Add actions and checks to the screen's struct in `CircuitTimerUITests/Screens/`, or a new struct that conforms to `Screen`. Queries stay private. Every action and check takes `file: StaticString = #filePath, line: UInt = #line` and passes them to the waits and to the next screen, so a failure points at the test's line. An action returns the screen the user lands on, which waits until it shows. A screen that returns to where it came from is generic, like `AlertScreen<Source>`; behavior several screens share goes into a protocol with a default implementation.
4. **Test.** In `<Area>UITests.swift`, a `@MainActor final class` with methods named `test_<start>_<action>_<expected>`, starting with `let app = launch(.<scenario>)`. Lint rejects `sleep`, waits in tests and `XCUIApplication()` outside `launch`; keep `setUp`, if any, synchronous.
5. **Parallel safety.** A test shares nothing with other tests and depends on no order: it launches its own app. Each launch already gets its own in-memory workouts and preferences, no record, notifications or Live Activity, its own clock and identifiers. TipKit's datastore on the simulator is shared; `launch` hides tips, so a test of a tip first adds a launch option that resets the datastore and shows them.
6. **Run.** `make test-ui` runs on `iPhone 17`; another simulator takes its own result bundle, log and DerivedData, for example `make test-ui DESTINATION='platform=iOS Simulator,name=iPhone 17 #2,OS=27.0'`. Runs on two simulators may overlap only after one run on each has finished alone; each first run is a cold build and its DerivedData takes several GB. `scripts/report-test-results.sh .build/TestResults/*.xcresult` prints failures, flaky tests and the slowest tests. More than one Xcode worker (`UI_TEST_WORKERS`) runs only on CI.
7. **Time stands still.** A scenario's clock never advances, so a started timer stays on its first countdown digit. The timer's logic is tested in the package with `TestStore` and `TestClock`.

## Snapshot tests

### Snapshot test example

The test names a state of the app, here the editor in its editing phase, and the harness draws it and compares it with the references:

```swift
extension SnapshotTests {
    @MainActor
    @Suite
    struct WorkoutEditorSnapshotTests {
        @Test(arguments: SnapshotTextSize.currentCases())
        func test_editor_editing_matchesReference(textSize: SnapshotTextSize) async throws {
            try await assertAppSnapshot(textSize: textSize) { language in
                .editing(SnapshotFixtures.editorWorkout(language: language))
            }
        }
    }
}
```

### Comparison

Both images are normalized to 8-bit sRGB for comparison. Their dimensions and alpha bytes must match exactly. RGB channels may differ by at most 2/255 on at most 1.25% of the pixels; exceeding either limit fails the test. These bounds cover the measured host-dependent edge and glass rendering differences. The same criterion applies to both mounts; PNG recording keeps the renderer's original output.

### Harness tests

The capture harness has its own tests: `make test-snapshot-kit` runs the package tests, and `make test-snapshot-contracts` runs `CircuitTimerSnapshotContractTests` inside the empty snapshot host. Contract tests use temporary synthetic references and do not change the screen references in `CircuitTimerSnapshotTests/__Snapshots__`. Serialize these two commands manually per checkout, including across simulator destinations: temporary reference directories are shared between those processes. Generated contract PNGs are ignored if a process is interrupted. Each command also runs one language check in a process of its own, `make test-snapshot-kit` in Russian and `make test-snapshot-contracts` in German, a language the app does not support; that check must run and pass, not skip.

`make test-scripts` also checks the snapshot runner and make targets using fixture result bundles.

### How to add a snapshot

1. **State.** Build the `AppFeature.State` the screen shows once its transitions have finished (for the timer, see the next paragraph), with a factory in `Support/AppFeature+SnapshotStates.swift` (`list`, `failedList`, `viewing`, `editing`) or a new one there. Set the Workouts stack's `path` and the editor's `phase` directly; `@testable import` reaches their internal setters. Never `send` actions to get there. Data comes from `SnapshotFixtures`, in the language the closure receives. The closure runs once per mount, inside the snapshot's dependencies, so it must build the same state every time. Link any new product imported by shared `Support/` into both `CircuitTimerSnapshotTests` and `CircuitTimerSnapshotContractTests`.

   The timer is drawn without the app: its full-screen cover does not draw in the first frame. Build a `WorkoutTimerFeature.State` with a factory in `Support/WorkoutTimerFeature+SnapshotStates.swift` (`startCountdown`, `paused`, `finished`, `stageList`) or a new one there. A factory starts from the state Start creates (`AppFeature.timerState(for:)`), sets the run at `TimerSnapshotDependencies.now` and the timer's own `path`, and ends with `markAppeared()`, which settles the state as the timer stands once it has appeared. The timer's appear actions then change nothing on screen; `assertTimerSnapshot` refuses a state that is not settled so, and one with the close dialog.
2. **Test.** One test function per state, in `<Area>SnapshotTests.swift` inside `extension SnapshotTests`, named `test_<screen>_<state>_matchesReference` and unique across the snapshot tests. It always takes text sizes as its arguments: `SnapshotTextSize.currentCases()` (`large`, `ax5`), or `SnapshotTextSize.currentCases(in: [.large])` where the largest text adds nothing. Keep this `@Test` declaration on one line, using one of these two forms, so the run check can enumerate the expected sizes. Call `assertAppSnapshot(textSize:)`, or `assertTimerSnapshot(textSize:)` for the timer, once.
3. **Language.** Every snapshot runs in English and in Russian: `make test-snapshots` starts four test processes, one per language and text size. A Russian process breaks lines differently from Russian strings in an English one, and UIKit fonts read the process's preferred text size. The scheme passes `-UIPreferredContentSizeCategoryName` from `SNAPSHOT_CONTENT_SIZE_CATEGORY`; `SNAPSHOT_TEXT_SIZE` selects the test arguments. The capture checks that the actual process category matches its argument before building the screen. Narrow a run only with `SNAPSHOT_LANGUAGES=en` or `ru`; flags that select or repeat tests are refused. The app is dark only.
4. **Record.** `make record-snapshots` on `iPhone 17` / iOS 27.0, with no uncommitted change under `CircuitTimerSnapshotTests/__Snapshots__`. It writes the references that are missing or differ beyond the comparison bounds, leaves matching references untouched (including differences within the bounds), compares everything again and lists the new references: check that your test's appear. References are `__Snapshots__/<test file>/<test function>.<language>-<size>.png`. If the final comparison fails, run `git restore` and `git clean -f` on that folder and record again. A reference that does not load or has the wrong size fails its test. Replacing an invalid reference or intentionally replacing one accepted within the bounds requires removing its PNG in a reviewed commit before recording the replacement; the reference folder must be clean when recording starts.
5. **Review.** Open every new or changed PNG and say in the pull request why it changed. Delete the references of a test you rename or remove: a reference no test checks fails the run. `make test-snapshots` and CI never write references; a failure keeps the actual image in `.build/TestResults/Snapshots-<run>-<language>-<size>-artifacts/<test file>/`, where `<run>` names the simulator and runtime, such as `iPhone-17-27.0`, and, when the image strategy can produce them, the reference, failure and difference images in the result bundle. A normalization error or a failure for which the strict strategy supplies no attachments can leave only the failure text there.
6. **Effects.** Dependencies are the test context's, except what `Support/SnapshotDependencies.swift` sets, and for the timer what `TimerSnapshotDependencies` in `Support/TimerSnapshot.swift` adds: the preview values of every client the timer reaches, a constant `date`, `preferredLocales`, `uuid` and `dismiss`. A new client the timer reads needs a line there too; lint checks only `AppScenario.prepare`. These are rendering tests, not exhaustive effect tests. Unconfigured dependency endpoints keep their test values; a passing snapshot does not prove that no effects ran. TipKit is not configured in the host, so no tip shows.

### Work on one snapshot

While adding or changing a screen, select its test function without the suite name or `(textSize:)`:

```sh
make test-snapshot TEST=test_editor_editing_matchesReference
make test-snapshot TEST=test_timer_paused_matchesReference
make record-snapshot TEST=test_editor_editing_matchesReference \
  SNAPSHOT_LANGUAGE=ru SNAPSHOT_TEXT_SIZE=ax5
```

`SNAPSHOT_LANGUAGE` is `en` (default) or `ru`; `SNAPSHOT_TEXT_SIZE` is `large` (default) or `ax5`. Use the singular `SNAPSHOT_LANGUAGE` here; the plural `SNAPSHOT_LANGUAGES` belongs to the full-matrix commands and is rejected by the single-snapshot commands. The function must exist exactly once inside an explicitly annotated `@Suite` in the screen snapshot sources and support that size. The command fails if the selected case does not run, skips, or runs alongside another case. Result bundles and artifacts use the `Snapshot-<run>-<function>-<language>-<size>` prefix, separate from the full matrix.

These commands are local only. Comparison accepts the same simulators as `make test-snapshots`; recording requires `iPhone 17` / iOS 27.0 and a clean reference folder, as `make record-snapshots` does. Recording writes only the selected missing or out-of-bounds reference, then runs that comparison in `never` mode. Review the changed PNG before committing it. The reference folder must be clean before each recording command; use `make record-snapshots` when adding several variants of a new test. Before submitting a change, run the full `make test-snapshots` matrix; CI always checks all applicable cases.

### Limits

The timer's full-screen cover does not draw in the first frame, so `assertAppSnapshot` fails a state that presents it, and the timer's snapshots draw `WorkoutTimerStack` as the window's root instead, with the real reducer. On 2026-10-31 (iPhone 17, iOS 27.0, all four states in every variant) that root's first frame matched, within the comparison bounds, the presented cover over the loaded list, and was identical to the frame the timer settles on after its real appearance (`.task`, notification access, an active scene and the actions that lead to the state). The root pins `scenePhase` to `.active`: a hosting controller installed as a window's root sits outside the host's `WindowGroup` and reads SwiftUI's default `.background`, which would restart the countdown's audio preparation or reset the signal baseline; the app's cover reads `.active`. Alerts and dialogs, the timer's close dialog among them, are not supported yet. Snapshots run only on iOS 27.0 with iPhone 17's screen. They do not cover how the tab bar leaves on a push (`TabBarRidesWithRoot`).
