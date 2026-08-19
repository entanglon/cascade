# Cascade — Development Journal

>> Chronological log of the work on the Cascade macOS app. Companion to
> HANDOVER.md (current state) and ROADMAP.md (deferred plans). Last entry:
> 2026-08-20 (night) — Public/icon.png optimized and applied as macOS AppIcon.

---

## 2026-08-20 (night) — Public/icon.png optimized and applied as macOS AppIcon

The user supplied a cropped 1238×1238 `Public/icon.png` (eliminating the 8 px border padding from the previous 1254×1254 master) to be optimized, used as the app icon, built, and restarted.

### Changes

- Losslessly optimized `Public/icon.png` compression (reduced from 1.71 MB to 1.41 MB, ~17.3% smaller) and synchronized to the root `icon.png` master.
- Regenerated all 10 required macOS asset catalog renditions in `xCloud/Assets.xcassets/AppIcon.appiconset/` using high-fidelity Lanczos resampling with max PNG compression across all scales (16×16, 32×32, 64×64, 128×128, 256×256, 512×512, and 1024×1024).
- Rebuilt Debug application (`Cascade.app`).
- Terminated running processes and relaunched `Cascade.app`.

### Build / test

- Build green (Debug).
- Full test suite **TEST SUCCEEDED** (64 tests: 56 unit + 4 UI + 4 launch, 0 failures).
- App running as `Cascade.app`. **No Release build** — user policy.

---

## 2026-08-20 — Revised Cascade icon adopted

The first Cascade icon correction was technically tightly cropped but still looked visually undersized in macOS. The user supplied a revised `Public/icon-new.png` with the three-step mark enlarged and an edge-to-edge rounded background.

### Changes

- Preserved the supplied 1254×1254 composition exactly (no additional crop), copied it to the canonical `Public/icon.png`, and kept `Public/icon-new.png` as the committed supplied original.
- Regenerated all ten macOS asset-catalog renditions in `xCloud/Assets.xcassets/AppIcon.appiconset/`, from 16×16 through 1024×1024.

### Verification

- Inspected 1024 px and 64 px outputs: the larger mark stays clear at small size and the background reaches the canvas edge.
- Debug build **SUCCEEDED**, including `actool` asset-catalog compilation. Stopped the previous Debug process and launched the newly built `Cascade.app`. No Release build — user policy.

Commit: `15ce81c` — `Use revised Cascade app icon`.

---

## 2026-08-19 (late) — Cascade app icon framing corrected

The installed `AppIcon` set still contained the older blue cloud image, while the intended dark Cascade mark was present in `Public/icon.png` but carried excess black canvas around its rounded silhouette.

### Changes

- Cropped `Public/icon.png` from 1254×1254 to a centered 1168×1168 master: the mark now fills the icon canvas while retaining an 8 px-equivalent safety margin around the outer edge and shadow.
- Regenerated all ten required macOS app-icon renditions in `xCloud/Assets.xcassets/AppIcon.appiconset/` from that master (16 through 1024 px). The assets now consistently use the dark Cascade mark at every scale.

### Verification

- Inspected the 1024 px and 64 px variants visually; the rounded silhouette is not clipped and the three-step mark remains recognizable at small sizes.
- Debug build succeeded, including asset-catalog compilation. No Release build — user policy.

Commit: `ab77457` — `Fix Cascade app icon framing`.

---

## 2026-08-19 (late) — Cascade rename (product + bundle ID), login simplification, icon crop

Renamed the app from xCloud to Cascade. This was a follow-up to commit `6226354` ("Rename xCloud → Cascade across the entire project").

### Changes

- `xCloud.xcodeproj/project.pbxproj`: `PRODUCT_NAME = Cascade` on app targets (Debug + Release), `PRODUCT_MODULE_NAME = xCloud` to keep the Swift module stable (existing `@testable import xCloud` in tests still works), `PBXFileReference` + `TEST_HOST` updated from `xCloud.app` → `Cascade.app`, test/UI test targets kept `$(TARGET_NAME)` to avoid swiftmodule collisions.
- `Features/TelegramSetupView.swift`: removed the "API Credentials" heading from the login form (kept the instruction text "Get your API ID and API Hash from my.telegram.org").
- `xCloud/Assets.xcassets/AppIcon.appiconset/`: regenerated all 10 icon sizes from the 1254×1254 source (`icon.png`) after cropping ~7-15px dark padding via content-bounds detection. Icon border gap remains slightly imperfect — user to finalize manually.

### Build / test

Build green (Debug). Full test suite **TEST SUCCEEDED** (0 failures). App launches as `Cascade.app` with bundle id `com.cascade.app` (dev) / `com.cascade.app.prod` (release).

### Known: the folder is still `xCloud`

The project folder on disk is still `~/Projects/xCloud`. The user plans to rename it manually in a fresh session after committing this work.

---

## 2026-08-19 (night) — Share archiving (hide without revoking)

Public shares never expire, so the Shared page accumulates cards forever. Added an archive mechanism: hide share cards from the UI without revoking the link (the share stays live in the channel).

### Changes

- `Storage/Models.swift`: `ShareRecord.isArchived: Bool = false` (v25).
- `Storage/DatabaseManager.swift`: migration `v25-share-archive` adds `shares.isArchived` column; `archiveShare(id:)` / `unarchiveShare(id:)` methods.
- `App/AppState.swift`: `activeOutgoingShares` excludes archived; `archivedOutgoingShares` computed property; `archiveShare(_:)` / `unarchiveShare(_:)` methods.
- `Features/ShareManagerView.swift`: header toggle (Active / Archived), context menu gains Archive / Unarchive action, empty state adapts.
- `xCloudTests/xCloudTests.swift`: `archiveShareHidesFromActiveList` — archive hides, unarchive restores, persists.

Build green; full suite **TEST SUCCEEDED** (56 unit + 4 UI + 4 launch, 0 failures). **No Release build** — user policy.

---

## 2026-08-19 (night) — Reverted: 24h TTL restored + launch heal added

The previous commit (8920745) mistakenly removed the 24h server-side TTL (auto-delete) from private share channels. The user clarified this was an intentional feature: private share messages should auto-delete from Telegram after 24 hours as a lifecycle/security mechanism — the share link expires and the channel messages vanish, even if the app never runs again.

### Changes reverted

- `TelegramClient.swift`: restored `ttlSeconds: Int = 86400` default (was 0); restored original doc comment.
- `Engine/ShareEngine.swift`: restored `setMessageAutoDelete(chatId:)` calls in all 3 `allocatePrivateChannel` paths (reuse, rejoin, adopt) + `createPoolChannel` (private only). Removed old `disableAutoDeleteOnPoolChannels()` heal. Added new `ensureTTLOnPrivatePoolChannels()` heal.
- `App/AppState.swift`: replaced `disableAutoDeleteOnPoolChannels()` call with `ensureTTLOnPrivatePoolChannels()` in post-auth block.

### New heal: `ensureTTLOnPrivatePoolChannels()`

Iterates all recorded pool channels and calls `setMessageAutoDelete` (86400) on every PRIVATE slot. Idempotent — catches channels whose TTL was previously cleared (e.g. by the mistaken heal) or never set. Public channel never touched. Wired into post-auth next to `healChannelPhotos`.

### Verification

Build green; full suite **TEST SUCCEEDED** (55 unit + 4 UI + 4 launch, 0 failures). Relaunched; Telegram PC1 confirms "Messages will be automatically deleted after 1 day" restored. Server-side enforcement confirmed — messages auto-delete even if the app never runs. **No Release build** — user policy.

---

## 2026-08-19 (night) — Private share "file not in any channel" diagnosis + 24h server-side TTL removed

User reported private shares break: card appears in Shared page, but the file isn't in any private share channel; Telegram shows no channels. Long evidence-gathering session; conclusions:

- **The share flow works.** Headless repro (`--create-share` + `--import-share` debug hooks in App/AppState.swift:537-588) forwarded a fresh file into PC3 (`-1004464188620`), **rejoining the previously-LEFT slot via its permanent invite** (the left-channel reuse concern is handled — `allocatePrivateChannel` second pass). Record `8451B411` minted, link produced, recipient import SUCCEEDED.
- **Channels are invisible to the user because every pool channel (PC1-PC5) and the public channel are ARCHIVED** (`chatListArchive` in the TDLib dump — `createPoolChannel` calls `archiveVaultChannel`, TelegramClient.swift:750) — Telegram's chat list shows none of them. Server state confirmed the files ARE in PC1/PC2 (message id 5242880, posted 08-18 13:46/17:12 UTC) with `message_auto_delete_time = 86400` (24h TTL set by the 08-18 "1-day shares + TTL" round) — TTL deletion was due 08-19 19:16/22:42 IST.
- **No new DB record existed for the user's latest test** — sharing the same file again reuses the live link (no re-forward); the card they saw was the existing record, still "active" until the 6h/launch cleanup.
- A 17:55 IST burst of `updateSupergroup` → `chatMemberStatusBanned` covered only OLD revoked channels (08-17 debug+release era), NOT PC1/PC2 — the app had not left the active channels.

### Change (user decision: "Remove TTL")

- Removed the 24h `setMessageAutoDelete(86400)` calls from `allocatePrivateChannel` (first pass, rejoin, adopt) and `createPoolChannel` (Engine/ShareEngine.swift) — share messages now persist until the app revokes them at expiry.
- Added `ShareEngine.disableAutoDeleteOnPoolChannels()` — idempotent launch heal that sets TTL=0 on every recorded pool channel (`allShareChannels()`), clearing the legacy TTL already applied server-side to PC1-PC5. Wired into the post-auth heal block (App/AppState.swift:766, next to `healChannelPhotos`). `setMessageAutoDelete` default is now 0.

### Verification

Build green; full suite **TEST SUCCEEDED** (55 unit + 4 UI + 4 launch). Debug app relaunched; log confirms all 6 pool channels (PC1-PC5 + OC) got `setChatMessageAutoDeleteTime(0)` (chat updates show `message_auto_delete_time = 0`). **No Release build** — user policy. Commit: `8920745`.

## 2026-08-19 (night) — Fullscreen player overhaul (ghost-window transition, direct + image fullscreen), player polish, audio player fixes

One continuous session on top of the ESC/scaling/purge round (`5e12d3d`). All code lands in a single commit `cf4320c`.

### Track 1 — Ghost-window fullscreen transition (approved; completes deferred "smooth fullscreen transition" from item 86)

Implemented in `Features/MPVVideoView.swift`:

- **Snapshot capture** (`captureTheaterSnapshot`): before the Space transition starts, capture the theater's composited pixels via `SCWindow`/ScreenCaptureKit (`CGWindowListCreateImage` is unavailable on macOS 26), **cropped to the video area** — the theater chrome (bottom transport) is excluded, so the ghost reads as pure video. The snapshot becomes the fullscreen window's container content for the transition ("ghost window") — the theater never shows a hole during the Space swap.
- **Live swap at `didEnterFullScreen`**: the real video layer is attached into the container and faded in over the ghost.
- **Theater fade-out**: new `@Published videoLiveInFullscreen` on `PlayerFullScreenWindow` — true from transition start until the video returns to the theater at dismissal; the theater fades itself out while the flag is true.
- Capture failure → live-attach fallback (old behavior).

### Track 2 — Direct fullscreen for media files + image fullscreen

- `SessionKind` enum (`.theater` / `.directVideo` / `.image`); `Session` gained `kind` + `file: ObjectRecord?`; `present`/`presentNow` take `kind` + `file`.
- **`presentDirect(appState:file:playlist:)`** — context-menu "Open in Full Screen" for `isVideo || isPhoto` (`Features/FileBrowserView.swift`): plays the file straight into the fullscreen player window, no theater. `directMode = kind != .theater`; `DirectFullscreenRoot` shows a spinner until the engine's mpv controller exists; `attachVideoThenToggle` got a **directMode fast path** — direct mode has no `MPVLayerHost`, so the old container-wait retry loop would time out and dismiss ("attach aborted — container never mounted"). onClose/onDismiss stop the engine, clear `theaterFile`, `isTheaterFullScreen = false`. **User-verified "perfect".**
- **`presentImage(appState:file:)`** — `SessionKind.image`, no engine. A bug was found + fixed here: an earlier version gated the download Task on `window.isActive && session.kind == .image`, which raced `present()`'s deferral paths (stale scene window → dismiss + 0.5s re-present, transition gate) and dropped the URL → eternal spinner. Fixed by removing the window-side URL and letting `ImageFullscreenRoot` own the download in `.task(id: file.id)` (same pattern as the theater's `loadFile`) with a "Downloading N%" progress ring and failure states. Cached images are instant; SVG rendered via `SVGWebView`. **Loading-stuck bug user-reported + fixed.**
- Theater header fullscreen button moved to the top-right next to Close; `togglePlayerFullScreen()` now routes `.image` → `presentImage`.

### Track 3 — Player polish

