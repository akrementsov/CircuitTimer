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
		\"UIBackgroundModes\": [\"remote-notification\"], \"CTCloudKitContainerIdentifier\": \"$container\"}"
	write_plist "$app/_CodeSignature/signed-entitlements.plist" "{\"aps-environment\": \"development\",
		\"com.apple.developer.icloud-container-identifiers\": [\"$container\"],
		\"com.apple.developer.icloud-services\": [\"CloudKit\"]}"
	write_plist "$app/PlugIns/CircuitTimerWidgets.appex/Info.plist" \
		'{"NSExtension": {"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"}}'
	info="$app/Info.plist"
	signature="$app/_CodeSignature/signed-entitlements.plist"
}

# ipa_fixture: the payload of an export that passes; `zip_ipa` packs it. The widget has no iCloud entitlement.
ipa_fixture() {
	rm -rf "$work/export"
	app="$work/export/Payload/CircuitTimer.app"
	widget="$app/PlugIns/CircuitTimerWidgets.appex"
	signature="$app/_CodeSignature/signed-entitlements.plist"
	profile="$app/embedded.mobileprovision"
	write_plist "$signature" "{\"application-identifier\": \"$team.$app_id\",
		\"com.apple.developer.team-identifier\": \"$team\", \"get-task-allow\": false,
		\"com.apple.developer.icloud-container-identifiers\": [\"$container\"],
		\"com.apple.developer.icloud-services\": [\"CloudKit\"],
		\"com.apple.developer.icloud-container-environment\": \"Production\", \"aps-environment\": \"production\"}"
	write_plist "$profile" "{\"Name\": \"App Store app\", \"TeamIdentifier\": [\"$team\"],
		\"Entitlements\": {\"com.apple.developer.icloud-container-identifiers\": [\"$container\"]}}"
	write_plist "$widget/_CodeSignature/signed-entitlements.plist" "{\"application-identifier\": \"$team.$widgets_id\",
		\"com.apple.developer.team-identifier\": \"$team\", \"get-task-allow\": false}"
	write_plist "$widget/embedded.mobileprovision" "{\"Name\": \"App Store widgets\", \"TeamIdentifier\": [\"$team\"]}"
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
	run python3 -I "$script" ipa "$ipa" "$team" "$app_id" "$widgets_id" "$container" < /dev/null
}

describe "archive: the app with remote notifications and its container in Info.plist and in the signature"
archive_fixture
check_archive
expect_status 0
expect_in "$work/out" "CircuitTimer.app declares Live Activities and $container, carries its entitlements and embeds CircuitTimerWidgets.appex"
expect_not_in "$work/out" "::error::"

# Each row changes one key of the passing archive: Info.plist (info) or the ad hoc signature (signature); null
# removes the key.
while IFS='|' read -r description file key value message; do
	describe "archive: $description"
	archive_fixture
	case "$file" in info) edit_plist "$info" "$key" "$value" ;; signature) edit_plist "$signature" "$key" "$value" ;; esac
	check_archive
	expect_status 1
	expect_in "$work/out" "::error::$message"
	expect_not_in "$work/out" "carries its entitlements"
done <<EOF
no remote-notification background mode|info|UIBackgroundModes|["audio"]|CircuitTimer.app: UIBackgroundModes ['audio'] lack remote-notification
no background modes|info|UIBackgroundModes|null|CircuitTimer.app: UIBackgroundModes None lack remote-notification
a container other than iCloud.<bundle id>|info|CTCloudKitContainerIdentifier|"iCloud.com.example.other"|CircuitTimer.app: the CloudKit container is 'iCloud.com.example.other', not $container
the empty container of an unsigned build|info|CTCloudKitContainerIdentifier|""|CircuitTimer.app: the CloudKit container is '', not $container
no container in Info.plist|info|CTCloudKitContainerIdentifier|null|CircuitTimer.app: the CloudKit container is None, not $container
no container in the signature|signature|com.apple.developer.icloud-container-identifiers|null|CircuitTimer.app: iCloud containers are None, not ['$container']
another container in the signature|signature|com.apple.developer.icloud-container-identifiers|["iCloud.com.example.other"]|CircuitTimer.app: iCloud containers are ['iCloud.com.example.other'], not ['$container']
no CloudKit in the signature|signature|com.apple.developer.icloud-services|["CloudDocuments"]|CircuitTimer.app: iCloud services ['CloudDocuments'] lack CloudKit
no aps-environment in the signature|signature|aps-environment|null|CircuitTimer.app: the archived signature has no aps-environment
EOF

describe "archive: an unsigned app"
archive_fixture
rm "$signature"
check_archive
expect_status 1
expect_in "$work/out" "::error::CircuitTimer.app: codesign failed: "
expect_in "$work/out" "CircuitTimer.app: code object is not signed at all"

describe "ipa: both bundles signed for the App Store, the widget without iCloud"
ipa_fixture
zip_ipa
check_ipa
expect_status 0
expect_in "$work/out" "CircuitTimer.app: signed for $team.$app_id with profile 'App Store app'"
expect_in "$work/out" "CircuitTimerWidgets.appex: signed for $team.$widgets_id with profile 'App Store widgets'"
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
EOF

describe "ipa: five arguments, without the container, print the usage"
ipa_fixture
zip_ipa
run python3 -I "$script" ipa "$ipa" "$team" "$app_id" "$widgets_id" < /dev/null
expect_status 1
expect_in "$work/out" "verify-export-signing.py ipa <CircuitTimer.ipa> <team> <app id> <widgets id> <icloud container>"
expect_not_in "$work/out" "CircuitTimer.app: signed for"

finish
