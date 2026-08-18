# Current Unresolved Problems

> Status: no open items. The fullscreen-player item tracked here was resolved
> 2026-08-19 (see below). New problems get added to the top of this file.

## Fullscreen Player — Liquid Glass + True Fullscreen (2026-08-19 — RESOLVED)

### Problem Summary (original)

The video player's fullscreen mode needs two things that were in tension:

1. **Liquid glass on ALL controls** — volume slider, minimize, close, fullscreen toggle, transport buttons all need `.glassEffect(.regular.interactive())` to render properly
2. **True native macOS fullscreen** — the player window must open in its own macOS Space (like Apple TV / Netflix), not as a floating overlay on the main window

### History of attempts (what DIDN'T work)

| Attempt | Result |
|---|---|
| Manual `.borderless` NSWindow (pre-2026-08-19) | Window full-screen-sized but glass flat (no blur); no native Spaces fullscreen |
| Manual "fake borderless" NSWindow (`.titled + .resizable + .fullSizeContentView`, c425e14) | Window collapsed to ~200×100 px at top-left — **root cause: `contentViewController` Auto Layout collapse** (reproduced as 1×1 px in a harness) |
| That + plain contentView + NSHostingView subview (84236ff) | Window sized correctly, but the fullscreen window still died instantly — **root cause #2: the TheaterView placeholder SWAPPED the player out; unmounting dismantled the mpv NSViewController → teardown() → `PlayerFullScreenWindow.shared.dismiss()` (MPVVideoView.swift:787) → the fullscreen window killed itself the moment it appeared, and the mpv teardown/rebuild blacked out the main window** |
| **SwiftUI `Window` scene (2026-08-19, current)** | **WORKS.** System-managed window: correct sizing, native Spaces fullscreen, glass in the scene environment |

### Current Architecture (what works)

- `App/xCloudApp.swift`: `Window("Fullscreen Player", id: "fullscreenPlayer")`
  scene, `.windowStyle(.hiddenTitleBar)`, `.defaultSize(1280×800)` — the same
  pattern the flux app uses for its player window. `FullscreenWindowLink` (an
  invisible view in the MAIN window) binds `openWindow`/`dismissWindow` into
  `PlayerFullScreenWindow` so plain AppKit code can open/close the scene.
- `Features/MPVVideoView.swift`: `PlayerFullScreenWindow` is session-based
  (Session: player/mpv/title/subtitle/appState). `present()` re-parents the
  live `MPVLayerView` into the scene (playback continues uninterrupted; the
  SAME layer is used, never recreated) and opens the window.
  `FullscreenPlayerSceneView` renders video + controls in ONE SwiftUI tree
  (`.glassEffect()` works). `FullscreenWindowConfigurator`
  (NSViewRepresentable) sets dark appearance, `.fullScreenPrimary`, the EDR
  color space, and auto-enters native fullscreen on `didBecomeKey` (guarded —
  toggles once; the controls' fullscreen button is the manual fallback).
  `dismiss()` closes the scene; `sceneDidDisappear` (the scene content's
  onDisappear) also covers out-of-band closes (Cmd+W) and `completeDismissal`
  re-parents the mpv layer back to the theater.
- `Features/TheaterView.swift`: the "Playing in full-screen" placeholder is an
  OPAQUE OVERLAY on top of the still-mounted player (ZStack), never a swap —
  unmounting the player tears down mpv and kills the fullscreen window.

### Notes for the Future

- **Never hand-roll an NSWindow for the player.** Scene windows get sizing,
  fullscreen, and rendering environment from the system. This codebase burned
  three rounds on manual windows (flat glass, tiny window, self-kill).
- **Never swap out the theater's player view while the fullscreen window is
  up** — dismantling it triggers mpv teardown, which calls
  `PlayerFullScreenWindow.shared.dismiss()`.
- The window is clamped to the visible frame (menu bar + Dock) before entering
  fullscreen — normal macOS behavior for titled windows, not a bug.
- ESC two-step exit and the controls overlay are unchanged and verified.

### Files Modified (resolution)

| File | Change |
|---|---|
| `App/xCloudApp.swift` | `"fullscreenPlayer"` Window scene + `FullscreenWindowLink` binding |
| `Features/MPVVideoView.swift` | `PlayerFullScreenWindow` session-based scene driver; `FullscreenPlayerSceneView`, `FullscreenWindowConfigurator`, `FullscreenWindowLink` |
| `Features/TheaterView.swift` | Placeholder = opaque overlay, player stays mounted |
| `Features/VideoPlaybackView.swift` | Unchanged this round |