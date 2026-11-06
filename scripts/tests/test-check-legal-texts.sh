#!/usr/bin/env bash
# Tests scripts/check-legal-texts.py on a tree of the four legal texts and their bundled copies that passes, each case
# changing one of them.
# The script finds the repository by its own place, so the tree gets a copy of it.
. "$(dirname "$0")/lib.sh"

resources=CircuitTimerKit/Sources/SettingsFeature/Resources
policy=docs/legal/privacy-policy.md
policy_copy=$resources/en.lproj/PrivacyPolicy.md
terms_ru=docs/legal/ru/terms-of-use.md
terms_ru_copy=$resources/ru.lproj/TermsOfUse.md

# text FILE [LINE]: writes a document of every block the app draws, then LINE if given.
text() {
	mkdir -p "$(dirname "$work/tree/$1")"
	cat > "$work/tree/$1" <<TEXT
---
title: Title
lang: en
---

# Title

Last updated: today, with a [link](https://example.com) and **bold**.

## Section

- a bullet;
- another one.
TEXT
	if [ -n "${2:-}" ]; then
		printf '%s\n' "$2" >> "$work/tree/$1"
	fi
}

tree() {
	rm -rf "$work/tree"
	mkdir -p "$work/tree/scripts"
	cp "$root/scripts/check-legal-texts.py" "$work/tree/scripts/"
	for name in privacy-policy terms-of-use; do
		text "docs/legal/$name.md"
		text "docs/legal/ru/$name.md"
	done
	for language in en ru; do
		text "$resources/$language.lproj/PrivacyPolicy.md"
		text "$resources/$language.lproj/TermsOfUse.md"
	done
}

check() {
	run python3 -I "$work/tree/scripts/check-legal-texts.py"
}

describe "the repository's legal texts"
run python3 -I "$root/scripts/check-legal-texts.py"
expect_status 0

describe "every original with an exact copy"
tree
check
expect_status 0
expect_equal "$(cat "$work/out")" ""

describe "a copy that differs from its original"
tree
text "$terms_ru_copy" "One more paragraph."
check
expect_status 1
expect_in "$work/out" "check-legal-texts: $terms_ru_copy: not an exact copy of $terms_ru"

describe "a copy missing"
tree
rm "$work/tree/$policy_copy"
check
expect_status 1
expect_in "$work/out" "check-legal-texts: $policy_copy: "
expect_not_in "$work/out" "Traceback"

describe "an original missing"
tree
rm "$work/tree/$policy"
check
expect_status 1
expect_in "$work/out" "check-legal-texts: $policy: "
expect_not_in "$work/out" "not an exact copy"
expect_not_in "$work/out" "Traceback"

# Each row appends one line the app would show with its marks to an original and its copy: NAME|LINE.
while IFS='|' read -r name line; do
	describe "$name"
	tree
	text "$policy" "$line"
	text "$policy_copy" "$line"
	check
	expect_status 1
	expect_in "$work/out" "check-legal-texts: $policy:14: "
	expect_not_in "$work/out" "not an exact copy"
done <<EOF
a third-level heading|### Details
a heading without a space|##Details
a numbered list|1. First
an asterisk bullet|* item
a dash without a space|-item
a quote|> quoted
a table|| a | b |
a code fence|\`\`\`
an HTML tag|<br>
EOF

describe "front matter without its closing line"
tree
printf -- '---\ntitle: Title\n\n# Title\n' > "$work/tree/$policy"
cp "$work/tree/$policy" "$work/tree/$policy_copy"
check
expect_status 1
expect_in "$work/out" "check-legal-texts: $policy:1: front matter without its closing ---"

finish
