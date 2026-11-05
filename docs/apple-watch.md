# Apple Watch

The watch app is a remote for the iPhone timer: the workout runs on the iPhone, and without it the watch app does not work. It needs watchOS 10 or later and ships inside the iPhone app. CT-9 delivers it in slices; this page grows with them. The implementation rules are in [AGENTS.md › Apple Watch](../AGENTS.md#apple-watch-ct-9), [Module map](../AGENTS.md#module-map) and [Delivery](../AGENTS.md#delivery); change this file together with them.

## What it does now (CT-9-5)

The watch app shows the iPhone's workouts, in the iPhone's order, with their total time. While a workout runs on the iPhone, the watch shows it instead, drawn like the iPhone timer's cards: the workout's name as the screen's title, the stage's time and name on its colour, and the stage that comes next on a dark card; paused, «Get ready» and «Done» read as on the Live Activity. Choose a workout to open its Start screen; the workout runs on the iPhone through the same permissions flow as its own Start button.

The time counts on the watch only while the iPhone confirmed the run at most 10 seconds ago; the watch asks again every 5 seconds while the run's screen shows. Without a fresh confirmation the stage stays on screen without its time, under «Waiting for iPhone…», «iPhone isn't connected» or «Unlock your iPhone». When a stage ends, its time goes until the iPhone confirms the next stage. With the wrist lowered (Always On) the time is hidden and nothing is asked about the run, though the list's own reasons still ask (a retry after a failure, the iPhone back in reach, a state the order asks to confirm, a command's reply from another iPhone process); raising the wrist shows the time again, or asks once.

While the iPhone confirms the time, a Pause or Resume button stands under the cards; the iPhone's timer applies it as it applies the Live Activity's button, also with Live Activities off. Without a confirmation, at a stage's end and with the wrist lowered the button is gone, its place kept. Its outcome:

| Outcome | The watch shows |
|---|---|
| Applied | the paused or running workout |
| The workout changed on the iPhone first (a pause from the card, a stage the watch had not shown as ended) | the iPhone's workout and «The workout changed on iPhone» |
| The iPhone is busy with another command, or cannot take one | «Couldn't. Try on iPhone» |
| No answer, or the link failed after sending | «Checking on iPhone…» until the next confirmation shows what the iPhone did |

The list updates when the workouts change on the iPhone. When the watch has no fresh list, it says why:

| Situation | The watch shows |
|---|---|
| The iPhone is out of reach | the last list, under «iPhone isn't connected · Updated …», or «iPhone isn't connected» without a list |
| The iPhone restarted and is locked | «Unlock your iPhone» |
| The iPhone app is not installed | «CircuitTimer isn't available on iPhone» |
| The iPhone could not load its workouts | the last list, dimmed, with «Couldn't load workouts on iPhone. Showing the earlier list.» under the status line, if any, such as «iPhone isn't connected · Updated …» |
| The list does not fit in one transfer | the start of the list with «Not every workout fits on the watch.»; if even that fails, the last list dimmed or «Workouts don't fit on the watch» |
| The iPhone app was launched in the background and has not loaded its workouts | the last list under «Earlier list from … · Waiting for iPhone», or «Open CircuitTimer on your iPhone» |
| The two apps speak different versions | «Update CircuitTimer on your iPhone» or «… on your watch» |
| A workout runs whose names do not fit in a transfer | «A workout is running on your iPhone», until it closes |

## Start from the watch

Choose a workout, then tap Start. A selected workout is resolved from the current list: a new name appears immediately, while removal, unavailable data or a different schedule closes the selection. A list whose newer digest has arrived without its contents is waiting for confirmation: its selection says the list is updating, and Start is disabled. Being reachable alone does not confirm a catalog.

The iPhone accepts a Start only after its root has subscribed and it has observed an active scene. Otherwise the watch asks to open CircuitTimer on the iPhone; a cold WatchConnectivity launch cannot start a workout invisibly. The app replies busy while a timer, presentation, purchase, draft, unresolved saved run, list mutation or iCloud reload is in the way. A missing, changed, unplayable or unavailable workout has its own message. Once admitted, a reload or unrelated list mutation does not cancel Start by itself: continuation checks the chosen workout in the current loaded list, and a changed schedule, missing or unplayable workout cancels it. No draft is discarded.

Admission waits at most five seconds from arrival at the iPhone. The app creates an intent before answering accepted, and begins its usual notifications → Health flow only when the ticket confirms acceptance. This confirms admission, not physical delivery of the reply. The intent has thirty seconds from reducer acceptance, measured on the monotonic clock and checked at every callback and before opening. Inactive or background does not cancel an already accepted intent: opening waits for active, within the same original limit. Expiry removes the intent and its own alert, but cannot dismiss a system permission sheet. A late Health answer can update access without opening a timer. The watch's permission hint is conservative: it says the iPhone may ask, not that a sheet has already opened.

