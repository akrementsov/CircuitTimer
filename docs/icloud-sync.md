# iCloud sync

Workouts, their stages and the list order sync through the user's private CloudKit database. The signal switches and the saved timer run stay on each device. SwiftData mirrors the store; the `CloudSync` module decides whether it does and reports how it goes.

## How a launch decides

- `CloudSyncClient.mirroredContainer()` decides once per process, on the first call, from the iCloud sync switch (`@Shared(.iCloudSync)`, key `iCloudSync`, on by default) and the container the app's Info.plist names (`CTCloudKitContainerIdentifier`, from `CT_CLOUDKIT_CONTAINER` in `Configs/App.xcconfig`).
- `WorkoutStoreProvider.live()` opens the same file `Workouts.store` with `.private(container)` or `.none`. If opening with CloudKit throws, it logs a fault and opens the file on the device; only a store that fails both ways is a list error. It then reports `storeOpened(isMirroring:)`.
- An open `ModelContainer` cannot change its mirroring, so a change of the switch applies at the next launch. Until then Settings asks to close and reopen the app.
- Without an iCloud account the store still opens with `.private` and works on the device; signing in later should start syncing without a relaunch (a device check below).
- Unsigned builds (`make build-app`, UI tests, snapshots) pass `CT_CLOUDKIT_CONTAINER=`: they carry no entitlement, and creating a `CKContainer` without it traps the process. Their store stays on the device.

## What CloudSync reports

