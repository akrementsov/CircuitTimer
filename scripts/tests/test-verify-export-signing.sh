#!/usr/bin/env bash
# Tests scripts/verify-export-signing.py on archives and IPAs made of property lists. Stand-ins for codesign and
# security print what a bundle's `_CodeSignature/signed-entitlements.plist` and `embedded.mobileprovision` hold, so
# Linux runs it too; a bundle without the first is unsigned.
. "$(dirname "$0")/lib.sh"

mkdir -p "$work/bin"
cat > "$work/bin/codesign" <<'EOF'
#!/usr/bin/env bash
set -eu
[ "$#" -eq 5 ] && [ "$1 $2 $3 $4" = "-d --entitlements - --xml" ] || { echo "codesign stand-in: unexpected $*" >&2; exit 64; }
signature="$5/_CodeSignature/signed-entitlements.plist"
[ -f "$signature" ] || { echo "$5: code object is not signed at all" >&2; exit 1; }
cat "$signature"
EOF
cat > "$work/bin/security" <<'EOF'
#!/usr/bin/env bash
set -eu
[ "$#" -eq 4 ] && [ "$1 $2 $3" = "cms -D -i" ] || { echo "security stand-in: unexpected $*" >&2; exit 64; }
[ -f "$4" ] || { echo "security: failed to open $4" >&2; exit 1; }
cat "$4"
EOF
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH"

team=ABCDE12345
app_id=com.akrementsov.circuittimer
widgets_id=$app_id.widgets
watch_id=$app_id.watchkitapp
container=iCloud.$app_id
script="$root/scripts/verify-export-signing.py"

# edit_plist FILE KEY JSON: sets the top-level KEY to the JSON value; null removes it.
edit_plist() {
	python3 -I -c 'import json, plistlib, sys
path, key, value = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
with open(path, "rb") as file:
    data = plistlib.load(file)
if value is None:
    data.pop(key, None)
else:
    data[key] = value
with open(path, "wb") as file:
    plistlib.dump(data, file)' "$1" "$2" "$3"
}

# archive_fixture: an archive that passes, as `make archive` signs it ad hoc with Configs/CircuitTimer.entitlements.
archive_fixture() {
	archive="$work/archive/CircuitTimer.xcarchive"
	rm -rf "$work/archive"
	app="$archive/Products/Applications/CircuitTimer.app"
	write_plist "$app/Info.plist" "{\"CFBundleIdentifier\": \"$app_id\", \"NSSupportsLiveActivities\": true,
		\"CFBundleShortVersionString\": \"1.2.3\", \"CFBundleVersion\": \"261031.120000\",
		\"UIBackgroundModes\": [\"remote-notification\", \"workout-processing\"],
		\"CTCloudKitContainerIdentifier\": \"$container\",
		\"NSHealthShareUsageDescription\": \"Reads nothing.\", \"NSHealthUpdateUsageDescription\": \"Runs a workout.\"}"
	write_plist "$app/ru.lproj/InfoPlist.strings" '{"NSHealthShareUsageDescription": "Ничего не читает.",
		"NSHealthUpdateUsageDescription": "Ведёт тренировку."}'
	write_plist "$app/_CodeSignature/signed-entitlements.plist" "{\"aps-environment\": \"development\",
		\"com.apple.developer.icloud-container-identifiers\": [\"$container\"],
		\"com.apple.developer.icloud-services\": [\"CloudKit\"], \"com.apple.developer.healthkit\": true}"
	write_plist "$app/PlugIns/CircuitTimerWidgets.appex/Info.plist" \
		'{"NSExtension": {"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"}}'
	write_plist "$app/Watch/CircuitTimerWatch.app/Info.plist" "{\"CFBundleIdentifier\": \"$watch_id\",
		\"WKApplication\": true, \"WKCompanionAppBundleIdentifier\": \"$app_id\",
		\"CFBundleShortVersionString\": \"1.2.3\", \"CFBundleVersion\": \"261031.120000\"}"
	info="$app/Info.plist"
	watch_info="$app/Watch/CircuitTimerWatch.app/Info.plist"
	russian="$app/ru.lproj/InfoPlist.strings"
	signature="$app/_CodeSignature/signed-entitlements.plist"
}

