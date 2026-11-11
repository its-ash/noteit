APP := build/NoteIt.app
BIN := .build/release/NoteIt
ICON := logo.svg
VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
ZIP := build/NoteIt-$(VERSION)-macos.zip
# A stable signing identity keeps Keychain access across rebuilds; without one the build is ad-hoc signed.
SIGN ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Router Local|Apple Development|Developer ID Application/ { print $$2; exit }')

.PHONY: run build zip swift-test

run: build
	@pkill -x NoteIt || true
	open $(APP)

build:
	swift build -c release
	rm -rf $(APP) build/AppIcon.iconset
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources build/AppIcon.iconset
	cp $(BIN) $(APP)/Contents/MacOS/NoteIt
	cp Info.plist $(APP)/Contents/Info.plist
	for s in 16 32 128 256 512; do \
		rsvg-convert -w $$s -h $$s $(ICON) -o build/AppIcon.iconset/icon_$${s}x$${s}.png; \
		rsvg-convert -w $$((s * 2)) -h $$((s * 2)) $(ICON) -o build/AppIcon.iconset/icon_$${s}x$${s}@2x.png; \
	done
	iconutil -c icns build/AppIcon.iconset -o $(APP)/Contents/Resources/AppIcon.icns
	codesign --force --options runtime --sign "$(or $(SIGN),-)" $(APP)

# Release archive in the layout the homebrew-tap cask expects.
zip: build
	rm -f $(ZIP)
	cd build && ditto -c -k --keepParent NoteIt.app $(notdir $(ZIP))
	shasum -a 256 $(ZIP)

swift-test:
	swift test
