# Apple Health

On iOS 26 and later a running timer holds a Health workout session, which keeps the app running in the background, so closing the app removes its Live Activity and notifications. When the session ends, the timer's workout is saved to Health. The implementation rules are in [AGENTS.md › Apple Health (CT-11)](../AGENTS.md#apple-health-ct-11); change this file and that section together.

## What is saved

One High Intensity Interval Training workout, indoors, per timer, with no samples such as heart rate or energy. It starts when the run first runs, at the end of the start countdown, and ends when the timer closes: at Finish, at a close from a pause (the start of that pause), where a finished run stopped, or when iOS terminates the app. Pauses by the user or the schedule, the resume countdown, the stage list and the close dialog are pauses of the workout, so its duration is the time the run counted. A clock moved back while the app measures time shifts the whole workout, so that time is kept.

Nothing is saved on iOS 17–25, when writing workouts is not allowed, when the session failed to start before the timer closed or for a workout of zero length; the app never says so. A session another app takes over, or HealthKit stops, saves the workout up to then. Continue after a relaunch saves a second workout; the time between the process's death and Continue is in neither.

## Accepted limits

- At termination the last changes of the run may not have reached Health, so a pause, resume or start made just before iOS terminated the app can be missing from the workout.
- A save that does not finish within the 2 s iOS leaves at termination is lost.
- A crash or a kill of a suspended app saves nothing.
- A clock moved back while the app did not measure it, or just before a lost session or a termination, can shorten the workout, up to saving none.

## Device checklist

Check these on iOS 26 or later before release (CT-7):

- [ ] Finish after a manual pause, a schedule pause, the stage list and Stay with its countdown: one workout, starting at the end of the start countdown, whose duration is the running time.
- [ ] Close from a pause: the workout ends at the pause's start.
- [ ] An App Switcher swipe after more than 3 minutes in the background: the workout ends at the swipe, its save fits the termination deadline (the log's «Saved a workout to Health in … ms»), and the card and notifications still go.
- [ ] Finish, then a swipe at once: the workout is saved and the session ends within 2 s.
- [ ] Continue after a swipe, then Finish: a second workout.
- [ ] Another app's workout session takes over: the workout up to the takeover is saved, also with a swipe right after it.
- [ ] A close and a swipe on a locked phone: the workout is saved.
- [ ] A process stopped without termination (Stop in Xcode), then a launch: no workout, and the session ends.
- [ ] Writing turned off in Settings: no workout and no alert; access revoked during a workout: the error is logged.
- [ ] iOS 17.5: nothing is asked or saved.
