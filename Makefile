SWIFTLINT ?= swiftlint
DESTINATION ?= platform=iOS Simulator,name=iPhone 17,OS=27.0
BUILD_DESTINATION := generic/platform=iOS Simulator
HOST_ARCH := $(shell uname -m)
SOURCE_PACKAGES ?= $(CURDIR)/.build/SourcePackages
DERIVED_DATA ?= $(CURDIR)/.build/DerivedData
ARCHIVE_PATH ?= $(CURDIR)/.build/CircuitTimer.xcarchive
EXPORT_PATH ?= $(CURDIR)/.build/Export
# One result bundle and log per test run; scripts/report-test-results.sh reads them all.
TEST_RESULTS ?= $(CURDIR)/.build/TestResults
TEST_FLAGS ?=
# UI test runs keep apart by destination: `iPhone 17 #2` on 27.0 runs as `iPhone-17-2-27.0`.
UI_RUN ?= $(shell printf '%s' '$(DESTINATION)' | sed -E 's/.*name=([^,]+).*OS=([0-9.]+).*/\1-\2/; s/[^A-Za-z0-9.]+/-/g')
# Parallel workers clone the simulator, so more than one is allowed only on CI.
UI_TEST_WORKERS ?= 1

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

.PHONY: lint check-resolved resolve build-package test build-app test-ui archive check-release-app upload ci verify-clean

lint:
	$(SWIFTLINT) lint --strict --quiet
	scripts/check-scenario-dependencies.sh

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
# The output is quiet, so failure messages live only in the result bundle, which run-tests.sh names.
test:
	cd CircuitTimerKit && $(STRICT) "$(CURDIR)/scripts/run-tests.sh" "$(TEST_RESULTS)/Package.xcresult" \
		xcodebuild test -scheme CircuitTimerKit-Package \
		-destination '$(DESTINATION)' -testLanguage en -testRegion US \
		-derivedDataPath "$(DERIVED_DATA)/Package" $(XCODEBUILD_FLAGS) $(TEST_FLAGS)

build-app:
	xcodebuild build -project CircuitTimer.xcodeproj -scheme CircuitTimer \
		-destination '$(BUILD_DESTINATION)' ARCHS=$(HOST_ARCH) CODE_SIGNING_ALLOWED=NO \
		-derivedDataPath "$(DERIVED_DATA)/App" $(XCODEBUILD_FLAGS)

# Each destination has its own result bundle, log and DerivedData, so runs on different simulators can overlap; the
# package checkouts are shared and only read. A failing test gets one more run, and one that passes only then is
# reported as flaky. Parallel workers stay off unless UI_TEST_WORKERS says otherwise, which xcodebuild needs to hear
# either way: its flag overrides the scheme. Diagnostics are never collected: the simulator can keep xcodebuild
# waiting ten minutes for them after the tests, and the result bundle keeps its screen recordings without them.
test-ui:
	@set -eu; \
	w='$(UI_TEST_WORKERS)'; \
	case "$$w" in [1-9]|[1-9][0-9]) ;; *) echo "test-ui: UI_TEST_WORKERS must be a number from 1 to 99, not '$$w'" >&2; exit 2 ;; esac; \
	if [ "$$w" -gt 1 ] && [ "$${CI:-}" != true ]; then \
		echo "test-ui: parallel workers clone simulators, which only CI may do (see AGENTS.md)" >&2; exit 2; \
	fi; \
	if [ "$$w" -eq 1 ]; then par="-parallel-testing-enabled NO"; \
	else par="-parallel-testing-enabled YES -parallel-testing-worker-count $$w"; fi; \
	scripts/run-tests.sh "$(TEST_RESULTS)/UITests-$(UI_RUN).xcresult" \
		xcodebuild test -project CircuitTimer.xcodeproj -scheme CircuitTimer -destination '$(DESTINATION)' \
		-derivedDataPath "$(DERIVED_DATA)/UITests-$(UI_RUN)" $$par \
		-retry-tests-on-failure -test-iterations 2 -test-timeouts-enabled YES -collect-test-diagnostics never \
		-default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 120 \
		CODE_SIGNING_ALLOWED=NO $(XCODEBUILD_FLAGS) $(TEST_FLAGS)

# Unsigned on purpose: an App Store Connect API key can sign only at export, so `upload` signs.
archive:
	@test -n "$(BUILD_NUMBER)" || { echo "archive: BUILD_NUMBER is required" >&2; exit 1; }
	xcodebuild archive -project CircuitTimer.xcodeproj -scheme CircuitTimer -configuration Release \
		-destination 'generic/platform=iOS' -archivePath "$(ARCHIVE_PATH)" \
		CODE_SIGNING_ALLOWED=NO CURRENT_PROJECT_VERSION=$(BUILD_NUMBER) \
		-derivedDataPath "$(DERIVED_DATA)/Archive" $(XCODEBUILD_FLAGS)

# UI test scenarios are Debug-only: no file of the archived app may name the scenario key, the module or a fixture.
check-release-app:
	@set -eu; \
	app="$(ARCHIVE_PATH)/Products/Applications/CircuitTimer.app"; \
	test -d "$$app" || { echo "check-release-app: no archived app at $$app; run make archive first" >&2; exit 1; }; \
	found=$$(find "$$app" -type f | while IFS= read -r file; do \
		if strings -a "$$file" | grep -qE 'CT_APP_SCENARIO|AppScenarios|Leg day'; then echo "$$file"; fi; \
	done); \
	if [ -n "$$found" ]; then \
		echo "check-release-app: UI test scenarios reached the Release app in:" >&2; echo "$$found" >&2; exit 1; \
	fi; \
	echo "check-release-app: OK"

# Signs the archive with a cloud-managed distribution certificate and uploads it to App Store Connect.
# The upload writes nothing to EXPORT_PATH; testflight.yml inspects a separate export instead.
upload:
	@test -n "$(ASC_KEY_PATH)" -a -n "$(ASC_KEY_ID)" -a -n "$(ASC_ISSUER_ID)" \
		|| { echo "upload: ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID are required" >&2; exit 1; }
	xcodebuild -exportArchive -archivePath "$(ARCHIVE_PATH)" \
		-exportOptionsPlist Configs/ExportOptions.plist -exportPath "$(EXPORT_PATH)" \
		-allowProvisioningUpdates -authenticationKeyPath "$(ASC_KEY_PATH)" \
		-authenticationKeyID "$(ASC_KEY_ID)" -authenticationKeyIssuerID "$(ASC_ISSUER_ID)"

ci: lint check-resolved test build-app test-ui

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
