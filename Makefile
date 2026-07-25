CONFIG ?= release
ARCH ?= $(shell uname -m)
APP := dist/MeetRec-$(ARCH).app
BIN = $(shell swift build -c $(CONFIG) --arch $(ARCH) --show-bin-path)/MeetRec

APP_ICON_PNG := Sources/MeetRec/Resources/AppIcon.png
APP_ICON_ICNS := Sources/MeetRec/Resources/AppIcon.icns

.PHONY: build app run dev icns clean

build:
	swift build -c $(CONFIG) --arch $(ARCH)

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp "$(BIN)" $(APP)/Contents/MacOS/MeetRec
	cp Support/Info.plist $(APP)/Contents/Info.plist
	cp $(APP_ICON_ICNS) $(APP)/Contents/Resources/AppIcon.icns
	printf 'APPL????' > $(APP)/Contents/PkgInfo
	codesign --force --sign - $(APP)
	@echo "Built $(APP)"

run: app
	open $(APP)

# Dev loop: run the app binary directly (not via `open`) so it stays
# attached to the terminal and its stderr shows up live. ⌃C, or Quit
# MeetRec from the menu, stops it.
dev: app
	$(APP)/Contents/MacOS/MeetRec

# Regenerate AppIcon.icns from the 1024×1024 PNG source.
icns:
	rm -rf AppIcon.iconset
	mkdir AppIcon.iconset
	sips -z 16 16     $(APP_ICON_PNG) --out AppIcon.iconset/icon_16x16.png
	sips -z 32 32     $(APP_ICON_PNG) --out AppIcon.iconset/icon_16x16@2x.png
	sips -z 32 32     $(APP_ICON_PNG) --out AppIcon.iconset/icon_32x32.png
	sips -z 64 64     $(APP_ICON_PNG) --out AppIcon.iconset/icon_32x32@2x.png
	sips -z 128 128   $(APP_ICON_PNG) --out AppIcon.iconset/icon_128x128.png
	sips -z 256 256   $(APP_ICON_PNG) --out AppIcon.iconset/icon_128x128@2x.png
	sips -z 256 256   $(APP_ICON_PNG) --out AppIcon.iconset/icon_256x256.png
	sips -z 512 512   $(APP_ICON_PNG) --out AppIcon.iconset/icon_256x256@2x.png
	sips -z 512 512   $(APP_ICON_PNG) --out AppIcon.iconset/icon_512x512.png
	cp $(APP_ICON_PNG) AppIcon.iconset/icon_512x512@2x.png
	iconutil -c icns AppIcon.iconset -o $(APP_ICON_ICNS)
	rm -r AppIcon.iconset

clean:
	rm -rf .build dist
