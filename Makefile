SWIFTLINT ?= swiftlint
# Edits the archive's entitlements; the script tests replace it, as Linux has none.
PLISTBUDDY ?= /usr/libexec/PlistBuddy
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
# Test runs keep apart by destination, so runs on different simulators can overlap: `iPhone 17 #2` on 27.0 runs as
# `iPhone-17-2-27.0`.
TEST_RUN ?= $(shell printf '%s' '$(DESTINATION)' | sed -E 's/.*name=([^,]+).*OS=([0-9.]+).*/\1-\2/; s/[^A-Za-z0-9.]+/-/g')
# Parallel workers clone the simulator, so more than one is allowed only on CI.
UI_TEST_WORKERS ?= 1
# What `check-release-app` looks for. An optimized build may fold a short string literal into code, so the list also
# names the types, which Swift metadata keeps; `AppScenario` also matches the module `AppScenarios`. Keep it in step
# with UITestContract's AppScenario.swift.
RELEASE_FORBIDDEN := AppScenario|ScenarioLaunch|ScenarioFixture|CT_APP_SCENARIO|Leg day
# Simulator builds without a signature carry no iCloud entitlement, and CloudKit traps a process that uses a container
# without it, so they name no container: the store stays on the device.
UNSIGNED = CODE_SIGNING_ALLOWED=NO CT_CLOUDKIT_CONTAINER=
# What `build-ui-tests` builds and `test-ui` runs: the same arguments, so the tests find the build done.
UI_TEST_BUILD = -project CircuitTimer.xcodeproj -scheme CircuitTimer -destination '$(DESTINATION)' \
	-derivedDataPath "$(DERIVED_DATA)/UITests-$(TEST_RUN)" $(UNSIGNED) $(XCODEBUILD_FLAGS)

SNAPSHOT_REFERENCE_DESTINATION := platform=iOS Simulator,name=iPhone 17,OS=27.0
SNAPSHOTS_DIR := CircuitTimerSnapshotTests/__Snapshots__
SNAPSHOT_LANGUAGES ?= en ru
test-snapshot record-snapshot: export SNAPSHOT_LANGUAGE ?= en
test-snapshot record-snapshot: export SNAPSHOT_TEXT_SIZE ?= large
test-snapshot record-snapshot: export SNAPSHOT_SELECTED_TEST = $(TEST)
SNAPSHOT_TEST_BUILD = -project CircuitTimer.xcodeproj -scheme CircuitTimerSnapshots -destination '$(DESTINATION)' \
	-derivedDataPath "$(DERIVED_DATA)/Snapshots-$(TEST_RUN)" $(UNSIGNED) $(XCODEBUILD_FLAGS)

XCODEBUILD_FLAGS = -quiet \
	-clonedSourcePackagesDirPath "$(SOURCE_PACKAGES)" \
	-skipMacroValidation \
	-skipPackagePluginValidation \
	-disableAutomaticPackageResolution

# Package builds are strict; the app build is not, because Xcode builds the package as a
# dependency there with suppressed warnings (see CircuitTimerKit/Package.swift).
STRICT := CIRCUITTIMER_STRICT_WARNINGS=1

PACKAGE_RESOLVED := CircuitTimerKit/Package.resolved
SNAPSHOT_KIT_RESOLVED := CircuitTimerSnapshotKit/Package.resolved
PROJECT_RESOLVED := CircuitTimer.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
PINS := [.pins[] | {identity, version: .state.version, revision: .state.revision}] | sort_by(.identity)

.PHONY: lint test-scripts check-resolved resolve build-package build-snapshot-kit test build-app build-ui-tests test-ui archive \
	build-snapshots test-snapshots test-snapshot record-snapshot test-snapshot-kit test-snapshot-contracts record-snapshots check-release-app upload ci verify-clean

lint:
	$(SWIFTLINT) lint --strict --quiet
	scripts/check-scenario-dependencies.sh

# Tests of the scripts and of the make targets around xcodebuild, with fixtures and stand-ins for xcodebuild and xcrun,
# so CI's Linux lint job runs them too; a test that lints uses SWIFTLINT.
test-scripts:
	@set -u; failed=0; \
	for test in scripts/tests/test-*.sh; do SWIFTLINT="$(SWIFTLINT)" "$$test" || failed=1; done; \
	exit $$failed

