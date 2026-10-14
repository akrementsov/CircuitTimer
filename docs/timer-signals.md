# Timer signals

Settings stores Sound, Vibration and Speak stage names separately; all default to on. Changes persist across app launches. Turning Sound off silences only tones. Speech follows the app language (English or Russian), and a blank stage name uses its intensity name.

| Moment | Tone | Haptic | Stage announcement |
|---|---|---|---|
| Ready/resume countdown 3, 2, 1 | 880 Hz beep | Light impact | None |
| Stage starts, including a manual pause | 1320 Hz tone | Heavy impact | Name, Work, Rest or Pause |
| Same stage resumes | Start tone | Heavy impact | None |
| Last three seconds of a timed stage | Countdown beep | Light impact | None |
| Workout finishes | C6–E6–G6 | Success | None |

Signals run while the timer is visible and the app is active. Control Center stops them, although the workout keeps going. Opening the stage list or the close alert also stops them. A new cue cuts the preceding cue; closing the timer ends its output immediately. Returning or restoring a running workout never replays skipped signals. A restored paused stage is announced on resume.

The audio session plays through the silent switch and ducks other audio. After the last output ends it releases the session after 1.5 seconds, keeping music ducked between countdown beeps. Leaving the active scene or closing releases it immediately. With VoiceOver on, stage names use a low-priority accessibility announcement instead of synthesizer speech; delivery can be delayed by other announcements.

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