For an already admitted Start, the notification authorization client may be called once while the iPhone scene is inactive or in the background; becoming active does not ask a second time. Its ten-second stall timer waits for an active scene. Health authorization waits for active before calling the client. These rules describe client calls, not a guarantee that iOS displays a permission sheet in the background; the actual sheets still need the paired-device checks below.

A new Start can take over a stalled Health stage from either the editor or the watch and continue without Health, including skipping another access read. Notification checks, admission and the new thirty-second limit still apply. Taking over retires the older stalled intent before the new ticket is confirmed; if that ticket has expired, neither the old late Health continuation nor the new intent opens a timer. If a Health access read stalls and later returns not determined, it does not show a new permission sheet automatically: the accepted watch intent waits until its original deadline or a new Start takes over without Health. A local Start during another live watch intent is refused and its local button is freed; a stalled Health intent retains the existing start-without-Health rule.

After accepted, the watch waits thirty seconds plus five seconds for publication, counted from receiving the reply. Sending, waiting and the outcome belong to the root: Back closes only the selection, and the status remains above the list or empty/unavailable/connection notice. While Start is pending the list cannot open another workout; a new selection after it ends clears the earlier outcome. The app going to the background ends only this local wait. A lost reply or a wait without a run says to check the iPhone, since the workout may have started. An accepted run, including one published after the local wait ended, replaces the status; a run too large to travel does the same with its existing notice. An incompatible app ends the wait and asks for an update. Start outcomes apply only to the matching request UUID, independently of state ordering; only a refresh reply can switch iPhone processes or open a confirmation lease.

## How it works

- The iPhone app publishes its list whenever it settles: after it loads, and after every save, delete, duplicate and reorder once the write has finished. The newest list goes into the WatchConnectivity application context, which the watch app receives now or when it opens, and to a reachable watch app at once as a message.
- The watch app asks the iPhone for its current state when it opens or comes back to the front (lowering and raising the wrist does not count), when the iPhone becomes reachable, and after a failure, again after 5, 10 and 20 seconds, then every 20 seconds while the watch app is open and the iPhone in reach. Once the iPhone answers, the watch does not ask again until the next of these reasons; an unchanged list is confirmed by its digest without being sent again.
- A request from the watch can launch the iPhone app in the background. That process answers at once but has not read the workouts, so it says it knows no list; the list comes when the iPhone app loads it.
- The iPhone's timer publishes its run with the list after every change, into the context and to a reachable watch as a message. A request from the watch goes to the running timer, which settles the run, and only its answer confirms the time; the watch counts the 10 seconds from when it sent that request. A context or a message shows the run, but never confirms its time.
- Pause and Resume go to the running timer the same way, as a request of their own; the timer applies them by the Live Activity's rules (the content the watch showed must be current) and answers once its card and notifications have caught up. The reply carries the run as published then; it keeps a confirmation going but never starts one.
- Closing the timer, or the system ending the iPhone app, removes the run from what the watch receives; the watch then shows the list again.

## How it is built and shipped

- `WatchLink` holds the channel: the wire format, the WatchConnectivity bridge and both sides' clients. `WatchRemoteFeature` holds the watch app's reducer and screens. Both build for iOS and watchOS, so their tests run with the package's on the iPhone simulator. `DesignSystem` and `WorkoutActivity` build for watchOS too; their iOS-only parts are left out there.
- The `CircuitTimerWatch` target is a thin watchOS app over a `Store` of `WatchRemoteFeature`. The iPhone app depends on it and embeds it in `CircuitTimer.app/Watch/`, so every app build, the UI test build and the archive build it.
- `make build-watch-package` builds the watch app's modules strictly for the watch's own architectures, `arm64_32` for watches with chips before S9 and `arm64` from S9, in `make ci` and as its own CI step. It needs the watchOS SDK, not a watchOS runtime; the `xcode-27` CI image has the SDK.
- `make archive` signs the watch app ad hoc between the widget and the iPhone app; `testflight.yml` checks its Info.plist in the archive and its App Store signature, without HealthKit or iCloud, in the exported IPA.

## TestFlight tag at the end of CT-9

One tag after CT-9-5 checks what only App Store Connect can. `v0.1.1-rc.4` (build 0.1.1 (261105.155753), 2026-11-05) passed both:

