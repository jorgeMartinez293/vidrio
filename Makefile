# Makefile for vidrio (familia vaho)

APP_NAME = vidrio
EXECUTABLE = Vidrio
# Universal (arm64 + x86_64) products land here instead of .build/release.
BUILD_DIR = .build/apple/Products/Release
APP_BUNDLE = $(APP_NAME).app
PLIST = Info.plist
ICON = icon.icns

# Signing identity. Prefers the Apple Development certificate (stable designated
# requirement → TCC grants survive rebuilds); ad-hoc otherwise. Override with
# `make SIGN_IDENTITY=-` to force ad-hoc.
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null \
	| grep -m1 -o '"Apple Development: [^"]*"' | tr -d '"')
ifeq ($(strip $(SIGN_IDENTITY)),)
SIGN_IDENTITY = -
endif

all: build

build:
	swift build

run: build
	./.build/debug/$(EXECUTABLE)

test:
	swift test

clean:
	swift package clean
	rm -rf $(APP_BUNDLE)

release:
	swift build -c release --arch arm64 --arch x86_64

bundle: release
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	mkdir -p $(APP_BUNDLE)/Contents/Frameworks
	cp $(BUILD_DIR)/$(EXECUTABLE) $(APP_BUNDLE)/Contents/MacOS/$(EXECUTABLE)
	cp $(ICON) $(APP_BUNDLE)/Contents/Resources/AppIcon.icns
	cp $(PLIST) $(APP_BUNDLE)/Contents/Info.plist
	# Embed Sparkle.framework (auto-update): swift build links against it but doesn't
	# copy it into the bundle, and Sparkle can't run from outside the app.
	@SPARKLE_FW=$$(find .build -maxdepth 8 -name 'Sparkle.framework' -type d | head -1); \
	if [ -z "$$SPARKLE_FW" ]; then echo "ERROR: Sparkle.framework not found in .build"; exit 1; fi; \
	cp -R "$$SPARKLE_FW" $(APP_BUNDLE)/Contents/Frameworks/
	install_name_tool -add_rpath @executable_path/../Frameworks $(APP_BUNDLE)/Contents/MacOS/$(EXECUTABLE) 2>/dev/null || true
	codesign --force --deep --sign "$(SIGN_IDENTITY)" $(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework
	codesign --force --deep -s "$(SIGN_IDENTITY)" $(APP_BUNDLE)
	codesign --verify --deep --strict $(APP_BUNDLE)
	@echo "App Bundle created and signed ($(SIGN_IDENTITY)) at $(APP_BUNDLE)"

# DMG for first-time downloads (auto-updates travel as .zip via Sparkle).
# Stable, unversioned name: the landing links releases/latest/download/vidrio.dmg.
dmg:
	rm -f dist/$(APP_NAME).dmg
	mkdir -p dist
	create-dmg --volname "$(APP_NAME)" --window-size 500 320 --icon-size 96 \
	  --icon "$(APP_BUNDLE)" 120 130 --app-drop-link 380 130 \
	  --hide-extension "$(APP_BUNDLE)" \
	  dist/$(APP_NAME).dmg $(APP_BUNDLE)
	codesign --force --sign "$(SIGN_IDENTITY)" dist/$(APP_NAME).dmg
