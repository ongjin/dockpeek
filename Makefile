SWIFT_FILES := $(shell find DockPeek -name '*.swift' -type f)
APP_NAME    := DockPeek
BUNDLE_ID   := com.dockpeek.app
VERSION     := 1.4.6
TARGET      := arm64-apple-macos14.0
SWIFT_FLAGS := -swift-version 5 -target $(TARGET) -parse-as-library \
               -framework AppKit -framework SwiftUI \
               -framework CoreGraphics -framework ApplicationServices

SIGN_ID     := DockPeek Development
INSTALL_APP := /Applications/$(APP_NAME).app
INSTALL_BIN := $(INSTALL_APP)/Contents/MacOS/$(APP_NAME)

.PHONY: build release clean install dev run dist open generate setup kill

# ============================================================
# DEVELOPMENT WORKFLOW (recommended)
#
#   1. First time:  make setup    (install + grant permissions)
#   2. After edits: make dev      (hot-swap binary, no re-grant)
#   3. Stop:        make kill
# ============================================================

# First-time setup: build, install to /Applications, launch
setup: release
	@mkdir -p "$(INSTALL_APP)/Contents/MacOS" "$(INSTALL_APP)/Contents/Resources"
	@cp -R build/Release/$(APP_NAME).app/ "$(INSTALL_APP)/"
	@xattr -cr "$(INSTALL_APP)"
	@echo ""
	@echo "=== DockPeek installed to /Applications ==="
	@echo "Opening now — grant Accessibility permission when prompted."
	@echo "After granting, use 'make dev' for fast rebuilds (no re-grant needed)."
	@echo ""
	@open "$(INSTALL_APP)"

# Fast dev cycle: rebuild binary and swap into /Applications in-place
# Keeps the same app bundle so macOS preserves granted permissions
dev: kill
	@echo "Compiling..."
	@mkdir -p build/Debug
	@swiftc $(SWIFT_FLAGS) -Onone -g -o build/Debug/$(APP_NAME) $(SWIFT_FILES)
	@if [ ! -d "$(INSTALL_APP)" ]; then \
		echo "Error: Run 'make setup' first to install DockPeek.app"; exit 1; \
	fi
	@cp build/Debug/$(APP_NAME) "$(INSTALL_BIN)"
	@cp DockPeek/Info.plist "$(INSTALL_APP)/Contents/Info.plist"
	@cp DockPeek/Resources/AppIcon.icns "$(INSTALL_APP)/Contents/Resources/AppIcon.icns"
	@codesign --force --sign "$(SIGN_ID)" "$(INSTALL_APP)"
	@echo "Binary updated. Launching..."
	@open "$(INSTALL_APP)"

# Kill running instance
kill:
	@pkill -x $(APP_NAME) 2>/dev/null || true

# --- Standard builds (for distribution / CI) ---

build:
	@mkdir -p build/Debug/$(APP_NAME).app/Contents/MacOS \
	          build/Debug/$(APP_NAME).app/Contents/Resources
	swiftc $(SWIFT_FLAGS) -Onone -g -o build/Debug/$(APP_NAME).app/Contents/MacOS/$(APP_NAME) $(SWIFT_FILES)
	@cp DockPeek/Info.plist build/Debug/$(APP_NAME).app/Contents/Info.plist
	@cp DockPeek/Resources/AppIcon.icns build/Debug/$(APP_NAME).app/Contents/Resources/AppIcon.icns
	@codesign --force --sign "$(SIGN_ID)" build/Debug/$(APP_NAME).app
	@echo "Built: build/Debug/$(APP_NAME).app"

release:
	@mkdir -p build/Release/$(APP_NAME).app/Contents/MacOS \
	          build/Release/$(APP_NAME).app/Contents/Resources
	swiftc $(SWIFT_FLAGS) -O -whole-module-optimization \
		-o build/Release/$(APP_NAME).app/Contents/MacOS/$(APP_NAME) $(SWIFT_FILES)
	@cp DockPeek/Info.plist build/Release/$(APP_NAME).app/Contents/Info.plist
	@cp DockPeek/Resources/AppIcon.icns build/Release/$(APP_NAME).app/Contents/Resources/AppIcon.icns
	@codesign --force --sign "$(SIGN_ID)" build/Release/$(APP_NAME).app
	@echo "Built: build/Release/$(APP_NAME).app"

run: build
	@xattr -cr build/Debug/$(APP_NAME).app
	open build/Debug/$(APP_NAME).app

dist: release
	cd build/Release && zip -r ../../$(APP_NAME).zip $(APP_NAME).app
	@echo "Created $(APP_NAME).zip"
	@shasum -a 256 $(APP_NAME).zip

install: release
	cp -R build/Release/$(APP_NAME).app /Applications/
	@xattr -cr /Applications/$(APP_NAME).app
	@echo "Installed to /Applications/$(APP_NAME).app"

clean:
	rm -rf build DerivedData DockPeek.xcodeproj $(APP_NAME).zip

# --- Xcode project (requires XcodeGen + Xcode.app) ---

generate:
	@command -v xcodegen >/dev/null 2>&1 || { echo "Install XcodeGen: brew install xcodegen"; exit 1; }
	xcodegen generate
	@echo "Generated DockPeek.xcodeproj"

open: generate
	open DockPeek.xcodeproj