- [x] `testflight.yml` exports and verifies the IPA: the cloud signing creates the watch app's App ID and signs it for the App Store.
- [x] TestFlight's processing accepts the build with the watch app. Xcode adds `MinimumOSVersion~ipad` to the watch app's Info.plist on its own; App Store Connect does not mind: the build is ready to test on iOS and watchOS.
The items only a live session can check (the force-quit launch by a request, switching watches, repeated wrist raises and the running workout on iOS 17.5 and 26) are in the [device checklist](#device-checklist), run on a TestFlight build under CT-7.

The tag went to internal testers only, so the wire's version 1 stays open after it: a fix these checks call for, and CT-6-2, may still change it. It freezes at the first build that leaves internal testing ([AGENTS.md › Apple Watch](../AGENTS.md#apple-watch-ct-9)).

## Accepted limits

- WatchConnectivity documents no size limit; the iPhone keeps each transfer under 60,000 bytes, an assumption checked on a device.
- A context write that fails waits for the next activation, change of watch or publication on the iPhone, or for the watch app to come to the front.
- An iPhone app launched in the background by the watch does not read its workouts, so the watch keeps its list marked as earlier until the iPhone app loads them.
- While the watch app stays open and the iPhone is out of reach, a context a new iPhone process wrote waits: the watch believes a new process only through the answer to its own request, because WatchConnectivity promises no order between two processes. The watch shows the earlier list until it can ask.
- After the user switches to another watch, the iPhone writes its newest list again once the session for that watch activates.
- After a change on the iPhone whose message is lost, such as a pause, the watch may count the old time for up to 10 seconds from its last confirmed request, then hides it.
- A lost or slow reply (the iPhone's timer has 5 seconds to answer) hides the time until the next confirmation; on iOS 17–25 a suspended iPhone app is woken for each request, which takes a few seconds.
- The renewal asks every 5 seconds also while the run is paused or waits for the user: a pause ended on the iPhone is a change of time too.
- On iOS 17–25 the renewal can wake the iPhone app up to 12 times a minute, and each answer runs the timer's settling once; if iOS limits these launches, the time hides more often.
- The time ends on screen at the confirmation's end in wall time; a watch clock set meanwhile is caught by the watch app, which moves that end back to what its monotonic clock vouches for. If watchOS does not redraw the screen at that moment, the time goes at its next redraw.
- The time shown includes the difference between the iPhone's and the watch's clocks.
- Out of reach, the last run shows without its time; after the iPhone app died without ending its run, the run stays until a new iPhone process answers.
- A workout whose names do not fit in a transfer, even with a shorter list, is not shown on the watch until its timer closes, another workout starts or the iPhone app ends. Since CT-9-3 the list is cut to 60,000 − 8,192 bytes, leaving room for a running workout. A workout larger than that room may show a shorter list on the watch while it runs, and the list comes back whole when it ends.
- A command that got no answer may have applied: the watch says «Checking on iPhone…» and shows what the next confirmation brings. An answer the iPhone could not confirm in time (a slow card or notification update, a timer that closed, the iPhone app ending) hides the time and the button until the next confirmation.
- While a command waits, the time shown keeps counting under its confirmation, at most 10 seconds from the last one; if the confirmation runs out meanwhile, the button goes and the outcome shows as a note.
- A Pause sent from a stage the iPhone has already left pauses the iPhone's current stage: the command is fenced only by changes of the run's phase, as the Live Activity's button is.
- A command that did not fit the iPhone timer's request queue reads as «Checking on iPhone…» although it never arrived.
- Commands from the watch and the Live Activity at the same moment: one of them gets «Couldn't». A card update stuck on the iPhone for over 10 seconds makes every later command «Couldn't» until it ends.
- A Pause/Resume reply from another iPhone process shows no command outcome; the watch asks for the state at most once per state, also with the wrist lowered, and a request already in flight may be followed by one more. A command during the run's renewal may cost one extra request too.
- Leaving the watch app, or closing the timer, while a command waits shows no outcome. A command the iPhone app had already taken when the system ended it reads as «Checking on iPhone…» and may have applied.
- The full version will gate the watch app in CT-6-2; Start, Pause and Resume are not gated yet.
- Return to Clock: by default watchOS goes back to the watch face about two minutes after the wrist is lowered, and the watch app asks again when it comes back. In the Watch app on the iPhone, CircuitTimer can stay in front for an hour.

## Device checklist

Check these on an iPhone with a paired Apple Watch on watchOS 10 or later before release (CT-7):

- [ ] A TestFlight build installs the watch app with the iPhone app (automatically, or from the Watch app's Available Apps).
- [ ] The watch app's name is CircuitTimer, its icon the iPhone app's, and its screens show in English and Russian, their background filling the screen.
- [ ] At the largest text size the screens scroll and no text is cut off.
- [ ] The list appears, and follows a save, a delete, a duplicate and a reorder on the iPhone, with the watch app open and when it opens later.
- [ ] Each situation in the table above shows its text; out of reach, the last list keeps its time.
- [ ] Force quit the iPhone app, then open the watch app: it gets an answer and the list is marked as earlier. Note whether the iPhone app's scene connects when it was launched that way.
- [ ] On iOS 17.5, opening the watch app and raising the wrist repeatedly does not exhaust the iPhone's background launches.
- [ ] With the watch app closed, a change on the iPhone reaches it by the next time it opens.
- [ ] With two watches paired to the iPhone, switch to the other one: once its session activates, its watch app shows the iPhone's current list without a change on the iPhone.
- [ ] Many workouts and one very long name: the list is cut with its note.
- [ ] iOS 26 with Health, iPhone locked: stages change on the watch as they go, and a pause on the iPhone shows on the watch within about a second. Note whether «Waiting for iPhone…» shows at a stage's end.
- [ ] iOS 17.5, iPhone app in the background: at a stage's end the time hides and comes back within seconds; 20 minutes of a workout do not exhaust the background launches; note the iPhone's battery use and the record writes the renewal causes.
- [ ] Bluetooth off on the iPhone during a stage: «iPhone isn't connected» at once, no time; 10 seconds later still no time, also after raising the wrist.
- [ ] Always On, and a watch without it: wrist lowered — no time; raised within 3 seconds — the time at once; after 15 seconds — one request, then the time.
- [ ] Return to Clock, by default and with «After 1 hour».
- [ ] The watch's and the iPhone's times differ by at most a second.
- [ ] Closing the timer: an open watch shows the list at once, a closed one when it opens. A swipe in the App Switcher on iOS 26 does the same; a force quit on iOS 17.5 leaves the run without time until a request, then the list.
- [ ] Continue of a saved run shows the run on the watch.
- [ ] A workout with very long stage names: «A workout is running on your iPhone», without a title, until it closes, then the list.
- [ ] The run's screen in English and Russian and at the largest text size.
- [ ] VoiceOver on the run's screen: the stage card reads as one element, the stage's name and then its time; without the iPhone's confirmation it reads no time, and its focus stays on the card when the confirmation comes and goes.
- [ ] A 41 mm watch and a stage whose name takes one line: the next stage shows under it without scrolling; a long name shows whole and scrolls.
- [ ] A stage of 10 minutes or more: the clock is as wide as `22:22` and no digit is cut off.
- [ ] Editing the workout list on the iPhone during a workout: the watch keeps showing the run.
- [ ] Relaunching the watch app during a workout shows the run.
- [ ] Pause and Resume from the watch: iPhone open; iOS 26 with Health and the iPhone locked; iOS 17.5 with the iPhone app suspended. The card, the notifications and the Health workout follow the command.
- [ ] Live Activities off, and separately a swiped-away card: Pause and Resume from the watch apply, without «Couldn't».
- [ ] Pause on the card, then Pause on the watch before it updates: «The workout changed on iPhone».
- [ ] Resume from the watch with the stage list, the close dialog and the resume 3-2-1 open on the iPhone.
- [ ] The button goes at a stage's end and with the iPhone out of reach, comes back with the confirmation, and the cards do not move; «Get ready» and «Done» have no empty space for it.
- [ ] Bluetooth off on the iPhone while a command waits: «Checking on iPhone…», then the outcome once it is back.
- [ ] Always On: no button, VoiceOver does not read it, nothing is asked.
- [ ] The button in English and Russian, at the largest text size and on a 41 mm watch.
- [ ] iOS 26: swipe the iPhone app away in the App Switcher while a command waits.
- [ ] Two quick taps on the Live Activity's button while its card is slow to update: the second says to try again shortly, after 10 seconds to check the timer in the app, and never applies.
- [ ] A watch screen that does not redraw (O4): note when the time disappears after the confirmation ends; the accepted limit is that it goes at the next redraw.

- [ ] Start with the iPhone active on Workouts and Settings; test the first notification and Health prompts on iOS 17.5 and iOS 26+.
- [ ] Start while the iPhone app is cold, inactive, locked, showing a draft/purchase/timer, restoring a saved run or reloading iCloud: the watch shows the appropriate refusal and the draft survives.
- [ ] Answer a system permission sheet after thirty seconds, including after background and return: access may update, but no expired timer opens.
- [ ] Let Health stall while reading access and while its sheet is open; a new local/watch Start continues without another Health read or request.
- [ ] Back while sending and while waiting; lose the accepted reply; change/remove/rename the selected workout, and publish a run before the reply or after the local wait: the root status and run remain truthful.
- [ ] Start selection, disabled state, all messages and VoiceOver hints in English/Russian, on a 41 mm watch and at the largest text size; the screens scroll.