# ipa_fixture: the payload of an export that passes; `zip_ipa` packs it. The widget and the watch app have no iCloud
# or HealthKit entitlement.
ipa_fixture() {
	rm -rf "$work/export"
	app="$work/export/Payload/CircuitTimer.app"
	widget="$app/PlugIns/CircuitTimerWidgets.appex"
	watch="$app/Watch/CircuitTimerWatch.app"
	signature="$app/_CodeSignature/signed-entitlements.plist"
	profile="$app/embedded.mobileprovision"
	write_plist "$signature" "{\"application-identifier\": \"$team.$app_id\",
		\"com.apple.developer.team-identifier\": \"$team\", \"get-task-allow\": false,
		\"com.apple.developer.icloud-container-identifiers\": [\"$container\"],
		\"com.apple.developer.icloud-services\": [\"CloudKit\"],
		\"com.apple.developer.icloud-container-environment\": \"Production\", \"aps-environment\": \"production\",
		\"com.apple.developer.healthkit\": true}"
	write_plist "$profile" "{\"Name\": \"App Store app\", \"TeamIdentifier\": [\"$team\"],
		\"Entitlements\": {\"com.apple.developer.icloud-container-identifiers\": [\"$container\"],
		\"com.apple.developer.healthkit\": true}}"
	write_plist "$widget/_CodeSignature/signed-entitlements.plist" "{\"application-identifier\": \"$team.$widgets_id\",
		\"com.apple.developer.team-identifier\": \"$team\", \"get-task-allow\": false}"
	write_plist "$widget/embedded.mobileprovision" "{\"Name\": \"App Store widgets\", \"TeamIdentifier\": [\"$team\"]}"
	write_plist "$watch/_CodeSignature/signed-entitlements.plist" "{\"application-identifier\": \"$team.$watch_id\",
		\"com.apple.developer.team-identifier\": \"$team\", \"get-task-allow\": false}"
	write_plist "$watch/embedded.mobileprovision" "{\"Name\": \"App Store watch\", \"TeamIdentifier\": [\"$team\"]}"
}

zip_ipa() {
	ipa="$work/CircuitTimer.ipa"
	rm -f "$ipa"
	(cd "$work/export" && python3 -I -m zipfile -c "$ipa" Payload)
}

check_archive() {
	run python3 -I "$script" archive "$archive" < /dev/null
}

check_ipa() {
	run python3 -I "$script" ipa "$ipa" "$team" "$app_id" "$widgets_id" "$watch_id" "$container" < /dev/null
}

describe "archive: the app with its background modes, Health texts and container in Info.plist and HealthKit signed"
archive_fixture
check_archive
expect_status 0
expect_in "$work/out" "CircuitTimer.app declares Live Activities, workout processing and $container, carries its entitlements and embeds CircuitTimerWidgets.appex and CircuitTimerWatch.app"
expect_not_in "$work/out" "::error::"

# Each row changes one key of the passing archive: Info.plist (info), its Russian strings (russian), the ad hoc
# signature (signature) or the watch app's Info.plist (watch); null removes the key.
while IFS='|' read -r description file key value message; do
	describe "archive: $description"
	archive_fixture
	case "$file" in
		info) edit_plist "$info" "$key" "$value" ;;
		russian) edit_plist "$russian" "$key" "$value" ;;
		signature) edit_plist "$signature" "$key" "$value" ;;
		watch) edit_plist "$watch_info" "$key" "$value" ;;
	esac
	check_archive
	expect_status 1
	expect_in "$work/out" "::error::$message"
	expect_not_in "$work/out" "carries its entitlements"
