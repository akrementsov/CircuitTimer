# Live Activity

The running workout shows on the Lock Screen and in the Dynamic Island, with Pause/Resume controls on the card and the expanded Island. `WorkoutActivity` keeps a compact state of the run within iOS's 4 KB limit, and the `CircuitTimerWidgets` extension draws it in the app's dark palette, with clocks that keep counting while the app sleeps. The implementation rules are in [AGENTS.md › Live Activity (CT-4)](../AGENTS.md#live-activity-ct-4); change this file and that section together.

## Controls

The Lock Screen card and expanded Dynamic Island have one Pause/Resume button beside the clock. Resume continues immediately, including a manual pause, and closes an open stage list or finish confirmation in the app. The initial countdown and finished card have no control; compact and minimal Island views stay read-only.

A card command targets its activity and control generation, so an older card cannot toggle a later pause. If the app process has gone, tapping ends only that orphan card: the saved run stays available for the next launch's Continue prompt. An intent waits at most five seconds for the card and notification sync; timing out does not undo a command already delivered. The run's existing background assertion protects its disk write; intent execution takes no additional assertion.

App and UI-test builds check the compiled intent metadata in both hosts, including the static-module registration needed on iOS 17.

## Device checklist

Check these before release (CT-7):

- [ ] Protected Lock Screen delivery and system error presentation on a physical device.
- [ ] Real process suspension at the five-second wait bound.
- [ ] Runtime absence from Shortcuts and Spotlight.
- [ ] Release runtime on a physical device.
- [ ] On iOS 26.x, an App Switcher swipe while a timer runs in the background removes its card at once, a finished card included.
- [ ] Complete system coverage of all card states, maximum text sizes, English labels and RTL.

Release simulator probes exercised card and expanded-Island Pause/Resume on iOS 17.5 and 27.0. They do not establish the physical-device checks above.