- Hover tints normalized: per-button rounded-rect tints removed; container-level `.playerHoverTint(.capsule)` on the pill row; **autoplay button removed entirely** (user request — the icon was changed to `forward.end.fill` first, then the user decided the button shouldn't exist at all; engine `autoplayNextEnabled` default true is persisted but has no UI).
- `PlayerHoverTint` overlay got `.allowsHitTesting(false)` — a shape overlay is hit-testable even with a transparent fill; a tinted PARENT (the volume pill capsule) would swallow every drag aimed at the slider beneath it.

### Track 4 — Audio player fixes (user-reported)

- **Volume bar didn't track the system volume.** Root cause: `Binding(get: { SystemVolumeManager.shared.volume })` is untracked by SwiftUI observation — rocker/Control Center changes never re-rendered the slider/icon. Fixed with `@Bindable private var volumeManager = SystemVolumeManager.shared` + `Slider(value: $volumeManager.volume)` in the audio player (TheaterView) AND the video player (PlayerControlsView) — slider + mute icon now follow external changes live.
- **Up/down arrow keys** now adjust volume (±0.1) for both audio and video previews (previously they navigated files); rockers (F11/F12) already pass through KeyMonitorView to the system.
- **Side prev/next chevrons not vertically centered**: the transport band was pinned to the play cluster's height (audio 68pt, video 76pt) and the edge-arrow row fills it (`maxHeight: .infinity`) so all buttons share the same center.
- **Volume slider not draggable**: the hover-tint capsule overlay on the volume pill was swallowing drags (buttons kept working because their tint lives inside the button; the pill's tint is a sibling ABOVE the slider). Fix: `.allowsHitTesting(false)` on the tint **plus** removed the hover tint from the volume pill entirely — matching the Apple TV app, which has no volume-bar hover. **User-verified fixed.**

### Verification & commits

Build green; full suite **TEST SUCCEEDED** (55 unit + 4 UI + 4 launch). Debug app relaunched. **No Release build** — user policy. Commit: `cf4320c`.

## 2026-08-19 (late) — ESC routing fixed, fullscreen scaling animation killed, legacy empty folders purged permanently

Follow-up to the evening session. User reports: (1) transition still laggy both directions; (2) scaling animation on entry (the window visibly grows into the screen); (3) ESC double-press does NOT work in fullscreen (the exit button does); (4) two empty legacy folders "Video"/"Audio" appeared in All Files that the user never created.

### Track 1 — ESC routing: the theater's key monitor was eating the key

**Root cause** (harness-proven, `/var/folders/k3/72m2fcsx4r58mt6zhzt4gkfr0000gn/T/opencode/monorder/main.swift`): local `keyDown` monitors fire in REVERSE registration order, so the player's monitor (installed later, at `presentNow`) normally runs BEFORE the theater's `KeyView` monitor. But `KeyView` returned `nil` (swallowed ESC) UNCONDITIONALLY — any remount/reorder of monitors starves the player's monitor → fullscreen ESC dead. **Fix**: `KeyView` now passes ESC through (`return event`) while `PlayerFullScreenWindow.shared.isActive` (Features/TheaterView.swift). Player monitor also logs `ESC #1` / `ESC #2` for verification.

**Spec change**: single ESC in the SMALL player now exits playback for EVERYTHING (videos included) — `handleEscapeKey` no longer does the two-step for video; the two-step hint lives ONLY in the fullscreen player (`showExitWarning` moved: TheaterView @State + VideoPlaybackView param removed; PlayerControlsView keeps it for the window).

### Track 2 — Entry scaling animation: scene default size was the cause

The fullscreen scene opens at `.defaultSize(width: 1280, height: 800)` (App/xCloudApp.swift:118); the native transition then SCALES the window up to the screen → the visible growth animation. **Fix**: `configureAndEnter` sets `window.frame = screen.frame` (before `makeKeyAndOrderFront`/toggle) → the transition is a pure Space absorb, no scaling.

### Track 3 — Exit lag: timing diagnostics added

`dismiss()` and `sceneDidDisappear()` now print timestamps (`dismiss t=…` / `sceneDidDisappear t=…`) to measure where the exit time goes (dismiss → actual window close). Pending user re-test: entry transition (scale gone?), exit transition, fullscreen double-ESC, small-player single-ESC.

### Track 4 — Legacy empty folders: explained + purged permanently

**Answer to the user's question**: the Video/Audio folders were ALWAYS in the channel — old-format `xcloud:v1:` TEXT metadata messages from the pre-unified app (msg 292552704 = Video/069584F2…, msg 286261248 = Audio/809AEBD2…), both empty (0 files). The local catalog loss + repair fix made them visible; not a DB-snapshot problem.

**Purge (user-approved data deletion)**: new debug hook `--purge-legacy-folders` (App/AppState.swift, runs BEFORE post-auth so no scan can rebuild them): `VaultRepair.legacyFolderPurgeCandidates` finds old-format folder messages whose folder is EMPTY locally (no children — a legacy folder WITH children is never a candidate); deletes those messages + the local records (`deleteObjectWithChunks`) + publishes a fresh checkpoint via `publishCheckpointFromLocal` (base = newest). **Why the checkpoint matters**: `mergedChannelState` (CatalogSnapshot.swift:291) replays only deltas NEWER than the checkpoint's baseMessageID — with base = newest, the old deltas containing the folder records can never resurrect them.

**Verified**: DB has 4 folders (Books/Audios/Videos/Images), 25 objects (27 − 2); channel dump shows 0 `xcloud:v1:` messages, newest checkpoint at 378535936; app relaunch healthy.

### Verification & commits

Build green; full suite **TEST SUCCEEDED** (4 UI + 4 launch, 0 failures — tally as before). Debug app relaunched. **No Release build** — user policy. Commit: `5e12d3d`.

## 2026-08-19 (evening) — Flashless fullscreen entry (transition gate + alpha-0), ESC-like minimize/exit buttons, folders recovered from the channel delta log

Two tracks this session.

### Track 1 — Folders "missing from the cloud" → actually missing from the LOCAL catalog; repair fixed + healed from deltas

**User report**: "all folders missing from the All Files page — every file flattened at root".

**Diagnosis (answered before fixing)**: folders were NEVER lost from the cloud — the vault channel still has all 6 folder metadata messages (Books/Images/Audios/Videos unified + legacy `xcloud:v1:` Video/Audio), and every file's chunk caption still carries its `parentID`. The LOCAL catalog lost the folder records (first cause unknown; candidates: undo of a folder creation — `registerUndo` delete at AppState.swift:1512-1518 — or a restore from a folderless checkpoint). Three bugs then made the loss permanent:
1. `VaultRepair.run()` caption-extraction switch lacks `.messageText` — folders are sent as TEXT messages, so the scan could never rebuild them.
2. `ChunkCaption.parse` REQUIRED `index`; legacy folder captions lack it → they didn't parse at all.
3. The orphan-flatten (VaultRepair.swift:263) set files' `parentID = nil` with NO check whether the cloud still knows the folder.
Plus: a folderless state got published as the authoritative checkpoint (`publishCheckpointFromLocal` collapse guard counts only files).

**Fix** (`Storage/VaultRepair.swift`, `Engine/ChunkCaption.swift`): scan handles `.messageText`; `isFolder` also true via mime `xcloud/folder`; `channelKnownFolderIDs` collected from folder captions + all file captions' parentIDs; the folder's linkage chunk row (size-0) is recreated when missing (keeps rename-edit linkage, prevents duplicate metadata messages/resurrection); flatten runs only when the parentID is unknown BOTH locally and in the channel. `ChunkCaption.parse` defaults `index` to 0.

**Recovery (the heal in action)**: on the next launch, `CatalogSnapshot.upload()`'s reconcile merged the channel DELTAS (which contained the folder records) back into the local catalog before the repair scan ran — DB now has 6 folders (Books 5, Images 4, Audios 3, Videos 2 files inside), 6 linkage chunk rows, 27 objects (21 files + 6 folders), `repair scan changed=false`. Nothing new to publish ("reconciled, nothing new to publish" ×3) — the cloud never needed the fix; the local catalog is healed.

### Track 2 — Fullscreen player: flashless entry + exit polish (completes deferred item 86)

**Goal** (deferred from the morning session): the player must appear to swipe straight into its own Space — flux/Apple TV feel, no pop-up in the normal Space.

**Root cause of the remaining flash**: `configureAndEnter` set alpha-0 only at window-found (0.02–0.1s after creation) — the window was visible in between. The configurator now sets alpha-0 at ATTACH (frame 1, guarded on `isActive` so restoration/Window-menu windows stay visible).

**AppKit landmine (Qwen + Claude consultant consensus, AGENTS rule 8)**: macOS runs at most one fullscreen Space transition at a time; `toggleFullScreen` during another window's transition is SILENTLY IGNORED and the target window is PERMANENTLY POISONED (only close+recreate recovers). Implemented `FullscreenTransitionGate` (Features/MPVVideoView.swift): observes will/did Enter+Exit (object:nil), FIFO pairing, 3.5s force-settle watchdog. Only 4 fullscreen notifications exist (no didFail variants). `present()` queues via `runWhenIdle` while transitioning; controls `toggleFullScreen` gate-guarded. **Swift globals are lazy, even module-level** — the gate is touched in `xCloudApp.init()` (harness-proven: App.init runs at process start).

**Entry ladder**: `enterFullscreenSafely(attempt:)` (window-found ladder 0.02/0.1/0.3/0.6s, gate re-check, `.insert(.fullScreenPrimary)`, `tabbingMode = .disallowed`, black background, alpha-0, reveal at `willEnterFullScreen`, `didEnter` confirm, entryGeneration guards stale closures, 0.7s watchdog → `recoverIgnoredFullscreen`: soft reset → reopen fresh scene (≤2, `reopensDone` reset in presentNow) → alpha-1 windowed fallback). Harness-validated: gate queued a player request during the main window's transition and opened it after settle (fs=1 held); normal case attach→alpha0→toggle→willEnter reveal ~7ms.

**Exit polish (user-driven)**:
- OS **minimize** button (traffic light) on the fullscreen player now dismisses to the theater like ESC (`willMiniaturize` observer, gated on `.fullScreen` styleMask; windowed minimize keeps dock behavior).
- Controls' **exit-fullscreen button** now dismisses to the theater when fullscreen; only toggles INTO fullscreen when the window is windowed (recovery fallback).

**Regression found + fixed (this session)**: `updateNSViewController` re-asserted the player frame on EVERY SwiftUI update — while the player is re-parented into the fullscreen window, every controls re-render clobbered its frame to the theater size → video shifted/small in fullscreen (and the ESC flow LOOKED broken — the state after exit was wrong). Guarded: assert only when `superview === controller.view`.

**Diagnostics kept**: GL surface-size-change log (`xCloud gl: surface=WxH videoOut=WxH viewFrame=…`) + post-return fit samples (`xCloud player: post-return …`). mpv client API 2.3 (modern — FBO-size reconfig handled internally; `video-out-params` mirrors input params on this build, so it is not a fit oracle).

**Verification**: harness runs (gate/alpha/reveal); build green; full suite **TEST SUCCEEDED** (59 unit + 4 UI + 4 launch, 0 failures); user by eye: transition "much much better, almost perfect"; video fit + ESC×2 + exit button verified. Debug app relaunched. **No Release build** — user policy.

**Commits**: `3a40113` (VaultRepair/ChunkCaption — folders) + `705bad5` (MPVVideoView/xCloudApp — fullscreen polish).

## 2026-08-19 — User confirmed the fullscreen fix; new item: smooth fullscreen transition (deferred to tomorrow)

- **User confirmed** the `ensureFullscreen` fix (`256f2e7`): the player now
  opens in native fullscreen even when the app's main window is in fullscreen.
- **New item (deferred by user to 2026-08-20)**: the transition is NOT smooth —
  the player scene window first POPS UP OVERLAID (visible in the normal Space),
  then animates into fullscreen, then lands in its own Space. Wanted: a single
  seamless swipe motion like flux / Apple's player (Apple TV style) — no
  overlay flash before the fullscreen animation.
- **Mechanism to explore tomorrow**: `openWindow(id:)` makes the scene window
  visible immediately (in the normal Space); `ensureFullscreen`'s toggle
  (+0.1s) then starts the Space transition — hence the flash. Candidate
  approaches: suppress the window's initial display until the fullscreen
  transition starts (alpha 0 / off-screen positioning / hidden until
  `toggleFullScreen`), `window.animationBehavior`, or ordering the fullscreen
  enter before the window becomes visible. Also compare with how flux's player
  window behaves (flux does NOT auto-fullscreen at all — the user may want the
  window to just open fullscreen-looking or animate like Apple TV).
- Session closed for the day: build green, tests green (55 unit + 4 UI +
  4 launch), debug app running, tree clean, commit `256f2e7`.

## 2026-08-19 — Fullscreen player: auto-fullscreen moved to present()/ensureFullscreen (fixes "opens non-fullscreen when the app is fullscreen")

- **User reported** (after the scene rebuild `96f6a20`): when the APP's main
  window is in native fullscreen and the user clicks the player's fullscreen
  button, the player opens in a separate window that is NOT fullscreen and
  "doesn't support full screen". When the app is windowed, everything works.
- **Reproduced in the two-scene harness**
  (`/var/folders/.../opencode/fstest2`, real .app bundle + log file):
  - Run 1: with the main window in native fullscreen, the scene window opened
    key/visible but `toggleFullScreen` was silently IGNORED — both at attach
    (+0.1s) and as a late manual call (+2.5s). `collectionBehavior` was NOT set.
  - Run 2: setting `window.collectionBehavior = [.fullScreenPrimary]` FIRST made
    the toggle work even while the main window was fullscreen (player fs=true,
    main fs=true simultaneously).
  - Run 3: the app's EXACT previous configurator code (collectionBehavior +
    didBecomeKey observer + attach check, toggle +0.1s) PASSED with the main
    window fullscreen — proving the configurator logic itself is fine, and that
    the real-app failure comes from lifecycle deltas: (a) the configurator is a
    one-shot NSViewRepresentable — `guard let window = view.window` silently
    no-ops if the window is nil at attach (no retry), and (b) if a scene window
    survives from an earlier session, SwiftUI REUSES it on `openWindow(id:)`
    WITHOUT re-creating the content — no configurator run, no toggle, black
    non-fullscreen window with no way to fullscreen it (hiddenTitleBar = no
    traffic lights; the controls' fullscreen button only dismissed).
- **Fix** (`Features/MPVVideoView.swift`):
  - `PlayerFullScreenWindow.present()` now OWNS the toggle: after `openWindow`
    it runs `ensureFullscreen(attempt:)` — retries at 0.1/0.3/0.6/1.0s, finds
    the window by a new identifier tag (`windowTag` = "xCloudFullscreenPlayer"),
    re-asserts `.fullScreenPrimary`, and toggles only while not already
    fullscreen (idempotent; stops once fullscreen or inactive). Works whether
    the window is fresh, reused, or never became key.
  - `present()` first closes a leftover scene window (dismissWindow + 0.5s
    re-present) so a stuck window can never be reused; `completeDismissal()`
    force-closes the tagged window if the close didn't land.
  - `FullscreenWindowConfigurator` keeps only appearance/EDR/collectionBehavior
    + sets the identifier tag — the didBecomeKey observer/toggle is GONE
    (single owner of the toggle → no double-toggle race with the retry loop).
  - `PlayerFullScreenControls.onToggleFullScreen` now calls
    `window.toggleFullScreen()` (real native fullscreen toggle, green-button
    semantics) instead of dismissing — the manual fallback the user was missing.
- Build green (Debug). Test suite green: **TEST SUCCEEDED** (55 unit + 4 UI +
  4 launch, 0 failures). Debug app relaunched — user to verify both cases
  (windowed app → player fullscreen; app fullscreen → player fullscreen).
  **No Release build** — user policy.

## 2026-08-19 — Fullscreen player REBUILT on a system-managed SwiftUI Window scene; placeholder dismantle loop found + fixed

- **User reported** (after the previous fix): fullscreen shows a non-fullscreen
  window and the main window "closes or disappears". User asked to do it the
  simple way like their OTHER app — `~/Projects/flux` opens video in a separate
  window that just works.
- **Second real bug found** (`Features/TheaterView.swift`): the placeholder was
  an if/else SWAP — when fullscreen activated, `VideoPlaybackView` unmounted →
  SwiftUI dismantled the mpv NSViewController (`MPVVideoView.swift:29-31`) →
  `cleanup()` → `teardown()` → `PlayerFullScreenWindow.shared.dismiss()`
  (`MPVVideoView.swift:787`) → the fullscreen window flashed up and died
  instantly; the mpv teardown/rebuild made the main window go black/restart.
  This is why "it's not going away" — the manual-window fixes were real but the
  window was being KILLED by the placeholder swap the moment it appeared.
- **Flux's pattern** (verified in its source): a separate SwiftUI
  `WindowGroup(id: "player")` scene + `.windowStyle(.hiddenTitleBar)`; the
  system manages the window (correct sizing, native fullscreen), zero manual
  NSWindow code.
- **Rebuilt the same way**:
  - `App/xCloudApp.swift`: new `Window("Fullscreen Player", id:
    "fullscreenPlayer")` scene (hiddenTitleBar, 1280×800) + `FullscreenWindowLink`
    (invisible view in the main window) that binds `openWindow`/`dismissWindow`
    into `PlayerFullScreenWindow` so plain AppKit code can open/close the scene.
  - `Features/MPVVideoView.swift`: `PlayerFullScreenWindow` is now session-based
    (Session: player/mpv/title/subtitle/appState) and opens the scene instead of
    hand-rolling an NSWindow — no style masks, no intrinsic-size collapse, no
    timing races. `FullscreenPlayerSceneView` renders the transferred mpv layer
    + controls (one SwiftUI tree → `.glassEffect()` works) and
    `FullscreenWindowConfigurator` (NSViewRepresentable) sets dark appearance,
    `.fullScreenPrimary`, EDR color space and auto-enters native fullscreen once
    the window becomes key (guarded, toggles once). Dismiss closes the scene;
    `sceneDidDisappear` (onDisappear) handles out-of-band closes (Cmd+W) and
    re-parents the mpv layer back to the theater in `completeDismissal`.
  - `Features/TheaterView.swift`: the placeholder is now an OPAQUE OVERLAY on
    top of the still-mounted player (ZStack) — the player stays mounted, so mpv
    is never dismantled while fullscreen is up.
- **Playback transfer** unchanged: the SAME MPVLayerView is re-parented into the
  scene (removed from the theater, embedded via MPVLayerHost), so playback
  continues uninterrupted across the transition; dismiss hands it back.
- Build green (Debug). Test suite green: **TEST SUCCEEDED** (55 unit + 4 UI +
  4 launch, 0 failures). Debug app relaunched — user to verify. **No Release
  build** — user policy.

## 2026-08-19 — Fullscreen player tiny-window FIXED (root cause: contentViewController Auto Layout collapse)

- **User asked** to look at `docs/PROBLEMS.md` — the fullscreen player still
  opened tiny/broken despite the fake-borderless rewrite (c425e14).
- **Root cause found + proven empirically** (`Features/MPVVideoView.swift`):
  `win.contentViewController = host` (NSHostingController) lets Auto Layout
  collapse the window to the hosting view's fitting size. Reproduced in a
  standalone harness: window created at `screen.frame` (1440×900) collapsed to
  **1×1 px** at top-left the moment the controller was attached. The old
  working code never used contentViewController — it attached plain subviews
  with explicit frames + autoresizing masks.
- **Fix**: host the SwiftUI tree (`FullscreenPlayerRoot` = MPVLayerHost + 
  controls in one tree, so `.glassEffect()` keeps working) in a plain
  `NSHostingView` subview of a plain `NSView` contentView, with
  `hosting.frame = content.bounds` + `autoresizingMask = [.width, .height]`.
  Same render tree, same glass; window keeps its screen-sized frame.
- **Verified end-to-end in a minimal .app bundle** (same titled fake-borderless
  window + plain contentView + NSHostingView): window created at
  (0,0,1440,900), ordered front → clamped to visible frame (normal macOS),
  `didBecomeKey` → `toggleFullScreen` → **native fullscreen entered**
  (frame = full screen, `styleMask.contains(.fullScreen)` = true), exit
  restored the window. The window collapsing to ~200×100 was the bug; the
  visible-frame clamp (menu bar + Dock) is normal.
- Build green (Debug). Test suite green: **TEST SUCCEEDED** (55 unit + 4 UI +
  4 launch, 0 failures). Debug app relaunched with the fix — user to verify
  fullscreen by eye. **No Release build** — user policy.
- `docs/PROBLEMS.md` brought into the main repo and rewritten as resolved.

## 2026-08-19 — Fullscreen player architectural rewrite (IN PROGRESS)

- **Fullscreen player rewritten** (`Features/MPVVideoView.swift`): replaced the old
  `.borderless` manual NSWindow (which broke `.glassEffect()`) with a "fake
  borderless" approach (`.titled + .resizable + .fullSizeContentView` with hidden
  titlebar/traffic lights). Video + controls embedded in one SwiftUI render tree
  via `NSHostingController` + `MPVLayerHost` (NSViewRepresentable) — glass works
  in this configuration.
- **Native fullscreen NOT YET WORKING**: the window opens tiny/broken despite
  all fixes (see `docs/PROBLEMS.md` for full analysis and next steps).
- **TheaterView placeholder**: main window now shows "Playing in full-screen"
  message when the fullscreen player is active, instead of a broken video view.
- **Stamp/bar alignment finalized**: `.frame(width: 76, height: 28)` in both
  `VideoPlaybackView.swift` and `TheaterView.swift` — pixel-perfect centerline
  alignment.
- Committed as part of this changeset. Debug build. **No Release build** — user
  policy.


## 2026-08-18 (late night) — Freebuff fixes: fullscreen glass restoration + stamp↔bar vertical alignment

- **Fix #1 — Fullscreen liquid glass restored** (`Features/MPVVideoView.swift`):
  `PlayerFullScreenWindow.present(...)` creates a manual borderless `NSWindow`
  (level `.mainMenu`, black background) outside the SwiftUI scene. The main
  window forces `.preferredColorScheme(.dark)`, but this window had no
  appearance → liquid-glass materials (`glassEffect(.regular.interactive(),
  ...)`) rendered in light mode over the black background and looked flat/plain
  (no blur, no glass). Fix: `win.appearance = NSAppearance(named: .darkAqua)`
  right after `win.backgroundColor = .black`. Now the fullscreen player's
  volume slider, minimize/close/transport buttons all render with proper liquid
  glass, matching the windowed player.

- **Fix #2 — Time stamps sit exactly on the bar centerline** (`Features/VideoPlaybackView.swift`
  + `Features/TheaterView.swift`):
  The previous `.offset(y: -1.5)` on both time labels nudged them up but
  wasn't enough (~3 px remaining gap: bar centerline y≈591, stamp centers
  y≈594). Root cause: the text labels had no explicit height — their natural
  line height (~16 pt for 13 pt monospaced) didn't match the bar's 28 pt frame,
  so SwiftUI's center alignment placed them at a slightly different vertical
  position than the 5 pt capsule inside the 28 pt ZStack. Fix: replaced
  `.frame(width: 76, alignment: ...).offset(y: -1.5)` with
  `.frame(width: 76, height: 28, alignment: ...)` — the text containers now
  have the exact same height as the bar frame, so their vertical centers align
  pixel-perfectly with the bar's capsule centerline. Applied in all 4 places
  (left/right labels in both the video player and the audio scrubber).

