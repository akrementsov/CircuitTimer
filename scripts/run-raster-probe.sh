#!/usr/bin/env bash
# Temporary primitive experiment; its app links DesignSystem only, without feature stores.
set -euo pipefail
destination=$1
app=$2
output=$3
case "$destination" in
  'platform=iOS Simulator,name=iPhone 17,OS=27.0') name='iPhone 17' ;;
  'platform=iOS Simulator,name=iPhone 17 #2,OS=27.0') name='iPhone 17 #2' ;;
  'platform=iOS Simulator,name=iPhone 17 #3,OS=27.0') name='iPhone 17 #3' ;;
  *) echo 'raster-probe: use an allowed iPhone 17 on iOS27.0' >&2; exit 2 ;;
esac
case "${output##*/}" in
  RasterProbe-*) ;;
  *) echo 'raster-probe: output must be a dedicated RasterProbe-* directory' >&2; exit 2 ;;
esac
rm -rf "$output"
mkdir -p "$output"
udid=$(xcrun simctl list devices available -j | jq -r --arg name "$name" \
  '.devices["com.apple.CoreSimulator.SimRuntime.iOS-27-0"][]? | select(.name == $name) | .udid' | head -1)
[ -n "$udid" ] || { echo "raster-probe: no $name" >&2; exit 2; }
bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")
xcrun simctl bootstatus "$udid" -b
xcrun simctl install "$udid" "$app"
container=$(xcrun simctl get_app_container "$udid" "$bundle" data)
probe="$container/Documents/RasterProbe"
rm -rf "$probe"
sw_vers > "$output/host.txt"
uname -m >> "$output/host.txt"
if ! sysctl -n machdep.cpu.brand_string >> "$output/host.txt"; then
  echo 'raster-probe: CPU brand unavailable' >> "$output/host.txt"
fi
xcodebuild -version >> "$output/host.txt"
xcrun simctl launch --terminate-running-process "$udid" "$bundle"
cleanup() {
  if ! xcrun simctl terminate "$udid" "$bundle"; then
    echo 'raster-probe: app was not running at cleanup' >&2
  fi
}
trap cleanup EXIT
for ((attempt=0; attempt<120; attempt++)); do
  if [ -f "$probe/report.json" ]; then
    cp -R "$probe/." "$output/"
    python3 scripts/check-raster-probe.py "$output"
    exit 0
  fi
  if [ -f "$probe/error.txt" ]; then
    cp -R "$probe/." "$output/"
    cat "$probe/error.txt" >&2
    exit 1
  fi
  sleep 1
done
echo 'raster-probe: app did not finish in120s' >&2
if [ -d "$probe" ]; then cp -R "$probe/." "$output/"; fi
exit 1
