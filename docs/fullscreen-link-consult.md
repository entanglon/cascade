# Consult: share-link delivery exits a full-screen window — how should a macOS app handle it?

*Self-contained prompt for Claude / Qwen / any external model. No project access needed.*

---

## Problem

A macOS SwiftUI app (a cloud file manager whose video player runs its own mpv-based
engine, think Stremio-on-macOS) registers a custom URL scheme (`xcloud://share…`).
When the user opens one of those links from a browser while the app's window is in
**normal macOS full screen**, the window **goes invisible** — the user's exact
words: "the already active window went invisible. I have to then restart the app to
get the UI back." No video is involved: the user enters full screen the standard way
(fn+f, or the green traffic-light button), then opens a share link in Chrome, macOS
prompts "Open in xCloud?", the user confirms, and the app's full-screen window
vanishes — the app process keeps running, but there is no visible window until the
app is restarted. The share link itself IS delivered and processed correctly (the
import happens) — the problem is purely the window state. In **windowed** mode the
same link works perfectly (app activates, window comes forward, file revealed).

The user asks: "If it works in Stremio etc., why not in our app?" — Stremio's macOS
app brings its full-screen window forward (or switches to its Space) when its URL
scheme is opened, staying full screen.

## IMPORTANT: this is the PLAIN app window in standard macOS full screen

- The app has ONE window (a SwiftUI `Window` scene, never `WindowGroup`). "Full
  screen" = the user toggles the whole window full screen the standard way
  (fn+f / green traffic-light button / ⌃⌘F). The window fills the screen with the
  normal app UI (file browser, sidebar, etc.). NO video is playing in the reported
  case — the video player is irrelevant here, and no fix may depend on it.
- The reported symptom is severe: after confirming the browser prompt, the
  full-screen window is **gone** — the process is alive (TDLib keeps running, the
  link import completes) but there is **no visible window** until the user quits
  and relaunches the app.
- In our isolated tests (below) we measured the window being kicked out of full
  screen to a windowed frame; whether the "invisible" state in the user's
  environment is (a) the un-full-screened window stranded on the now-vacated
  full-screen Space (no `.moveToActiveSpace` to follow the user), or (b) the
  SwiftUI scene actually destroying/recreating the window invisibly, is an open
  question we'd like your help answering.

## App architecture (relevant facts)

- SwiftUI `@main` app, `NSApplicationDelegateAdaptor` for URL handling. The main
  scene is a **single `Window` scene** (deliberately NOT `WindowGroup` — a
  `WindowGroup` answers open-URL events by creating a NEW window each time, which
  spawned duplicate windows; `Window` can't duplicate and the OS reuses the one
  main window).
- `AppDelegate.application(_:open:)` receives `xcloud://…` URLs, queues the link for
  the SwiftUI state to import, and raises the existing window.