- Committed as `eae32f1`. Build green (Debug). Full test suite green:
  **TEST SUCCEEDED** (59 unit + UI/launch tests, 0 failures). Debug app NOT
  launched (user verifies both fixes). **No Release build** — user policy.

## 2026-08-18 (night) — Player controls: seek-target hold, bar↔stamp alignment, fullscreen environment fix; fullscreen glass regression + stamp vertical alignment handed to freebuff

- **User reports**: (1) after clicking/dragging the progress bar it snapped back
  to the old position for a split second; (2) the time stamps and the progress
  bar are not on one straight line / the bar is not centered between the stamps;
  (3) NEW — in the fullscreen (maximized) player ALL liquid-glass UI is gone
  (volume slider, minimize, close, transport buttons), while the windowed player
  has proper glass — "it's like two different player UIs".
- **Diagnostics (live screenshots + macOS Vision OCR + Gemini on a 1024×640
  crop)**: a phone-screen UI inside the MOVIE ("Farah / @thefarahmir / 01:15")
  sits exactly where the left time stamp renders — pixel analysis alone was
  misleading until OCR separated app UI from video content. Gemini measured the
  real row: bar x 294–905 (611px), left stamp "00:47" x 226–255, right stamp
  "-01:52" x 939–975, gaps 39px / 34px (bar shifted toward the right stamp),
  bar centerline y≈591 vs stamp centers y≈594 (~3px — the bar sits HIGHER than
  the stamp optical center).
- **Fixed (commit `ce8c6fc`, `Features/VideoPlaybackView.swift` +
  `Features/TheaterView.swift` + `Features/MPVVideoView.swift`)**:
  - **Seek no snap-back**: `@State seekTarget` + `holdProgressUntilSeekLands(_:)`
    (1.5s MainActor watchdog) — `displayedProgress` pins to the target until
    `abs(mpv.progress − target) ≤ 0.01`, so the bar never jumps back after a
    click/drag seek. Same in the audio scrubber (`progressFraction` helper).
    User verified: "the seek is fixed".
  - **Alignment (horizontal)**: both time labels get equal 76pt frames AND now
    hug the BAR side of their frame (left label `.trailing`, right label
    `.leading`) — the stamp→bar gap is exactly 20pt on both sides (Apple TV /
    flux look) instead of 39/34px asymmetric. User: "you have moved the time
    stamps closer to the progress bar and that's actually good".
  - **Alignment (vertical)**: labels nudged `.offset(y: -1.5)` to sit on the
    bar's optical centerline — user says the vertical axis is STILL not
    aligned with the bar → **handed to freebuff**.
  - **Fullscreen crash (earlier, now committed)**: `PlayerFullScreenWindow
    .present(...)` hosts `PlayerControlsView` in an `NSHostingView` OUTSIDE the
    SwiftUI scene; `@Environment(AppState.self)` was missing → EXC_BREAKPOINT
    on first layout. Fixed by `appState:` param +
    `NSHostingView(rootView: AnyView(controls.environment(appState)))`; user
    verified fullscreen works.
  - **Fullscreen liquid glass regression → handed to freebuff (NOT fixed)**:
    windowed player glass OK, fullscreen borderless window loses every
    glassEffect material. Working hypothesis: the manual NSWindow has no
    appearance while the main window forces `.preferredColorScheme(.dark)` —
    glass materials render in light mode over the black borderless window
    (candidate fix: `win.appearance = NSAppearance(named: .darkAqua)` in
    `PlayerFullScreenWindow.present`, `Features/MPVVideoView.swift` ~line 1480).
- Verified: build green (Debug). Full test suite NOT rerun after `ce8c6fc`
  (last green: 67 at `330f46e`) — freebuff should run it. Debug app relaunched
  (9:22PM). **No Release build** — user policy.

## 2026-08-18 (evening) — Player polish: EOF replay, autoplay-next toggle, transport/slider UX; hover scrub preview added then removed

- **User asked**: audio/video players should behave like a normal media player —
  Space replays a finished file instead of doing nothing, an autoplay-next toggle
  should exist, transport buttons + keyboard arrows should be intuitive, the slider
  should seek on click, and (initially) a YouTube-style hover scrub preview.
- **Replay after EOF (verified live via logs)**: mpv now uses `keep-open=yes`
  (`Features/MPVVideoView.swift`, after `video-sync`), `eof-reached` is observed
  (new `handlePropertyChange` case) and routed to `onEndOfFile`. The engine
  (`Engine/AudioPlayerEngine.swift`) tracks `ended` + dedupes the EOF signal
  (`lastEOFAt`/`lastEOFTrackID`, 5s window — END_FILE can also fire);
  `togglePlayPause()` with `ended` does `seek(absolute: 0)` + `play()` on the SAME
  core (the old async teardown/reload raced with rapid Space presses — the
  "10-20 presses to restart" flake). Log evidence: `EOF track=… autoplay=true
  ended=true` → `replay seek0+play track=…`.
- **Autoplay-next toggle**: `autoplayNextEnabled` (@Observable stored property,
  UserDefaults `autoplayNextEnabled`, default true; honored by `onEndOfFile`).
  UI: `infinity` + "Auto" pill, `XTheme.accent` when ON — video bottom bar
  (56×36) and audio volume row (54×30 capsule). User verified: "works as
  expected".
- **Transport**: `skipPrevious()` always goes to the previous track (the >3s
  rewind heuristic removed; else `seek(to: 0)`); the video transport play/pause
  button routes through `AudioPlayerEngine.shared.togglePlayPause()` (was a
  second toggle path); audio artist view gained edge prev/next chevrons
  (`canGoPrevious`/`canGoNext`, gated on the playlist like the video player) —
  the transport ZStack is `.frame(maxWidth: .infinity)` so the chevrons pin to
  the real edges and center vertically with the cluster.
- **Keyboard arrows**: in fullscreen video (`PlayerFullScreenWindow.shared.isActive`)
  Left/Right seek ±10s; otherwise they navigate files (`navigateMedia(±1)`) —
  wired in both the `KeyMonitorView` closures and the `.onKeyPress` handlers.
- **Sliders (video + audio)**: click-to-seek and instant drag response via
  `DragGesture(minimumDistance: 0)`; visual-only during drag (`dragProgress`),
  ONE seek on release (live seeks caused mpv fast-forward artifacts); the whole
  28pt band is the hit area — `contentShape(Rectangle())` must be on the view
  that owns the gesture (SwiftUI hit-tests the gesture view's shape; the 5pt
  track was the click-precision bug).
- **Hover scrub preview — ADDED, THEN REMOVED (user decision)**: a YouTube-style
  bubble (AVAssetImageGenerator frame + time, or time-only) above the bar,
  driven by `.onContinuousHover`; overlay-based so it never shifted the slider.
  Two real bugs were found and fixed (the preview moved out of the layout ZStack;
  stream-URL resolution starved by the request-ID guard during multi-second
  Telegram layout downloads — resolution is now a per-track independent task).
  The user then asked to remove the feature entirely ("we don't need it"). All
  preview code, state, and the temporary `import AVFoundation` are gone from
  `Features/VideoPlaybackView.swift`; the audio scrubber's hover time bubble
  (`scrubHoverFraction`) was removed too. **The no-AVFoundation mandate
  (HANDOVER item 28) was briefly violated during development and is restored:
  zero `import AVFoundation` in the codebase.**
- Verified: `** TEST SUCCEEDED **` (67: 59 unit + 4 UI + 4 launch), debug app
  relaunched (PID 17502), committed as `330f46e`. No Release build (policy).

## 2026-08-18 — PDF reader: single Preview-style UI (drop the book chrome)

- **User asked**: PDFs showed TWO preview overlays — the Apple Books-style
  reader chrome AND WebKit's PDF viewer bar. Wants ONLY the Preview-app-like
  UI for PDFs, with extra buttons (close, share, etc.). Confirmed via
  question: "one is like how books are previewed in Apple Books (controls),
  and a bar like the macOS Preview app — keep the preview only for pdf and
  add more buttons for closing sharing etc".
- **Changes** (`Features/BookReaderView.swift`):
  - `body`: for `format == .pdf` the book chrome (topControls/bottomControls
    with hover auto-hide) is replaced by a slim always-visible `pdfToolbar`;
    the WebKit PDF view (which range-fetches from the stream server) provides
    the Preview-style page UI. Book chrome unchanged for epub/text/comic.
  - `pdfToolbar`: glass capsule with Close (Esc), file title, Open with
    Default App, Share (macOS share sheet), Full Screen. Title + icons are
    fixed `.white` over the light glass bar per user feedback (first used
    `theme.foreground` — grey-on-white in dark theme; then adaptive
    `.primary` — black; user wants white text, bar as is).
  - `sharePDF()`: quiet download (`DownloadEngine.download`) then
    `NSSharingServicePicker` anchored top-right of the window (share needs
    real bytes; streaming stays on the preview path).
  - `fullscreenButton` now takes a `foreground:` color (book chrome passes
    `theme.foreground`, PDF toolbar passes `.white`).
  - Position bug fixed: the toolbar was CENTERED at first (the `if format ==
    .pdf` branch replaced the full-height VStack, so the ZStack centered the
    bar) → wrapped in `VStack { pdfToolbar; Spacer() }` + top padding; added
    a stroke border + shadow for visibility.
- **Storage cleanup (user asked "why is DerivedData so big")**: 23 GB →
  6.8 GB. Cause: FIVE xCloud derived-data folders from different sessions;
  four stale ones (xCloud-wt 4.3G, xCloud-tests 4.1G, xCloud-release 4.0G,
  xCloud-main 4.0G) were pure regenerable build output — deleted. The active
  pinned folder (xCloud-cdpcjcegyfsbheeztqhmjnnukgcv, AGENTS.md) kept: 3.8G
  Build + 1.9G SourcePackages + caches.
- Build green; tests green (67: 59 unit + 4 UI + 4 launch). Debug app
  relaunched. **No Release build** — user policy.

---

## 2026-08-18 — PDF streaming: byte-range preview without a full download

