# TwinTake: notes for contributors and coding agents

TwinTake is a native macOS menu-bar app (Swift 6, SwiftPM, macOS 15+) that records a capture card
and a screen frame into separate `.mov` files per take. See [README.md](README.md),
[docs/guide.md](docs/guide.md) and the session folder contract in [docs/SCHEMA.md](docs/SCHEMA.md).

## Commands

```bash
swift build                       # all modules
swift test                        # unit tests (no devices, no permissions)
scripts/build-app.sh [release]    # signed build/TwinTake.app
scripts/install.sh                # release build installed in /Applications
scripts/render-docs-images.sh     # docs/images/*.png from the app's own views (offscreen)
swift scripts/make-icon.swift     # App/Icon/AppIcon.svg -> App/AppIcon.icns
swift scripts/make-banner.swift   # docs/images/logo.svg -> README banner
```

## Modules

`RecorderCore` (models, session folder, event log, mic detector) · `MediaWriter` (shared
AVAssetWriter pieces) · `CameraCapture` · `ScreenCapture` · `WindowTools` (snapping, overlay,
hotkeys, geometry) · `Replay` (read-only playback of growing files) · `RecorderApp` (UI and the
session coordinator).

## Rules learned the hard way

1. **Tests and agents never open devices.** No camera, microphone or screen capture, and no
   permission requests, in tests or scripted runs: they pop macOS dialogs. Device behaviour is
   checked by hand with the steps in [docs/TESTING.md](docs/TESTING.md).
2. **Thread rule.** The main thread never touches `AVCaptureSession`, its inputs, outputs,
   connections, devices or an attached preview layer, and never blocks on a capture queue.
   AVFoundation can wait on the main thread while holding the session lock (`stopRunning` with a
   file output), so any main-thread call into the session can deadlock.
   `Tests/RecorderAppTests/ThreadRuleTests.swift` enforces this; keep it passing.
3. **No closures in a `Mutex` tuple.** A closure stored inside a `Synchronization.Mutex` generic
   tuple gains a reabstraction thunk on every write across a module boundary in debug builds, and
   the chain later overflows the stack. Keep closures in a named struct field or a class box
   (see `PictureCheck.HandlerBox` in `EmptyFrames.swift`).
4. **Recording first.** Nothing may slow, block or alter the writers during a take: UI and replay
   work run off the capture queues, replay only reads files.
5. **Exact frame rates.** Store rates as rationals (`24000/1001`, never `24` or `23.976`); the
   writers place frames on that exact grid following real arrival time.
6. **TwinTake's own windows stay out of recordings** (`sharingType = .none` plus self-exclusion
   in the screen filter) and never take focus from the recorded app.
7. **Keep colors as captured.** Don't change pixel formats or color tags without a device test.
8. **C callbacks are file-scope functions.** A closure literal passed as a C callback inside a
   `@MainActor` type inherits the main actor; Swift then checks the thread on every call and traps
   when the callback runs elsewhere (the event tap's thread did, and a take ended). Pass a
   file-scope function (see `keyTapCallback` in `KeyEventTap.swift`) and test it from a plain thread.

## Conventions

- New behaviour gets unit tests for its pure logic and a device check in docs/TESTING.md.
- Changes to the session folder are additive within the major schema version; update docs/SCHEMA.md.
- Keep docs short and plain; update README.md/docs when behaviour changes.
