SWIFTLINT ?= swiftlint
DESTINATION ?= platform=iOS Simulator,name=iPhone 17,OS=26.5
BUILD_DESTINATION := generic/platform=iOS Simulator
HOST_ARCH := $(shell uname -m)
SOURCE_PACKAGES ?= $(CURDIR)/.build/SourcePackages
DERIVED_DATA ?= $(CURDIR)/.build/DerivedData

XCODEBUILD_FLAGS = -quiet \
	-clonedSourcePackagesDirPath "$(SOURCE_PACKAGES)" \
	-skipMacroValidation \
	-skipPackagePluginValidation \
	-disableAutomaticPackageResolution

# Package builds are strict; the app build is not, because Xcode builds the package as a
# dependency there with suppressed warnings (see CircuitTimerKit/Package.swift).
STRICT := CIRCUITTIMER_STRICT_WARNINGS=1

PACKAGE_RESOLVED := CircuitTimerKit/Package.resolved
PROJECT_RESOLVED := CircuitTimer.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
PINS := [.pins[] | {identity, version: .state.version, revision: .state.revision}] | sort_by(.identity)

.PHONY: lint check-resolved resolve build-package test build-app ci verify-clean

lint:
	$(SWIFTLINT) lint --strict --quiet

# The local package inside the app project keeps its own lockfile, so both must pin the same versions.
check-resolved:
	@set -eu; \
	command -v jq >/dev/null || { echo "check-resolved: jq is required" >&2; exit 1; }; \
	package=$$(jq -cS '$(PINS)' $(PACKAGE_RESOLVED)); \
	project=$$(jq -cS '$(PINS)' $(PROJECT_RESOLVED)); \
	if [ "$$package" != "$$project" ]; then \
		echo "check-resolved: the two Package.resolved files differ; run 'make resolve' and commit both" >&2; exit 1; \
	fi

resolve:
	cd CircuitTimerKit && xcodebuild -resolvePackageDependencies -clonedSourcePackagesDirPath "$(SOURCE_PACKAGES)"
	xcodebuild -resolvePackageDependencies -project CircuitTimer.xcodeproj -scheme CircuitTimer \
		-clonedSourcePackagesDirPath "$(SOURCE_PACKAGES)"

build-package:
	cd CircuitTimerKit && $(STRICT) xcodebuild build -scheme CircuitTimerKit-Package \
		-destination '$(BUILD_DESTINATION)' ARCHS=$(HOST_ARCH) \
		-derivedDataPath "$(DERIVED_DATA)/Package" $(XCODEBUILD_FLAGS)

# Tests run in English so assertions on localized text do not depend on the machine's language.
test:
	cd CircuitTimerKit && $(STRICT) xcodebuild test -scheme CircuitTimerKit-Package \
		-destination '$(DESTINATION)' -testLanguage en -testRegion US \
		-derivedDataPath "$(DERIVED_DATA)/Package" $(XCODEBUILD_FLAGS)

build-app:
	xcodebuild build -project CircuitTimer.xcodeproj -scheme CircuitTimer \
		-destination '$(BUILD_DESTINATION)' ARCHS=$(HOST_ARCH) CODE_SIGNING_ALLOWED=NO \
		-derivedDataPath "$(DERIVED_DATA)/App" $(XCODEBUILD_FLAGS)

ci: lint check-resolved test build-app

# Runs `make ci` on a fresh clone of exactly HEAD, so uncommitted files cannot make it pass.
verify-clean:
	@set -eu; \
	if [ -n "$$(git status --porcelain)" ]; then \
		echo "verify-clean: commit or stash changes first" >&2; exit 1; \
	fi; \
	root=$$(git rev-parse --show-toplevel); \
	sha=$$(git rev-parse HEAD); \
	tmp=$$(mktemp -d "$${TMPDIR:-/tmp}/circuittimer-verify.XXXXXX"); \
	if git clone -q --no-checkout "$$root" "$$tmp/repo" \
		&& git -C "$$tmp/repo" fetch -q "$$root" HEAD \
		&& [ "$$(git -C "$$tmp/repo" rev-parse FETCH_HEAD)" = "$$sha" ] \
		&& git -C "$$tmp/repo" checkout -q --detach "$$sha" \
		&& $(MAKE) -C "$$tmp/repo" ci SWIFTLINT="$(SWIFTLINT)" SOURCE_PACKAGES="$(SOURCE_PACKAGES)"; then \
		rm -rf "$$tmp"; echo "verify-clean: OK ($$sha)"; \
	else \
		echo "verify-clean: FAILED ($$sha), clone kept at $$tmp" >&2; exit 1; \
	fi
