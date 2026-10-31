#!/usr/bin/env bash
# Tests `make archive` after xcodebuild, which a stand-in replaces with an archived app of two extensions and a watch
# app: the ad hoc signatures, the app's entitlements with the container of the archived Info.plist, and where it stops.
# A stand-in records codesign. On a Mac the recipe uses the real plutil and PlistBuddy; Linux has neither, so stand-ins
# that edit property lists the same way take their place. Make exits 2 when the recipe fails.
. "$(dirname "$0")/lib.sh"

repo="$work/repo"
mkdir -p "$repo/Configs" "$work/bin" "$work/trace"
cp "$root/Makefile" "$repo/"
cp "$root/Configs/CircuitTimer.entitlements" "$repo/Configs/"

cat > "$work/bin/xcodebuild" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$@" > "$TRACE/xcodebuild.args"
while [ "$#" -gt 0 ]; do
	case "$1" in -archivePath) archive=$2 ;; -derivedDataPath) derived=$2 ;; esac
	shift
done
mkdir -p "$derived"
app="$archive/Products/Applications/CircuitTimer.app"
for extension in CircuitTimerWidgets Second; do mkdir -p "$app/PlugIns/$extension.appex"; done
if [ "${WITHOUT_WATCH:-}" != 1 ]; then mkdir -p "$app/Watch/CircuitTimerWatch.app"; fi
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CTCloudKitContainerIdentifier</key><string>%s</string></dict></plist>\n' \
	"$ARCHIVED_CONTAINER" > "$app/Info.plist"
EOF
# Records each call; keeps the entitlements it signs with as they were at that moment.
cat > "$work/bin/codesign" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'codesign %s\n' "$*" >> "$TRACE/calls"
previous=""
for argument in "$@"; do
	if [ "$previous" = --entitlements ]; then cp "$argument" "$TRACE/signed-entitlements.plist"; fi
	previous=$argument
done
if [ "$1" = --verify ] && [ "${FAIL_VERIFY:-}" = 1 ]; then
	echo "$previous: a sealed resource is missing or invalid" >&2
	exit 1
fi
EOF
if ! command -v plutil > /dev/null; then
	cat > "$work/bin/plutil" <<'EOF'
#!/usr/bin/env bash
set -eu
[ "$#" -eq 4 ] && [ "$1" = -extract ] && [ "$3" = raw ] || { echo "plutil stand-in: unexpected $*" >&2; exit 64; }
exec python3 -I -c 'import plistlib, sys
with open(sys.argv[2], "rb") as file:
    data = plistlib.load(file)
if sys.argv[1] not in data:
    sys.exit(f"{sys.argv[2]}: Could not extract value, error: No value at that key path or invalid key path: {sys.argv[1]}")
print(data[sys.argv[1]])' "$2" "$4"
EOF
fi
plistbuddy=()
if [ ! -x /usr/libexec/PlistBuddy ]; then
	cat > "$work/bin/PlistBuddy" <<'EOF'
#!/usr/bin/env bash
set -eu
[ "$#" -eq 3 ] && [ "$1" = -c ] || { echo "PlistBuddy stand-in: unexpected $*" >&2; exit 64; }
exec python3 -I -c 'import plistlib, re, sys
command, path = sys.argv[1:]
match = re.fullmatch(r"Set :([^:]+):([0-9]+) (.*)", command)
if not match:
    sys.exit(f"PlistBuddy stand-in: unexpected command {command}")
with open(path, "rb") as file:
    data = plistlib.load(file)
data[match[1]][int(match[2])] = match[3]
with open(path, "wb") as file:
    plistlib.dump(data, file)' "$2" "$3"
EOF
	plistbuddy=(PLISTBUDDY="$work/bin/PlistBuddy")
fi
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH" TRACE="$work/trace"

archive_path="$work/CircuitTimer.xcarchive"
app="$archive_path/Products/Applications/CircuitTimer.app"
entitlements="$work/dd/Archive/CircuitTimer.entitlements"

# archive CONTAINER: `make archive` of an app whose Info.plist names CONTAINER.
archive() {
	rm -rf "$TRACE" "$archive_path" "$work/dd"
	mkdir -p "$TRACE"
	: > "$TRACE/calls"
	ARCHIVED_CONTAINER=$1 run make -s -C "$repo" archive BUILD_NUMBER=261022.101500 ARCHIVE_PATH="$archive_path" \
		DERIVED_DATA="$work/dd" SOURCE_PACKAGES="$work/sp" ${plistbuddy[@]+"${plistbuddy[@]}"}
}

# Prints a property list as sorted JSON.
plist_json() {
	python3 -I -c 'import json, plistlib, sys
with open(sys.argv[1], "rb") as file:
    print(json.dumps(plistlib.load(file), sort_keys=True))' "$1"
}

signing="codesign --force --sign - --timestamp=none $app/PlugIns/CircuitTimerWidgets.appex
codesign --force --sign - --timestamp=none $app/PlugIns/Second.appex
codesign --force --sign - --timestamp=none $app/Watch/CircuitTimerWatch.app
codesign --force --sign - --timestamp=none --entitlements $entitlements $app
codesign --verify --deep --strict $app"

describe "every extension and the watch app are signed before the app, the app with the archived container, then verified"
archive iCloud.com.example.archived
expect_status 0
expect_equal "$(cat "$TRACE/calls")" "$signing"
# The entitlements of Configs/CircuitTimer.entitlements with the container of the archived Info.plist.
expected=$(python3 -I -c 'import json, plistlib, sys
with open(sys.argv[1], "rb") as file:
    data = plistlib.load(file)
data["com.apple.developer.icloud-container-identifiers"] = [sys.argv[2]]
print(json.dumps(data, sort_keys=True))' "$root/Configs/CircuitTimer.entitlements" iCloud.com.example.archived)
expect_equal "$(plist_json "$TRACE/signed-entitlements.plist")" "$expected"
expect_in "$TRACE/signed-entitlements.plist" "<string>iCloud.com.example.archived</string>"
expect_in "$TRACE/signed-entitlements.plist" "<string>CloudKit</string>"
expect_in "$TRACE/signed-entitlements.plist" "<key>aps-environment</key>"
# The checked-in entitlements keep their build setting; only the copy names the container.
expect_equal "$(cat "$repo/Configs/CircuitTimer.entitlements")" "$(cat "$root/Configs/CircuitTimer.entitlements")"
# The archive itself is built unsigned and keeps the project's container.
expect_equal "$(head -1 "$TRACE/xcodebuild.args")" archive
expect_line "$TRACE/xcodebuild.args" CODE_SIGNING_ALLOWED=NO
expect_line "$TRACE/xcodebuild.args" CURRENT_PROJECT_VERSION=261022.101500
expect_not_in "$TRACE/xcodebuild.args" CT_CLOUDKIT_CONTAINER

describe "an app without a container stops before any signature"
archive ""
expect_status 2
expect_in "$work/out" "archive: the app names no CloudKit container"
expect_equal "$(cat "$TRACE/calls")" ""

describe "an app without the watch app stops before any signature"
WITHOUT_WATCH=1 archive iCloud.com.example.archived
expect_status 2
expect_in "$work/out" "archive: the app embeds no watch app at $app/Watch/CircuitTimerWatch.app"
expect_equal "$(cat "$TRACE/calls")" ""

describe "a failed verification fails the archive"
FAIL_VERIFY=1 archive iCloud.com.example.archived
expect_status 2
expect_in "$work/out" "$app: a sealed resource is missing or invalid"
expect_equal "$(cat "$TRACE/calls")" "$signing"

finish
