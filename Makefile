APP_NAME := AutoProxy
BUNDLE_ID := me.ikvarxt.autoproxy
EXECUTABLE := AutoProxy
CONFIG := release
BUILD_DIR := .build/$(CONFIG)
APP_BUNDLE := build/$(APP_NAME).app
SIGN_IDENTITY := -
VERSION :=
BUILD_NUMBER :=

-include local.mk

.PHONY: all build test app icon run deploy install uninstall clean

all: app

build:
	swift build -c $(CONFIG)

test:
	swift test

app: build
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS $(APP_BUNDLE)/Contents/Resources
	cp $(BUILD_DIR)/$(EXECUTABLE) $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	cp Resources/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	swift scripts/make-icon.swift build/$(APP_NAME).iconset >/dev/null
	iconutil -c icns build/$(APP_NAME).iconset -o $(APP_BUNDLE)/Contents/Resources/AppIcon.icns
ifneq ($(VERSION),)
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" $(APP_BUNDLE)/Contents/Info.plist
endif
ifneq ($(BUILD_NUMBER),)
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD_NUMBER)" $(APP_BUNDLE)/Contents/Info.plist
endif
	codesign --force --sign "$(SIGN_IDENTITY)" $(APP_BUNDLE)
	@echo "built $(APP_BUNDLE)"

icon:
	swift scripts/make-icon.swift build/$(APP_NAME).iconset

run: app
	pkill -x $(APP_NAME) || true
	open $(APP_BUNDLE)

deploy:
	./scripts/deploy.sh

install: app
	pkill -x $(APP_NAME) || true
	rm -rf /Applications/$(APP_NAME).app
	cp -R $(APP_BUNDLE) /Applications/
	@echo "installed /Applications/$(APP_NAME).app"

uninstall:
	pkill -x $(APP_NAME) || true
	rm -rf /Applications/$(APP_NAME).app

clean:
	rm -rf .build build
