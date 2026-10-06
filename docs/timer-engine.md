# Timer engine contract

`WorkoutRun` (in `WorkoutDomain`) plays a `WorkoutSchedule`. It never counts ticks: it stores the schedule position reached at an anchor date and derives everything else from the date passed into each call. This document is the contract its code follows; tests pin it.

## State

- `phase`: `idle`, `running(since: Date)`, `paused`, `awaitingUser`, `finished`.
- `position`: schedule time reached at the anchor, in whole milliseconds.
- `cursor`: index of the current stage; equals `stages.count` once finished.
- A run over an empty schedule starts as `finished`.

## Settling

Every public operation first *settles* the elapsed time, which only does something while running:

1. If `now < since`, the clock went back past the anchor: re-anchor at `now`, keep the position.
2. Otherwise add `elapsed = min(now − since, total − position)` and walk forward from `cursor`:
   - reaching a manual pause stops there with `awaitingUser`;
   - a timed stage that is not finished keeps the run `running` with the new anchor `min(since + elapsed, now)`;
   - walking past the last stage finishes the run.

`snapshot(at:)` settles a copy and projects it; it never changes the run. `tick(at:)` commits the settled state.

## Operations

The row is the phase *after* settling.

| Phase | `tick` | `start` | `pause` | `resume` | `skipToNextStage` | `rebase(keeping: k)` |
|---|---|---|---|---|---|---|
| `idle` | — | first stage, running | — | — | — | — |
| `running` | commits | — | `paused` | — | next stage, running | advance to `max(position, k′)`, re-anchor at `now` |
| `paused` | — | — | — | `running` on the current stage | next stage, paused | — |
| `awaitingUser` | — | — | — | next stage, running | next stage, running | — |
| `finished` | — | — | — | — | — | — |

"Next stage" resolves the same way everywhere: a manual pause becomes `awaitingUser`, running past the end becomes `finished`. `k′` is `k` clamped to `0…total` and truncated to milliseconds, so any `Duration` is safe. `rebase` never moves back, never passes a manual pause and never goes past the end.

## Invariants

| | |
|---|---|
| I1 | `0 ≤ cursor ≤ stages.count`, and `cursor == stages.count` exactly when `finished` |
| I2 | `idle` ⇒ the schedule is not empty, `cursor == 0`, `position == 0` |
| I3 | `finished` ⇒ `position == total` |
| I4 | the stored position lies inside the current stage; a running or paused timed stage has `position < end`; every timed stage lasts at least 1 ms |
| I5 | outside `idle` and `finished`, the current stage is a manual pause exactly when the phase is `awaitingUser` |
| I6 | every duration in the schedule and the position are whole milliseconds |
| I7 | `snapshot(at: t)` equals the projection of the state after `tick(at: t)` |
| I8 | `Workout.totalDuration == WorkoutSchedule(workout:).totalDuration` |
| I9 | after any public operation at `now` while running, `since ≤ now` |

## Snapshot

| Phase | Current stage | Next stage | Stage elapsed / remaining | Total elapsed / remaining | Current stage end date |
|---|---|---|---|---|---|
| `idle` | first | second | 0 / its duration | 0 / total | — |
| `running` | at `cursor` | following | derived | derived | `since + (end − position)` |
| `paused` | at `cursor` | following | stored | stored | — |
| `awaitingUser` | the pause | following | 0 / 0 | stored | — |
| `finished` | — | — | 0 / 0 | total / 0 | — |

## Time

- `TimeMath` is the only place converting between `Date` and `Duration`.
- Elapsed time is truncated to milliseconds with a 1 µs tolerance, so for dates of the current epoch an exact `currentStageEndDate` already shows the next stage, and a moment 2 µs earlier still shows the current one.
- Accuracy: the position trails real time by up to one millisecond (the truncated remainder) plus a microsecond-level term from date rounding. Measured on dates of the current epoch: at most 1.004 ms after 5 000 updates and 1.009 ms after 50 000 updates (about 14 hours at one update per second). Irregular or missed UI updates do not add error, because nothing is accumulated per tick.

## Clock changes

- **Backwards past the anchor:** the run re-anchors at the current time instead of stalling. Committed progress is kept; time between the last commit and the change can be lost, and `rebase(at:keepingTotalElapsed:)` lets the UI restore what it has already shown.
- **Forwards:** indistinguishable from time spent in the background, so timed stages are skipped up to the next manual pause. This is an accepted trade-off of using wall-clock time, which is what survives an app restart and drives a Live Activity countdown.