- **User asked**: add PDF streaming; first check whether it's supported; also
  asked whether only linearized PDFs stream (he'd heard that claim) and
  whether locally linearizing non-linear PDFs is the way, "or is there a
  better way".
- **Was it supported?** No — PDFs were fully downloaded before viewing (books:
  `DownloadEngine.download` → `loadFileURL` in BookReaderView; Theater: PDFs
  were metadata-only). But the byte-range plumbing (VaultStreamServer: 206/
  Content-Range/Accept-Ranges, `plaintextSliceStream`, 1 MB slices,
  `fetchRangeData`, 48 MB SliceCache) was 90% there — verified live with curl
  before any code changed.
- **Linearization answer (from the user's question)**: the "only linearized
  PDFs stream" claim applies to SEQUENTIAL loaders. Every modern PDF renderer
  (WebKit, PDFKit, PDF.js) is range-capable: it fetches the head, fetches the
  tail (xref/trailer), then page objects on demand — non-linearized PDFs
  stream fine, one extra round-trip. Linearizing locally (qpdf — Apache-2.0,
  or CoreGraphics' `kCGPDFContextCreateLinearizedPDF`, or a CGContext
  regenerate) would only be needed for a sequential-only data provider or as a
  robustness fix for sloppy generators — rejected as unnecessary.
- **Changes**:
  - `VideoStreamingEngine.loadLayoutUncached`: `pdf` → `application/pdf`
    content type; new `pdfStreamURL(for:)` (same layout machinery as
    `mpvStreamURL`).
  - `BookReaderView`: PDFs now load via `loadPDF()` — `pdfStreamURL` when
    uncached (WKWebView loads the stream URL with `isRemote`, WebKit's PDF
    renderer range-fetches), else full download. `BookWebView` gained
    `isRemote` (load URLRequest vs loadFileURL) + `onLoadError`
    (didFail/didFailProvisional → `handlePDFStreamFailure` → falls back to
    download, once — `pdfFallbackScheduled`).
  - `TheaterView` PDF details panel: added "Preview" button (opens the
    reader, which streams).
  - `FileBrowserView.open`/`quickLook`: PDFs (mime or ext) now open directly
    in the reader (double-click / Space) instead of the Theater metadata
    panel (user feedback from the spike: "double clicking or pressing space
    bar doesn't open the file").
- **Spike verification (live, real object)**: generated a 86.7 MB,
  120-page, deliberately NON-linearized PDF (no Linearized dict, xref at
  tail — verified with python) and uploaded it via a TEMPORARY
  `--import-file` debug hook (removed after the test). Server: HEAD → 200,
  exact Content-Length, `application/pdf`; range → 206; trailer-first probe
  (`startxref` reachable from the last 1024 bytes) + head probe (`%PDF-1.3`).
  Client: removed the upload's cache copy (UploadEngine copies imports to the
  cache — the first render test silently used the local copy!), relaunched;
  user confirmed pages render; log shows `Stream layout … canStream=true`;
  **no cache file was created** — the PDF rendered entirely from byte ranges.
  First false positive is a good gotcha: `UploadEngine.upload` populates the
  cache for instant previews (UploadEngine.swift:380-389), so a fresh import
  is ALWAYS cached — streaming only kicks in once that copy is evicted.
- The 86.7 MB test PDF (`xc-stream-test.pdf`) is still in the vault (user can
  test/delete via the UI).
- Build green; tests green (67: 59 unit + 4 UI + 4 launch). **No Release
  build** — user policy. Debug app relaunched and running.

## 2026-08-18 — Channel profile pictures: branded avatars on every xCloud channel

- **User asked**: "What do you think?" about giving the Telegram channels
  (vault, share pool slots, public channel) profile pictures. I said yes —
  cheap and makes the channels recognizable; public channel photo also shows
  on t.me link previews. User approved.
- **Implementation**:
  - New `Engine/ChannelAvatar.swift`: draws 640×640 JPEG (TDLib static chat
    photos must be JPEG) — diagonal gradient in a per-family hue + the label
    centered in bold white with a soft shadow. Written to
    `<tmp>/xcloud-avatars/<label>.jpg`. Pure CoreGraphics + CoreText, no
    assets. (Engine/ is a file-system-synchronized pbxproj group — no pbxproj
    edit needed, unlike Features/.)
  - `TelegramClient.setChannelPhoto(chatId:label:hue:)` (best-effort, logged)
    via TDLib `setChatPhoto` + `.inputChatPhotoStatic` +
    `.inputFileLocal`; `hasChannelPhoto(chatId:)` via `getChat().photo`.
  - Wiring: `VaultManager.ensureVault` (label "Vault", hue 0.58) and
    `ensureBackupChannel` ("Backup", 0.35) — only when the channel has no
    photo yet; `ShareEngine.createPoolChannel` always (private slots
    "PC1"…"PC5" with per-slot hue, public "OC" hue 0.75); legacy pool
    channels get branded on reuse/rejoin only when photo == nil.
  - `ShareEngine.healChannelPhotos()`: idempotent backfill at launch
    (AppState post-auth, after `cleanupExpiredShares`) — sets a photo on
    every recorded channel (vault, backup, slots 1–5, OC) that has none.
    This matters because `ensureVault` early-returns for existing rows, so
    pre-existing channels would otherwise never be branded.
- **Verification (live)**: first launch generated all 8 avatars (all distinct
  md5s, valid 640×640 JPEGs) and set them; second launch regenerated NONE —
  `hasChannelPhoto` was true on every channel, proving the photos landed
  server-side and the backfill is idempotent. (os.Logger lines not persisted
  to `log show`; verified via avatar-file timestamps + the photo guard.)
- Build green; tests green (67: 59 unit + 4 UI + 4 launch). **No Release
  build** — user policy. Debug app relaunched and running.


## 2026-08-18 — Share lifecycle round: 1-day expiry, channel TTL, cancel-on-use, staged import UX

- **User asked**: expiry 7d → 1d; "auto delete message after a day in the
  channel" — is that an option?; cancel-on-use when the recipient joins (with
  a grace so their app can forward first); and a NEW import UX: opening a link
  should NOT auto-import — instead show a detail screen with a file card +
  Import/Cancel, with the messages ALREADY forwarded to the user's cloud
  channel so files can be streamed/previewed WITHOUT importing.
- **TTL answer: YES** — `setChatMessageAutoDeleteTime` (TDLibKit), 86400s
  allowed (divisible by 86400, ≤ 365d), server-enforced: Telegram deletes
  every message 24h after posting even if the app never runs again. Applied to
  PRIVATE pool channels only (creation + reuse + rejoin paths) — NEVER the
  vault or public channel.
- **Changes** (commit pending):
  - `ShareEngine.defaultLifetime` 7d → 1d (86400).
  - `AppState.completePostAuthSetup`: `cleanupExpiredShares()` now also runs
    at launch (previously only in the 6h in-app loop).
  - Cancel-on-use: `TelegramClient.handleUpdate` case `updateChatMember` →
    `ShareEngine.handleShareChannelMemberJoined` — private slot + joiner ≠ me
    → after `cancelOnUseGrace` (300s) the share self-cancels (messages
    deleted + channel left) if still active. The recipient's forward is a
    server-side copy into THEIR vault, so the grace is safe; TTL+expiry cover
    the app-not-running case.
  - **Staged import UX**: `importLink` now forwards chunks into the
    recipient's vault channel and returns `.pending(objectID:)` instead of
    cataloging. The object is saved as `state = "pendingImport"` (incoming
    share row `state = "pending"`): streamable/previewable via the existing
    DB-driven stack (theater/MPV/audio/thumbnail) but INVISIBLE to
    `DatabaseManager.allObjects()`/`allChunks()` (catalog, snapshot, sync,
    VaultRepair step-2 promotion, heal dedupe, existingObject, uniqueName —
    all central-filtered). `confirmImport(objectID:)` = unique name, state →
    ready, `BackupSync.enqueue` per chunk (mirroring deferred so cancelled
    files never reach the backup channel), incoming row → imported.
    `discardImport(objectID:)` = delete vault-channel copies + drop rows.
    `PendingImportView` sheet (RootView): file card (kind icon, name, size,
    type), Preview (media), Import to My Cloud (primary), Cancel (destructive).
    Pending imports re-surface at launch via `pendingImports()`. Re-opening
    the same link re-presents the existing pending instead of double-forwarding.
  - New file `Features/PendingImportView.swift` added to the pbxproj
    (explicit Features group).
- Build green; tests green (67: 59 unit + 4 UI + 4 launch). **No Release
  build** — user policy. Debug app relaunch pending after docs commit.

## 2026-08-18 — Expiry cleanup aligned with join/leave (commit 50b2b2f)

- User asked whether one-time-use private links make the 7-day link expiry
  pointless. Answer (from code): no — the two mechanisms are orthogonal. The
  one-use invite (memberLimit 1) is the SECURITY property (only the intended
  recipient ever gets in); the 7-day expiry is the share LIFETIME — the
  recipient has 7 days to open the link, and `cleanupExpiredShares()`
  (ShareEngine.swift:1124, runs on the transfer cleanup loop) revokes shares
  nobody opened, deleting the file's copies from the channel so unopened
  shares don't sit on Telegram forever.
- Found while answering: `revokeExpired` (1142) still used the OLD behavior —
  `deleteChat` + DROP the share_state row on expiry — so an expired (not
  cancelled) share left its channel AND lost its row, and the next private
  share created a NEW channel: the exact "new channels again and again" bug,
  still lurking on the expiry path.
- Fixed: expired pool-slot shares now follow join/leave exactly like
  cancelShare — delete this share's messages, `leaveChat` the slot (when no
  other active share uses it), KEEP the row so the next share rejoins via the
  recorded permanent invite. Legacy v1 disposable channels (messageIDs empty)
  still forget their row outright.
- Build green, tests green (67). **No Release build** — user policy.

## 2026-08-18 — Join/leave share semantics implemented (commit 8bbc928)

- **User asked for**: cancel = delete the messages AND leave the channel;
  create = reuse the 5-slot pool via join/leave; also explained the intended
  security model (see link-encryption answer below).
- **Live probes (tdtest harness, real account session copy)**:
  - Slots 1-5 were no longer "Chat not found" — the account had become
    creator/member again (user's own manual rejoin test; memberCount 0 → 1),
    so rejoin-via-invite now returns USER_ALREADY_PARTICIPANT.
  - Full cycle on slot 5 (-1004145642528): `leaveChat` on an OWNED channel
    succeeds → channel stays alive, myStatus left; `joinChatByInviteLink`
    (+A6GEaqjkB3lmYTBl) → chatId -1004145642528 == stored row, status back to
    creator. Slot 5 restored to pre-test state afterwards.
- **Changes** (`Engine/ShareEngine.swift`):
  - `cancelShare`: deletes the share's messages + `leaveChat` on the channel
    for PRIVATE shares (public channel is permanent, never left — public
    cancel still deletes only its messages).
  - `allocatePrivateChannel` pass 2: a slot whose channel we LEFT is REJOINED
    via its recorded permanent invite (chatExists false → join → same chatId →
    row stays valid; adopt the returned chatId if it ever differs; rename
    legacy titles). Pass 3 (create new channel) only when no recorded invite
    resolves.
  - Doc comments updated (allocatePrivateChannel, cancelShare,
    cancelAllShares) + test comment (xCloudTests.swift cancelShareMarksRecordsRevoked).
- **Security answer (user question)**: the share link is NOT protected by a
  hardcoded key. `obfuscate` (ShareEngine.swift:1140) wraps the plaintext
  link in AES-256-GCM under a RANDOM per-link 256-bit key that rides inside
  the blob (`xcloud://share#base64url(key || ciphertext)`); the recipient
  unwraps it with the embedded key. It is obfuscation, not secrecy — the link
  IS the credential. Defense in depth: private links embed a ONE-USE invite
  (memberLimit 1, expires with the share) so only the first joiner gets in and
  the channel is otherwise closed (no public access, one share's messages at a
  time); public links embed the channel's permanent invite by design (any
  holder can join any time).
- Build green; tests green (67: 59 unit + 4 UI + 4 launch). **No Release
  build** — user policy. Debug app relaunch pending after docs commit.

## 2026-08-18 — Manual TDLib probe: deleteChat does NOT delete pool channels (join/leave confirmed)

- **User's claim to verify**: "deleteChat didn't really delete the channel, it
  just left the channel — with the invite link we could still rejoin the same
  channel and gain admin rights right away; the old mechanism was 5 channels
  we join/leave on share create/cancel." Asked for a manual test.
- **Method**: built a standalone TDLib harness (SwiftPM exe, TDLibKit
  1.5.2-tdlib-1.8.66, in the temp dir `tdtest/`) running against a COPY of
  the Debug app's TDLib session (`~/Library/Application Support/xCloud/tdlib`
  → temp; credentials read from Keychain: apiID 34035379 / apiHash from
  `security find-generic-password -s com.nemesys.xcloud.xCloud -a
  telegram-credentials`). Session copy logged in fine (authorizationStateReady).
  Probed getChat on 11 channel ids + checkChatInviteLink on 8 links from the
  real DB.
- **RESULTS (all five original pool slots)**: getChat on slots 1-5 recorded
  channels → "Chat not found" (the account is NO LONGER a member), BUT their
  PERMANENT pool invites still resolve — `t.me/+5VSskzM6sjk4MDY1` →
  'xCloud PC1' (memberCount=0), etc. Public channel alive, creator, title
  'xCloud OC'. Some newer revoked test channels alive too; the per-share
  ONE-USE invite links (expiring) are dead (INVITE_HASH_EXPIRED) as designed.
- **CONCLUSION — user is right**: TDLib `deleteChat` on these owned channels
  LEFT them (creator removed) instead of destroying them server-side. The
  channels persist with memberCount=0 and their permanent invites stay valid
  — the creator can rejoin and regain admin instantly. So the old
  join/leave-on-cancel mechanism was leaving channels, and
  `allocatePrivateChannel`'s reuse pass (chatExists/getChat-based) saw left
  channels as "lost" and created new ones every cycle — the "new channels
  again and again" bug the user reported.
- Follow-up options for the user: (a) keep current keep-membership reuse
  (channels stay archived in the chat list), or (b) true join/leave: cancel
  LEAVES the channel, create REJOINS via the stored permanent invite and only
  creates new when rejoin fails (also cleans the 5 zombie slot channels by
  reusing them). Awaiting user decision. Harness kept at
  /var/folders/…/opencode/tdtest.

## 2026-08-18 — Private channel REUSE (disposed channels never deleted) + imports backed up

- **User tested again and found a regression vs expectations**: shared several
  private links, cancelled, shared again — brand-new Telegram channels kept
  being created; the disposed channels were never reused.
- **Root cause** (`Engine/ShareEngine.swift:cancelShare`): cancel on a private
  share called `deleteChat` (killed the Telegram channel) AND dropped the
  share_state row. `allocatePrivateChannel`'s reuse pass needs a live recorded
  channel, so the next share always fell through to `createPoolChannel` →
  new channel every time. (Round 3 had "verified" this as intended; the user
  now explicitly wants reuse: channels are disposed, not destroyed.)
- **Fix**: `cancelShare` now deletes ONLY that file's messages — the channel
  (private pool or public) survives as a disposed slot and the row stays;
  allocation reuses it on the next share and creates a channel only when the
  recorded one is lost (`chatExists` false). Slot freeing needs no row
  deletion — allocation counts only channels with ACTIVE shares as busy.
  `cancelAllShares` and the cancel test comment updated to match.
- **Imports not backed up (second finding)**: `UploadEngine.swift:303` mirrors
  every uploaded chunk into the backup channel via `BackupSync.enqueue`, but
  `ShareEngine.importForwarded` (v2 links) and `importLegacy` (v1 links)
  forwarded chunks into the vault channel WITHOUT enqueueing — imported files
  existed only in the vault channel, so a restore-from-backup would lose
  them. Fix: `BackupSync.enqueue(messageID:newMessageId, objectID:)` right
  after each import forward (both paths). Catalog checkpoints were already
  mirrored; now the chunk DATA is too.
- Build green, 67 tests green, committed, Debug app relaunched for re-test.
  No Release per user policy.

## 2026-08-18 — Finder-style name dedupe for moves (no more same-name conflicts)

- **User asked** to prevent same-name conflicts on MOVE ("we should totally do
  that so we don't face the same name conflict... make sure this doesn't happen
  anywhere"). Audited every path that writes parentID:
  - moveObject (single move: context menu + drag-drop), moveObjects (album/
    playlist batch), bulkMove (multi-selection Move), addToPlaylist (single
    add), moveToFolder (dead helper, now delegates to moveObject), rename
    (Finder auto-"Name 2" parity), uploads (already deduped,
    UploadEngine.swift:108-126), share imports (already deduped at root via
    uniqueImportName).
- **Fix**: new `DatabaseManager.uniqueObjectName(base:parentID:reserved:excluding:)`
  (Finder-style "file 2.mp4", case-insensitive, root = nil) built on the
  existing pure `ShareEngine.uniqueName`. moveObject/bulkMove/addToPlaylist/
  rename use it with undo/redo capturing old+new names; moveObjects pre-computes
  names with a shared reserved set so two same-named files moving together land
  as "file.mp4" + "file 2.mp4" without racing each other's DB writes (the
  in-memory sibling set avoids an actor call in a sync MainActor context).
- Gotchas hit: `??` RHS is a non-async autoclosure — `try? await` inside it is
  a compile error; DatabaseManager is an actor, its read/write helpers need
  await from Task contexts.
- Build green, 67 tests green (59 unit + 4 UI + 4 launch), Debug app
  relaunched. No Release per user policy.

## 2026-08-18 — Agent instruction file (AGENTS.md), HDR/Dolby verification, move-conflict semantics

- **User asked** for a durable anti-loss setup after the freebuff crash: an
  instruction file any coding agent must follow to save work, commit, and keep
  HANDOVER.md + JOURNAL.md current after every task. Created `AGENTS.md` at the
  repo root (non-negotiable session rules, build/test/run commands, commit
  conventions, doc conventions, gotchas, session-end checklist). Future
  sessions read it first.
