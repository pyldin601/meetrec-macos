# MeetRec

A native macOS app that records meeting audio from two sides at once:

- **App / window audio** — the sound produced by a selected running application or a selected
  window, captured with **ScreenCaptureKit**.
- **Microphone** — a selected input device, captured raw (no voice processing) with
  **AVAudioEngine**.

Each recording session writes separate AAC files into `~/MeetRecRecordings`, sharing one
timestamp prefix:

```
2026-07-21 14.30.05 - app.m4a   (48 kHz stereo, 160 kbps)
2026-07-21 14.30.05 - mic.m4a   (48 kHz, mono 96 kbps or stereo 160 kbps, matching the device)
```

Either source alone is enough to record — only the selected sources produce files.

## Requirements

- macOS 14 (Sonoma) or newer
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

MeetRec needs two permissions, requested on first use:

- **Microphone** — prompted the first time you record with a mic selected.
- **Screen Recording** — required by ScreenCaptureKit to list and capture apps/windows
  (macOS has no audio-only permission for this API). macOS requires you to enable the app in
  **System Settings › Privacy & Security › Screen Recording** and then **relaunch the app** —
  the grant does not take effect in a running process. On macOS 15+ the system periodically
  re-confirms this permission with a banner; that is expected.

The app is ad-hoc signed (`codesign --sign -`), so the code-signing identity changes across
rebuilds and macOS may occasionally re-ask for these permissions after you rebuild.

## Behavior details

- **Stop conditions** — pressing Stop, the captured app quitting, the captured window closing,
  or the microphone disconnecting all stop the whole session and finalize every file; partial
  recordings are always kept.
- Quitting the app (or closing its window) during a recording finalizes the files first.
- While recording, the system is kept from idle-sleeping (`ProcessInfo.beginActivity`).
- MeetRec's own sounds are excluded from app-audio capture
  (`excludesCurrentProcessAudio`).
- In window mode, ScreenCaptureKit delivers the audio of the window's owning application —
  per-window audio separation does not exist on macOS.
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