done <<EOF
no remote-notification background mode|info|UIBackgroundModes|["audio"]|CircuitTimer.app: UIBackgroundModes ['audio'] lack remote-notification
no background modes|info|UIBackgroundModes|null|CircuitTimer.app: UIBackgroundModes None lack remote-notification
no workout-processing background mode|info|UIBackgroundModes|["remote-notification"]|CircuitTimer.app: UIBackgroundModes ['remote-notification'] lack workout-processing
a blank Health share text|info|NSHealthShareUsageDescription|" "|CircuitTimer.app: NSHealthShareUsageDescription is ' ', not a text
no Health update text|info|NSHealthUpdateUsageDescription|null|CircuitTimer.app: NSHealthUpdateUsageDescription is None, not a text
no Russian Health share text|russian|NSHealthShareUsageDescription|null|CircuitTimer.app/ru.lproj/InfoPlist.strings: NSHealthShareUsageDescription is None, not a text
an empty Russian Health update text|russian|NSHealthUpdateUsageDescription|""|CircuitTimer.app/ru.lproj/InfoPlist.strings: NSHealthUpdateUsageDescription is '', not a text
a container other than iCloud.<bundle id>|info|CTCloudKitContainerIdentifier|"iCloud.com.example.other"|CircuitTimer.app: the CloudKit container is 'iCloud.com.example.other', not $container
the empty container of an unsigned build|info|CTCloudKitContainerIdentifier|""|CircuitTimer.app: the CloudKit container is '', not $container
no container in Info.plist|info|CTCloudKitContainerIdentifier|null|CircuitTimer.app: the CloudKit container is None, not $container
no container in the signature|signature|com.apple.developer.icloud-container-identifiers|null|CircuitTimer.app: iCloud containers are None, not ['$container']
another container in the signature|signature|com.apple.developer.icloud-container-identifiers|["iCloud.com.example.other"]|CircuitTimer.app: iCloud containers are ['iCloud.com.example.other'], not ['$container']
no CloudKit in the signature|signature|com.apple.developer.icloud-services|["CloudDocuments"]|CircuitTimer.app: iCloud services ['CloudDocuments'] lack CloudKit
no aps-environment in the signature|signature|aps-environment|null|CircuitTimer.app: the archived signature has no aps-environment
no HealthKit in the signature|signature|com.apple.developer.healthkit|null|CircuitTimer.app: the archived signature has com.apple.developer.healthkit None, not True
HealthKit off in the signature|signature|com.apple.developer.healthkit|false|CircuitTimer.app: the archived signature has com.apple.developer.healthkit False, not True
a watch app that is not WatchKit's|watch|WKApplication|null|CircuitTimerWatch.app: WKApplication is None, not True
a watch app with another companion|watch|WKCompanionAppBundleIdentifier|"com.example.other"|CircuitTimerWatch.app: the companion is 'com.example.other', not '$app_id'
a watch app without a companion|watch|WKCompanionAppBundleIdentifier|null|CircuitTimerWatch.app: the companion is None, not '$app_id'
a watch app of another version|watch|CFBundleShortVersionString|"1.2.4"|CircuitTimerWatch.app: CFBundleShortVersionString is '1.2.4', not the app's '1.2.3'
a watch app of another build|watch|CFBundleVersion|"1"|CircuitTimerWatch.app: CFBundleVersion is '1', not the app's '261031.120000'
EOF

describe "archive: no Russian strings"
archive_fixture
rm "$russian"
check_archive
expect_status 1
expect_in "$work/out" "::error::"
expect_in "$work/out" "ru.lproj/InfoPlist.strings"
expect_not_in "$work/out" "carries its entitlements"

describe "archive: no watch app"
archive_fixture
rm -r "$app/Watch"
check_archive
expect_status 1
expect_in "$work/out" "::error::"
expect_in "$work/out" "Watch/CircuitTimerWatch.app/Info.plist"
expect_not_in "$work/out" "carries its entitlements"

describe "archive: an unsigned app"
archive_fixture
rm "$signature"
check_archive
expect_status 1
expect_in "$work/out" "::error::CircuitTimer.app: codesign failed: "
expect_in "$work/out" "CircuitTimer.app: code object is not signed at all"

describe "ipa: every bundle signed for the App Store, the widget and the watch app without iCloud and HealthKit"
ipa_fixture
zip_ipa
check_ipa
expect_status 0
expect_in "$work/out" "CircuitTimer.app: signed for $team.$app_id with profile 'App Store app'"
expect_in "$work/out" "CircuitTimerWidgets.appex: signed for $team.$widgets_id with profile 'App Store widgets'"
expect_in "$work/out" "CircuitTimerWatch.app: signed for $team.$watch_id with profile 'App Store watch'"
expect_not_in "$work/out" "::error::"

# Each row changes one key of the passing app's signature (signature) or profile (profile).
while IFS='|' read -r description file key value message; do
	describe "ipa: $description"
	ipa_fixture
	case "$file" in signature) edit_plist "$signature" "$key" "$value" ;; profile) edit_plist "$profile" "$key" "$value" ;; esac
	zip_ipa
	check_ipa
	expect_status 1
	expect_in "$work/out" "::error::$message"
	expect_not_in "$work/out" "CircuitTimer.app: signed for"