- **HDR/Dolby verified intact** (user wanted confirmation the work survived the
  freebuff problems): the full HDR/EDR pipeline is present in
  `Features/MPVVideoView.swift` — `applyColorPipeline()` (line 859, PQ/HLG on
  BT.2020/P3 → EDR layer + PQ colorspace + target-peak hard clip; SDR fallback;
  churn guard via `lastPipelineKey`), gamma/primaries observation (lines
  1023-1026), RGBA16F backbuffer + extendedSRGB window colorspace (line 573),
  `edrPeakNits()` (line 833); Dolby Atmos/DTS passthrough (`audio-spdif`
  ac3,eac3,truehd,dts + `audio-exclusive` on `xc.audioPassthrough`, lines
  974-981) with the Settings toggle (`SettingsView.swift:239`). History of live
  verification: HANDOVER item 1 (HDR file PQ/BT.2020 verified playing via the
  EDR pipeline), JOURNAL lines 100-136. Nothing was removed by the freebuff
  incidents.
- **Move-conflict semantics (asked and answered, no code change)**: moving a
  file into a folder (or root) where a same-named file already exists does NOT
  rename, replace, or dedupe — `moveObject`/`moveToFolder`/`moveObjects`
  (`App/AppState.swift:1545-1622`) only write `parentID`. Both records keep the
  exact same name and coexist (current intended behavior — two `file.mp4` in
  one folder). The Finder-style unique-name logic
  (`uniqueName`/`uniqueImportName`, `Engine/ShareEngine.swift:1060-1080`,
  "Name 2.ext") applies ONLY to share imports at the root.
- Committed with AGENTS.md + journal rework as part of this commit; round 6
  hash corrected to `27d0799`. Tests green (67: 59 unit + 4 UI + 4 launch).

## 2026-08-18 — Round 6: Share menu split, channel naming, duplicate heal, rename field

- FileBrowserView: "Share via Public Link…" replaced by expandable Share menu
  (Private lock.fill / Public globe), N items → "Share N Items".
- ShareEngine.poolChannelTitle(id:kind:) — public "xCloud OC", private
  "xCloud PC1"–"xCloud PC5"; TelegramClient.renameChatIfNeeded renames legacy
  "xCloud Shares" channels at reuse.
- Cancel semantics re-verified against live behavior: private = deleteChat +
  row drop + slot freed (re-share recreates channel); public = message delete
  only; pool 5 max; same-file re-share reuses the live link.
- Duplicate file found in the real DB: two root objects, same name/size, same
  vault message 355467264; record B (36BE56EC, no rootHash, 15:40) vs record A
  (1DE982EC, has rootHash, 12:33). Root cause class: object-level dupes
  invisible to chunk dedupe. Fix: DatabaseManager.dedupeDuplicateObjects()
  (keep hash-bearing or older record, delete the loser + chunks), wired into
  the post-auth heal block so a corrected checkpoint republishes.
- Rename field: .id(renameTarget) on the alert TextField (fresh field per
  presentation — stale cleared text was being reused); onKeyPress "a"/"c"/"v"
  ignore while renaming so Cmd+A/C/C+V reach the text field.
- Build green, 67 tests green, committed 27d0799, Debug app relaunched (heal
  confirmed: duplicate gone). No Release per user policy.

## 2026-08-17 (evening) — Post-v3 polish: Shared page redesign, Library covers, transfer clarity

- **User feedback on the v3 Shared page**: "the UI is too bad, it doesn't even
  follow the app's design scheme — the simple cards like before were already
  good". Redesigned `ShareManagerView` to the app's transfer-row card language:
  full-width glassEffect cards, leading kind icon circle (lock orange / globe
  green), name + expiry line ("Expires in 3 days" / "Never expires"), small
  kind badge on the card's top-trailing corner, and Copy Link / Cancel Share in
  the trailing ellipsis menu (same circle menu as transfer cards). "Cancel All
  Shares" only appears when >1 active. `.shared` page can no longer
  Upload/Create (page lists links, not files).
- **Library covers fixed**: root cause — `bookCoverURL` was cache-only by
  design; uncached books returned nil (placeholder) until the book was opened
  (that's when DownloadEngine generated the cover). Now missing covers on
  uncached books trigger a background fetch (new `BookCoverFetcher` actor:
  single-flight per book, max 3 concurrent, `DownloadEngine.download(quiet:)` →
  cover generated → `.xcThumbnailReady` → grid re-keys → cover appears live).
  No download storm, no waiting for the user to open books.
- **Transfers cards explained (user asked "are those even real?")**: YES — real
  persisted history rows, including phantom-era junk names (from the
  phantom-object bug sessions). Nothing was deleted. Added clarity: terminal
  statusText is now semantic ("Uploaded" / "Downloaded" / "Imported" instead of
  "Complete") and cards show their finished time ("Uploaded · 4:12 PM"; older
  rows "MMM d, h:mm a") via new `Item.finishedAt`.
- **Release reinstall**: built Release (bundle id `.prod`), backed up
  `~/Library/Application Support/xCloud-Prod` → `xCloud-Prod.bak-2026-08-17`,
  replaced `/Applications/xCloud.app` (1.2.0) — the prod session (Telegram user
  946154826, state ready) lives in Application Support so it survives the
  swap. Both Debug (com.nemesys.xcloud.xCloud) and Release (…prod) apps can run
  side by side with separate data — the basis for the user's two-account share
  test.
- **Tests**: full suite green (46 unit + 4 UI + 4 launch). Commits: `d9a3e4d`
  (v3 share upgrade) + `95d7579` (polish round 1: cover fetch, semantic
  statuses) + `cf3a1ce` (polish round 2: Shared page = All Files-style GRID
  cards with lock badge / green unlocked-lock badge, fixed-size transfer grid
  cards, "Cancel All" label).
- **Round 2 (user correction)**: the user did NOT want row cards on the Shared
  page — "just create the same cards which are in all files, with that small
  lock for private shares and green unlocked lock for public shares". Redone:
  Shared page is now a LazyVGrid of cards structurally identical to the file
  browser's (thumbnail 115pt + name/status, rounded 12, hover scale), kind badge
  top-trailing corner (orange lock.fill / green lock.open.fill), Copy Link +
  Cancel Share in the ellipsis menu AND right-click menu; "Cancel All Shares"
  button → short "Cancel All". Transfers grid cards were text-sized (name
  wrapping 2 lines made cards unequal) — now fixed-shape like file cards (92pt
  icon area, 1-line name/status with fixed heights) so every card is
  pixel-identical. Debug app relaunched; DB confirms 3 real active private
  shares render as grid cards.
- **Round 3 (user correction)**: lock badge moved to the card's TOP-LEFT as a
  24pt button exactly like the top-right ellipsis menu (same size/styling);
  private = orange `lock.shield.fill`, public = green `lock.open.fill`.
  Share cards were dead (no tap gestures) — now single-click selects (accent
  highlight) and double-click reveals the shared file via `revealObject`
  (group shares reveal the first member). **User policy change: no Release
  builds until the user approves — Debug only from now on.**
- **Round 4 (user correction)**: arrow-key navigation on the Shared page was
  missing — now left/right move along the row and up/down move to the same
  column of the next/previous row (row-major math over the grid's column
  count), the scroll view follows the selection, and Return reveals the
  selected share's file. New window-scoped `ShareKeyMonitorView` (same
  technique as the file browser's monitor; FileBrowserView now defers on
  `.shared`). Lock icon fixed to the proper padlock: orange `lock.fill`
  (private) / green `lock.open.fill` (public) — the shield-lock was rejected.
- **Round 5**: volume slider was DEAD — diagnosed with a standalone CoreAudio
  probe: the default output (OnePlus Buds 3, Bluetooth) exposes volume scalar
  only on stream elements (1, 2); master (0) and 'virm' return unsupported.
  The app pinned the main element so reads fell back to 1.0 and writes failed
  silently. `SystemVolumeManager` now probes candidate elements
  [Main, Master, 2, 3, 4] for a readable scalar at start and on every
  default-device change, and reads/writes the resolved element. Seek sliders
  checked (correct value×duration math in both players). Shared page: section
  headers simplified to "Public"/"Private"; Space bar now opens the selected
  share like double-click (Return too).

## 2026-08-14 — Foundation work

- **ROADMAP decisions**: Finder integration deferred to a **File Provider
  extension** (iCloud/Drive-style; WebDAV and sync-folder models rejected) —
  5-milestone plan + three hard problems written up. Auto-backup deferred on
  macOS. Other OS support parked.
- **Transfer history persistence** (DB v11–v13, `Storage/Models.swift`,
  `AppState`, `TransfersView`): finished transfers persist to the `transfers`
  table and restore on launch; "Clear Finished" deletes only terminal cards.
- **Apple-style liquid-glass transfer FAB** with progressive fill + morphing
  cell-division animation; round 48×48 sphere matching the Add button.
- **Private Vault encrypted-download integrity verification**: AES-GCM slice
  stride, temp-directory race, and SVG WebKit rendering fixes.

## 2026-08-15 — Media pipeline, players, and cloud hardening

### HDR / EDR color pipeline (mpv)
- Root cause of "washed-out but brighter" video: the layer opted into EDR +
  float framebuffer unconditionally, so mpv's sRGB pixels were decoded as
  linear light (double gamma). Fix mirrors IINA: `applyColorPipeline()` —
  EDR **off** by default; observes `video-params/gamma` + `primaries`; SDR (or
  HDR on an SDR display) → sRGB + mpv tone-maps itself; real HDR (PQ/BT.2020)
  on an EDR display → PQ color space + `target-peak` + clip. Verified live
  against the user's HDR file on an SDR display (`SDR pipeline active`).

### Cache policy
- Replaced fixed 5 GB LRU with `enforceCacheBudget()`: hard cap
  (`xc.cacheCapGB`, default 5, 0 = unlimited) + free-space floor (evict when
  free < 15 GB), 15-min modification guard for in-flight downloads; runs at
  launch, on a 30-min timer, and around downloads. Settings → "Local Storage
  & Cache".

### Playback pipeline (mpv)
- **AVFoundation REMOVED entirely (user mandate)**: the player kept
  resurrecting through side doors — AVAssetResourceLoader streaming,
  AVPlayer fallbacks, AVKit `NativeAVPlayerView`, AVAssetImageGenerator
  thumbnails, AVURLAsset duration badges. All deleted. mpv is the ONLY media
  engine; video/audio previews come from Telegram's attached thumbnails;
  durations come from mpv during playback. Zero AV* symbols in the codebase.
- **Any-container streaming**: `VaultStreamServer` — loopback-only HTTP/1.1
  byte-range server mapping `GET /stream/<id>` onto the decrypt+slice
  pipeline; mpv/FFmpeg demuxes mkv/webm/avi/ts/flv/...; HTTP keep-alive +
  Range header accumulation fixes (split TCP segments broke seeks).
- **HDR/EDR render path**: RGBA16F backbuffer + extendedSRGB window colorspace
  only on EDR displays (SDR Macs get the proven 8-bit surface); pipeline-key
  guard against reconfig churn; mpv log level v→warn.
- **AV1 playback**: M2 has no hardware AV1 (arrived with M3) — mpv falls back
  to software dav1d; telemetry verified `vfps:60.0`, zero drops.
- **Dolby/Atmos**: bitstream passthrough (`audio-spdif=ac3,eac3,truehd,dts` +
  exclusive mode) when the user enables it; FFmpeg decodes otherwise. Verified
  with the app's exact bundled libmpv via a `/tmp/mpvtest` harness.
- **Video thumbnails — headless FFmpeg** (`VideoFrameExtractor`): QuickLook
  always picks frame 0 (black for Atmos files); dead ends documented
  (invisible-window GL capture, mpv SW renderer, `--vo=image`, offscreen CGL
  FBO). Direct FFmpeg frame extraction: seek back to keyframe, decode forward,
  score 5 candidate positions by luma variance, sws_scale to RGBA with real
  colorspace/range, NSBitmapImageRep encode. Opens local files AND loopback
  stream URLs (uncached videos get thumbs with a few byte-range requests).
- **mpv init/teardown off the main thread**: core init + teardown moved to
  mpv's background queue (`onCoreReady` fires on main); teardown binds the
  retained CGL context before freeing the render context (SIGSEGV fix in
  `glDeleteTextures` during async teardown); `vd-lavc-dr=no` (8K AV1 crash).
- **Background playback**: audio plays headless (`vo=null`); video
  headless→view handoff (resume exact position) built, then **removed by user
  decision** — videos stop when the theater closes; mini player is audio-only.
- **Media-type recognition**: `isAudio`/`isVideo`/`isPhoto` extension
  fallbacks so `.mkv`/`.wav`/`.ogg` uploads as octet-stream still route
  correctly to the player and category pages.

### Player UI (flux-style redesign)
- **`PlayerControlsView`** — self-contained chrome owning its own 3 s hover
  auto-hide: top bar (minimize/title+size/volume/fullscreen/close), truly
  centered transport (-10s/play/+10s glass circles), bottom bar (tracks pills,
  drag seek bar, monospaced times), "Press Esc again to exit" pill. Two-step
  ESC everywhere (windowed + full screen). Full-screen window
  (`PlayerFullScreenWindow`, ObservableObject) hosts the same controls over
  the re-parented layer. `.contentShape(Circle())` hit-test fix (buttons only
  clicked in the exact center).
- **Music player** — dedicated Apple Music/Spotify-style UI
  (`TheaterAudioPlayerView`): hero artwork disc + ambient bloom + glow pulse,
  custom drag scrubber, glass transport, volume pill, "x of y" counter;
  thumbnail loads in parallel, never gates playback.
- **Opening-lag diagnosis**: two sequential network awaits gated playback
  (stream layout fetch + thumbnail before `play()`), and the ghosted
  "Preparing…" glass card showed through the fade-in. Fixes: `play()` fires
  immediately in parallel with `loadFile()`; optimistic stream URLs; in-flight
  `loadLayout` dedup; parallel thumbnail.
- **First-play-after-restart lag**: one-time process costs (MPVKit dylib +
  FFmpeg codec tables + mpv core init + NWListener bind) sat on the first play
  path. Fixed with launch-time warm-up: `VaultStreamServer.startServer()` +
  `MPVController.warmUp()` (throwaway headless core, 4 s timeout) 0.5 s after
  Telegram connects.
- **Buffer loader**: `PlayerStatusOverlay` — spinner + "Loading…" during
  initial load; progress ring with live % (mpv `cache-buffering-state`) during
  stalls; present in windowed AND full-screen player.
- **Mini player**: audio-only, visible only while the theater is closed;
  minimize/ESC springs it in as the theater fades (the "full player turns
  into mini player" transition). Dead full-screen audio overlay deleted.

### Volume
- **Crackle fix**: slider drags wrote mpv's `volume` twice per tick (slider +
  engine echo sink) → 100+ gain re-applications/sec. `MPVController.setVolume`
  coalesces behind a 60 ms debounce.
- **System volume**: sliders now control the macOS **system output volume**
  (`SystemVolumeManager`, CoreAudio) — keyboard keys and the sliders are one
  control, always in sync; mpv's volume pinned at 100; the whole mpv-volume
  feedback loop deleted.

### Cloud / storage hardening
- **CATALOG COLLAPSE INCIDENT (recovered)**: an automatic repair chain
  deleted the media from Telegram — a no-gate purge cascaded into a collapsed
  checkpoint publish, which restored folders-only, which passed the orphan
  purge gate and deleted every chunk message. **Repair is now reconstruct-only
  and never deletes.** Safety rails: publish floor on non-folder counts,
  restore refuses folders-only checkpoints, backup tables inside
  `replaceCatalog`, `resetVault` confirmation, ratio-guard on the orphan
  purge. Recovery: cache preserved, DB + channel deltas merged into a
  recovered catalog, `--recover-upload` re-uploaded 15/18 files with original
  IDs/keys. 3 files permanently lost (bytes nowhere).
- **Partial-cache fix**: `isCached` required `size > 0` — a truncated 1 GB
  download counted as cached and fell back to a broken player. Now requires
  the cache file to be EXACTLY `object.size` (`partialCachedFileIsNotCached`).
- **Snapshot system**: `CatalogSnapshot` — instant iCloud-style restore from
  `xcloud:dbsnapshot:v1:` documents, checkpoint pruning, collapse guards.
