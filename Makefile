CONFIG ?= release
APP := dist/MeetRec.app
BIN = $(shell swift build -c $(CONFIG) --show-bin-path)/MeetRec

.PHONY: build app run dev clean

build:
	swift build -c $(CONFIG)

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp "$(BIN)" $(APP)/Contents/MacOS/MeetRec
	cp Support/Info.plist $(APP)/Contents/Info.plist
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

clean:
	rm -rf .build dist