done <<EOF
another container|signature|com.apple.developer.icloud-container-identifiers|["iCloud.com.example.other"]|CircuitTimer.app: iCloud containers are ['iCloud.com.example.other'], not ['$container']
no container|signature|com.apple.developer.icloud-container-identifiers|null|CircuitTimer.app: iCloud containers are None, not ['$container']
no CloudKit|signature|com.apple.developer.icloud-services|null|CircuitTimer.app: iCloud services None lack CloudKit
the Development CloudKit environment|signature|com.apple.developer.icloud-container-environment|"Development"|CircuitTimer.app: the CloudKit environment is 'Development', not 'Production'
no CloudKit environment|signature|com.apple.developer.icloud-container-environment|null|CircuitTimer.app: the CloudKit environment is None, not 'Production'
development push|signature|aps-environment|"development"|CircuitTimer.app: the push environment is 'development', not 'production'
no push|signature|aps-environment|null|CircuitTimer.app: the push environment is None, not 'production'
a profile without the container|profile|Entitlements|{}|CircuitTimer.app: the profile allows the iCloud containers [], not '$container'
a profile with another container|profile|Entitlements|{"com.apple.developer.icloud-container-identifiers": ["iCloud.com.example.other"]}|CircuitTimer.app: the profile allows the iCloud containers ['iCloud.com.example.other'], not '$container'
no HealthKit|signature|com.apple.developer.healthkit|null|CircuitTimer.app: the signature has com.apple.developer.healthkit None, not True
HealthKit off|signature|com.apple.developer.healthkit|false|CircuitTimer.app: the signature has com.apple.developer.healthkit False, not True
a profile without HealthKit|profile|Entitlements|{"com.apple.developer.icloud-container-identifiers": ["$container"]}|CircuitTimer.app: the profile does not allow HealthKit
a profile with HealthKit off|profile|Entitlements|{"com.apple.developer.icloud-container-identifiers": ["$container"], "com.apple.developer.healthkit": false}|CircuitTimer.app: the profile does not allow HealthKit
EOF

describe "ipa: a widget signed with HealthKit"
ipa_fixture
edit_plist "$widget/_CodeSignature/signed-entitlements.plist" com.apple.developer.healthkit true
zip_ipa
check_ipa
expect_status 1
expect_in "$work/out" "::error::CircuitTimerWidgets.appex: the signature has HealthKit, which only the app needs"
expect_not_in "$work/out" "CircuitTimerWidgets.appex: signed for"

# watch_ipa KEY JSON: the passing IPA with KEY of the watch app's signature set to JSON.
watch_ipa() {
	ipa_fixture
	edit_plist "$watch/_CodeSignature/signed-entitlements.plist" "$1" "$2"
	zip_ipa
	check_ipa
	expect_status 1
	expect_not_in "$work/out" "CircuitTimerWatch.app: signed for"
}

describe "ipa: a watch app signed with HealthKit"
watch_ipa com.apple.developer.healthkit true
expect_in "$work/out" "::error::CircuitTimerWatch.app: the signature has HealthKit, which only the app needs"

describe "ipa: a watch app signed with iCloud"
watch_ipa com.apple.developer.icloud-container-identifiers "[\"$container\"]"
expect_in "$work/out" "::error::CircuitTimerWatch.app: the signature has iCloud, which only the app needs"

describe "ipa: a watch app signed for another bundle"
watch_ipa application-identifier "\"$team.$app_id.other\""
expect_in "$work/out" "::error::CircuitTimerWatch.app: application-identifier is '$team.$app_id.other', not '$team.$watch_id'"

describe "ipa: a watch app with a development signature"
watch_ipa get-task-allow true
expect_in "$work/out" "::error::CircuitTimerWatch.app: get-task-allow is set, so this is a development signature"

describe "ipa: an unsigned watch app"
ipa_fixture
rm "$watch/_CodeSignature/signed-entitlements.plist"
zip_ipa
check_ipa
expect_status 1
expect_in "$work/out" "::error::CircuitTimerWatch.app: codesign failed: "

describe "ipa: six arguments, without the container, print the usage"
ipa_fixture
zip_ipa
run python3 -I "$script" ipa "$ipa" "$team" "$app_id" "$widgets_id" "$watch_id" < /dev/null
expect_status 1
expect_in "$work/out" "verify-export-signing.py ipa <CircuitTimer.ipa> <team> <app id> <widgets id> <watch id> <icloud container>"
expect_not_in "$work/out" "CircuitTimer.app: signed for"

finish
