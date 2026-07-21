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

# Dev loop: run the bundled app attached to the terminal with the process's
# unified-log output (os.Logger doesn't reach stdout) streaming alongside.
# ⌃C — or quitting the app from its menu — stops both.
dev: app
	@echo "→ running $(APP) with live logs (⌃C or Quit MeetRec stops both)"
	@log stream --level debug --style compact --predicate 'process == "MeetRec"' & \
	LOG_PID=$$!; \
	trap "kill $$LOG_PID 2>/dev/null" EXIT; \
	$(APP)/Contents/MacOS/MeetRec

clean:
	rm -rf .build dist
