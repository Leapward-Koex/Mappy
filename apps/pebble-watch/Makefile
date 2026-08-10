SHELL := /usr/bin/env bash

APP_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
PACKAGE_JSON := $(APP_DIR)/package.json
BUILD_DIR := $(APP_DIR)/build
DIST_DIR := $(APP_DIR)/dist
PBW_SRC := $(BUILD_DIR)/pebble-watch.pbw
VERSION := $(shell python3 -c 'import json; print(json.load(open("$(PACKAGE_JSON)", "r"))["version"])')
APP_SLUG := mappy-watch
PHONE_RELEASE_PBW := $(DIST_DIR)/$(APP_SLUG)-$(VERSION)-phone.pbw
FIXTURE_RELEASE_PBW := $(DIST_DIR)/$(APP_SLUG)-$(VERSION)-fixture.pbw

.PHONY: help build build-phone build-fixture build-real-fixture release release-phone release-fixture clean clean-build clean-dist print-version

help:
	@printf '%s\n' \
		'Targets:' \
		'  make release          Build the production phone-mode PBW for sideloading.' \
		'  make release-phone    Same as release.' \
		'  make release-fixture  Build the emulator-only fixture PBW.' \
		'  make build            Build the default production phone-mode PBW in build/.' \
		'  make build-phone      Build the production phone-mode PBW in build/.' \
		'  make build-fixture    Build the fixture-mode PBW in build/.' \
		'  make build-real-fixture  Build using the local provider-map fixture.' \
		'  make clean            Remove build/, dist/, and generated fixture options.' \
		'' \
		'Environment overrides:' \
		'  PEBBLE_PLATFORM=emery' \
		'  MAPPY_FIXTURE_TILE_DELAY_MS=900' \
		'  MAPPY_FIXTURE_TILE_STAGGER_MS=80' \
		'  MAPPY_FIXTURE_TILE_ANIMATION_MODE=2'

build: build-phone

build-phone:
	cd "$(APP_DIR)" && MAPPY_WATCH_PHONE_MODE=phone pebble build

build-fixture:
	cd "$(APP_DIR)" && MAPPY_WATCH_PHONE_MODE=fixture pebble build

build-real-fixture:
	cd "$(APP_DIR)" && MAPPY_WATCH_PHONE_MODE=real-fixture pebble build

release: release-phone

release-phone: build-phone $(PHONE_RELEASE_PBW)
	@printf 'Release PBW: %s\n' "$(PHONE_RELEASE_PBW)"

release-fixture: build-fixture $(FIXTURE_RELEASE_PBW)
	@printf 'Fixture PBW: %s\n' "$(FIXTURE_RELEASE_PBW)"

$(PHONE_RELEASE_PBW): $(PBW_SRC)
	mkdir -p "$(DIST_DIR)"
	cp "$(PBW_SRC)" "$(PHONE_RELEASE_PBW)"

$(FIXTURE_RELEASE_PBW): $(PBW_SRC)
	mkdir -p "$(DIST_DIR)"
	cp "$(PBW_SRC)" "$(FIXTURE_RELEASE_PBW)"

clean: clean-build clean-dist
	rm -f "$(APP_DIR)/src/pkjs/fixture-options.generated.js"

clean-build:
	rm -rf "$(BUILD_DIR)"

clean-dist:
	rm -rf "$(DIST_DIR)"

print-version:
	@printf '%s\n' "$(VERSION)"
