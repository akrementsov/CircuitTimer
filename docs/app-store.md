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

> Circuit Timer is an interval timer. On iOS 26 and later, with the user's permission, it runs an HKWorkoutSession (high-intensity interval training, indoors) while a workout timer is open, and when the timer closes it asks Apple Health to save that workout without its pauses. It only writes workouts and never reads Health data. To see it: open the sample workout, tap Start workout, allow notifications, then allow Health access in the sheet, let the timer run for a minute, then close it and tap Finish; once Health has saved it, the workout is in the Health app under Workouts.
>
> The full version is the non-consumable "Full Version". It unlocks iCloud sync, more than two workouts and the Apple Watch app; without it, the watch app shows that the full version is needed. Settings › Buy the App opens the purchase screen; Restore Purchases is on the same screen.

## Description

What version 1.0 holds in App Store Connect, as entered on 2026-11-06. Its bullets on Apple Health and the Apple Watch app are the paragraph this page asked for; change them together with Apple Health and the watch app.

English:

```
Circuit Timer runs interval and circuit workouts the way you build them: a warm-up, a training block repeated for as many rounds as you need, and a cool-down, each made of timed work and rest stages, with manual pauses wherever you want to stop and wait.

• A full-screen timer you can read from across the room, with tones, haptics and spoken stage names; each signal has its own switch.
• Keeps going in the background: notifications for each new stage, and a Live Activity on the Lock Screen and in the Dynamic Island with Pause and Resume.
• Picks up where you left off if the app is closed mid-workout.
• Saves your workouts to Apple Health on iOS 26 and later, without their pauses.
• Dark design, in English and Russian.

Full version, a one-time purchase:
• more than two workouts;
• iCloud sync between your devices;
• the Apple Watch app: pick a workout, start it on the iPhone, pause and resume it from your wrist.

No accounts, no ads, no tracking.
```

Russian:

```
Circuit Timer ведёт интервальные и круговые тренировки так, как вы их собрали: разминка, тренировочный блок на нужное число раундов и заминка — из этапов работы и отдыха по времени, с ручными паузами там, где нужно остановиться и подождать.

• Полноэкранный таймер, который видно издалека: звуки, вибрация и названия этапов голосом, у каждого сигнала свой переключатель.
• Работает в фоне: уведомления о каждом новом этапе и Live Activity на экране блокировки и в Dynamic Island с паузой и продолжением.
• Если приложение закрылось посреди тренировки, предложит продолжить с того же места.
• На iOS 26 и новее сохраняет ваши тренировки в Apple Health, без пауз.
• Тёмное оформление, английский и русский языки.

Полная версия, разовая покупка:
• больше двух тренировок;
• синхронизация через iCloud между вашими устройствами;
• приложение для Apple Watch: выбрать тренировку, запустить её на iPhone, поставить на паузу и продолжить с запястья.

Без аккаунтов, рекламы и слежки.
```

## Other fields

| Field | Value |
|---|---|
| Keywords, English | `tabata,emom,workout,training,rounds,boxing,fitness,gym,exercise,cardio,stopwatch,countdown,rest` |
| Keywords, Russian | `таймер,интервальный,тренировка,табата,круговая,раунды,хиит,фитнес,бокс,кардио,зал,упражнения,отдых` |
| Copyright | `2026 Andrey Krementsov` |
| Categories | Health & Fitness, then Sports |
| Age rating | 4+: every content question answered None or No, Health or Wellness Topics included (the app gives no advice) |
| Content rights | No third-party content |
| App Review sign-in | Not required |
| Screenshots | iPhone 6.1/6.3" (1206×2622) and Apple Watch (416×496) in both languages, taken on the simulators; App Store Connect asks for no larger iPhone size |
