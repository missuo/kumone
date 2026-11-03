# Kumone — developer entry points.
#
# `make configure` selects which capabilities the iOS build ships with. CarPlay is
# opt-in because its entitlement needs per-app approval from Apple, so the default
# configuration — the one CI and every contributor gets — leaves it out entirely.
# See the CarPlay section of the README.
#
# `make project` regenerates ios/KumoneIOS.xcodeproj from ios/project.yml with
# XcodeGen; it is only needed after editing project.yml, never for CarPlay.

.DEFAULT_GOAL := help
.PHONY: help configure configure-carplay project build test app ios-test ios-uitest testflight clean

help: ## Show this help
	@echo "Kumone make targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

configure: ## Configure the iOS build (default: CarPlay disabled)
	@Scripts/configure-ios.sh

configure-carplay: ## Configure the iOS build with the CarPlay capability enabled
	@Scripts/configure-ios.sh --carplay

project: ## Regenerate ios/KumoneIOS.xcodeproj from ios/project.yml (needs xcodegen)
	@cd ios && xcodegen generate

build: ## Build the macOS app with SwiftPM
	@swift build

test: ## Run the macOS SwiftPM test suite
	@swift test

app: ## Build and bundle the macOS .app (Scripts/build-app.sh)
	@Scripts/build-app.sh $(CONFIG)

IOS_DESTINATION ?= platform=iOS Simulator,name=iPhone 17 Pro

ios-test: ## Run the iOS unit tests on a simulator (override with IOS_DESTINATION=...)
	@# The KumoneIOS scheme only carries the UI test target, so the package's unit
	@# tests have to be driven through the package's own scheme.
	@cd ios/KumoneIOSPackage && xcodebuild test \
		-scheme KumoneIOSFeature \
		-destination '$(IOS_DESTINATION)'

ios-uitest: ## Run the iOS UI tests on a simulator
	@xcodebuild test \
		-workspace ios/KumoneIOS.xcworkspace \
		-scheme KumoneIOS \
		-destination '$(IOS_DESTINATION)'

TESTFLIGHT_FLAGS := $(if $(filter 1,$(CARPLAY)),--carplay) $(if $(filter 1,$(UPLOAD)),--upload)

testflight: ## Archive the iOS app for TestFlight (CARPLAY=1 adds CarPlay, UPLOAD=1 uploads; needs KUMONE_TEAM_ID)
	@Scripts/testflight.sh $(TESTFLIGHT_FLAGS)

clean: ## Remove build artifacts and generated CarPlay overlays
	@swift package clean || true
	@rm -rf .build
	@rm -f ios/Config/CarPlay.local.xcconfig
	@rm -rf ios/Config/Generated
