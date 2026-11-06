# App Store Connect

What the app's page and its review in App Store Connect hold, in the words to enter there. The texts themselves live in `docs/legal/` (AGENTS.md › Localization); purchases have their own checklist in [Purchases](purchases.md#app-store-connect-checklist-owner).

## Addresses

GitHub Pages publishes `docs/` from `main` (`https://akrementsov.github.io/CircuitTimer/`).

| Field | English | Russian |
|---|---|---|
| Privacy Policy URL | `https://akrementsov.github.io/CircuitTimer/legal/privacy-policy.html` | `https://akrementsov.github.io/CircuitTimer/legal/ru/privacy-policy.html` |
| Support URL | `https://akrementsov.github.io/CircuitTimer/` | the same |
| License Agreement | Apple's Standard EULA; the Terms of Use add to it and are not uploaded as a custom one | |

## App Privacy

**Data Not Collected.** Neither the developer nor a third-party service of the developer receives any data from the app: it has no accounts, servers, analytics, advertising or tracking. What leaves the app goes to Apple under the user's own Apple Account, which Apple's privacy details do not count as collection by the developer:

- iCloud sync (full version): workouts in the user's private CloudKit database;
- Apple Health (iOS 26 and later, with permission): workouts written on the device, nothing read;
- the purchase: handled by the App Store;
- the Apple Watch app: the WatchConnectivity link between the user's own devices.

Change these answers, the Privacy Policy and this section together if the app ever sends data anywhere else.

## App Review note

Enter in App Review Information › Notes:

> Circuit Timer is an interval timer. On iOS 26 and later it starts an HKWorkoutSession (high-intensity interval training, indoors) while a workout timer runs, so the timer and its Live Activity keep running in the background, and when the timer closes it saves the workout to Apple Health without its pauses. It only writes workouts and never reads Health data. To see it: open the sample workout, tap Start workout, allow Health access in the sheet, let the timer run, then close it and tap Finish; the workout appears in the Health app under Workouts.
>
> The full version is the non-consumable "Full Version". It unlocks iCloud sync, more than two workouts and the Apple Watch app; without it, the watch app shows that the full version is needed. Settings › Buy the App opens the purchase screen; Restore Purchases is on the same screen.

## Description

The paragraph that names Apple Health and the Apple Watch app; the rest of the Description is the owner's.

English:

> Saves your workouts to Apple Health on iOS 26 and later, without their pauses. With the full version, control the timer from Apple Watch: pick a workout, start it on the iPhone, pause and resume it from your wrist.

Russian:

> На iOS 26 и новее сохраняет ваши тренировки в Apple Health, без пауз. С полной версией таймером можно управлять с Apple Watch: выбрать тренировку, запустить её на iPhone, поставить на паузу и продолжить с запястья.
