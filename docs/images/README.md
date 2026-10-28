# Screenshots

The four images at the top of the [README](../../README.md) are screenshots of the running app, taken by hand. Nothing checks them, unlike the snapshot tests' references: retake them when the look of the list, the workout screen, the timer or the Live Activity changes.

1. Set the `iPhone 17` simulator on iOS 27.0 to English and remove the app from it, so that it starts with no data: `xcrun simctl uninstall <udid> com.akrementsov.circuittimer`. Then build and run the app as in [README › Run the app](../../README.md#run-the-app).
2. Set the status bar: `xcrun simctl status_bar <udid> override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState discharging --batteryLevel 100`.
3. Fill the list: the app seeds Morning HIIT on its first launch; add Tabata sprints (9:00), Core 15 (11:00), Kettlebell circuit (13:00) and Evening stretch (6:00) in the editor.
4. Turn off Background notifications in Settings before the timer shot: on the simulator iOS does not confirm the scheduled notifications, and the timer would show its footnote.
5. Take each shot with `xcrun simctl io <udid> screenshot <file>.png`: the list as `list.png` and Morning HIIT's workout screen as `workout.png`; start it and take the timer during a work stage as `timer.png`; then lock the simulator with the side button of its frame in Device Hub and take the Lock Screen as `lock.png`.
6. Scale the PNGs to 600 px wide: `sips --resampleWidth 600 <file>.png`. Save the Lock Screen as JPEG, which keeps its wallpaper near 100 KB, and delete `lock.png`: `sips --resampleWidth 600 -s format jpeg -s formatOptions 85 lock.png --out lock-screen.jpg && rm lock.png`.
7. Turn Background notifications back on and run `xcrun simctl status_bar <udid> clear`.
