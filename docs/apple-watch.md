# Apple Watch

The watch app is a remote for the iPhone timer: the workout runs on the iPhone, and without it the watch app does not work. It needs watchOS 10 or later and ships inside the iPhone app. CT-9 delivers it in slices; this page grows with them. The implementation rules are in [AGENTS.md › Module map](../AGENTS.md#module-map) and [Delivery](../AGENTS.md#delivery); change this file together with them.

## What it does now (CT-9-1)

The watch app installs with the iPhone app and shows one screen: «Open CircuitTimer on your iPhone — your workouts will appear here». The workout list, the running stage, Pause and Resume and Start from the watch follow in CT-9-2 to CT-9-5 ([roadmap](roadmap.md)).

## How it is built and shipped

- `WatchRemoteFeature` holds the watch app's screens; it builds for iOS and watchOS, so its tests run with the package's on the iPhone simulator. `DesignSystem` builds for watchOS too; its iOS screen parts are left out there.
- The `CircuitTimerWatch` target is a thin watchOS app that shows `WatchRootView`. The iPhone app depends on it and embeds it in `CircuitTimer.app/Watch/`, so every app build, the UI test build and the archive build it.
- `make build-watch-package` builds the watch app's modules strictly for a generic watchOS Simulator destination. It needs the watchOS SDK, not a watchOS runtime: no watch simulator exists locally, and the `xcode-27` CI image has the SDK.
- `make archive` signs the watch app ad hoc between the widget and the iPhone app; `testflight.yml` checks its Info.plist in the archive and its App Store signature, without HealthKit or iCloud, in the exported IPA.

## Device checklist

Check these on an iPhone with a paired Apple Watch on watchOS 10 or later before release (CT-7):

- [ ] A TestFlight build installs the watch app with the iPhone app (automatically, or from the Watch app's Available Apps).
- [ ] The watch app's name is CircuitTimer, its icon the iPhone app's, and it shows the screen above in English and Russian.
- [ ] TestFlight's processing accepts the build with the watch app, and the watch app's App ID is created by the cloud signing.