- **Share links**: cloud-to-cloud sharing via temp Telegram channels +
  obfuscated `xcloud://share#` blobs (invite + key + expiry, default 7 days),
  positional chunk pairing, revoke-on-delete.
- **Archive mode** (DB v16): `isArchived` flag + Archive sidebar destination,
  recursive multi-select archiving, hidden everywhere else, defensive decode.
- **Thumbnail pipeline**: tiered self-healing (memory → disk → Telegram
  attached → thumbnail-only quiet download, photos only) + launch warm-up;
  face-aware subject cropping (Vision) applied to local generation and
  uploads; face featureprint clustering (2048-dim) for People pages.

### Library & readers
- **Library destination + BookReader**: EPUB (spine + NCX TOC in WKWebView),
  text, PDF, comics (paged/webtoon); themes, font sizing, progress. EPUB
  SIGABRT fixed (JSONSerialization + top-level String → JSONEncoder).
  Portrait poster cards from QuickLook-generated covers.

### Photos / Videos pages
- **Google/Apple-Photos-style Photos + Videos pages**: boxy 1:1 grids, day
  sections with pinned date pills, hover polish, selection badges, Albums +
  Playlists rows with layered stack tiles, drag-drop into collections. Media
  pages aggregate across the cloud (every file of that type from all folders;
  plain folders never render — user explicitly rejected that).
- **On-device People** (`FaceEngine`): face detect → tight crop → featureprint
  embedding → incremental cosine clustering, rename/merge, face thumbnails in
  `xCloud/faces` (survive cache clears, not synced).
- **Album covers** (DB v19): auto first-photo, manual picker, "Set as Album
  Cover" context action, chunk-caption metadata sync.
- **Keyboard navigation**: local NSEvent monitors (menu key-equivalent
  conflicts), true grid row/column walking via onOrderedChange/column count
  reports, theater preview arrow navigation, album-inside navigation.

### Bugs / incidents
- **"Work is gone / old app keeps opening"**: TWO COPIES of the project — the
  agent built the worktree while the user's Xcode built the main folder.
  Fixed by rsync; the sync rule is now documented in HANDOVER.md §2.
- **AV1 thumbnail CPU storm**: AVAssetImageGenerator failing on AV1 (no hw
  decoder on M2) retried across every grid render — codec gate, then mooted
  by the AVFoundation removal.
- **Video volume slider overlap, space-key replay, button hit targets,
  folder navigation in preview** — all fixed.
- **"Photo moves back automatically"**: stale `modifiedAt` lost the LWW merge.
  Rule: every mutation MUST bump `modifiedAt` via `updateObject`.

---

## 2026-08-15 — First commit

The entire accumulated body of work (2026-08-14 + 2026-08-15) was committed
to `main` in one commit. Generated junk excluded + gitignored: the worktree
copy (`.freebuff/worktrees/`), `*.dmg`, `*.profraw`, `website/`
(275 MB node_modules), the dev Telegram DBs, and `LocalMPVKit/.swiftpm/`.
New `JOURNAL.md` (this file) + HANDOVER.md kept in sync.

---

## 2026-08-15 — Library shelf polish (book covers)

- **Menu button leak fixed**: the ellipsis overlay was attached AFTER the
  breathing-room padding, so it aligned to the padded box and its top edge
  poked above the cover. Moved INSIDE the cover's own bounds (attached right
  after the clip) with a clean 8 pt inset (`FileBrowserView.bookPosterCard`).
- **Menu button style matched**: same look as every other card's menu —
  full opacity, `Color.black.opacity(0.40)` circle + glass (the hover-fade
  was rejected by the user).
- **Reading-progress bar**: Apple Books-style 4 pt accent bar pinned to the
  cover's bottom edge once a book is > 2% read. The reader now persists a
  throttled 0–1 scroll fraction (`xc.reader.progressFraction.<id>`,
  `BookReaderView.persistScrollFraction`); comics report page position.
  Covers read it live via dynamic-key `@AppStorage` on the grid item.
- **Richer placeholder**: muted gradient "dust jacket" + serif spine-style
  title instead of a bare icon.

## 2026-08-15 — Photos page: transfer progress + keyboard navigation

### Upload progress stutter (30 → 27, 70 → 68) — two root causes, both fixed
1. **Chunk retry resets**: TDLib resets a retried segment's
   `uploaded_size`, so an in-flight chunk's fraction dipped and dragged the
   aggregate down. `ParallelUploadProgress.setFraction` is now monotonic per
   chunk (`UploadEngine.swift`).
2. **Parallel uploads finishing**: the FAB averaged only ACTIVE transfers,
   so when one of several parallel photos completed, its done work left the
   denominator and the overall jumped backward. TransferCenter now keeps a
   `settledWork` accumulator + `settledItems` set: completed transfers count
   at 100% until the batch ends (a new batch starts when an active transfer
   begins with nothing else active; unsettle on discard/remove/clear/evict).
   New `TransferCenter.batchProgress` is monotonic by construction; the FAB
   uses it. `update()` clamps defensively too.

### "Random photo opens on →" — the recurring row/column navigation bug
- **Why it kept coming back**: the grid and the preview built their orders
  from DIFFERENT sources. The Photos/Videos grids show albums/playlists then
  day-grouped media (`MediaGridLayout.dayGroups`: newest day first, oldest
  first within a day) — an order no single global sort expresses. The
  theater's arrows re-derived the order from the browser's GLOBAL sort
  option (`sortedMediaBase`), so → jumped to whatever the global sort put
  next — a different, "random" photo.
