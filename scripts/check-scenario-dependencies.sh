#!/usr/bin/env bash
# Fails when a UI test scenario could reach the outside world: a client whose preview value is its live one, a
# client or key that `AppScenario.prepare` does not set, a dependency looked up by type, or a storage strategy whose
# default store `prepare` does not replace. It reads the code with comments removed, but not string literals, and
# knows nothing about our own `SharedKey`s or keys only a library reads.
# Runs with bash 3.2 and with BSD, GNU or mawk awk, so on a Mac and on CI's Linux lint job alike.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
# Keys the library answers by itself in every context, without reaching the outside world.
LIBRARY_DEFAULTS="context dismiss preferredLocales"
PREPARE="CircuitTimerKit/Sources/AppScenarios"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/check-scenario-dependencies.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

failures=0
fail() {
	echo "check-scenario-dependencies: $*" >&2
	failures=$((failures + 1))
}

# Copies the Swift files under $1 to $2 without `//` and `/* */` comments, keeping their paths and line numbers.
strip_comments() {
	find "$1" -name '*.swift' | while IFS= read -r file; do
		copy="$2/${file#"$1"/}"
		mkdir -p "$(dirname "$copy")"
		awk '
			{
				line = $0
				out = ""
				while (line != "") {
					if (inblock) {
						i = index(line, "*/")
						if (i == 0) {
							line = ""
						} else {
							line = substr(line, i + 2)
							inblock = 0
						}
					} else {
						b = index(line, "/*")
						c = index(line, "//")
						if (c > 0 && (b == 0 || c < b)) {
							out = out substr(line, 1, c - 1)
							line = ""
						} else if (b > 0) {
							out = out substr(line, 1, b - 1)
							line = substr(line, b + 2)
							inblock = 1
						} else {
							out = out line
							line = ""
						}
					}
				}
				print out
			}
		' "$file" > "$copy"
	done
}

kit="$tmp/CircuitTimerKit/Sources"
app="$tmp/CircuitTimer"
strip_comments "$root/CircuitTimerKit/Sources" "$kit"
strip_comments "$root/CircuitTimer" "$app"
scenarios="$kit/AppScenarios"
mv "$scenarios" "$tmp/AppScenarios"
scenarios="$tmp/AppScenarios"

is_set_in_prepare() {
	grep -rqE "\\.$1[[:space:]]*=[^=]" "$scenarios"
}

# (a) A key's preview value must exist and must not be its live value: swift-dependencies falls back to the live
# value when a key declares no preview value.
keys=$(cd "$tmp" && find CircuitTimerKit/Sources -name '*.swift' -exec awk '
	function braces(s, ch,   t) {
		t = s
		return gsub(ch, "", t)
	}
	FNR == 1 {
		inkey = 0
	}
	!inkey && /:[[:space:]]*(Test)?DependencyKey([[:space:]]|[{,]|$)/ {
		inkey = 1
		depth = 0
		opened = 0
		haspreview = 0
		inpreview = 0
		start = FNR
	}
	inkey {
		if (inpreview && /static[[:space:]]/ && !/previewValue/) {
			inpreview = 0
		}
		if (/static[[:space:]]+(let|var)[[:space:]]+previewValue/) {
			haspreview = 1
			inpreview = 1
		}
		if (inpreview && /liveValue/) {
			print FILENAME ":" FNR ": previewValue reads liveValue"
		}
		depth += braces($0, "[{]") - braces($0, "[}]")
		if (depth > 0) {
			opened = 1
		}
		if (opened && depth <= 0) {
			if (!haspreview) {
				print FILENAME ":" start ": a DependencyKey without a previewValue is live in previews"
			}
			inkey = 0
		}
	}
' {} +)
if [ -n "$keys" ]; then
	while IFS= read -r problem; do
		fail "$problem; give it a preview value that is not live"
	done <<EOF
$keys
EOF
fi

# (b) Every client of our own must be set by `prepare`.
clients=$(cd "$tmp" && find CircuitTimerKit/Sources -name '*.swift' -exec awk '
	function braces(s, ch,   t) {
		t = s
		return gsub(ch, "", t)
	}
	!inext && /extension[[:space:]]+DependencyValues([[:space:]]|[{]|$)/ {
		inext = 1
		depth = 0
		opened = 0
	}
	inext {
		if (match($0, /public[[:space:]]+var[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*:/)) {
			name = substr($0, RSTART, RLENGTH)
			sub(/^public[[:space:]]+var[[:space:]]+/, "", name)
			sub(/[[:space:]]*:$/, "", name)
			print name
		}
		depth += braces($0, "[{]") - braces($0, "[}]")
		if (depth > 0) {
			opened = 1
		}
		if (opened && depth <= 0) {
			inext = 0
		}
	}
' {} + | sort -u)
for name in $clients; do
	if ! is_set_in_prepare "$name"; then
		fail "DependencyValues.$name is not set in $PREPARE; give scenarios a value that is not live"
	fi
done

# (c) Every key the app or the package reads must be set by `prepare` or be one the library answers by itself.
used=$(grep -rhoE '@Dependency\(\\\.[A-Za-z_][A-Za-z0-9_.]*\)' "$kit" "$app" \
	| sed -e 's/^@Dependency(\\\.//' -e 's/[.)].*$//' | sort -u || true)
for name in $used; do
	case " $LIBRARY_DEFAULTS " in
		*" $name "*) continue ;;
	esac
	if ! is_set_in_prepare "$name"; then
		fail "@Dependency(\\.$name) is read but not set in $PREPARE; set it there or, if the library answers it without the outside world, add it to LIBRARY_DEFAULTS"
	fi
done

# (d) A dependency looked up by type escapes the key path checks above.
bytype=$(cd "$tmp" && grep -rnE '@Dependency\([^\\]' CircuitTimerKit/Sources CircuitTimer || true)
if [ -n "$bytype" ]; then
	while IFS= read -r line; do
		fail "$line: read dependencies by key path, @Dependency(\\.name), so this check sees them"
	done <<EOF
$bytype
EOF
fi

# (e) A storage strategy in use needs its default store replaced, or scenarios share the device's.
check_strategy() {
	if grep -rqE "\\.$1\\(" "$kit" "$app" && ! is_set_in_prepare "$2"; then
		fail ".$1 storage is used but $2 is not set in $PREPARE"
	fi
}
check_strategy appStorage defaultAppStorage
check_strategy fileStorage defaultFileStorage
check_strategy inMemory defaultInMemoryStorage

if [ "$failures" -gt 0 ]; then
	echo "check-scenario-dependencies: $failures problem(s); see the UI tests section of AGENTS.md" >&2
	exit 1
fi
