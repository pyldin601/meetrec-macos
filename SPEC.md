# MeetRec — Product Specification

MeetRec is a macOS menu bar utility that records meeting audio from up to two
sources at once — the system audio mix and a microphone — into separate files.
It has **no window interface**: the entire UI is a status item (icon + menu) in
the macOS menu bar.

This document is the source of truth for user-facing behavior. Change it in the
same commit as any intentional behavior change.

## 1. Audio sources

### 1.1 System audio

- Two possible selections: **None** (off) or **All apps** — the whole system
  output mix.
- Captured with **CoreAudio process taps** (audio only, no Screen Recording
  permission; taps exist since macOS 14.2, the app requires 14.4 to avoid
  early tap bugs). MeetRec's own audio output is excluded from the capture.
- Default selection: **None**.

### 1.2 Microphone

- Selections: **None** (off) or exactly one input device from the list of
  currently connected input devices.
- Captured raw (no voice processing / AGC) with AVAudioEngine.
- Default selection at launch: the system default input device; **None** if no
  input device is connected (the submenu then contains only None). The
  selection is not persisted across launches.
- The device list refreshes automatically when devices are connected or
  disconnected. Whenever the app is idle and the selected device is absent,
  the selection resets to **None** — including right after a
  disconnect-triggered stop (see §3.2).

### 1.3 Source rules

- Recording requires at least one source ≠ None; with both set to None,
  starting a recording is unavailable.
- Either source alone is enough — only selected sources produce files.
- Source selections cannot be changed while a recording is in progress.

## 2. User interface

### 2.1 App shape

- **No windows, no Dock icon** (`LSUIElement` accessory app). The only UI is a
  status item in the menu bar and standard system dialogs (permission prompts,
  error alerts).

### 2.2 Status item icon

- **Idle (default):** a "record" icon (e.g. `record.circle`).
- **While recording:** a **stop icon** plus the **elapsed time**, updating
  every second, in monospaced digits (`M:SS` growing to `H:MM:SS`).
- Clicking the status item always opens the menu (it never toggles recording
  directly).

### 2.3 Menu

Top to bottom:

| Item | Behavior |
|---|---|
| **Start Recording** / **Stop Recording** | Single item whose title and action follow state. Disabled when idle with no source selected. |
| ─ separator ─ | |
| **System Audio ▸** | Submenu: **All Apps**, **None**. Checkmark on the current selection. Disabled while recording. |
| **Microphone ▸** | Submenu: one entry per connected input device, then **None**. Checkmark on the current selection. Disabled while recording. |
| ─ separator ─ | |
| **Quit MeetRec** | Exits the app. If a recording is running, it is stopped and its files finalized first. |

## 3. Recording behavior

### 3.1 Output files

- Directory: `~/MeetRecRecordings` (created on demand).
- Each session shares one CLI-friendly, digits-only timestamp prefix
  (`yyyyMMddHHmmss`), one file per active source:
  - `20260721143005-system.m4a` — system mix, AAC 48 kHz stereo 160 kbps
  - `20260721143005-mic.m4a` — microphone, AAC 48 kHz; mono 96 kbps or stereo
    160 kbps, matching the device's channel count
- Files are written as streaming AAC while recording (no post-processing step).

### 3.2 Session lifecycle

- **Start:** requests any missing permission, then starts all selected
  captures; if any capture fails to start, the whole session is rolled back
  and empty files are discarded.
- **Stop conditions** — any of these stops the *whole* session and finalizes
  every file: the user chooses Stop Recording, the selected microphone
  disconnects or changes configuration (its engine stops rendering), or the
  app quits. Partial recordings are always kept. After a disconnect-triggered
  stop the microphone selection resets to **None**.
- While recording, system idle sleep is suppressed
  (`ProcessInfo.beginActivity`).

### 3.3 Errors

- With no window, failures (capture start failure, denied permission, source
  died mid-recording) are surfaced with a standard alert. Permission errors
  offer a button opening the relevant System Settings pane.

## 4. Permissions

Both are normal allow-dialogs on first use — no Screen Recording access, no
relaunch:

- **Microphone** — prompted the first time a recording starts with a mic
  selected.
- **System Audio Recording Only** — prompted the first time a recording starts
  with system audio selected (listed under System Settings › Privacy &
  Security › *Screen & System Audio Recording*, but grants audio only).

## 5. Platform & distribution

- macOS 14.4 (Sonoma) or newer; Swift 5.9+, Swift Package Manager.
- The Makefile assembles `dist/MeetRec.app` (`make app` / `make run`);
  `swift run` works for the dev loop. Ad-hoc signed by default.
- CI builds and uploads `MeetRec.app.zip` on every push.

## 6. Non-goals

- **Per-app capture selection.** The capture engine supports per-process taps,
  but the menu deliberately exposes only All Apps / None.
- No pause/resume, no playback, no transcription, no editing.
- No windows, preferences panel, or onboarding UI.
