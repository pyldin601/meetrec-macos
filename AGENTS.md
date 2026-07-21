# AGENTS.md

## Product spec

User-facing behavior — audio sources, the menu bar UI, file naming, recording
lifecycle, permissions — is defined in **[SPEC.md](SPEC.md)**. Read it before
changing behavior, and update it in the same commit when behavior is
intentionally changed.

## Build & verify

```sh
swift build     # typecheck / compile (SPM package)
make app        # assemble dist/MeetRec.app (SPM can't build bundles)
make run        # build, assemble, and launch the app
```

Requires macOS 14.4+ (CoreAudio process taps). CI builds the bundle on every
push. README.md covers permissions and signing details.
