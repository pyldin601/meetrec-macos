# AGENTS.md

MeetRec — a macOS menu bar utility that records meeting audio. Being rebuilt
step by step on this branch; a complete reference implementation lives on the
`claude/macos-meeting-audio-recorder-7ro5zl` branch — use it for inspiration,
not wholesale copying.

## Build & verify

```sh
swift build     # typecheck / compile (SPM package)
make app        # assemble dist/MeetRec.app (SPM can't build bundles)
make run        # build, assemble, and launch the app
```

Requires macOS 14.4+ (CoreAudio process taps).

## Code style

Minimal code wins. Every line must be needed by behavior that exists *now*:

- Implement only what the current step needs; nothing speculative. Machinery
  arrives in the same commit as the feature that requires it, not before.
- Prefer the simplest representation that models today's states — e.g. an
  optional over an enum until there is a third state, direct UI refresh over
  Observation until state changes from outside the UI, a static menu over
  rebuild-on-open until the contents vary per open.
- Reuse system behavior over writing code: responder-chain actions instead of
  target/action plumbing, autoenabled menu items instead of manual enabling.
- Comments explain only non-obvious constraints (the "why"); never narrate
  what the code does.
- When simplifying, behavior must stay identical — verify with a build and a
  launch before calling it done.