- `remoteChanges()` yields after every successful `.import` and `.setup` event of `NSPersistentCloudKitContainer.eventChangedNotification`, after `CKAccountChanged` and again once the account status that change caused is read. The observers are registered before the store opens, so its first setup and import are seen. `AppFeature` reads the list again on each, never over a write in its queue, a reload in flight or the first load, which read again when they finish.
- After a load, a read-only workout screen on top of the stack shows the stored version, or closes when the workout is gone. A draft, a screen with an alert and a screen starting the timer are never replaced.
- `status()` gives `isRequested` (the launch's decision), `isMirroring` (how the store opened) and a problem: a failed open while sync is on, then the account (no account, restricted, temporarily unavailable), then full iCloud storage, then any other failed import or export. A later successful event of the same kind clears its failure.
- `CloudSyncClassification` sorts the errors, looking inside a partial failure at its items and passing over items that only shared a failed batch: `CKError.quotaExceeded`; `notAuthenticated` and `accountTemporarilyUnavailable` read the account again; network, rate limit, zone busy and a changed server record, which Core Data resolves on retry, are only logged; cancelled operations are ignored. Core Data's undocumented Cocoa codes, as Apple engineers explain them on the Developer Forums: 134400 (no usable account) and 134406 (the mirroring delegate never started) read the account again; 134419 (history analysis deferred) and 134417 (an export gave way to a pending one) are only logged.
- The account is read through `CKContainer(identifier:)` only while the store mirrors: after it opened, after an account change and when an event fails on the account. Only the latest read counts, and an account change clears the previous account's failures.
- Settings shows, in this order: «Close and reopen the app to apply this change.» while the switch differs from the launch's decision; «Workouts are stored only on this device.» while it is off; otherwise the problem, if any.

## Copies and deletions

Two devices that each held a workout before syncing, the seeded sample above all, end up with several records of one `workoutID`. Schema V2 adds two properties to `WorkoutModel`:

- `copyID`, an identifier a device sets once. New records get one from `@Dependency(\.uuid)`; records from before V2 get one on the next read.
- `isFreshSample`, set on a sample this device seeded and cleared by the first save of it.

The visible copy is the readable one with the lowest `(isFreshSample, copyID)`, the same on every device. The other readable copies stay stored, are not reported as hidden and receive no edits. Reads never delete them: a copy that arrives before its stages would otherwise replace a complete one.

Deleting a workout deletes all its copies and writes a `SeedMarkerModel` with the key `deleted:<id>`. The marker syncs, so a copy that arrives later is hidden and removed, the sample is never seeded again, and saving that workout from an open editor reports `.deletedElsewhere`: the editor offers Save as new, under a new identifier at the end of the list, or Don't save.

Every store operation runs in a `ModelContext` of its own, so it reads what an import changed since the previous one. Stored order is `(order, workoutID, copy rank, persistentModelID)`, and stages break ties by `stageID`, so equal `order` values from two devices sort alike everywhere.

## Accepted limits

- Of copies that differ, one shows and the other's edits are lost (owner decision).
- Concurrent edits of one workout on two devices can mix fields and stages, as CloudKit merges records one by one; past 50 stages in a section the merged workout fails to read and hides (owner decision). A whole-workout snapshot is a separate task if device checks show it is common.
- A deletion made with sync wins over edits of that workout made on another device with sync off.
- Signing out of iCloud or switching accounts may remove the synced workouts from the device; they return after signing in (owner decision). The sample is seeded again meanwhile, as on a new device; if it was deleted, its edits from that time are lost when the marker returns.
- A sample deleted before sync existed comes back from another device that kept it: that deletion was local (owner decision).
- A workout can show empty for a moment while its stages are still importing.
- Stages of a deleted copy that arrive later stay orphaned, since an orphan may still be waiting for its parent; unshown copies of the sample remain, and renumbering rewrites their `order` too.
- Two devices can assign different `copyID`s to one record from before V2; CloudKit keeps one of the values.
- Simulators receive no CloudKit pushes: a change from another device arrives when the app becomes active.

## Signing and delivery

- `Configs/CircuitTimer.entitlements` gives the app the container, CloudKit and `aps-environment`; `Configs/Info.plist` adds the `remote-notification` background mode. The widget has no iCloud entitlement.
- `make archive` builds unsigned and then signs the widget and the app ad hoc, the app with the entitlements, because the export keeps only the entitlements of the archived signature. `scripts/verify-export-signing.py` checks the archive and the exported IPA, including `icloud-container-environment = Production` and `aps-environment = production`, before `testflight.yml` uploads.

Before the first TestFlight build with sync, and after every schema change:

1. Developer Portal: the App ID `com.akrementsov.circuittimer` has iCloud with CloudKit and Push Notifications, and the container `iCloud.com.akrementsov.circuittimer` is assigned to it.
2. Run a signed Debug build signed in to iCloud with the launch argument `-CTInitializeCloudKitSchema`. It creates every record type and field in Development (`CD_WorkoutModel` with `CD_copyID` and `CD_isFreshSample`, `CD_StageModel`, `CD_SeedMarkerModel`) and exits.
3. CloudKit Console: check the types, then Deploy Schema Changes to Production.
4. Only then tag a release. Production only accepts additions: a later schema version may add fields and types, never rename or remove them.

## Experiments

Run on 2026-10-21/22 with a throwaway build, before the store code was written.

| | Question | Result |
|---|---|---|
| E1 | Does the archive carry the entitlements to the export? | Ad hoc signing during the archive fails ("requires a provisioning profile"). An unsigned archive exports without iCloud and Push. Signing the unsigned archive ad hoc first, then exporting, gives an IPA with Production CloudKit and production Push. |
| E2 | Does a real V1 store migrate when opened with `.private`? | Yes, on iOS 27.0: lightweight V1→V2, `copyID` assigned, setup, import and export succeed; a second simulator received all records with their `copyID`. |
| E3a | Which signal refreshes an open list? | Simulators get no pushes. On activation an import starts within about 1.5 s, ends successfully and posts its event. |
| E4 | Does `.private` → `.none` → `.private` keep and upload the changes made in between? | Yes, on iOS 27.0: writes under `.none`, then the edit, deletion and new order reached the second simulator. |
| E3b, E3c | Does an open, active list refresh on a real device; what happens on sign-out? | On the owner's iPhones, not run yet: see the checklist. |
| E5 | What does an unsigned build do? | Opening `.private` does not throw; creating a `CKContainer` traps. Hence the empty container in unsigned builds. |

## Device checklist

On the owner's iPhones on iOS 17 and 26.5, one Apple ID, builds of the same kind:

- [ ] An update from a CT-2 store: the sample shows once and no hidden-records footnote appears; the store migrates on iOS 17 too.
- [ ] Create, edit, reorder and delete on one device appear on the other while its list stays open and active (E3b). If an import arrives without its event, the list needs a bounded refresh while active; if no import arrives at all, the owner decides.
- [ ] An open read-only workout updates or closes; a draft does not.
- [ ] Concurrent reorders with one device offline end in the same order on both; saving in the editor while an import lands does not fail.
- [ ] Switch off and relaunch, then on and relaunch, with the footnotes; changes made while off arrive (E4 on iOS 17).
- [ ] Sign out of iCloud and back in: the list reloads after the actual removal, the footnote asks to sign in, the workouts return (E3c).
- [ ] Airplane mode shows no footnote and edits keep working.
- [ ] A sample deleted with sync does not return on a new installation; an edited sample is not replaced by a fresh one.
- [ ] Saving a workout deleted on the other device: Save as new adds it at the end on both devices.
- [ ] TestFlight: Production and production Push in the build, sync between two TestFlight installations.
