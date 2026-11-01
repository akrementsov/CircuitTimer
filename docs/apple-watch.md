# Apple Watch

The watch app is a remote for the iPhone timer: the workout runs on the iPhone, and without it the watch app does not work. It needs watchOS 10 or later and ships inside the iPhone app. CT-9 delivers it in slices; this page grows with them. The implementation rules are in [AGENTS.md › Apple Watch](../AGENTS.md#apple-watch-ct-9), [Module map](../AGENTS.md#module-map) and [Delivery](../AGENTS.md#delivery); change this file together with them.

## What it does now (CT-9-2)

The watch app shows the iPhone's workouts, in the iPhone's order, with their total time. The rows do nothing yet: the running stage, Pause and Resume and Start from the watch follow in CT-9-3 to CT-9-5 ([roadmap](roadmap.md)).

The list updates when the workouts change on the iPhone. When the watch has no fresh list, it says why:

| Situation | The watch shows |
|---|---|
| The iPhone is out of reach | the last list, under «iPhone isn't connected · Updated …», or «iPhone isn't connected» without a list |
| The iPhone restarted and is locked | «Unlock your iPhone» |
| The iPhone app is not installed | «CircuitTimer isn't available on iPhone» |
| The iPhone could not load its workouts | the last list, dimmed, with «Couldn't load workouts on iPhone. Showing the earlier list.» |
| The list does not fit in one transfer | the start of the list with «Not every workout fits on the watch.»; if even that fails, the last list dimmed or «Workouts don't fit on the watch» |
| The iPhone app was launched in the background and has not loaded its workouts | the last list under «Earlier list from … · Waiting for iPhone», or «Open CircuitTimer on your iPhone» |
| The two apps speak different versions | «Update CircuitTimer on your iPhone» or «… on your watch» |

## How it works

- The iPhone app publishes its list whenever it settles: after it loads, and after every save, delete, duplicate and reorder once the write has finished. The newest list goes into the WatchConnectivity application context, which the watch app receives now or when it opens, and to a reachable watch app at once as a message.
- The watch app asks the iPhone for its current state when it opens or comes back to the front, when the iPhone becomes reachable, and after a failure, again after 5, 10 and 20 seconds, then every 20 seconds while the watch app is open and the iPhone in reach. Once the iPhone answers, the watch does not ask again until the next of these reasons; an unchanged list is confirmed by its digest without being sent again.
- A request from the watch can launch the iPhone app in the background. That process answers at once but has not read the workouts, so it says it knows no list; the list comes when the iPhone app loads it.

## How it is built and shipped

- `WatchLink` holds the channel: the wire format, the WatchConnectivity bridge and both sides' clients. `WatchRemoteFeature` holds the watch app's reducer and screens. Both build for iOS and watchOS, so their tests run with the package's on the iPhone simulator. `DesignSystem` and `WorkoutActivity` build for watchOS too; their iOS-only parts are left out there.
- The `CircuitTimerWatch` target is a thin watchOS app over a `Store` of `WatchRemoteFeature`. The iPhone app depends on it and embeds it in `CircuitTimer.app/Watch/`, so every app build, the UI test build and the archive build it.
- `make build-watch-package` builds the watch app's modules strictly for the watch's own architectures, `arm64_32` for watches with chips before S9 and `arm64` from S9, in `make ci` and as its own CI step. It needs the watchOS SDK, not a watchOS runtime; the `xcode-27` CI image has the SDK.
- `make archive` signs the watch app ad hoc between the widget and the iPhone app; `testflight.yml` checks its Info.plist in the archive and its App Store signature, without HealthKit or iCloud, in the exported IPA.

## TestFlight tag at the end of CT-9

One tag after CT-9-5 checks what only App Store Connect can:

- [ ] `testflight.yml` exports and verifies the IPA: the cloud signing creates the watch app's App ID and signs it for the App Store.
- [ ] TestFlight's processing accepts the build with the watch app. Xcode adds `MinimumOSVersion~ipad` to the watch app's Info.plist on its own; this shows whether App Store Connect minds.

## Accepted limits

- WatchConnectivity documents no size limit; the iPhone keeps each transfer under 60,000 bytes, an assumption checked on a device.
- A context write that fails waits for the next activation, change of watch or publication on the iPhone, or for the watch app to come to the front.
- An iPhone app launched in the background by the watch does not read its workouts, so the watch keeps its list marked as earlier until the iPhone app loads them.
- While the watch app stays open and the iPhone is out of reach, a context a new iPhone process wrote waits: the watch believes a new process only through the answer to its own request, because WatchConnectivity promises no order between two processes. The watch shows the earlier list until it can ask.
- After the user switches to another watch, the iPhone writes its newest list again once the session for that watch activates.

## Device checklist

Check these on an iPhone with a paired Apple Watch on watchOS 10 or later before release (CT-7):

- [ ] A TestFlight build installs the watch app with the iPhone app (automatically, or from the Watch app's Available Apps).
- [ ] The watch app's name is CircuitTimer, its icon the iPhone app's, and its screens show in English and Russian, their background filling the screen.
- [ ] At the largest text size the screens scroll and no text is cut off.
- [ ] The list appears, and follows a save, a delete, a duplicate and a reorder on the iPhone, with the watch app open and when it opens later.
- [ ] Each situation in the table above shows its text; out of reach, the last list keeps its time.
- [ ] Force quit the iPhone app, then open the watch app: it gets an answer and the list is marked as earlier. Note whether the iPhone app's scene connects when it was launched that way.
- [ ] On iOS 17.5, opening the watch app repeatedly does not exhaust the iPhone's background launches.
- [ ] With the watch app closed, a change on the iPhone reaches it by the next time it opens.
- [ ] With two watches paired to the iPhone, switch to the other one: once its session activates, its watch app shows the iPhone's current list without a change on the iPhone.
- [ ] Many workouts and one very long name: the list is cut with its note.