# Shared dependencies agree across the packages; their union is exactly what the project resolves.
check-resolved:
	@set -eu; \
	command -v jq >/dev/null || { echo "check-resolved: jq is required" >&2; exit 1; }; \
	conflicts=$$(jq -sr '[.[].pins[] | {identity, version: .state.version, revision: .state.revision}] | group_by(.identity)[] | select((unique | length) > 1) | .[0].identity' \
		$(PACKAGE_RESOLVED) $(SNAPSHOT_KIT_RESOLVED)); \
	if [ -n "$$conflicts" ]; then \
		echo "check-resolved: CircuitTimerKit and CircuitTimerSnapshotKit pin $$conflicts differently; run 'make resolve' and commit all three" >&2; exit 1; \
	fi; \
	package=$$(jq -csS '[.[].pins[] | {identity, version: .state.version, revision: .state.revision}] | unique | sort_by(.identity)' \
		$(PACKAGE_RESOLVED) $(SNAPSHOT_KIT_RESOLVED)); \
	project=$$(jq -cS '$(PINS)' $(PROJECT_RESOLVED)); \
	if [ "$$package" != "$$project" ]; then \
		echo "check-resolved: the packages' lockfiles together differ from the project's; run 'make resolve' and commit all three" >&2; exit 1; \
	fi; \
	if ! jq -es '([.[0].pins[] | select(.identity == "swift-snapshot-testing")] | length) == 0 and all(.[1:][]; ([.pins[] | select(.identity == "swift-snapshot-testing")] | length) == 1 and any(.pins[]; .identity == "swift-snapshot-testing" and .state.version == "1.19.6"))' \
		$(PACKAGE_RESOLVED) $(SNAPSHOT_KIT_RESOLVED) $(PROJECT_RESOLVED) >/dev/null; then \
		echo "check-resolved: SnapshotTesting 1.19.6 belongs to CircuitTimerSnapshotKit and the project only; run 'make resolve' and commit all three" >&2; exit 1; \
	fi

resolve:
	cd CircuitTimerKit && xcodebuild -resolvePackageDependencies -clonedSourcePackagesDirPath "$(SOURCE_PACKAGES)"
	cd CircuitTimerSnapshotKit && xcodebuild -resolvePackageDependencies -clonedSourcePackagesDirPath "$(SOURCE_PACKAGES)"
	xcodebuild -resolvePackageDependencies -project CircuitTimer.xcodeproj -scheme CircuitTimer \
		-clonedSourcePackagesDirPath "$(SOURCE_PACKAGES)"
	xcodebuild -resolvePackageDependencies -project CircuitTimer.xcodeproj -scheme CircuitTimerSnapshots \
		-clonedSourcePackagesDirPath "$(SOURCE_PACKAGES)"

build-snapshot-kit:
	cd CircuitTimerSnapshotKit && $(STRICT) xcodebuild build -scheme CircuitTimerSnapshotKit \
		-destination '$(BUILD_DESTINATION)' ARCHS=$(HOST_ARCH) \
		-derivedDataPath "$(DERIVED_DATA)/SnapshotKit" $(XCODEBUILD_FLAGS)

