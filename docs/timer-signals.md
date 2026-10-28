# Timer signals

Settings stores Sound, Vibration, Speak stage names and Keep screen on and Background notifications separately; all default to on. Changes persist across app launches. Keep screen on prevents automatic locking during countdowns and running stages; turning it off allows normal auto-lock without stopping the timer. Pauses and finished workouts always allow auto-lock. Turning Sound off silences cue tones and the system sound of background notifications. Speech follows the app language (English or Russian), and a blank stage name uses its intensity name.

| Moment | Tone | Haptic | Stage announcement |
|---|---|---|---|
| Ready/resume countdown 3, 2, 1 | 880 Hz beep | Light impact | None |
| Stage starts, including a manual pause | 1320 Hz tone | Heavy impact | Name, Work, Rest or Pause |
| Same stage resumes | Start tone | Heavy impact | None |
| Last three seconds of a timed stage | Countdown beep | Light impact | None |
| Workout finishes | C6–E6–G6 | Success | None |

Before a start/resume countdown, the timer prepares its first beep and briefly shows a readiness indicator. Only then does it show 3 and start the three-second countdown. The monotonic origin is captured in the reducer, so delayed effect launch does not shift its deadlines. Countdown and stage loops request zero sleep tolerance to avoid system wake-up coalescing. Cancelling preparation releases the audio session; preparation errors appear as signal failures and do not hold the timer.

Foreground signals run while the timer is visible and the app is active. Control Center stops them, although the workout keeps going. Opening the stage list or the close alert also stops them. A new cue cuts the preceding cue; closing the timer ends its output immediately. Returning or restoring a running workout never replays skipped signals. A restored paused stage is announced on resume.

The audio session plays through the silent switch and ducks other audio. After the last output ends it releases the session after 1.5 seconds, keeping music ducked between countdown beeps. Leaving the active scene or closing releases it immediately. With VoiceOver on, stage names use a low-priority accessibility announcement instead of synthesizer speech; delivery can be delayed by other announcements.

Deactivation failures are logged at error level. Except for `isBusy`, which already leaves the session inactive, a failure receives one automatic retry after 1.5 seconds. A successful new activation supersedes that cleanup; VoiceOver-only cues and unavailable activation keep the pending cleanup without replenishing its retry budget.

Audio and missing-voice failures appear under the timer while the affected output is enabled. They do not stop the run. A later successful result clears the corresponding failure.

Regenerate the bundled tones from the repository root:

```sh
swift scripts/generate-cue-tones.swift
```

## Device checklist

Simulator tests cover signal decisions, preference persistence, revision fences and session teardown. Check these native behaviors on iOS 17.5 and 26.x before release:

- [ ] Play over music and a podcast: ducking recovers after the last cue and after closing, with no volume bounce between countdown beeps.
- [ ] Close during a spoken name and immediately after the finish tone; neither audio output continues.
- [ ] Silent switch on: tones and speech still play; each Settings switch affects only its own output.
- [ ] Headphones connected and then unplugged: the next cue uses the current route.
- [ ] Call and Siri interruptions: cues stop gracefully; subsequent cues work.
- [ ] Control Center during a name: it stops; returning does not announce the missed stage.
- [ ] Open stage list and close confirmation during a name: output stops; resume restarts the countdown.
- [ ] App language English and Russian; named, blank work/rest and manual pause stages speak correctly.
- [ ] Missing app-language voice: visible notice, no foreign-language fallback or stuck ducking; download the voice and return to the app.
- [ ] VoiceOver: toggles report their state; stage announcements do not speak over existing accessibility speech, including short consecutive stages.
- [ ] Haptics: countdown light, stage/resume heavy, finish success; none while inactive or in the stage list.
- [ ] iOS 17.5: completion, resign-active and interruptions do not trap.

## Background notifications

Background notifications is a separate default-on switch. The first Start asks iOS for alert and sound permission before the timer and its 3-2-1 are created. Turning the switch on in Settings does not prompt; continuing a saved run never prompts. Refusal does not stop a workout. Settings shows only the switch, without permission status. The timer shows a notification footnote only for an unknown or blocked permission state or a scheduling failure while the preference is on; healthy coverage and an intentionally disabled preference add no timer text.

A slow authorization callback leaves the request waiting. After ten seconds of active-scene waiting, an alert offers Start now or Wait. The alert never starts the timer automatically. A late permission response may enable notifications, so Start now does not promise a session without notifications.

The running timer queues up to 32 upcoming stage starts and the finish, including the start of a manual pause. No events beyond a manual pause can be dated until the user continues. There are no countdown-digit or final-three-second background notifications. Titles name the workout; the body names the stage, using Work/Rest/Pause for a blank name; a truncated window adds a request to reopen CircuitTimer to the last real event. Sound follows Sound; there is no background speech or independent vibration control.

The queue is maintained while the timer runs, including before backgrounding. Foreground presentation is suppressed by the delegate installed at launch, leaving the existing tones/haptics/speech in charge. Control Center remains silent. Pause, finish and closure remove the owner's pending requests; a resumed or restored run uses the current settled schedule. System removals have no acknowledgement.

On launch, pending and delivered requests from older process owners are cleaned in parallel with run restoration. A late answer cannot delete the new owner's queue. Each caller waits at most 500 ms, physical cleanup reads are coalesced and reissued at most every 30 seconds, and a persistent list notice offers Retry if iOS has not answered and explains the 30-second wait before trying again. Already viewed notifications cannot be made unseen.

The client uses unique physical identifiers and revision fences. It verifies future requests against pending IDs using a fresh date after the query. Imminent missing events remain unconfirmed rather than being counted as expired; they are not replayed near the deadline. Scheduling failures retry through regular ticks after ten monotonic seconds or upon becoming active; no result action immediately retries itself. A blocked-delivery report does not trigger scheduling-failure retries. If the timer lacks permission status, it adopts the scheduler's full status rather than inferring denial from a delivery boolean; a late failed read cannot erase that recovered status. A millisecond key change can produce a revision without a system API call.

Suspension, force quit or another process death stops window refilling. Existing requests may still arrive, unless iOS reports the termination: then the app removes them (see `AGENTS.md` › Apple Health). Clock changes cannot be repaired until the app runs again. iOS controls timing, Focus, silent mode, sound and vibration; scheduling is not proof of exact delivery.

Additional device checks on iOS 17.5 and 26.x before release:

- [ ] First Start: allow, refuse, read the prompt slowly, and recover through Start now / Wait.
- [ ] First Start on iOS 26.x: the Health sheet follows the notification prompt; allow, refuse, and leave it open for 10 s, then tap Start again.
- [ ] Lock during short stages; check stage/finish titles and that foreground presentation does not duplicate cues.
- [ ] Manual pause stops the forecast; continue schedules only the remaining stages.
- [ ] Change permission in iOS Settings, return to a running timer, and check its footnote and recovery.
- [ ] Kill and relaunch while requests remain: old owners are cleaned and the restored owner survives late callbacks.
- [ ] A workout beyond the 32-event window, clock changes, Focus and the silent switch show the documented limits.
- [ ] Swipe the app away in the App Switcher while a timer runs in the background: on iOS 26.x its pending and delivered notifications and its card go at once; on iOS 17.5 they stay once iOS has suspended the app.
- [ ] On iOS 26.x, stop the app from Xcode while a timer runs: note whether iOS relaunches it in the background to recover the workout session; the next launch ends that session and asks to continue the run.
