# Screenshots

The four images at the top of the [README](../../README.md) are screenshots of the running app, taken by hand. Nothing checks them, unlike the snapshot tests' references: retake them when the list, the workout screen, the timer or the Live Activity changes.

1. Build the app with `make build-app` and run it on the `iPhone 17` simulator on iOS 27.0 as in [README › Run the app](../../README.md#run-the-app), with the simulator's language set to English.
2. Set the status bar: `xcrun simctl status_bar <udid> override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState discharging --batteryLevel 100`.
3. Fill the list: the app seeds Morning HIIT on its first launch; add the other workouts in the editor.
4. Turn off Background notifications in Settings before the timer shot: on the simulator iOS does not confirm the scheduled notifications, and the timer would show its footnote.
5. Start Morning HIIT; take the timer during a work stage, then lock the simulator with the side button of its frame in Device Hub and take the Lock Screen.
6. Take each one with `xcrun simctl io <udid> screenshot <file>.png`, then scale it to 600 px wide: `sips --resampleWidth 600 <file>.png`. Save the Lock Screen as JPEG, which keeps its wallpaper near 100 KB: `sips --resampleWidth 600 -s format jpeg -s formatOptions 85 lock.png --out lock-screen.jpg`.
7. Turn Background notifications back on and run `xcrun simctl status_bar <udid> clear`.
