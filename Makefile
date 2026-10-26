CONFIGURATION ?= Debug
DERIVED_DATA ?= build/DerivedData
DESTINATION ?= platform=macOS,arch=$(shell uname -m)
APP = $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/MeetMeet.app
XCODEBUILD = xcodebuild -quiet -project MeetMeet.xcodeproj -scheme MeetMeet -configuration "$(CONFIGURATION)" -destination "$(DESTINATION)" -derivedDataPath "$(DERIVED_DATA)"

.PHONY: build run test test-xcode verify release

build:
	$(XCODEBUILD) build

run: build
	open "$(APP)"

test:
	swift test

test-xcode:
	$(XCODEBUILD) test

verify: build
	codesign --verify --deep --strict "$(APP)"
	codesign --display --entitlements - "$(APP)"

# Example: make release VERSION=0.1.0 (requires a clean committed tree).
release:
	bash scripts/package-release.sh "$(VERSION)"
