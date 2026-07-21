CONFIG ?= release
APP := dist/MeetRec.app
BIN = $(shell swift build -c $(CONFIG) --show-bin-path)/MeetRec

.PHONY: build app run clean

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

clean:
	rm -rf .build dist
