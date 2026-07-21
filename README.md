# MeetRec

A native macOS app that records meeting audio from two sides at once:

- **App / system audio** — the sound produced by a selected running application, or the whole
  system mix, captured with **CoreAudio process taps** (the same audio-only mechanism used by
  meeting recorders like Granola — no Screen Recording permission involved).
- **Microphone** — a selected input device, captured raw (no voice processing) with
  **AVAudioEngine**.

Each recording session writes separate AAC files into `~/MeetRecRecordings`, sharing one
CLI-friendly digits-only timestamp prefix:

```
20260721143005-app.m4a      (48 kHz stereo, 160 kbps; "-system" when capturing the system mix)
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

- **Source list** — the app dropdown shows applications that are registered with CoreAudio,
  which means apps that have played (or captured) audio at some point since launch. An app
  that hasn't touched audio yet won't be listed; pick **System audio (all apps)** to capture
  everything regardless (MeetRec's own audio is excluded).
- **Stop conditions** — pressing Stop, the captured app quitting, or the microphone
  disconnecting all stop the whole session and finalize every file; partial recordings are
  always kept.
- Quitting the app (or closing its window) during a recording finalizes the files first.
- While recording, the system is kept from idle-sleeping (`ProcessInfo.beginActivity`).
- Audio capture is per-process on macOS — there is no per-window audio, which is why the
  picker selects applications rather than windows.
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
