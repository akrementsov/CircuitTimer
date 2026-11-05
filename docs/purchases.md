# Purchases

One non-consumable in-app purchase, the full version (`com.akrementsov.circuittimer.fullversion`), unlocks iCloud sync of workouts, more than two workouts and, from CT-6-2, the Apple Watch app. It is a one-time purchase with Family Sharing on. The price is always the App Store's `displayPrice` in the user's storefront; nothing in the app names an amount.

## How the app knows

- `Purchases` asks StoreKit 2 in every process; nothing about the purchase is stored on the device. The status is `unknown` until StoreKit has answered once, then `free` or `full`.
- `full` means a verified transaction of the product in `Transaction.currentEntitlements` without a `revocationDate`: bought, restored, shared through Family Sharing or approved after Ask to Buy. iOS 17 has no `currentEntitlements(for:)` (iOS 18.4), and `currentEntitlement(for:)` is deprecated there, so the monitor walks the whole sequence.
- `EntitlementMonitor` listens to `Transaction.updates` for the whole process from its first use, finishes every verified transaction and reads the entitlement again after each. A refund, a revocation, the end of Family Sharing and an Ask to Buy approval arrive this way while the app runs.
- Reads are numbered: only the newest one started publishes its answer, and a purchase makes the reads already under way older, so a late read never overwrites a newer purchase or refund.
- A purchase uses `Product.purchase(confirmIn:)` with the foreground `UIWindowScene` (the view-controller variant needs iOS 18.2). A cancelled payment or App Store sign-in is not an error and shows nothing.
- Restore runs `AppStore.sync()` and reads the entitlement again until its read is the newest one, so a transaction update that arrives meanwhile never makes it say the wrong thing.

## iCloud and the launch

The store mirrors to iCloud only with the full version. The launch decides once per process: with the switch on and a container, `CloudSyncClient.prepareDecision()` waits for StoreKit for at most a second, in a task no caller can cut short, while the saved run is read; the store then opens once with the answer ([iCloud sync](icloud-sync.md)). When StoreKit does not answer in time, the launch keeps workouts on the device; the full version still unlocks the rest of the app as soon as it arrives, and iCloud at the next launch. A purchase and a refund likewise reach iCloud at the next launch, and the screens say so.

## Where the app asks

- **Settings.** The tab reads the status `AppFeature` follows, so a buyer never sees the lock on its first frame. Without the full version the iCloud switch is a locked button (a lock next to its title, the switch drawn off) that opens the purchase sheet, and two rows offer «Buy the App» and «Restore Purchases»; Restore opens the sheet and restores at once. With it, the switch works as before and one row says «Full Version — Purchased». While StoreKit has not answered, neither rows nor footnote show.
- **The workout list.** «+» and Duplicate open the sheet once the list shows two workouts; the «+» looks as always. Stored workouts stay visible, editable and playable whatever their number.
- **The Apple Watch app** (CT-6-2): without the full version the iPhone will send the watch nothing and ignore its commands, and the watch will say to buy it on the iPhone. Until then the iPhone publishes its workouts to the watch whatever the status.

## The purchase sheet

`PurchaseFeature`, shown only by `AppFeature`, never in place of the question about a saved run, an alert or the timer; a request made meanwhile waits, and one made while the timer is up is dropped. A write that fails under the sheet shows its alert after the sheet has gone.

| State | What the sheet shows |
|---|---|
| Price loaded | Logo, «Full Version», the three features, «Buy for <price>», «Restore Purchases», the fine print |
| Opened by a limit | The same with a plaque: «The free version keeps two workouts» or «iCloud sync is part of the full version» |
| Loading the price | A dimmed button with a spinner; Restore works |
| Purchasing, restoring | A spinner on that button, the other dimmed, the close button and the swipe disabled |
| Waiting for approval | Ask to Buy or another approval: a note and a dimmed «Waiting for Approval»; the sheet may close, and the approval unlocks the app later |
| App Store unavailable | A note and «Try Again» |
| Purchased | «Thank You!», the features with checkmarks, «Done», and a note on iCloud as the app knew it when it showed the sheet: sync starts at the next launch with the switch on; turn it on in Settings with the switch off; none when the store already mirrors (a refund and a new purchase in one process) |

Alerts: «Purchase Failed» for a failed payment, «Purchases Are Not Allowed» when Screen Time or a profile forbids them, «No Purchases Found» when a restore finds nothing, «Couldn't Restore Purchases» for a failed restore. «Couldn't Verify the Purchase» (StoreKit could not verify a transaction) and «Couldn't Confirm the Purchase» (StoreKit reported success but the status did not say `full` within 3 seconds) offer Restore Purchases; a full version that arrives later still shows «Thank You!». A full version that arrives from elsewhere while the sheet is open, such as through Family Sharing, closes it. A write error or a saved run that waited for the sheet shows after it has left the screen.

## Accepted limits

- The free limit is enforced where the user creates, not in storage: an import from iCloud after the check, or a new-workout editor opened at one workout that saves after an import or a refund, can leave a third workout.
- After a refund the store keeps mirroring until the next launch; Settings says sync turns off after a relaunch.
- A buyer whose StoreKit does not answer within a second at launch, such as offline, keeps workouts on the device until the next launch.
- The entitlement is a verified transaction of the product without a `revocationDate`; `ownershipType` is not checked separately, as bought and Family-Shared are its only values today.

## Trying it locally

`Configs/CircuitTimer.storekit` holds the product for runs from Xcode (the `CircuitTimer` scheme's Run › Options › StoreKit Configuration). Debug › StoreKit › Manage Transactions refunds, approves or declines Ask to Buy and deletes transactions. The file is not synced with App Store Connect. UI test scenarios and snapshots never reach StoreKit: scenarios own the full version (`PurchaseClient.scenario(status: .full)`), except `twoWorkoutsFree`, which starts without it at the free limit and buys it in memory. The sheet's snapshots draw `PurchaseView` as the window's root.

## App Store Connect checklist (owner)

- [x] The Paid Apps Agreement, banking and tax are active; without them no purchase works, not even in the sandbox.
- [x] In-App Purchases › Non-Consumable, reference name «Full Version», product ID `com.akrementsov.circuittimer.fullversion`.
- [x] Price about $0.99 / 59 ₽, available in every storefront of the app: $0.99 in the US, 99 ₽ in Russia, 175 storefronts.
- [x] Family Sharing turned on. Apple does not let a developer turn it off again for a product; confirm before turning it on.
- [x] Display name and description in English and Russian; App Store Connect allows 55 characters, so the descriptions are shorter than in `Configs/CircuitTimer.storekit`.
- [x] Review Information: a screenshot of the purchase sheet and a note on what the purchase unlocks.
- [ ] Submit the first purchase together with an app version.
- [ ] Sandbox testers for the device checks: purchase, refund, Ask to Buy, Family Sharing, restore on a second device, launch offline (listed under CT-7).
- [ ] App Privacy: purchases are handled by Apple; the app collects nothing about them.
