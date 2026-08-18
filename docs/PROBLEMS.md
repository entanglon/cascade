# Current Unresolved Problems

> Status: no open items. The one item tracked here (fullscreen player
> tiny-window) was fixed 2026-08-19 — see the resolution below. New problems
> get added to the top of this file.

## Fullscreen Player — Liquid Glass + True Fullscreen (2026-08-19 — RESOLVED)

### Problem Summary (original)

The video player's fullscreen mode needs two things that were in tension:

1. **Liquid glass on ALL controls** — volume slider, minimize, close, fullscreen toggle, transport buttons all need `.glassEffect(.regular.interactive())` to render properly
2. **True native macOS fullscreen** — the player window must open in its own macOS Space (like Apple TV / Netflix), not as a floating overlay on the main window

### Resolution — root cause + fix

**Root cause of the tiny window** (`Features/MPVVideoView.swift`,
`PlayerFullScreenWindow.present()`): `win.contentViewController = host`
(NSHostingController) lets Auto Layout collapse the window to the hosting
view's SwiftUI fitting size. Reproduced in a standalone harness: a window
created at `screen.frame` (1440×900) collapsed to **1×1 px** at the screen's
top-left the moment the controller was attached. The pre-rewrite code never
used `contentViewController` — it attached plain subviews with explicit frames
+ autoresizing masks and never had this bug.

**Fix**: keep the single SwiftUI render tree (video via `MPVLayerHost` +
controls in one `FullscreenPlayerRoot` — this is what makes `.glassEffect()`
work), but host it in a plain `NSHostingView` subview of a plain `NSView`
contentView instead of via `contentViewController`:

```swift
let hosting = NSHostingView(rootView: AnyView(root.environment(appState)))
let content = NSView()
win.contentView = content
hosting.frame = content.bounds
hosting.autoresizingMask = [.width, .height]
content.addSubview(hosting)
```

**Verified end-to-end** in a minimal .app bundle with the exact same window
setup (titled fake-borderless, hidden traffic lights, `[.fullScreenPrimary]`):
window created at `screen.frame` → clamped to the visible frame on orderFront
(menu bar + Dock — normal macOS behavior, not the bug) → `didBecomeKey` →
`toggleFullScreen` → **native Spaces fullscreen entered** (frame = full
screen, `styleMask.contains(.fullScreen)` true) → exit restored the window.

### What Works (unchanged)

- **Liquid glass works** with video + controls in one SwiftUI render tree
  (NSHostingView + `MPVLayerHost` + `PlayerControlsView` in a ZStack).
- **Native fullscreen works** with the titled fake-borderless NSWindow +
  `toggleFullScreen` on `didBecomeKey` (window is a standard titled window, so
  macOS allows the Space transition).

### Architecture (Current State in Code)

```swift
// Features/MPVVideoView.swift — PlayerFullScreenWindow.present()

let win = NSWindow(
    contentRect: screen.frame,
    styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
    backing: .buffered, defer: false
)
win.titleVisibility = .hidden
win.titlebarAppearsTransparent = true
win.collectionBehavior = [.fullScreenPrimary]
win.standardWindowButton(.closeButton)?.isHidden = true
// ... traffic lights hidden, dark appearance, EDR color space on HDR screens

// Video + controls in ONE SwiftUI tree, hosted as a plain subview
// (NOT contentViewController — that collapses the window to 1x1).
let root = FullscreenPlayerRoot(mpvView: player) { controls }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .environment(\.colorScheme, .dark)
let hosting = NSHostingView(rootView: AnyView(root.environment(appState)))
let content = NSView()
win.contentView = content
hosting.frame = content.bounds
hosting.autoresizingMask = [.width, .height]
content.addSubview(hosting)

win.makeKeyAndOrderFront(nil)
// toggleFullScreen via NSWindow.didBecomeKeyNotification (+ 0.2s fallback)
```

### Notes for the Future

- **Never use `contentViewController` on a manual NSWindow for SwiftUI content
  that must fill a specific frame** — Auto Layout collapses the window to the
  SwiftUI fitting size. Plain contentView + NSHostingView subview with
  autoresizingMask is the proven pattern in this codebase.
- The window is clamped to the visible frame (menu bar + Dock) before entering
  fullscreen — that is normal macOS behavior for titled windows, not a bug.
- ESC two-step exit, re-parenting of the mpv layer view, and the TheaterView
  "Playing in full-screen" placeholder are all unchanged and verified.

### Other Changes in the Same Changeset (2026-08-19)

- **TheaterView placeholder**: when fullscreen is active, the main window
  shows a "Playing in full-screen" placeholder instead of the broken video
  view. Uses `PlayerFullScreenWindow.shared.isActive`.
- **Stamp/bar vertical alignment fix**: `.frame(width: 76, height: 28,
  alignment: ...)` replaces `.frame(width: 76, alignment: ...).offset(y: -1.5)`
  in both `VideoPlaybackView.swift` and `TheaterView.swift`.
- **VideoPlaybackView gradient revert**: top/bottom gradient opacities
  restored to original values (0.6/0.8).

### Files Modified

| File | Change |
|---|---|
| `Features/MPVVideoView.swift` | `PlayerFullScreenWindow.present()`: hosting via plain contentView + NSHostingView subview (was `contentViewController`), which collapses the window to 1×1 |
| `Features/TheaterView.swift` | Fullscreen placeholder (unchanged this round) |
| `Features/VideoPlaybackView.swift` | Gradient opacity revert, stamp/bar alignment (unchanged this round) |