- There is exactly ONE window in the app (the `Window` scene's main window), which
  can be toggled into full screen (the player's "full screen" button calls
  `NSWindow.toggleFullScreen`).
- The app previously had multiple app bundles registered for the scheme (stale
  builds, DMG test copies); that's fixed — one registered copy, and the app now
  re-asserts scheme ownership on every launch via
  `NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:)`. A single-instance
  guard hands off to the running process if a duplicate is ever launched.

## Empirical findings (live-isolated on a MacBook Air M1, macOS 26)

We drove the window into full screen via Accessibility
(`AXFullScreen = true`, window becomes 1440×900 at 0,0 — confirmed via AX), then
delivered a link with `open "xcloud://share/test"`, and read the window state back
via AX. Results, across four code variants:

| Variant | What `application(_:open:)` → `raiseMainWindow()` did | After link delivery |
|---|---|---|
| v1 | `NSApp.activate` → detect full screen → remove `.moveToActiveSpace` → `makeKeyAndOrderFront` | EXITED full screen (windowed 1224×776 at 216,30) |
| v2 | detect full screen → remove flag → `NSApp.activate` → `makeKeyAndOrderFront` | EXITED full screen |
| v3 | detect full screen → remove flag → `NSApp.activate` only (no order-front) | EXITED full screen |
| v4 | detect full screen → remove flag only, NO activate, NO order-front, leave window alone | could not fully verify (test environment's AX access degraded) |

Also: `open -g "xcloud://…"` (delivers the URL WITHOUT activating the app —
LaunchServices skips its activation step) **also** exited full screen in the v1–v3
builds, which rules out LaunchServices' pre-activation as the trigger and points at
the app's own `NSApp.activate` call.

Key observations:

1. The URL delivery itself is fine — TDLib logs confirm the link is imported in
   every variant. The only casualty is window state.
2. ANY app-side `NSApp.activate(ignoringOtherApps: true)` and/or
   `makeKeyAndOrderFront(_:)` during delivery yanked the full-screen window out of
   full screen (windowed, moved to the current/active space — and with multiple
   Spaces it can strand off the user's view, which reads as "the window
   disappeared").
3. A user **Cmd-Tab** into the app preserves full screen and switches Spaces
   (normal macOS behavior) — so a *user-driven* activation does not exit full
   screen, while *programmatic* activation during URL delivery does.
4. The window ends up at a windowed frame (~1224×776), close to the scene's
   `defaultSize` (1280×780) — consistent with either (a) the full-screen window
   being un-full-screened and moved, or (b) the SwiftUI `Window` scene being
   torn down and recreated at default size.

## Current implementation (what v4 looks like)

```swift
func application(_ application: NSApplication, open urls: [URL]) {
    // queue the links for AppState, then:
    raiseMainWindow()
}

private func raiseMainWindow() {
    DispatchQueue.main.async {
        let window = NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.canBecomeKey && $0.isVisible && !$0.isSheet })
            ?? NSApp.windows.first(where: { $0.canBecomeKey && !$0.isSheet })

        if let window, window.styleMask.contains(.fullScreen) {
            // FULL SCREEN: leave the window COMPLETELY alone. The OS has already
            // activated the app while delivering the URL, and that activation
            // switches to the window's Space without exiting full screen
            // (Cmd-Tab semantics). ANY extra window work here breaks it —
            // verified live: NSApp.activate / makeKeyAndOrderFront pull a
            // full-screen window OUT of full screen so it can become key on the
            // current space.
            window.collectionBehavior.remove(.moveToActiveSpace)
            return
        }

        // Windowed: bring onto the ACTIVE screen, then order front.
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.collectionBehavior.insert(.moveToActiveSpace)
            rescueWindowOnScreen(window)   // recenters if the frame is off every screen
            window.makeKeyAndOrderFront(nil)
        } else {
            // no window at all → ask the SwiftUI scene to recreate it
        }
    }
}
```

Also in the window-chrome setup (an `NSViewRepresentable` inside the scene), the app
inserts `.moveToActiveSpace` into the window's `collectionBehavior` so a *windowed*
window follows the user across Spaces — and now removes it on
`willEnterFullScreen`/`didEnterFullScreen` and restores it on exit, because the
flag on a full-screen window also caused exits on activation.

## Questions for you

1. **What is the correct, reliable macOS pattern for bringing a full-screen window
   forward when a URL scheme is delivered?** i.e. how do apps like Stremio/IINA do
   it? Is "leave the window alone and rely on the OS's own activation to switch to
   its Space" the right call, or is there a specific API
   (`NSApp.activate`, `makeKeyAndOrderFront`, `NSWindowController.showWindow`,
   `orderFrontRegardless`, …) that is safe on full-screen windows?

2. **Why does user Cmd-Tab preserve full screen while programmatic
   `NSApp.activate(ignoringOtherApps: true)` during URL delivery exits it?** Is
   there a documented difference (e.g. the programmatic path requests "make my
   window key on the current space", and a full-screen window can't be key on a
   shared space, so the window server un-full-screens it)? If so, is the fix to
   never activate programmatically when the window is full screen (v4), or to
   activate differently?

3. **Could a SwiftUI `Window` scene itself be involved?** When AppKit delivers
   `application(_:open:)`, does SwiftUI's scene system also react (e.g. attempt to
   open/recreate the scene window at the scene's default size), independent of what
   the delegate does? The window ending near `defaultSize` after the delivery
   suggests possible scene recreation. If scenes can interfere, what's the
   recommended SwiftUI-side setup for a single-window URL-scheme app?

4. **If the OS still kicks the window out of full screen no matter what the app
   does** (activation semantics on this macOS), what's the cleanest recovery:
   detect "the window WAS full screen just before delivery" and call
   `toggleFullScreen` again after the dust settles? Is there a reliable way to know
   the pre-delivery full-screen state from inside `application(_:open:)`
   (e.g. an app-wide observer on `NSWindow.didExitFullScreenNotification` recording
   that a full-screen exit just happened during URL processing)? Any risks of
   fighting the user (e.g. re-entering full screen when the user intentionally
   exited)?

5. **Anything about the single-instance/handoff path we're missing?** When a stale
   registration makes the OS launch a SECOND instance, that duplicate writes the
   URL to a handoff file, posts a distributed notification, calls
   `other.activate(options: [.activateIgnoringOtherApps])` on the running instance,
   and exits. The running instance drains the file and (in v4) leaves a full-screen
   window alone. Is the duplicate's `.activateIgnoringOtherApps` also a
   full-screen-exit hazard (v1–v3 evidence says programmatic activation is), and
   should the duplicate skip activation entirely and let the running instance
   handle everything?

Please give a concrete recommended implementation (Swift) for the full-screen case,
with reasoning, and flag anything in our current approach that is wrong or risky.