test-snapshot-kit:
	@set -eu; \
	results="$(TEST_RESULTS)"; \
	case "$$results" in /*) ;; *) results="$(CURDIR)/$$results" ;; esac; \
	cd CircuitTimerSnapshotKit; \
	$(STRICT) "$(CURDIR)/scripts/run-tests.sh" "$$results/SnapshotKit-$(TEST_RUN).xcresult" \
		xcodebuild test -scheme CircuitTimerSnapshotKit -destination '$(DESTINATION)' -testLanguage en -testRegion US \
		-derivedDataPath "$(DERIVED_DATA)/SnapshotKitTests-$(TEST_RUN)" -collect-test-diagnostics never $(XCODEBUILD_FLAGS) $(TEST_FLAGS); \
	$(STRICT) "$(CURDIR)/scripts/run-tests.sh" "$$results/SnapshotKit-$(TEST_RUN)-ru.xcresult" \
		xcodebuild test -scheme CircuitTimerSnapshotKit -destination '$(DESTINATION)' -testLanguage ru -testRegion RU \
		-derivedDataPath "$(DERIVED_DATA)/SnapshotKitTests-$(TEST_RUN)" -collect-test-diagnostics never $(XCODEBUILD_FLAGS) \
		-only-testing:'SnapshotCaptureTests/SnapshotCaptureTests/test_capture_bundleLanguageMismatch_throwsBeforeRoot()'; \
	report=$$(xcrun xcresulttool get test-results summary --path "$$results/SnapshotKit-$(TEST_RUN)-ru.xcresult"); \
		printf '%s\n' "$$report" | jq -e '.passedTests == 1 and .skippedTests == 0 and .failedTests == 0' > /dev/null

test-snapshot-contracts:
	@set -eu; \
	results="$(TEST_RESULTS)"; \
	case "$$results" in /*) ;; *) results="$(CURDIR)/$$results" ;; esac; \
	scripts/run-tests.sh "$$results/SnapshotContracts-$(TEST_RUN).xcresult" \
		xcodebuild test -project CircuitTimer.xcodeproj -scheme CircuitTimerSnapshotContracts -destination '$(DESTINATION)' \
		-derivedDataPath "$(DERIVED_DATA)/Snapshots-$(TEST_RUN)" $(UNSIGNED) -testLanguage en -testRegion US \
		-parallel-testing-enabled NO -collect-test-diagnostics never $(XCODEBUILD_FLAGS) $(TEST_FLAGS); \
	scripts/run-tests.sh "$$results/SnapshotContracts-$(TEST_RUN)-de.xcresult" \
		xcodebuild test -project CircuitTimer.xcodeproj -scheme CircuitTimerSnapshotContracts -destination '$(DESTINATION)' \
		-derivedDataPath "$(DERIVED_DATA)/Snapshots-$(TEST_RUN)" $(UNSIGNED) -testLanguage de -testRegion DE \
		-parallel-testing-enabled NO -collect-test-diagnostics never $(XCODEBUILD_FLAGS) \
		-only-testing:CircuitTimerSnapshotContractTests/SnapshotLanguageContractTests; \
	report=$$(xcrun xcresulttool get test-results summary --path "$$results/SnapshotContracts-$(TEST_RUN)-de.xcresult"); \
		printf '%s\n' "$$report" | jq -e '.passedTests == 1 and .skippedTests == 0 and .failedTests == 0' > /dev/null

build-package:
	cd CircuitTimerKit && $(STRICT) xcodebuild build -scheme CircuitTimerKit-Package \
		-destination '$(BUILD_DESTINATION)' ARCHS=$(HOST_ARCH) \
		-derivedDataPath "$(DERIVED_DATA)/Package" $(XCODEBUILD_FLAGS)

# Tests run in English so assertions on localized text do not depend on the machine's language.
# The output is quiet, so failure messages live only in the result bundle, which run-tests.sh names. Diagnostics are
# never collected: the simulator can keep xcodebuild waiting ten minutes for them. Each destination has its own result
# bundle, log and DerivedData, as in `test-ui`.
test:
	cd CircuitTimerKit && $(STRICT) "$(CURDIR)/scripts/run-tests.sh" "$(TEST_RESULTS)/Package-$(TEST_RUN).xcresult" \
		xcodebuild test -scheme CircuitTimerKit-Package \
		-destination '$(DESTINATION)' -testLanguage en -testRegion US \
		-derivedDataPath "$(DERIVED_DATA)/Package-$(TEST_RUN)" -collect-test-diagnostics never $(XCODEBUILD_FLAGS) $(TEST_FLAGS)

build-app:
	xcodebuild build -project CircuitTimer.xcodeproj -scheme CircuitTimer \
		-destination '$(BUILD_DESTINATION)' ARCHS=$(HOST_ARCH) $(UNSIGNED) \
		-derivedDataPath "$(DERIVED_DATA)/App" $(XCODEBUILD_FLAGS)
	python3 scripts/check-activity-intents.py "$(DERIVED_DATA)/App/Build/Products/Debug-iphonesimulator/CircuitTimer.app"

# The app with its UI tests, as `test-ui` builds them, so CI shows a build error in a step of its own.
build-ui-tests:
	xcodebuild build-for-testing $(UI_TEST_BUILD)
	python3 scripts/check-activity-intents.py "$(DERIVED_DATA)/UITests-$(TEST_RUN)/Build/Products/Debug-iphonesimulator/CircuitTimer.app"

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
	scripts/run-tests.sh "$(TEST_RESULTS)/UITests-$(TEST_RUN).xcresult" \
		xcodebuild test $(UI_TEST_BUILD) $$par \
		-retry-tests-on-failure -test-iterations 2 -test-timeouts-enabled YES -collect-test-diagnostics never \
		-default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 120 $(TEST_FLAGS)

# All snapshot targets use a fresh process per language and text size, without user-supplied selection or Xcode retries.
# Full-matrix runs never select tests; the local single targets supply their own selection.
# The only retry of an image is the capture helper's second mount.
define validate-snapshot-process
	case '$(DESTINATION)' in \
		'platform=iOS Simulator,name=iPhone 17,OS=27.0'|\
		'platform=iOS Simulator,name=iPhone 17 #2,OS=27.0'|\
		'platform=iOS Simulator,name=iPhone 17 #3,OS=27.0') ;; \
		*) echo "snapshots: comparisons require iPhone 17, #2 or #3 on iOS 27.0" >&2; exit 2 ;; \
	esac; \
	for flag in $(TEST_FLAGS) $(XCODEBUILD_FLAGS); do \
		case "$$flag" in \
			-only-testing*|-skip-testing*|-only-test-configuration*|-skip-test-configuration*|-testPlan*|\
			-test-iterations*|-retry-tests-on-failure*|-run-tests-until-failure*|-test-repetition-relaunch-enabled*) \
				echo "snapshots: '$$flag' would select or repeat cases; use the snapshot target's language/size options and TEST for a single snapshot" >&2; exit 2 ;; \
		esac; \
	done;
endef

define validate-snapshot-run
	$(validate-snapshot-process) \
	if [ -z '$(strip $(SNAPSHOT_LANGUAGES))' ]; then \
		echo "snapshots: SNAPSHOT_LANGUAGES must contain en or ru" >&2; exit 2; \
	fi; \
	seen=" "; \
	for language in $(SNAPSHOT_LANGUAGES); do \
		case "$$language" in en|ru) ;; *) echo "snapshots: unsupported language '$$language'" >&2; exit 2 ;; esac; \
		case "$$seen" in *" $$language "*) echo "snapshots: duplicate language '$$language'" >&2; exit 2 ;; esac; \
		seen="$$seen$$language "; \
	done;
endef

define run-snapshots
	set -eu; \
	$(validate-snapshot-run) \
	version=$$(xcodebuild -version); \
	printf '%s\n' "$$version"; \
	if [ -n "$${GITHUB_STEP_SUMMARY:-}" ]; then printf '%s\n' "$$version" >> "$$GITHUB_STEP_SUMMARY"; fi; \
	failed=0; english_large=""; english_ax5=""; russian_large=""; russian_ax5=""; suffix=""; \
	if [ '$(1)' = failed ]; then suffix=-record; fi; \
	for language in $(SNAPSHOT_LANGUAGES); do \
		case "$$language" in en) region=US ;; ru) region=RU ;; esac; \
		for text_size in large ax5; do \
			case "$$text_size" in large) category=UICTContentSizeCategoryL ;; ax5) category=UICTContentSizeCategoryAccessibilityXXXL ;; esac; \
			base="$(abspath $(TEST_RESULTS))/Snapshots-$(TEST_RUN)-$$language-$$text_size$$suffix"; \
			bundle="$$base.xcresult"; artifacts="$$base-artifacts"; \
			rm -rf "$$artifacts"; mkdir -p "$$artifacts"; \
			status=0; \
			env TEST_RUNNER_SNAPSHOT_TESTING_RECORD='$(1)' TEST_RUNNER_SNAPSHOT_ARTIFACTS="$$artifacts" \
				TEST_RUNNER_SNAPSHOT_TEXT_SIZE="$$text_size" \
				scripts/run-tests.sh "$$bundle" xcodebuild test $(SNAPSHOT_TEST_BUILD) \
				SNAPSHOT_CONTENT_SIZE_CATEGORY="$$category" \
				-testLanguage "$$language" -testRegion "$$region" -parallel-testing-enabled NO \
				-collect-test-diagnostics never $(TEST_FLAGS) || status=$$?; \
			SNAPSHOTS_DIR="$(SNAPSHOTS_DIR)" scripts/check-snapshot-run.sh '$(1)' "$$language" "$$text_size" "$$status" \
				"$$bundle" "$$artifacts" || failed=1; \
			case "$$language-$$text_size" in \
				en-large) english_large="$$bundle" ;; en-ax5) english_ax5="$$bundle" ;; \
				ru-large) russian_large="$$bundle" ;; ru-ax5) russian_ax5="$$bundle" ;; \
			esac; \
		done; \
	done; \
	if [ "$$failed" -eq 0 ] && [ -n "$$english_large" ] && [ -n "$$russian_large" ]; then \
		scripts/check-snapshot-run.sh --same-cases "$$english_large" "$$english_ax5" "$$russian_large" "$$russian_ax5" || failed=1; \
	fi; \
	[ "$$failed" -eq 0 ]
endef

build-snapshots:
	xcodebuild build-for-testing $(SNAPSHOT_TEST_BUILD)

test-snapshots:
	@$(call run-snapshots,never)

define validate-snapshot-recording
set -eu; \
	if [ "$${CI:-}" = true ]; then echo "$@: recording is local only" >&2; exit 2; fi; \
	if [ '$(DESTINATION)' != '$(SNAPSHOT_REFERENCE_DESTINATION)' ]; then \
		echo "$@: references require $(SNAPSHOT_REFERENCE_DESTINATION)" >&2; exit 2; \
	fi; \
	if [ -n "$$(git status --porcelain -- '$(SNAPSHOTS_DIR)')" ]; then \
		echo "$@: review and commit reference changes before recording" >&2; exit 2; \
	fi
endef

record-snapshots:
	@$(validate-snapshot-recording)
	@$(call run-snapshots,failed)
	@$(call run-snapshots,never)
	@git status --short -- '$(SNAPSHOTS_DIR)'
	@git ls-files --others --exclude-standard -- '$(SNAPSHOTS_DIR)'

# Local iteration checks one function and one process variant; CI always uses the full matrix.
define run-single-snapshot
	set -eu; \
	[ "$${CI:-}" != true ] || { echo "single snapshots are local only" >&2; exit 2; }; \
	$(if $(filter file,$(origin SNAPSHOT_LANGUAGES)),,echo "single snapshots: use SNAPSHOT_LANGUAGE; SNAPSHOT_LANGUAGES is for the full matrix" >&2; exit 2;) \
	$(validate-snapshot-process) \
	language="$$SNAPSHOT_LANGUAGE"; text_size="$$SNAPSHOT_TEXT_SIZE"; selected="$$SNAPSHOT_SELECTED_TEST"; \
	case "$$language" in en) region=US ;; ru) region=RU ;; *) echo "SNAPSHOT_LANGUAGE must be en or ru" >&2; exit 2 ;; esac; \
	case "$$text_size" in \
		large) category=UICTContentSizeCategoryL ;; ax5) category=UICTContentSizeCategoryAccessibilityXXXL ;; \
		*) echo "SNAPSHOT_TEXT_SIZE must be large or ax5" >&2; exit 2 ;; \
	esac; \
	printf '%s\n' "$$selected" | LC_ALL=C grep -Eq '^test_[A-Za-z0-9_]+$$' || { echo "TEST must name one snapshot function" >&2; exit 2; }; \
	identifier=$$(scripts/check-snapshot-run.sh --select "$$selected" "$$text_size"); \
	xcodebuild -version; \
	suffix=""; if [ '$(1)' = failed ]; then suffix=-record; fi; \
	base="$(abspath $(TEST_RESULTS))/Snapshot-$(TEST_RUN)-$$selected-$$language-$$text_size$$suffix"; \
	bundle="$$base.xcresult"; artifacts="$$base-artifacts"; \
	rm -rf "$$artifacts"; mkdir -p "$$artifacts"; status=0; \
	env TEST_RUNNER_SNAPSHOT_TESTING_RECORD='$(1)' TEST_RUNNER_SNAPSHOT_ARTIFACTS="$$artifacts" \
		TEST_RUNNER_SNAPSHOT_TEXT_SIZE="$$text_size" \
		scripts/run-tests.sh "$$bundle" xcodebuild test $(SNAPSHOT_TEST_BUILD) \
			SNAPSHOT_CONTENT_SIZE_CATEGORY="$$category" \
			-testLanguage "$$language" -testRegion "$$region" -parallel-testing-enabled NO \
			-collect-test-diagnostics never $(TEST_FLAGS) "-only-testing:$$identifier" || status=$$?; \
	SNAPSHOTS_DIR="$(SNAPSHOTS_DIR)" scripts/check-snapshot-run.sh '$(1)' "$$language" "$$text_size" "$$status" \
		"$$bundle" "$$artifacts" "$$selected"
endef

test-snapshot:
	@$(call run-single-snapshot,never)

record-snapshot:
	@$(validate-snapshot-recording)
	@$(call run-single-snapshot,failed)
	@$(call run-single-snapshot,never)
	@git status --short -- '$(SNAPSHOTS_DIR)'
	@git ls-files --others --exclude-standard -- '$(SNAPSHOTS_DIR)'

# Built unsigned: an App Store Connect API key can sign only at export, so `upload` signs. The export keeps the
# entitlements of the archived signature and an unsigned app has none, so the archived bundles are then signed ad hoc,
# the widget before the app that contains it, and the app with Configs/CircuitTimer.entitlements for its container.
archive:
	@test -n "$(BUILD_NUMBER)" || { echo "archive: BUILD_NUMBER is required" >&2; exit 1; }
	xcodebuild archive -project CircuitTimer.xcodeproj -scheme CircuitTimer -configuration Release \
		-destination 'generic/platform=iOS' -archivePath "$(ARCHIVE_PATH)" \
		CODE_SIGNING_ALLOWED=NO CURRENT_PROJECT_VERSION=$(BUILD_NUMBER) \
		-derivedDataPath "$(DERIVED_DATA)/Archive" $(XCODEBUILD_FLAGS)
	@set -eu; \
	app="$(ARCHIVE_PATH)/Products/Applications/CircuitTimer.app"; \
	container=$$(plutil -extract CTCloudKitContainerIdentifier raw "$$app/Info.plist"); \
	test -n "$$container" || { echo "archive: the app names no CloudKit container" >&2; exit 1; }; \
	entitlements="$(DERIVED_DATA)/Archive/CircuitTimer.entitlements"; \
	cp Configs/CircuitTimer.entitlements "$$entitlements"; \
	"$(PLISTBUDDY)" -c "Set :com.apple.developer.icloud-container-identifiers:0 $$container" "$$entitlements"; \
	for extension in "$$app"/PlugIns/*.appex; do codesign --force --sign - --timestamp=none "$$extension"; done; \
	codesign --force --sign - --timestamp=none --entitlements "$$entitlements" "$$app"; \
	codesign --verify --deep --strict "$$app"

# UI test scenarios are Debug-only: no file of the archived app may name one.
check-release-app:
	@set -eu; \
	app="$(ARCHIVE_PATH)/Products/Applications/CircuitTimer.app"; \
	test -d "$$app" || { echo "check-release-app: no archived app at $$app; run make archive first" >&2; exit 1; }; \
	found=$$(find "$$app" -type f | while IFS= read -r file; do \
		if strings -a "$$file" | grep -qE '$(RELEASE_FORBIDDEN)'; then echo "$$file"; fi; \
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

ci: lint test-scripts check-resolved test build-ui-tests test-ui build-snapshot-kit test-snapshot-kit build-snapshots test-snapshot-contracts test-snapshots

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
