#!/usr/bin/env bash
# Tests scripts/check-brand-colors.py on a tree of the three colour sets and the two logos that passes, each case
# changing one of them.
# The script finds the repository by its own place, so the tree gets a copy of it.
. "$(dirname "$0")/lib.sh"

brand=CircuitTimerKit/Sources/DesignSystem/Resources/Colors.xcassets/Brand.colorset/Contents.json
app_accent=CircuitTimer/Assets.xcassets/AccentColor.colorset/Contents.json
watch_accent=CircuitTimerWatch/Assets.xcassets/AccentColor.colorset/Contents.json
launch_logo=CircuitTimer/Assets.xcassets/LaunchLogo.imageset/LaunchLogo.svg
app_logo=CircuitTimerKit/Sources/DesignSystem/Resources/Images.xcassets/AppLogo.imageset/AppLogo.svg

# logo FILE [FILL]: writes a one-path SVG, by default in Brand's colour.
logo() {
	mkdir -p "$(dirname "$work/tree/$1")"
	printf '<svg viewBox="0 0 2 2" xmlns="http://www.w3.org/2000/svg"><path d="M0 0H2V2Z" fill="%s"/></svg>\n' "${2:-#E7FE54}" > "$work/tree/$1"
}

# colour_set FILE [RED [COLOUR_SPACE]]: writes a colour set of one universal sRGB colour, by default Brand's.
colour_set() {
	mkdir -p "$(dirname "$work/tree/$1")"
	cat > "$work/tree/$1" <<EOF
{
  "colors" : [
    {
      "color" : {
        "color-space" : "${3:-srgb}",
        "components" : { "alpha" : "1.000", "blue" : "0.329", "green" : "0.996", "red" : "${2:-0.906}" }
      },
      "idiom" : "universal"
    }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
EOF
}

tree() {
	rm -rf "$work/tree"
	mkdir -p "$work/tree/scripts"
	cp "$root/scripts/check-brand-colors.py" "$work/tree/scripts/"
	colour_set "$brand"
	colour_set "$app_accent"
	colour_set "$watch_accent"
	logo "$launch_logo"
	logo "$app_logo"
}

check() {
	run python3 -I "$work/tree/scripts/check-brand-colors.py"
}

describe "the repository's colour sets"
run python3 -I "$root/scripts/check-brand-colors.py"
expect_status 0

describe "Brand and both accent colours equal"
tree
check
expect_status 0
expect_equal "$(cat "$work/out")" ""

describe "the same colour written as hex and as integers"
tree
colour_set "$app_accent" 0xE7
colour_set "$watch_accent" 231
check
expect_status 0

# Each row changes the watch's or the app's accent colour: FILE|RED|COLOUR_SPACE.
while IFS='|' read -r name file red space; do
	describe "$name"
	tree
	colour_set "$file" "$red" "$space"
	check
	expect_status 1
	expect_in "$work/out" "check-brand-colors: $file: "
	expect_in "$work/out" "change them together"
done <<EOF
another red in the watch's accent colour|$watch_accent|0.800|srgb
another red in the app's accent colour|$app_accent|0.800|srgb
another colour space in the watch's accent colour|$watch_accent|0.906|display-p3
EOF

describe "another alpha in the watch's accent colour"
tree
sed 's/"alpha" : "1.000"/"alpha" : "0.500"/' "$work/tree/$watch_accent" > "$work/edited"
mv "$work/edited" "$work/tree/$watch_accent"
check
expect_status 1
expect_in "$work/out" "check-brand-colors: $watch_accent: "

describe "a dark appearance added to the watch's accent colour"
tree
python3 -I -c 'import json, sys
path = sys.argv[1]
data = json.load(open(path))
dark = dict(data["colors"][0], appearances=[{"appearance": "luminosity", "value": "dark"}])
data["colors"].append(dark)
json.dump(data, open(path, "w"))' "$work/tree/$watch_accent"
check
expect_status 1
expect_in "$work/out" "check-brand-colors: $watch_accent: holds 2 colours, not one"

describe "a component that is not a number"
tree
colour_set "$watch_accent" pink
check
expect_status 1
expect_in "$work/out" "check-brand-colors: $watch_accent: red is 'pink', not a colour component"

describe "the watch's accent colour missing"
tree
rm "$work/tree/$watch_accent"
check
expect_status 1
expect_in "$work/out" "check-brand-colors: $watch_accent: "
expect_not_in "$work/out" "Traceback"

describe "Brand missing"
tree
rm "$work/tree/$brand"
check
expect_status 1
expect_in "$work/out" "check-brand-colors: $brand: "
expect_not_in "$work/out" "Traceback"

finish

describe "a logo copy that differs from the launch logo"
tree
logo "$app_logo" "#FFFFFF"
check
expect_status 1
expect_in "$work/out" "check-brand-colors: $app_logo: not an exact copy of $launch_logo"

describe "a missing logo copy"
tree
rm "$work/tree/$app_logo"
check
expect_status 1
expect_in "$work/out" "check-brand-colors: $app_logo: "
