# MeetRec

A native macOS **menu bar** app that records meeting audio from two sides at once:

- **System audio** — the whole system output mix (excluding MeetRec itself), captured with
  **CoreAudio process taps** (the same audio-only mechanism used by meeting recorders like
  Granola — no Screen Recording permission involved).
- **Microphone** — a selected input device, captured raw (no voice processing) with
  **AVAudioEngine**.

There are no windows and no Dock icon: the entire UI is a status item in the menu bar — a
record icon while idle, a stop icon plus the elapsed time while recording — with a menu to
start/stop the recording, pick the sources (System Audio: All Apps or None; Microphone: any
connected input device or None), and quit.

Each recording session writes separate AAC files into `~/MeetRecRecordings`, sharing one
CLI-friendly digits-only timestamp prefix:

```
20260721143005-system.m4a   (48 kHz stereo, 160 kbps)
20260721143005-mic.m4a      (48 kHz, mono 96 kbps or stereo 160 kbps, matching the device)
```

Either source alone is enough to record — only the selected sources produce files.

## Requirements

- macOS 14.4 (Sonoma) or newer — CoreAudio process taps require it
- Xcode command-line tools with a Swift 5.9+ toolchain

## Build & run

The project is a plain Swift package; a small Makefile assembles the `.app` bundle
(Swift PM cannot produce bundles by itself):

```sh
make run        # build release, assemble dist/MeetRec.app, and open it
make app        # just build + assemble the bundle
make CONFIG=debug app
swift run       # dev loop without the bundle (works; the Info.plist is embedded in the binary)
```

Xcode users can open `Package.swift` directly.

## Permissions

MeetRec needs two permissions, both requested with a normal allow-dialog on first use —
**no Screen Recording access and no relaunch dance**:

- **Microphone** — prompted the first time you record with a mic selected.
- **System Audio Recording Only** — prompted the first time you record app/system audio
  (macOS files this under System Settings › Privacy & Security › *Screen & System Audio
  Recording*, but it grants audio capture only — MeetRec can never see your screen).

The app is ad-hoc signed (`codesign --sign -`), so the code-signing identity changes across
rebuilds and macOS may occasionally re-ask for these permissions after you rebuild.

## Behavior details

- **System audio** — the menu offers **All Apps** or **None**. The capture engine supports
  per-app process taps, but per-app selection is deliberately not exposed in the menu
  (see [SPEC.md](SPEC.md) §6).
- **Microphone** — the submenu lists the currently connected input devices and refreshes as
  they come and go. It defaults to the system default input; the selection resets to None
  when the selected device disappears while idle. The submenu stays enabled while
  recording: picking another device (or None) switches mic capture mid-session into a new
  `-mic-HHMMSS.m4a` segment file (named by its offset from the session start).
- **Mic failover** — if the mic dies mid-recording, MeetRec silently restarts capture on
  another input (the same device if it recovers, else the system default, else any input)
  as a new segment file. With no replacement available the session continues on system
  audio alone and the mic auto-resumes when an input device reappears; only when the mic
  was the only source does the session stop.
- **Stop conditions** — choosing Stop Recording, quitting the app, or losing the only
  active source with no replacement all stop the whole session and finalize every file;
  partial recordings are always kept.
- Quitting the app during a recording finalizes the files first.
- Failures (capture start failure, denied permission, a source dying mid-recording) surface
  as standard alerts; permission errors offer a button opening the relevant System Settings
  pane.
- While recording, the system is kept from idle-sleeping (`ProcessInfo.beginActivity`).
- Files are written as streaming AAC; if the app dies mid-recording the file may be missing
  its header. Stop recordings normally.

## Optional: hardened runtime

`Support/MeetRec.entitlements` (microphone entitlement) is included for anyone who wants to
sign with a real Developer ID and hardened runtime:

```sh
codesign --force --options runtime --entitlements Support/MeetRec.entitlements \
  --sign "Developer ID Application: …" dist/MeetRec.app
```

## CI

Every push builds the app bundle on a macOS GitHub Actions runner and uploads
`MeetRec.app.zip` as a workflow artifact.