- **The fix — one order source**: the grid's reported order now lives in
  `AppState.mediaOrderedIDs` (was browser-local `@State`); the theater's
  `navigableFiles`/`mediaFiles` walk exactly that sequence on Photos/Videos
  (fallback to the sorted list only before the grid reports). The filmstrip,
  "x of y" counter, audio queue, and up/down column math now all follow the
  on-screen grid. Media grids also publish their adaptive column count to
  `appState.gridColumnCount` (previously only the standard grid did, so the
  theater's vertical stepping used the wrong column count on media pages).
- This is why Apple Photos / Google Drive never hit it: the viewer consumes
  the grid's own layout. Lesson: the preview must never rebuild navigation
  order from a different source than the visible grid.
## 2026-08-16 — Thumbnail pipeline hardened, audio-message support, vault channel archiving

### App freeze after "local cache purge" — main-thread FFmpeg network poll
- Sample (`/tmp/xcloud-sample.txt`) showed the extractor task body executing ON THE
  MAIN THREAD despite `Task.detached`: this Swift runtime runs the nonisolated
  `@isolated(any)` closure inline via `completeTaskWithClosure` on the creating
  thread, so `avformat_open_input` → `ff_network_wait_fd_timeout` → `poll` (no
  timeout) jammed the UI forever after a purge re-keyed the grid and uncached
  videos took the stream-URL branch (loopback server not answering yet).
- Fix (`Engine/VideoFrameExtractor.swift`): `rw_timeout` + `timeout` AVOptions
  (15 s, via `OpaquePointer` AVDictionary) on remote opens; extraction now hops to
  `DispatchQueue("com.xcloud.thumbnail-extract", .utility)` through
  `withCheckedContinuation` + `withTaskCancellationHandler`; a
  `DispatchSemaphore(value: 2)` caps concurrent extractions.

### Upload-time thumbnails — verified end-to-end + JPEG compliance
- The app already attached an upload-time thumbnail (`InputThumbnail`) to every
  chunk message; this session verified the whole chain with real uploads of every
  type (images/audio/video/epub) + a cache-clear recovery test: 15/15 files
  regenerated or re-fetched (`-tg.jpg`) from the channel.
- Polished the encoder: `ThumbnailCrop.jpegData(from:quality:)` (CGImageDestination,
  q0.85, progressive via `kCGImagePropertyJFIFIsProgressive`, color-share
  optimized). `UploadEngine` consolidated four generation paths into
  `generateThumbnails(for:objectID:isVideo:)` (one subjectSquare at 640 → 2x PNG +
  aspectFit 320 → `-up.jpg`). FaceEngine thumbnails switched to the same encoder.
  All `-up.jpg` outputs verified: 320×320, progressive, <200 KB (TDLib
  `inputThumbnail` limits: JPEG, ≤320 px, <200 KB).

### The mp3 mystery: TDLib auto-converts .mp3 documents into audio messages
- A test mp3 neither streamed nor fetched a thumbnail; wav/ogg were fine. Root
  cause: `InputDocument.disableContentTypeDetection` was **false**, so TDLib
  converted the `.mp3` chunk into `messageAudio` — and the app's
  `primaryFile`/`thumbnailFileId`/`thumbnailData` switches only knew
  document/video/photo, so both streaming (`getFileId` threw) and thumbnail fetch
  returned nothing.
- Fix: `disableContentTypeDetection: true` (future uploads always stay documents,
  keeping real filenames), **plus** full `messageAudio` support in
  `primaryFile` (`audio.audio`), thumbnail fetch (`albumCoverThumbnail`/
  `albumCoverMinithumbnail`), caption extraction, the repair/rescan diagnostics,
  channel dump, orphan purge, and `blobCaption` — the already-uploaded mp3 streams
  and fetches a thumbnail without re-uploading.

### Vault channel auto-archive + mute
- The channel now keeps itself out of the Telegram chat list: at every post-auth
  setup the app calls `addChatToList(chatListArchive)` + mutes it
  (`setChatNotificationSettings(muteFor: 367 days)` — TDLib clamps >366 d to
  forever). The mute is essential: TDLib auto-moves UNMUTED archived chats back to
  the main list when a new message arrives, which would happen on every upload.
- Lesson learned: the first attempt placed the call inside `ensureVault()` after
  the vault save — but `ensureVault` returns EARLY for an existing vault, so the
  archive never ran for the user's real vault. Moved to `completePostAuthSetup`
  (runs every launch).

## 2026-08-16 — Backup mirror channel ("xCloud Restore")

### The idea (user): disaster-recovery mirror channel
- Research first: the "1,000 forwards/day" Telegram limit floating around is a MYTH —
  tginfo.me (authoritative limits reference) lists NO daily forward or upload quotas.
  Real limits are rate-based: ~1 msg/sec sustained per chat (flood control, already
  handled via `withFloodWait`), 2 GB/4 GB per file (irrelevant to 128 MiB chunks),
  captions 1,024/4,096 chars, non-Premium upload speed throttling after an
  undocumented monthly data threshold, 500/1,000 channel+group memberships. Full
  notes in ROADMAP.md. Conclusion: the backup concept was never cap-blocked, and no
  in-app "daily limit" warnings are warranted (user decision).
- User decisions: **one** mirror channel, no trash/retention channel (Trash is
  already the backup; permanent delete = gone from both mirrors), skip in-app
  warnings for now.

### Implementation (DB v20)
- `vaults.backupChannelID` + `backup_msgs` queue table (messageID PK, objectID,
  backupMessageID, status, attempts, createdAt).
- `Engine/BackupSync.swift` (new): `enqueue` (INSERT OR IGNORE + kick drainer),
  `editAndMirror` (caption edits synced to the backup copy via the mapping; edits
  before a forward are picked up automatically since the forward copies the current
  caption), `deleteFromVaultAndBackup` (both channels + mapping rows), `wipeBackupChannel`
  (vault reset), and the `BackupDrainer` actor — serial, flood-wait-aware, coalescing.
- `VaultManager.ensureBackupChannel()`: adopt-or-create "xCloud Restore", archive +
  mute (same as the vault); called from `completePostAuthSetup` every launch (the
  ensureVault early-return lesson from the archive task applied again).
- `TelegramClient.findVaultChannel` generalized to `findChannel(title:)` +
  `isChannelNamed(id:title:)`; `findBackupChannel()` added.
- Mirror hooks at every vault-channel message: UploadEngine chunk sends, CatalogSnapshot
  checkpoint/delta publishes (+ prune mirrors old-checkpoint deletes), VaultManager
  vault-key record post, AppState folder-metadata sends, unencrypt-file sends.
- Delete-forever now removes messages from BOTH channels; same for orphan purge,
  partial-upload cleanup, stale key records, and vault reset (full wipe).

### Verification status
- Build green (main + worktree), full test suite green, app relaunched. Pending
  user confirmation: "xCloud Restore" channel appears archived/muted, uploads are
  mirrored, permanent deletes vanish from both channels.

## 2026-08-16 — Backup mirror: debug + rename + root cause

### The bug: negative chat IDs vs `> 0` guards
- User tested: upload worked, but nothing was mirrored. DB forensics showed the
  `backup_msgs` queue was filling up with `attempts = 0` — the drainer never even
  tried to forward.
- Added file-based mirror logging (`/tmp/xcloud-backup.log`; the unified log is
  unreadable on this machine and stdout is lost when launched via `open`) and
  relaunched: `drain skipped (no vault/backup channel/authorization)`.
- Root cause: **`backupChannelID > 0` checks — Telegram chat IDs are large negative
  numbers** (`-100xxxxxxxxxx`), so `-1004350130680 > 0` is false and the guard ALWAYS
  failed. This silently killed the drainer, `syncCaption`, backup-side deletes and
  `wipeBackupChannel` — the whole mirror feature was dead on arrival.
- Side effect of the same bug: `ensureBackupChannel`'s early return never triggered,
  so every launch re-ran the full channel search (~10 s of launch time). When the
  user deleted the empty "xCloud Restore" channel from their Telegram client, the
  relaunch created a fresh "xCloud Backup" channel (-1004338372548) instead.
- Fix: replaced all five `backupChannelID > 0` guards with plain
  `if let backupID = vault.backupChannelID`.
- Verification: relaunched; the 2 queued rows (test chunk + delta) forwarded to the
  new channel and marked `done` (backup messages 1048577/1048585). Drainer logs
  every forward; `drain done (forwarded N)`.
- Rename per user request: channel is now **"xCloud Backup"**; `findBackupChannel`
  adopts a legacy "xCloud Restore" channel if present and renames it via
  `setChatTitle`.

## 2026-08-16 — Notes feature removed

- User decision: notes were never used; they are the one feature that is local-only
  (never synced to the vault channel, no catalog/snapshot/backup involvement), so
  they didn't fit xCloud's cloud model. Remove entirely; no notes exist to preserve.
- Deleted `Features/NotesView.swift` + `Features/NoteEditorSheet.swift` (also
  stripped from project.pbxproj — they were still explicitly referenced there,
  unlike the auto-synced root group).
- `AppState`: `.notes` destination removed (sidebar entry auto-disappears via
  `allCases`), `notes`/`editingNote` state, `loadNotes`/`createNewNoteDraft`/
  `createNote`/`updateNote`/`togglePinNote`/`trashNote`/`deleteNoteForever`,
  `emptyTrash`'s trashed-notes purge, `notes = []` in reset.
- `Models`: `NoteRecord` removed. `DatabaseManager`: note CRUD methods removed,
  `deleteVaultAndData` note cleanup dropped, **v21-drop-notes** migration drops the
  table (v7/v8 migrations stay — GRDB only runs unapplied ones).
- UI: trashed-notes sections on the Trash page, `trashNoteMenu`/helpers, "New Note"
  in the FAB, key-monitor defers and page-context-menu exceptions referencing
  notes. Unit test `noteRecordPersistenceAndPinToggle` removed.
- Gotcha: worktree had silently diverged — the freebuff branch's HEAD predates
  main commits that touched `Engine/TransferCenter.swift` and
  `Features/BookReaderView.swift`; the test host compile caught the mismatch
  (`TransferCenter.batchProgress` missing). Rule reinforced: sync the FULL tree
  (diff -rq), not just files touched this session.
- Build green (main + worktree), full test suite green.

## 2026-08-16 — Forward-based shares, unified caption codec

- **User decision (zero-upload shares)**: the old share flow re-uploaded files into
  a disposable channel. User asked why the vault copy couldn't just be forwarded —
  the blocker was caption incompatibility (recipient only read `xcloud:share:v1:`,
  and captions can't be rewritten on a reference forward), `protectContent`, and
  key wrapping. User empirically proved forwarding vault messages to a second
  account works (`protectContent` doesn't block it; `.bin` files only fail to play
  because they're raw splits/ciphertext). Chose: **forward-based shares** with one
  **reusable share channel**, **no encryption for shares** (link is the only
  credential; vault file access + leaked link = vault file decryptable — accepted).
- **New `Engine/ChunkCaption.swift`**: unified caption codec, ONE prefix (`xcloud:`)
  + self-describing JSON `kind` (`"chunk"` / `"object"`). Fields: id, name, size,
  mime, parentID, isPrivate, isFolder, trashed, isFavorite, index, totalChunks,
  wrappedKey, chunkSize, plainHash, rootHash, v. `encode` emits **sorted keys**
  (deterministic across processes — the prefix assertion in tests otherwise flaked
  on Swift's per-process dictionary hash seed). Legacy prefixes `xcloud:v1:` and
  `xcloud:share:v1:` are **read forever** (sent captions can't be rewritten);
  writers use unified only. `Meta.effectiveChunkSize` derives the assumed chunk
  size for legacy captions via `ChunkPlanner.chunkSize(for:profile:.automatic,mime:)`.
  `isChunkCaption` drives VaultRepair's orphan purge (legacy = always chunk; unified
  must say `"chunk"`; `"object"` never is).
- **Uploads** (`Engine/UploadEngine.swift`): vault chunk captions now carry
  `chunkSize` + `plainHash` + `rootHash` in unified format.
- **AppState**: `syncObjectMetadataToTelegram` rewrites per-chunk unified captions
  (preserving index/plainHash/chunkSize — the old dict rewrite would have stripped
  them and broken forward-shares of renamed files); `unencryptFileInTelegram`,
  `revokeShares` and `resetVault` handle v22 shares; sync stats count via
  `ChunkCaption.isChunkCaption`.
- **DB v22-forward-shares** (`Storage/DatabaseManager.swift`): `shares.messageIDs`
  + `shares.wrappedKeyB64` columns, new `share_state` table (id=1 row tracks the
  reusable channel ID), accessors `shareChannelID()`/`setShareChannelID(_:)`.
- **ShareEngine rewrite**: v2 link `xcloud://share?v=2&id=…&ch=…&inv=…&key=…&name=…&exp=…&m=<msgIDs>&w=<wrapped>` —
  `m` = comma-joined forwarded message IDs, `w` = object key wrapped under a fresh
  share key (EMPTY for non-private files — parse guard only demands a key when `w`
  is non-empty, or for v1). Sender forwards each vault chunk into the reusable
  "xCloud Shares" channel (server-side copy, no size cap), rolls back forwarded
  copies on failure, records the share. **Key wrinkle**: forwarded chunks stay the
  sender's vault ciphertext; the caption's `wrappedKey` is locked under the
  sender's master key, so the LINK is the only key source on import.
  `importForwarded` reads messages by ID, re-derives chunk sizes (legacy captions
  lack them), re-forwards into the recipient's vault, re-wraps the object key under
  the recipient's master key. `importLegacy` kept for v1 links. Expiry cleanup now
  deletes **per-file messages** from the reusable channel and retires the channel
  only when it holds nothing else; legacy shares keep whole-channel deletion.
  Self-open matching: v2 by messageIDs equality, v1 by channelID. Re-share of a
  live share returns the identical obfuscated link.
- **Reusable channel**: created lazily (channel, not group — same "group"
  classification trap as the vault), archived + muted; per-share **one-use expiring
  invite**; retired when no active outgoing shares remain.
- **Tests**: `unifiedCaptionCodecParsesAllFormats`, `forwardShareLinkRoundTripsMessageIDsAndKey`
  (v2 + plain v2 + v1 legacy). Two suite-visible bugs fixed while turning them
  green: (1) `ShareLink.parse` rejected empty-key v2 links (non-private files) —
  real bug, sender emits `key=` for them; (2) the codec test's raw prefix assertion
  depended on nondeterministic dict key order → encode now sorts keys.
- Build green (main + worktree), full test suite green (51 unit tests).

## 2026-08-16 — Share mechanism verified live; window-disappearing fixed; production build isolated (v1.1.0)

### Live verification of forward-based shares (first real end-to-end)
- First production-run share worked: reusable **"xCloud Shares"** channel created
  (archived + muted), vault chunks **forwarded server-side** into it
  (`messages.forwardMessages`), v2 link minted and stored (`shares.linkBlob`), all
  from the previously-restored catalog. Chunks in the reusable channel are the
  sender's vault ciphertext with unified captions — the recipient's import path
  (read by ID → parse captions → re-forward into own vault → catalog) matches by
  `m` (message IDs) only.
- **Stale-record hijack** (found live): re-sharing gave the old pre-rewrite v1
  link — `reusableShareLink` matched a legacy share record (state active, channel
  still in TDLib cache) and returned its v1 link verbatim, so the forward path
  never ran. Fixed: skip `messageIDs`-empty records when reusing; re-sharing
  mints a fresh v2 share; legacy records stay importable until expiry. Test
  `shareReusesLiveLinkInsteadOfMintingNewOne` extended (v2 records carry
  `messageIDs`, step 4 asserts legacy never reused).
- **Empty-catalog incident**: share attempt failed with `sourceUnavailable` — the
  local DB had 0 objects/0 chunks because the previous session's
  `CatalogSnapshot.restore()` never completed its write. Relaunching the app under
  a pty (`script -q /tmp/xcloud-app.log <binary>`, line-buffered stdout) made the
  prints visible: restore succeeded ("19 objects, 22 chunks"); every chunk has a
  message ID; no re-upload needed — the files had been in the channel all along.
- **Stale-binary incident**: an earlier "nothing happened" trace turned out to be
  the pre-rewrite binary still running (PID from 14:44, `xcloud:share:v1:`
  captions in its log) — relaunch on the fresh build fixed it.
- Deferred (user: "wait for the testing"): real two-account E2E, and the
  protectContent **second hop** (recipient re-forwarding protected copies).

### Flag-only private vault — user decision (NOT yet implemented)
- Private = `isPrivate` DB flag + PIN-gated section + `.bin` chunks; **no per-file
  encryption**. Move in/out = instant flag flip (no re-upload; the current
  `unencryptFileInTelegram` decrypt + re-upload path goes away). Shares of private
  files disabled ("move it out of Private to share"). Share links lose the key
  layer (`w`/shareKey); import never unwraps. Accepted tradeoff: encrypted chunks
  were the only thing protecting private chunks from a Telegram-session/account
  compromise; `.bin` naming is not protection. Old encrypted chunks become junk
  (throwaway test data). Not started — user wants the share mechanism proven first.

### Window-disappearing on link open — fixed
- Symptom: opening the shared link in the browser while the app runs made the main
  window vanish (process stayed alive). Reproduced state: app had **zero windows**
  (System Events), only a Dock thumbnail + menu-bar-sized windows in
  `CGWindowListCopyWindowInfo`.
- **Stale URL-handler registration**: `lsregister` showed the `xcloud://` claim on
  a DELETED build path (`DerivedData/xCloud/Build/Products/Debug/xCloud.app`, same
  bundle id as the running dev app) plus long-gone DMG-check copies — the exact
  "two instances fight over the window" trap the single-instance guard warns
  about. Cleaned: unregistered/removed stale paths; re-registered the current
  build with `lsregister -f`. Verified by `open xcloud://share#…` → the running
  app receives the URL, reveals the file (self-open), window stays.
- **Hardening** (`App/TerminationHandler.swift`, `App/xCloudApp.swift`):
  - URL delivery now explicitly `deminiaturize`s a minimized main window before
    ordering it front;
  - zero-window recovery: posts `recreateMainWindow` (observed by the main and
    About scenes → `openWindow(id: "main")`) AND simulates the Dock-icon reopen
    (`applicationShouldHandleReopen`) twice, since SwiftUI `Window` scenes restore
    natively on reopen — all idempotent (`openWindow` on an existing `Window`
    scene is a no-op);
  - diagnostic prints on the whole URL path (`xCloud URL: …`) — the previous
    silence made the disappearing window impossible to debug.
- The self-open reveal (file card flash) is confirmed working with both link
  forms: plain `xcloud://share?v=2…` and obfuscated `xcloud://share#<blob>`.

### Production build isolation (v1.1.0 DMG)
- **Problem**: Debug and Release shared bundle id `com.nemesys.xcloud.xCloud` and
  hardcoded `xCloud` data folders — the released app would share the dev app's
  Telegram session, keychain, database and TDLib state (and the single-instance
  guard would treat them as the same app). User requirement: the production
  version must not conflict with testing data.
- **Release config**: bundle id → `com.nemesys.xcloud.xCloud.prod`,
  `MARKETING_VERSION` → 1.1. Debug keeps `com.nemesys.xcloud.xCloud`. The keychain
  service derives from the bundle id (`Crypto/KeychainStore.swift`), so the
  production build has its own Telegram session/PIN/master key automatically.
- **`App/AppPaths.swift`** (new): `dataFolder` = `"xCloud"` (dev) vs
  `"xCloud-Prod"` (prod, bundle id ends in `.prod`). All hardcoded data paths now
  scoped through it: database, TDLib dirs + file cache, downloads cache, upload
  tmp/thumbs, face vectors, and the URL handoff file. Handoff notification name
  now derives from the bundle id so dev and prod never hand links to each other.
- Built `xCloud-1.1.0.dmg` (`scripts/make_dmg.sh 1.1.0`): Release, hardened
  runtime, unsandboxed (same as 1.0.0), verified `com.nemesys.xcloud.xCloud.prod`,
  `hdiutil verify` OK. Dev and prod can be installed and run side by side; the
  share link in the browser opens whichever build registered `xcloud://` last
  (documented in DISTRIBUTION.md; "Import Shared Link…" ⌘⇧I is the deterministic
  path inside the production app).
- Full test suite green (52 tests) in the worktree; main + worktree byte-identical.

---

## 2026-08-16 (second session) — Fresh-install deadlock fixed (v1.1.1)

- **Bug (user-reported)**: installed the v1.1.0 DMG, clicked "Connect Telegram"
  (the onboarding button) — the app showed the xCloud loading screen forever and
  never reached the API-credentials form.
- **Root cause**: fresh install → no stored API credentials → nothing ever starts
  TDLib (bootstrap and the login gate only start it when credentials exist) →
  `isAuthResolved` stays false forever → `RootView` renders the neutral
  `AuthSplashView` permanently. The onboarding "Connect Telegram" button only
  closes the sheet; the login gate it assumes it hands off to never appears,
  because the gate itself is gated behind `isAuthResolved`. The dev build never
  hit this because its keychain already had stored credentials — the fresh-install
  path had never been exercised. Disk evidence: prod keychain had `master-key` but
  no `telegram-credentials`; no `xCloud-Prod/tdlib` folder ever appeared.
- **Fix**: `AppState.hasTelegramCredentials` (set at bootstrap and after a
  successful credentials save) + `RootView` shows the login gate when
  `isAuthResolved || !hasTelegramCredentials` — no credentials → the API form
  appears immediately; credentials present → neutral splash until TDLib reports a
  state (unchanged, no login-gate flash on launch).
- **Verified live**: launched the rebuilt Release app against the untouched prod
  keychain/data; Accessibility tree shows the login gate ("Connect Telegram" /
  "Enter the API credentials from my.telegram.org" / API ID field) instead of the
  eternal splash. (Note: the TDLib `td_receive` thread that shows in the process
  log is spawned by `TDLibClientManager.init` — a red herring, it runs whenever
  `TelegramClient.shared` is touched, not just in `start()`.)
- **v1.1.1**: `MARKETING_VERSION` → 1.1.1, rebuilt Release, `xCloud-1.1.1.dmg`
  created + `hdiutil verify` OK. User reinstalls, enters API credentials, and the
  phone/code/password flow proceeds as in the dev build.

---

## 2026-08-16 (third session) — DMG paused; login-gate hit-testing findings

- **User decision**: stop working on the DMG/production path for now (no second
  device to test cross-account share with; the installed app's login gate is
  unusable). Resume with the dev/test build and improve other areas.
- **Finding 1 — field clicks**: the API ID/hash fields in the login gate only
  accept clicks near the text center; clicks on the rest of the field don't focus
  it. macOS 26 hit-testing issue with the custom-styled fields inside the
  `.ultraThinMaterial` card (the card itself was already moved to material
  background for an earlier container-glass hit-testing bug). Affects any build
  showing the gate, dev included.
- **Finding 2 — "Connect does nothing"**: the click actually worked. Evidence:
  `telegram-credentials` saved into the prod keychain at 19:05 and
  `xCloud-Prod/tdlib/db.sqlite` created at 19:06 (TDLib initialized). No crash
  reports. The gate presumably switched to the phone step, but the same field
  hit-testing problem blocked further input — perceived as "nothing happens".
- Paused: two-account share E2E via DMG (needs a second device), the
  protectContent second-hop check, and the DMG login-gate UX until the user
  wants to resume.

---

## 2026-08-16 (fourth session) — Encryption dropped: flag-only private vault

- **User decision executed**: per-file encryption is REMOVED. Private = `isPrivate`
  DB flag + PIN-gated section + `.bin` chunks; the vault key seal (PIN/device)
  still gates app access. Old encrypted chunks in the channel are junk (throwaway
  test-account data — the user wiped the channels before this session).
- **Upload/Download/Streaming** (carried from opencode, verified): `UploadEngine`
  writes plaintext chunks (`wrappedKey` nil/empty); `DownloadEngine` has no
  decrypt step (cache = plaintext file); `VideoStreamingEngine`'s `ObjectLayout`
  dropped `isPrivate`/`objectKey` — the byte-range server serves raw bytes.
  Chunk layout unchanged (128MB chunks, `CryptoEngine.sliceSize` arithmetic kept).
- **ShareEngine**: `share()` refuses private files (`ShareError.notShareable`,
  guarded before auth); the link's key layer (`w`/shareKey) is always empty;
  `importForwarded`/`importLegacy` never unwrap — imported files are recorded as
  plaintext. Reuse logic unchanged (live shares still return the identical link).
- **AppState**: `unencryptFileInTelegram` deleted; move out of Private is an
  instant flag flip, no decrypt/re-upload. UI copy updated app-wide (no more
  "AES-GCM / encrypted" claims in About, Onboarding, FileBrowser, share sheets).
- **Test fixes**: `ObjectLayout` test updated to the new init signature; the
  share-reuse test skips the `chatExists` stale-channel check under XCTest — the
  app-hosted suite boots the real app, whose auto-login flips `isAuthorized`
  mid-run and used to revoke the fake share records.
- Build green, full test suite green (48 unit tests).

---

## 2026-08-17 — Wrap-up: full-screen link fix CONFIRMED, release 1.2.0, cleanup

- **Full-screen link delivery — user confirmed FIXED** after the consolidated
  consult fix (raiseMainWindow leaves full-screen windows alone, the
  timestamp-guarded FullScreenReentryGuard re-enters if the OS kicks it out, the
  duplicate handoff no longer activates, and the chrome fixer keeps
  `.moveToActiveSpace` off full-screen windows).
- **Release build 1.2.0**: `xcodebuild -configuration Release -derivedDataPath
  build` (prod bundle id `com.nemesys.xcloud.xCloud.prod`), then
  `scripts/make_dmg.sh 1.2.0` → **xCloud-1.2.0.dmg (53 MB)**, verified via
  hdiutil; app inside reads 1.2.0. `MARKETING_VERSION` in the Release config was
  an uncommitted `1.1` leftover — bumped to `1.2.0` (also fixes the stale
  commit-state inconsistency). Reinstalled the `dmgbuild` tooling to
  `build/dmgbuild-tools` (it had been deleted with the stale build/ earlier).
- **Storage freed ≈ 20 GB**: deleted four stale DerivedData folders (xCloud,
  xCloud-wt, xCloud-cdpcj…, xCloud-ddqgy… — kept xCloud-main), cleaned /tmp
  agent junk (xc-unit logs, mpvshot artifacts), deleted stale untracked
  root-level duplicates `AppState.swift`, `RootView.swift`, and
  `project.pbxproj` (old flat project layout; not in the Xcode target — the
  App/ and Features/ copies are authoritative). Disk free 17 → 33 GB.
- `build/` and `xCloud-1.2.0.dmg` are gitignored. Both repo copies in sync;
  debug app still running.

## 2026-08-16/17 (eighth session) — Full-screen link delivery: consolidated consult fix

- External models (Claude + Qwen) confirmed the v4 approach and both emphasized:
  `.moveToActiveSpace`'s documented semantics ("move to active space instead of
  switching spaces") make it the prime culprit on full-screen windows; never
  order-front or activate a full-screen window during URL delivery; the duplicate
  instance must not activate the running one; and add a timestamp-guarded
  full-screen re-entry safety net.
- Implemented in TerminationHandler: raiseMainWindow leaves full-screen windows
  alone (only strips the flag); windowed path activates only when `!NSApp.isActive`;
  new `FullScreenReentryGuard` re-enters full screen if an exit lands within 0.75s
  of a delivery (0.4s settle delay; user exits never overridden); duplicate
  handoff no longer calls activate. Mission Control auto-space-switch is enabled
  on this Mac, so the setting wasn't the trigger.
- Escaping note: a str_replace with `String(format:)` nested quotes double-escaped
  the line (`\"` instead of `"`); fixed with a targeted byte-exact replacement.
- Handover item 60. Build green, tests green, zero crash reports, app running.

## 2026-08-16 (seventh session) — Login flash fixed; full-screen link delivery root cause

- **Login flash**: `hasTelegramCredentials` was set late in bootstrap → every
  launch flashed the login gate for logged-in users. Fixed by initializing it
  synchronously from the Keychain at AppState init.
- **Full-screen link delivery**: live-isolated with AX — delivering an
  `xcloud://` link while full screen made the window exit to windowed. Tested
  four variants: any app-side `NSApp.activate` / `makeKeyAndOrderFront` on a
  full-screen window during delivery exits full screen (window server pulls it
  out to become key on the current space). Final fix: `raiseMainWindow` leaves
  full-screen windows completely alone (only strips `.moveToActiveSpace`); the
  OS's own activation from the browser click switches to the window's Space.
  WindowChromeFixer also removes `.moveToActiveSpace` on full-screen enter.
- **Popup blocks full screen** = macOS sheet limitation, not a bug (same in all
  apps). Dismiss the dialog first.
- Handover item 59. Build green, tests green, zero crash reports, app running.

## 2026-08-16 (sixth session) — Share-link window vanishing: real root cause

- The full-screen guard alone didn't fix the "browser link makes the window
  disappear". Deep dive: `lsregister -dump` revealed NINE registered xCloud.app
  copies; the scheme resolved to an OLD `DerivedData/xCloud` build (18:36), so
  every link click STARTED a second instance of the old copy, which handed off
  to the running app and exited — and the running app only imported the link,
  never raised its window (`drainHandoff` had no raise; the raise code only ran
  in the process that received the URL from the OS, i.e. the dying duplicate).
- Fixed three ways: (1) self-register the scheme on every launch via
  `NSWorkspace.setDefaultApplication`; (2) `drainHandoff` now calls the
  extracted `raiseMainWindow()` (full-screen aware); (3) `handOff` uses plain
  activation instead of `.activateAllWindows`. Deleted 4 stale app bundles and
  unregistered all stale scheme entries (incl. a `/Volumes/xCloud` DMG record
  and `build/` Release/dmg-staging). Verified live: `open xcloud://…` spawns no
  second process and the running instance processes the link.
- Learned: agent-shell background (nohup) launches die when the tool command
  exits — the app wasn't crashing (zero crash reports), the environment was
  reaping it. Launch via `open` (LaunchServices) for persistence.
- Handover items 57–58. Build green, tests green, app running via `open`.

## 2026-08-16 (fifth session) — Share-link window recovery in full screen

- **Bug**: browser share link while the app window was full screen → window
  vanished. Root cause: `TerminationHandler` inserted `.moveToActiveSpace` into
  the window's `collectionBehavior` unconditionally; for a full-screen window
  (which owns its Space) that forces it OUT of full screen to follow the active
  space, stranding it off-screen. Fixed by guarding on
  `styleMask.contains(.fullScreen)` — pure `makeKeyAndOrderFront` lets macOS
  switch to the window's Space (also applied to Dock-reopen).
- **Collateral lesson**: the `rsync -a --delete` worktree→main sync wiped
  `website/node_modules` in main (gitignored; the worktree never has it). Two
  astro servers were running from it and files were locked. Restored via
  `npm install` in `website/`; from now on the sync MUST pass
  `--exclude node_modules`.
- Handover item 57 documents both. Build green, tests green, zero crash
  reports, app relaunched (fresh build).

## 2026-08-16 — Player polish: streaming fixes, keyboard, glass, share

- **Streaming replay buffering — root cause found (TDLib queue leftovers)**: TDLib's
  ranged `downloadFile` keeps downloading the WHOLE chunk (128MB files, one at a
  time, ~50s each) even for 8MB range requests; a stopped playback leaves those
  running, and the next play's ranges queue behind them → permanent buffering on
  replays. Fixes in `VideoStreamingEngine`: `invalidatePlayback(for:)` cancels
  fetcher chains + TDLib `cancelDownloadFile` per chunk on every teardown;
  `slicesPerFetch = 8` batching (8MB per TDLib call); per-chunk fetchers
  (probe/seek reads parallel to the forward stream); 30s `withFetchTimeout`
  safety net (hung download → cancel chain → retry supersedes it).
  `AudioPlayerEngine.stopMPVIfNeeded(for:)` captures the previous track's id so
  the teardown invalidates the RIGHT object on file switches. Telemetry confirms:
  MP4 replay now refills to a full 20s cache with zero pause-for-cache.
- **Player keyboard controls**: F7/F8/F9 media keys via an NSSystemDefined
  (subtype 8) monitor in TheaterView's `KeyView` + a regular F-key keyDown
  fallback (fn-lock keyboards); held-key repeats throttled to ~3/s. Video arrows
  now seek ±10s and ▲/▼ change volume instead of navigating files — through
  `AudioPlayerEngine.seekVideo(relative:)` which queues the seek (`pendingVideoSeek`
  / `seekAfterLoad`, applied on `MPV_EVENT_FILE_LOADED`) instead of switching
  files when mpv isn't ready.
- **Prev/next in the player**: glass chevron buttons pinned to the left/right
  edges, vertically centered with the transport; each shows ONLY when a file
  exists on that side of the playlist row (`canGoPrevious`/`canGoNext`). Fixed the
  black-loading-screen bug: skipping changed `currentTrack` but the theater stayed
  on the old file, detaching the player view — TheaterView now follows
  `currentTrack?.id` (`.onChange`) so prev/next (and EOF auto-advance) switch the
  theater to the new track.
- **Player chrome**: minimize chevron removed (X closes); file name + size shown
  only above the progress bar (not duplicated in the top bar); long filenames
  middle-truncate. Share button (glass `square.and.arrow.up`) added top-left —
  ShareEngine forward-based link copied to clipboard with a brief glass
  "Share link copied" confirmation.
- **Liquid glass consistency**: the audio player's and mini player's solid-accent
  play buttons converted to `.glassEffect(.regular.interactive(), in: .circle)`;
  video transport harmonized (58/76/58pt glass circles) so all transport controls
  app-wide are the same glass material.
- **Stale production build removed**: `~/Projects/xCloud/build/` (9.5GB) held a
  Release app with bundle id `com.nemesys.xcloud.xCloud.prod` — a separate app
  identity that hijacked the `xcloud://` scheme (browser opened it logged-out).
  Deleted the artifacts + `/private/tmp/xcloud-dmg-check*`, unregistered stale
  LaunchServices entries, re-registered the Debug build. The DMG backups
  (xCloud-1.0.0/1.1.0/1.1.1.dmg) are kept.
- **AGENT GOTCHA (two-copy rule)**: edits land in the Freebuff worktree
  (`.freebuff/worktrees/<id>/`); `xcodebuild` runs from MAIN (`~/Projects/xCloud`).
  Sync WORKTREE → MAIN for every changed file BEFORE building — a main→worktree
  sync after editing silently reverted fixes and shipped two builds without them.
- Build green, test suite green, zero crash reports; both repo copies identical;
  changes committed to main.

## 2026-08-17 (late) — Share-import "Not Found", blinking wrong file, post-login loading, phantom-object saga

**Context**: user tested the release build across accounts — sharing from the debug account and importing in the release account failed with "Not Found", importing a release-account photo link into debug "blinked" the first image, and the post-login loading screen lingered 10–20s.

### Root causes & fixes (all in main, Debug+Release rebuilt)
1. **forwardMessage stored TDLib LOCAL ids** → recipients' getMessage 404'd. Fixed with `resolveConfirmedMessageID` (waits for the server-confirmed id via completedSends/pending continuations); used by `sendFile` and `forwardMessage`. Old broken share records are auto-revoked by a `reusableShareLink` guard (ids must be clean multiples of 2^20). Verified live both directions.
2. **Self-open detection matched messageIDs alone** → cross-account id collision made a foreign link "reveal" (blink) the wrong file. Fixed: forward-based links match `channelID AND messageIDs`.
3. **Post-login loading** → `completePostAuthSetup` fetches identity/profile first; user card fills immediately.
4. **VaultRepair reconstructed chunks with `size/totalChunks`** (floor division → wrong boundaries, corrupts stream-layout fallbacks). Fixed to use the message's actual document size for both new and existing chunk records.

### The phantom-object saga (5C3C5432) — why "just delete it from the DB" never worked
A test-import object I deleted locally stayed in the **channel snapshot**. `CatalogSnapshot.upload()` merges the channel state as authoritative and `replaceCatalog`s — every launch resurrected it. Worse, one headless run's `upload()` published it as a **dbdelta**, which then re-injected it on every subsequent launch. Also discovered: a leftover **WAL file** from a pkill'd app session kept re-injecting stale DB state into app reads AND made sqlite3 CLI reads disagree with the app. Final fix: delete the poisoned delta message from the channel → stop app → remove `-wal`/`-shm` → clean the main DB file → relaunch. Now stable across multiple launches (2 objects, real ids, correct sizes, no crashes).

### New tooling
- `--repair-catalog <comma,objectIDs>` pre-post-auth hook: drops objects/chunks via the app's own GRDB connection, re-syncs chunk sizes to actual doc sizes, republishes a corrected checkpoint, quits.

### State
- Release account (`xCloud-Prod`): photo + Rings-Dolby-Atmos mp4, both ready; chunk ids 4194304..10485760 (real), sizes 134217728×6 + 7634680; session preserved (same login after app replacement).
- Debug account: untouched, 20 objects healthy.
- Both repo copies in sync; Debug + Release builds green; release app running for user testing.

## 2026-08-17 (late 2) — All Files / Shared visibility + leave share channel

User found the imported mp4 in Recent/Videos but missing from All Files and Shared, and asked why the app doesn't leave the share channel after importing.

1. **All Files invisibility** — VaultRepair adopted the caption's `parentID` (the sender's "Videos" folder) without checking the folder exists locally; the recipient had no such folder, so the file matched no folder filter. Added an orphaned-parent reconciliation pass at the end of `VaultRepair.run()`: files whose parentID doesn't resolve to a local folder are placed at root. Fixed the release account's mp4 automatically on next launch.
2. **Shared page** — showed only incoming shares; the old-binary import never recorded one (0 rows) and the user's own outgoing share was ignored. Now the Shared destination shows both directions (`sharedObjectIDs` = incoming ∪ outgoing-active), and I backfilled the release account's missing incoming record for the mp4 from the real share data (channel -1004357139874, ids 11534336..17825792).
3. **Leave share channel** — both import paths (v2 + legacy) now call `leaveChat` after a fully successful import, so the "xCloud Shares" channel doesn't clutter the Telegram chat list. Deliberately not on failure (retry needs membership for the one-use invite).

Debug + Release rebuilt, /Applications refreshed, session preserved, release app running.

## 2026-08-17 — Shared page keyboard navigation + log health check

- **Fix**: TheaterView.mediaBase treated `.shared` as empty (`base = []`), so
  opening any shared file made the viewer's arrow keys dead (no navigable list).
  Added a dedicated `.shared` case mirroring the browser grid filter
  (`sharedObjectIDs ∩ !trashed`) — row (left/right) and column (up/down) nav now
  work while previewing files from the Shared page.
- **Logs**: no crash reports; the only error-level unified-log line is harmless
  CFBundle codec-plugin factory noise; ~688 log lines over 15 min is normal
  TDLib/Telegram activity.
- Debug + Release rebuilt, worktree synced, /Applications reinstalled, release
  app running. Unit tests pass.

## 2026-08-17 — Shared nav, re-import dedup, import name dedup, phantom-object root cause

- **Viewer nav on Shared**: TheaterView.mediaBase now includes shared files
  (was `[]`), so left/right arrows open next/previous from the Shared page.
  Up/down column navigation removed from the preview (video up/down = volume;
  non-video = no-op); `navigateMediaVertical` deleted.
- **Re-import**: importing a link whose content rootHash already exists in the
  vault returns `.alreadyImported` → reveal + flash the existing file, no
  duplicate forward. Handled in AppState like `.selfOpen`.
- **Name dedup**: imports get Finder-style "Name 2.ext" suffixes when a
  same-named root file exists (`uniqueName`, unit-tested).
- **Phantom root cause found**: forwarded share chunks keep the SENDER's object
  id in the caption; VaultRepair fabricated phantom duplicates under that id
  on every channel scan (this is what 5C3C5432 and the release account's
  duplicate jpg B0D9C02D were). Guard added: skip if the message is already
  cataloged under another object. `deleteForever` also now refuses to delete
  channel messages still referenced by another object.
- Cleaned the release duplicate via --repair-catalog; verified stable (3
  objects / 9 chunks across relaunches). Tests pass; worktree synced; release
  app running with the fix.

## 2026-08-17 — Viewer Shared-nav actually landed; uniqueName case-insensitivity

- The TheaterView `.shared` mediaBase fix from earlier never reached the binary
  (edit landed in the worktree and was wiped by a main→worktree rsync before
  the build). Re-applied directly to main, rebuilt, verified in the installed
  app — forward/backward arrows on the Shared page preview now work.
- ShareEngine.uniqueName made case-insensitive against the taken set
  (`contains(where:)`) so it behaves like the Finder regardless of the input
  casing; added/kept the unit test (6 cases). Full test suite green.
- Everything committed to main; HANDOVER items 64-65 updated with the gotcha;
  JOURNAL updated.

## 2026-08-17 — v3 share upgrade: channel pool + public/private shares

- **Pool architecture**: private shares each get a DEDICATED pool channel
  (share_state ids 1–5, one active private share per slot — isolation), expiring
  one-use invite, revoke = delete whole channel (instant death, slot freed).
  Public shares never expire and share the persistent public channel (id 100)
  with its stored permanent invite embedded in every public link. App never
  leaves/retires owned channels; missing channel → recreated in place. Pool full
  (5 active private) → clear block alert (privatePoolFull), never evict-oldest.
- **DB v24**: shares.isPublic; share_state.kind + inviteLink; legacy reusable
  channel row becomes private slot 1; ShareChannelState model + per-slot CRUD.
- **Engine**: allocatePrivateChannel/publicChannel/createPoolChannel; kind-aware
  share() + reuse; codec exp=0 = "never"; cancelShare/cancelAllShares (channel
  death vs per-file message delete); cleanupExpiredShares pool-aware + finally
  wired into the 6h cleanup loop; deleteForever/resetVault rewritten on top.
- **UI**: Shared page = new ShareManagerView (active outgoing shares, public/
  private sections, Copy Link, Cancel, Cancel All with confirms); "Share via
  Public Link…" in the context menu; imports → "Imports" section on Transfers
  (.inbound cards); Transfers cards get real thumbnails (TransferIcon);
  Shared badge = active outgoing count.
- **Gotchas**: Features is an EXPLICIT pbxproj group (new file added manually);
  `import` is a Swift keyword (direction case is `inbound`); the type-checker
  limit on FileBrowserView.mainContent forced extracting destinationContent;
  the test suite runs against the REAL app DB which holds real active shares —
  the pool test is baseline-relative; createPoolChannel refuses under XCTest.
- Tests green (46 unit incl. 4 new v3 tests + 4 UI + 4 launch); build green;
  app launched; migration verified on the real DB. NOT committed.
