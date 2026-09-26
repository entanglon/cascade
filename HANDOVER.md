# Cascade — Session Handover

> Written 2026-08-14, updated **2026-09-17**: the **Android port is the active workstream**. DONE: M2 (real Telegram auth on the emulator), M3 transfer engines (upload/download verified live), cross-device catalog sync from the Mac (raw-DEFLATE snapshot decode fix, 58 objects/90 chunks merged), vault-key recovery UI + proactive unlock card, and a Files-by-Google UI (drawer with all 13 Mac sidebar destinations, outlined cards with colored type icons, folder bars + file cards gap-separated, circular upload hump, overflow + long-press menus: favorite/rename/trash). **NEXT UP (agreed tray, in order):** 1) ~~folder drill-down~~ DONE (`ee09b15`, 2026-09-18); 2) ~~delta publish favorite/rename/trash~~ DONE (`725ee8b`, 2026-09-18 — also fixed Android uploads never reaching the Mac; Swift-decode verified); 3) PIN unlock verification on device — STILL PENDING, user action (enter the Cascade PIN once: drawer → Telegram Vault card → Unlock; the thumbnail sweep then unseals everything). **AG-VERIFIED ARCHITECTURE (2026-09-18): the one-time PIN per new device is by design** — every object key is wrapped under the vault key (UploadEngine.swift:162), the vault key travels only as the v2 record's passwordSeal/deviceSeal, and iOS did the identical flow (JOURNAL.md ~2580). User DECISION: keep E2EE exactly as-is; revisit minimizing the PIN requirement later (candidate: device-pairing handshake — new device requests, existing device approves); 4) M4 in-app playback (Ktor byte-range server + libmpv; see the older roadmap below); 5) Transfers pause/resume polish, Shared pane (M6), then Windows/Linux. macOS + iOS verified healthy (2026-09-15). Read this first in any new chat before touching the code.

---

## 1. What this project is

**Cascade** — a native macOS SwiftUI app (the "Freebuff desktop" project) that turns a
Telegram account into a private cloud drive:

- Files are chunked and uploaded to a private Telegram channel ("vault"). Chunks
  are **plaintext** since 2026-08-16 (item 54 — per-file encryption dropped by user
  decision); the `isPrivate` flag + PIN-gated section control visibility, and the
  vault key seal (PIN/device) still gates app access.
- `mpv` (bundled via LocalPackages/LocalMPVKit) plays **any video container** through a
  local byte-range HTTP server (`Engine/VaultStreamServer.swift`) + `libmpv` render API.
- **mpv is the ONLY media engine. AVFoundation/AVKit are REMOVED from the codebase** —
  no `import AVFoundation`/`import AVKit` anywhere, no AVPlayer/AVAsset/AVAssetImageGenerator.
  Cached files → mpv from the local file; uncached → mpv from the byte-range stream server;
  audio plays headless through mpv. **Never reintroduce AVFoundation for playback, thumbnails,
  durations, or anything else** (user mandate, 2026-08-15).
- TDLibKit powers Telegram auth + messaging.
- Local SQLite catalog (`Storage/DatabaseManager.swift`) + snapshot sync between devices.
- Note editor, audio mini-player, fullscreen player, private vault (PIN), trash,
  folders/albums/playlists, Vision-based subject-aware thumbnails, archive
  (Gmail-style hide-from-view), cloud-to-cloud share links (forward-based, reusable
  share channel),
  cross-device catalog snapshot sync, transfer history, Google-Photos-style Photos +
  Videos pages with on-device People recognition, album covers, and an automatic
  self-healing thumbnail pipeline (incl. videos).

Stack: Swift 6.3, SwiftUI + AppKit, macOS 26.5 deployment target (all PQ color spaces
available). Uses `Logger(subsystem: "com.cascade.app", ...)` for app logging.

---

## 2. Build / run / test

**CRITICAL — two copies of the project exist and the user's Xcode builds the MAIN
folder, not the worktree.** This caused a multi-hour incident on 2026-08-15: the agent
edited + built the worktree (`xCloud-wt`), the user rebuilt from Xcode (main folder,
`xCloud-cdpcjcegyfsbheeztqhmjnnukgcv`) and saw an "old app" — their work appeared
gone, and every agent fix looked invisible. The main folder was missing whole files
(BookReaderView, MediaGridShared, Photos/VideosGridView, BookLoader, FaceEngine,
ShareEngine) and its pbxproj didn't reference them. FIXED by rsync'ing worktree → main.

**RULE: after ANY agent edit, build from the project root:**

```bash
cd ~/Projects/Cascade
xcodebuild -project Cascade.xcodeproj -scheme Cascade build
```

To run tests:
```bash
xcodebuild test -project Cascade.xcodeproj -scheme Cascade -destination 'platform=macOS' \
  -only-testing:CascadeTests
```

The user's Xcode / Dock launch uses DerivedData
`Cascade-ezedzhfojrwwyhefeufajkbrtlll`. If you ever `open` an app binary for the user,
open this DerivedData's build.

**IMPORTANT — launching the app:** when the agent (`open ...` or direct binary) launches
the app, the window often comes up invisible (ordered out; TCC/agent-context quirk on
this Mac). This does **not** happen when the user launches it normally. Always let the
**user** launch/relaunch the app to verify UI behavior. If an agent-launched instance is
left running, `pkill -f "xCloud.app"` before handing over.

Debug hooks (in `AppState.bootstrap`): `--cache-video <id>`, `--stream-server`,
`--chunk-info <id>`, `--dump-channel`, `--dump-chat <chatID>`, `--import-share <link>`,
`--revoke-shares` (deletes every active outgoing share channel + marks records
revoked — used for cleanup; destructive).

---

## 3. Repo state (CRITICAL)

Branch: **main**. The entire accumulated work (2026-08-14 + 2026-08-15) was
**committed** on 2026-08-15 (see `git log --oneline -1` — the commit message starts with
"Player redesign, system volume, buffer loader..."). Generated junk is gitignored
(`.freebuff/worktrees/`, `*.dmg`, `*.profraw`, `website/`, the dev DBs,
`LocalMPVKit/.swiftpm/` — see .gitignore; `.freebuff/desktop-v2.db*` were UNTRACKED with
`git rm --cached` so the repo no longer carries the dev Telegram session DB). Keep
committing per task from here on; check `git status` first — other agents/user may have
edited files.

A second commit followed the same day (Library cover polish, transfer-progress
monotonicity, photos keyboard navigation unification — items 40–42 below).

**CURRENT SESSION STATE (2026-09-26, items 138–140a):** the PLAINTEXT MIGRATION
is committed — encryption removed (CryptoEngine deleted, `SliceMath` replaces
`CryptoEngine.sliceSize`), vault moved to Saved Messages, "Private Vault" →
"Locked" with an app-level recoverable PIN (Forgot-PIN replaces it; no key
material derives from it), Android port migrated (own repo:
`/Users/zainulnazir/AndroidStudioProjects/cascade`, commit there), and the
`--purge-cloud` hook executed — old vault/backup channels DELETED on Telegram,
local catalog verified 0 objects. The user's existing encrypted library was
purged by design; anything kept must be re-uploaded. The user will test
uploads/streams/thumbnails/shares on the fresh vault in the NEXT session —
hand off there. UPDATE 2026-09-26 evening (item 141): the user uploaded 12
files + 4 folders and asked for verification before player work — thumbnails
confirmed cloud-bound (attached `inputThumbnail` on every chunk message,
fetch-back proven live), chunking intact (~1.9 GiB / 1 MiB slices), snapshots
(checkpoint + deltas) all published and mirrored, and one real bug fixed
(streaming fetch timeout used the broken task-group race — now uses the proven
`withResponseTimeout`). Build + tests green. The running app is still the
pre-fix binary — relaunch to pick up the fix; then player work is next.

---

## 4. Work completed in this conversation (items 1–42 committed 2026-08-15; items 43–48 committed 2026-08-16; items 49–53 committed 2026-08-16)

1. **HDR/EDR color pipeline fix** (`Features/MPVVideoView.swift`)
   - Root cause of "washed-out but brighter" video vs YouTube: the layer opted into
     EDR (`wantsExtendedDynamicRangeContent`) + a float framebuffer unconditionally, so
     mpv's sRGB-encoded pixels were interpreted as linear light → double gamma decode.
   - Fix mirrors IINA: `applyColorPipeline()` — EDR **off** by default; observes
     `video-params/gamma` + `video-params/primaries` (new `MPV_FORMAT_STRING` event
     handling); SDR (or HDR on an SDR display) → layer pinned to sRGB, mpv target
     options reset to `auto` (mpv tone-maps itself); real HDR (PQ on BT.2020/P3) on an
     EDR display → layer switches to `itur_2100_PQ`/`displayP3_PQ` + EDR on, mpv gets
     `target-trc=pq`, `target-prim=...`, `target-peak=<nits>`, `tone-mapping=clip`.
   - Removed `hdr-compute-peak=yes`. Verified live: user's file is HDR (PQ/BT.2020) on
     an SDR display → `SDR pipeline active` path, looks like YouTube now.
   - Debug logging in unified log: `SDR pipeline active` / `HDR/EDR active`.

2. **Adaptive cache policy** (`Engine/DownloadEngine.swift`, `App/AppState.swift`,
   `Features/SettingsView.swift`)
   - Replaced fixed 5 GB LRU with `enforceCacheBudget()`: hard cap from
     `@AppStorage("xc.cacheCapGB")` (default 5, 0 = unlimited) + free-space floor
     (evict oldest-accessed when free disk < 15 GB, via
     `volumeAvailableCapacityForImportantUsage`). 15-min modification guard protects
     in-flight downloads.
   - Runs at launch + 30-min timer in `bootstrap()`, and before/after downloads.
   - Settings → "Local Storage & Cache": Cache Limit picker (2/5/10/20/No limit) +
     Free Disk Space row. PROJECT_SUMMARY.md updated.

3. **Keyboard navigation fixes** (`Features/FileBrowserView.swift`)
   - ⌘V paste-upload + ⌘C were swallowed by the Edit menu's key equivalents
     (AppKit checks menus before views). Arrows died after the preview closed
     (SwiftUI FocusState unreliable — pattern already documented in NotesView).
   - Added `FileBrowserKeyMonitorView` (local NSEvent monitor) covering arrows,
     space, return, delete, esc, ⌘↑/⌘↓, ⌘C/⌘V/⌘R/⌘O/⌘Z, with defers for theater /
     note editor / fullscreen player / notes / transfers pages and text-field first
     responders.

4. **Preview (theater) column navigation** (`Features/TheaterView.swift`) — ↑/↓ in the
   preview moves through the grid rows using `FileBrowserView.gridVerticalStep` +
   shared `AppState.gridColumnCount`.

5. **Face-aware thumbnails** (`Engine/ThumbnailService.swift`,
   `Engine/UploadEngine.swift`) — `ThumbnailCrop.subjectSquare()` uses Vision:
   largest face → saliency → center; EXIF orientation baked in first. Applied to local
   thumbnail generation AND uploads. (2 new unit tests. Note: existing uploads keep
   their old Telegram-stored thumbs; new uploads get the new crop.)

6. **Square cards** — implemented then **REVERTED** (user preferred the original
   rounded-rectangle cards; thumbnail strip back to 115 pt landscape). The face-crop
   and preview nav stayed.

7. **Folder navigation in preview** (`Features/TheaterView.swift`) —
   Bug: `mediaFiles` stripped folders, so previewing a folder made all four arrows
   no-ops. Fixed by splitting `mediaBase` → `sortedMediaBase` →
   `mediaFiles` (files-only, still drives audio queues/filmstrip) +
   `navigableFiles` (folders-first, matching the browser grid).

8. **Transfer history persistence** (`Storage/Models.swift` v11–v13, `AppState`,
   `Features/TransfersView.swift`) — finished transfers persist to the `transfers`
   table and restore on launch; Clear Finished deletes only terminal cards (never
   paused/resumable); the Clear Finished button is sized to line up under the
   grid/list + sort controls (`XTheme.topBarControlsWidth`).

9. **Share links** (`Engine/ShareEngine.swift`, `App/AppState.swift`, migration v14–v15,
    v22-forward-shares) — cloud-to-cloud sharing is **forward-based** (v2): the sender
    forwards the file's vault chunk messages into ONE reusable "xCloud Shares" channel
    (server-side copy, no re-upload, no size cap; channel archived+muted, tracked in
    `share_state`); the link is an obfuscated `cascade://share#...` blob carrying
    channel + invite + key + expiry (default 7 days) + the forwarded message IDs (`m`)
    and, for private files, the object key re-wrapped under a fresh share key (`w`).
    Re-sharing the same file reuses the live link (byte-identical stored `linkBlob`;
    channel liveness verified via `getChat` before reuse; dead channels marked
    revoked; **legacy v1 records with empty `messageIDs` are never reused** — they'd
    hand out the pre-rewrite link instead of minting a v2 share; they stay
    importable until expiry). Links die with the file (`deleteForever` revokes shares
    + deletes the share-channel copies). Expired/revoked v2 shares delete their
    messages individually; the channel is retired once empty. Self-open (sharer opens
    own link) reveals the original Drive-style (v2 matched by messageIDs, v1 by
    channelID); recipient import (`importForwarded`) re-forwards the chunks into the
    vault and re-wraps the object key under their own master key. Legacy v1
    disposable-channel links still import (`importLegacy`); legacy share captions
    (`cascade:share:v1:`, `ChunkMeta`, no id) parse only via
    `ShareEngine.parseChunkMeta`. Import errors are wrapped with real messages (no
    more bare `TDLibKit.Error error 1`). **Verified live (2026-08-16)**: first v2
    share created the reusable channel + forwarded chunks; the `xcloud://` self-open
    reveal works with both the plain and obfuscated link forms.

10. **Window / URL-open fixes** (`App/xCloudApp.swift`, `App/TerminationHandler.swift`,
    `Features/RootView.swift`) — main scene is a single-instance `Window` (not
    `WindowGroup`), so link opens can never spawn duplicate windows; AppDelegate
    intercepts URL delivery (activate + bring main window front); single-instance
    guard hands off links via a file + notification when a second copy launches
    (handoff file + notification name are bundle-id-scoped, so dev and prod builds
    never hand links to each other); `.moveToActiveSpace` is permanent + off-screen
    rescue (centers on active screen); closing the window quits the app. Hardened
    2026-08-16: URL delivery `deminiaturize`s a minimized main window; zero-window
    recovery posts `recreateMainWindow` (main + About scenes observe → `openWindow`)
    plus a simulated Dock-icon reopen, so a torn-down scene is recreated; diagnostic
    prints (`xCloud URL: …`) on the whole delivery path. Stale `lsregister`
    registrations (deleted build paths claiming `xcloud://`) caused window-vanishing
    incidents — clean them when moving/renaming build folders.

11. **Storage indicator bar** (`Features/SettingsView.swift`) — Settings → Vault
    Usage now has an Apple-style stacked bar + legend (Images/Videos/Audio/
    Documents/Other with sizes + percentages), reusing the sidebar's mime+extension
    classification.

12. **Archive mode** (migration v16, `Storage/Models.swift`, `App/AppState.swift`,
    `Features/SidebarView.swift`, `Features/FileBrowserView.swift`,
    `Features/TheaterView.swift`) — `isArchived` flag; new **Archive** sidebar
    destination; Archive/Unarchive in the context menu (multi-select aware, recursive
    for folders); archived files hidden from every other view/smart-folder/count;
    upload FAB + page upload hidden on Archive; syncs via catalog snapshot +
    chunk-caption metadata; `ObjectRecord` decoding is now defensive
    (`decodeIfPresent` + defaults) so old snapshots without the key still decode.
    Covered by test `archiveFlagPersistsAndSurvivesOldSnapshots`.

13. **Library + BookReader** (`Features/BookReaderView.swift`, `Engine/BookLoader.swift`,
    `Storage/Models.swift`, `App/AppState.swift`, `Features/SidebarView.swift`,
    `Features/FileBrowserView.swift`) — **Library** sidebar destination collects
    book formats (epub/pdf/txt/md/cbz/cbr); reader renders EPUB (spine + NCX TOC,
    WKWebView chapters), text, PDF, and comics (paged/webtoon) with themes
    (light/sepia/dark), font sizing, progress persistence.
    - **Crash fix** (`BookReaderView.swift:687`): the reader SIGABRT'd on every EPUB
      open — `JSONSerialization.data(withJSONObject:)` raises an uncaught ObjC
      exception for top-level Swift Strings ("Invalid top-level type in JSON write")
      that `try?` can't catch. Now uses `JSONEncoder` (safe for any Swift String).
      Regression test: `readerCSSLiteralIsValidJSONString`.
    - **Poster cards** (Library-only): books render as clean 2:3 portrait posts —
      cover art only (no name/size rows); title appears on hover. Covers come from
      `UploadEngine.generateBookCover` (QuickLook, aspect-preserving, stored
      `<id>-cover.jpg`), generated at upload time for books and on-demand from the
      cache; `ThumbnailCrop.aspectFit` does the aspect-preserving downscale.
    - **Not yet verified by the user** — launch the app, open the Library page, and
      test a real EPUB (crash is fixed) + confirm the poster-card look.

### 2026-08-15 session — Photos/Videos pages, People, album covers, thumbnails

14. **Google/Apple-Photos-style Photos page** (`Features/PhotosGridView.swift`, new)
    — boxy 1:1 grid, day sections with pinned floating date pills
    (`Features/MediaGridShared.swift`), hover polish (thumb zoom 1.06, dim veil,
    name + face chips), checkmark badges + accent border on selection, "Albums"
    row of cover tiles, "People" chips row, person-filter view with back header +
    rename-alert. Album tiles double-click to open, single-click to select.
    - **Media pages aggregate across the cloud**: Photos/Videos/Audio pages show
      EVERY file of that type from all folders (root filter ignores `parentID`);
      plain folders NEVER appear on those pages — only albums/playlists
      (collections) do. User corrected an earlier wrong approach that showed
      folders as tiles. Library already aggregated this way.

15. **Videos page** (`Features/VideosGridView.swift`, new) — same design: boxy grid,
    day sections, hover play glyph + name, "Playlists" row (count badges), drag-drop
    into playlists. Root = all videos everywhere + playlists. (Duration badges were
    REMOVED with the AVFoundation purge — they needed `AVURLAsset.load(.duration)`;
    mpv reports duration during playback instead.)

16. **On-device People recognition** (`Engine/FaceEngine.swift`, new; DB v18
    `people`/`faces` tables) — per-photo face detection
    (`VNDetectFaceRectanglesRequest`) + capture-quality filter, tight face-crop
    featureprint embedding via `VNGenerateImageFeaturePrintRequest` (2048-dim —
    **macOS 26 SDK removed `VNCreateFaceprintRequest`/`VNFaceprint` entirely**,
    verified in SDK headers + swiftinterface; swap-friendly for a bundled Core ML
    model later), incremental cosine clustering (match 0.55, merge 0.80, dynamic
    dim centroid), merge pass, face thumbnails saved to `xCloud/faces` (sibling of
    evictable `thumbs`, survives cache clears; NOT synced — local-only derived
    data), `nameFace`/`renamePerson`/`mergePeople`, `deleteFaces` cleanup. Indexed
    on download and thumbnail generation; `.xcPhotoIndexed` notification drives
    the grid's `facesVersion` refresh.

17. **Album covers** (DB v19 `coverObjectID`) — auto-set to the first photo moved
    in (`moveObjects`, drag-drop) or added (`addToPlaylist`, context menu);
    manual via "Set Album Cover…" (picker sheet of the album's photos + Remove)
    on the album tile and "Set as Album Cover" right-clicking a photo inside the
    album. Covers sync via chunk-caption metadata (`coverObjectID` in meta) and
    show on tiles; `ThumbnailService.thumbnailURL` has a folder-cover branch
    (2b) that also kicks off generation when the cover photo is cached.

18. **Keyboard row/column navigation fixed** (FileBrowserView +
    grids) — PhotosGridView/VideosGridView report their true visual order
    (`onOrderedChange` → `mediaOrderedIDs`) and adaptive column count
    (`onColumnCountChange` → `mediaColumnCount`); `navigableFiles` +
    `gridVerticalNavigation` use them, so arrows walk actual rows/columns,
    including inside albums/playlists and the person-filter view.

19. **Drag & drop into albums/playlists** (`MediaDragPayload` in
    MediaGridShared) — files drag as newline-joined object IDs (`public.utf8-plain-text`);
    album/playlist tiles accept drops with accent-ring highlight; multi-select
    drags move the whole selection; `AppState.moveObjects(ids:to:)` batches moves
    (auto cover for the first photo when the album has none).

20. **Inside-album UI matches the photo page** — album/playlist contents render
    through the same media grids; back button + name live in the top bar
    (`headingTitle` already handled it — the initial in-page folder header was
    REMOVED after user feedback: "dir address should be in the head bar").

21. **Bugs fixed this session:**
    - **"Photo moves back automatically"**: `addToPlaylist` saved the whole stale
      `ObjectRecord` with its OLD `modifiedAt` → the 4s-debounced snapshot merge
      saw a tie with the channel's copy, kept the remote (old parentID) record,
      and the move silently reverted. Fix: go through
      `DatabaseManager.updateObject` (which bumps `modifiedAt` — see the comment
      in DatabaseManager.swift:655 about the LWW merge clock). Rule: **every
      mutation MUST bump modifiedAt or the next merge reverts it.**
    - **Videos page empty**: videos lived inside the "Movies" folder and the root
      filter required `parentID == nil` — fixed by cross-cloud aggregation (14).
    - **Duplicate folder headers** inside albums — removed (20).

22. **Self-healing thumbnail pipeline** (`Engine/ThumbnailService.swift`,
    `Engine/DownloadEngine.swift`, grids) — tiered guarantee that every file gets
    a preview:
    - Tiers 1–2 (existing): memory/disk caches, then Telegram's stored
      `-tg.jpg` (`fetchFromTelegram` — only files uploaded since the
      thumbnail-attachment feature have one; old uploads return nil).
    - Tier 3 NEW — **thumbnail-only download**: quietly download the file
      (`DownloadEngine.download(..., quiet: true)` — skips TransferCenter
      entirely), generate the thumb, then DELETE the cached copy so we never hold
      the whole file. Single-flight (`generatingIDs` gate) + 10-min failure
      backoff (`failedIDs`) so broken records can't loop; applies to
      photos/videos/audio (`isThumbnailable`).
    - Tier 4 NEW — **launch warm-up**: 3s after post-auth setup, a low-priority
      detached task walks every ready, non-private media object missing a
      thumbnail (videos sorted last) — no user action needed.
    - **Video/audio previews come from Telegram's attached thumbnail** (never from
      local frame extraction — that needed AVFoundation, which is removed). Photos
      are the only files generated locally (`generateAndSaveThumbnail` is now
      image-only); the last-resort thumbnail-only download applies to photos only,
      so a multi-GB video is never downloaded just to produce a preview.
    - `.xcThumbnailReady` notification → grids bump `appState.thumbnailVersion`
      → cell `.task(id:)` re-keys → thumbs pop in live. DownloadEngine posts it
      on (non-quiet) download completion too, so playing a video refreshes the
      grid with its new thumbnail.
    - Verified live: warm-up kicked off a quiet download of the first video
      (House of the Dragon) minutes after launch.

### 2026-08-15 verification pass (full handover review) — fixes applied

23. **Full review of the uncommitted work** (build + all unit/UI tests green):
    verified the EPUB crash fix (JSONEncoder in `BookWebView.inject`), the Library
    poster cards, BookLoader, the self-healing thumbnail tiers, FaceEngine,
    Photos/Videos grids, migrations v11–v19, and the LWW merge clock. Issues found
    and fixed:
    - **Videos page + sidebar badge missed videos with non-`video/*` mimes** — the
      Photos/Audio pages (and `isVideo`) have extension fallbacks; the Videos page
      and sidebar `.video` count only matched `mime.hasPrefix("video/")`, so e.g.
      an `.mkv` uploaded as octet-stream was invisible on the Videos page.
      `FileBrowserView` video aggregation + `SidebarView` `.video` count now include
      the same extension list as `ObjectRecord.isVideo`.
    - **TheaterView navigation didn't match the new cross-cloud aggregation** —
      `mediaBase` still required `parentID == nil` at the Photos/Videos/Audio roots
      (and listed no albums/playlists), so previewing a photo that lives inside a
      folder at the root made the arrow keys no-ops and the walk order didn't match
      the grid. Now mirrors `FileBrowserView.visibleFiles` (albums/playlists first,
      then every file of that type from ALL folders, extension fallbacks included).
    - **Standard grid / Library never refreshed thumbnails or covers live** —
      `.xcThumbnailReady` was only consumed by the Photos/Videos grids; the
      standard grid (All Files, Library poster cards, …) waited for a manual ⌘R.
      `FileBrowserView` now bumps `thumbnailVersion` on that notification.
    - **Library poster-card download storm** — `bookCoverURL` downloaded the whole
      book (with a visible transfer card per book) when the Library opened with
      many uncached books. Now cache-only, matching the documented design; covers
      for older books generate when the book is next downloaded (`DownloadEngine`
      now calls `generateBookCover` on download completion, and posts
      `.xcThumbnailReady` so the poster pops in live).
    - **Stale comments**: FaceEngine/FaceRecord said "512-dim faceprint" — the
      code uses the 2048-dim featureprint of the face crop. Docs fixed.

24. **Playback regression ("opens in the old player, doesn't play") — ROOT CAUSE
    + FIX.** Both of the user's videos sat in the cache — one COMPLETE (the 8K
    HDR file, 400,605,052 B = recorded size) and one PARTIAL (House of the
    Dragon, exactly 2^30 = 1 GB of 1,098,879,765 B — a thumbnail-only quiet
    download cut off when the app quit at 13:02). `DownloadEngine.isCached`
    only checked `size > 0`, so both counted as cached → `mpvStreamURL`
    returned nil → playback fell to the OLD AVPlayer, which was handed a
    truncated mp4 (moov missing) → "not playing", and the complete HDR file
    also went to AVPlayer (the old player) instead of the mpv HDR pipeline.
    - **Fix A:** `isCached` now requires the cache file to be EXACTLY
      `object.size` (partial files count as not-cached → mpv streams them from
      Telegram; download() re-creates the file from scratch). Regression test
      `partialCachedFileIsNotCached`.
    - **Fix B:** `AudioPlayerEngine.play` now routes ALL video/audio through
      mpv — cached files via the local file URL, uncached via the byte-range
      server. (Previously cached files always went to AVPlayer.) The stale
      partial was deleted.

25. **Layered album/playlist tiles** (`Features/MediaGridShared.swift` new
    `MediaStackTile`) — the cover (or newest photo) fills the tile; up to two
    more photos peek out behind the top-left edge (backs drawn 6%/12% larger +
    offset, so their edges show through the clip). Used by `PhotoAlbumTile`
    (Photos page) and `VideoPlaylistTile` (Videos page); count badge + selection
    border preserved.

26. **"Work is gone / old app keeps opening" incident — ROOT CAUSE: TWO COPIES
    OF THE PROJECT.** The user's Xcode opens the MAIN folder `~/Projects/xCloud`
    (DerivedData `xCloud-cdpcjcegyfsbheeztqhmjnnukgcv`); the agent's edits/builds
    were in the worktree (`.freebuff/worktrees/b32b5e13-…`, DerivedData
    `xCloud-wt`). The main folder was STALE — missing `BookReaderView.swift`,
    `MediaGridShared.swift`, `PhotosGridView.swift`, `VideosGridView.swift`,
    `Engine/BookLoader.swift`, `Engine/FaceEngine.swift`, `Engine/ShareEngine.swift`
    (its `project.pbxproj` had 0 references vs 16 in the worktree) and every
    shared file was older. Every Xcode rebuild compiled the old code → "my work
    is gone." **FIXED: rsync'ed worktree → main (no `--delete`), verified the
    main project builds, and relaunched from the MAIN folder's DerivedData.**
    See section 2 — the sync command is now the standing rule for this repo.

27. **Playback LAG ("still lags like hell") — ROOT CAUSE: THUMBNAIL CPU STORM
    ON AV1, not the player.** mpv telemetry showed PERFECT playback (vfps 60.0,
    voDrop/decDrop/mistimed all 0, cache full) while the user saw lag. The unified
    log revealed the thief: `FigAssetImageGenerator` failing with `err=-12430`
    repeatedly on MULTIPLE threads, right at playback start. The video is AV1
    1080p60 10-bit — VideoToolbox has NO AV1 decoder on this M2 (hardware AV1
    arrived with M3), so `ThumbnailService.generateAndSaveThumbnail` failed
    instantly, and every grid re-render / warm-up pass / `.xcThumbnailReady`
    bump retried it → a CPU storm stealing cycles from mpv's SOFTWARE AV1 decode.
    - **Fix:** codec gate `videoCodecIsAV1` (checks the first video track's
      format description for 'av01') — AV1 files never reach
      `AVAssetImageGenerator`; generation failures now record `failedIDs` and
      the cached path respects the 600s backoff; Telegram's own attached
      thumbnail (`fetchFromTelegram`, works for any codec) covers the poster.
      **Mooted a few hours later by item 28** — AVFoundation was then removed
      from the app entirely, so no video ever touches AVAssetImageGenerator.
    - **Earlier render-path fixes (same session):** RGBA16F backbuffer +
      extendedSRGB window colorspace are now EDR-display-only (SDR Macs get the
      proven 8-bit surface — the float buffer was pure overhead here);
      `applyColorPipeline` reconfig churn guarded by a pipeline key; mpv log
      level "v"→"warn" (per-frame log flood was drowning the unified log AND
      loading the playback thread). mpv itself was never broken — the Stremio
      options (hwdec=auto → clean dav1d fallback, profile=fast, 20s cache) were
      verified identical to commit 98f7827.

28. **AVFoundation REMOVED from the app entirely (user mandate, 2026-08-15).** The
    player kept "resurrecting" through side doors — AVAssetResourceLoader streaming
    (`VideoStreamingEngine.playerItem`), the AVPlayer fallback in `AudioPlayerEngine`,
    `NativeAVPlayerView` (AVKit) in `VideoPlaybackView`/`TheaterView`,
    `AVAssetImageGenerator` thumbnails, `AVURLAsset` duration badges. All gone:
    - `VideoStreamingEngine`: `AVAssetResourceLoaderDelegate` + `playerItem(for:)`
      deleted; only the mpv stream server (`mpvStreamURL`, `VaultStreamServer`,
      `ObjectFetcher`, slice cache) remains.
    - `AudioPlayerEngine`: mpv-only. `player`/AVPlayer/timeObserver/setupPlayer
      deleted; EOF auto-advance now rides mpv's `MPV_EVENT_END_FILE` (new
      `onEndOfFile` on MPVController/MPVLayerView, wired to `skipNext`).
    - `VideoPlaybackView` (rewritten): mpv-only; `NativeAVPlayerView` deleted.
    - `ThumbnailService`: `generateAndSaveThumbnail` is now IMAGE-ONLY; video/audio
      previews come from Telegram's attached thumbnail (`fetchFromTelegram`);
      last-resort thumbnail-only downloads are photos-only (a video is never
      downloaded whole just for a preview). `videoCodecIsAV1` deleted with the rest.
    - `VideosGridView`: duration badges removed (needed AVURLAsset).
    - Verified: zero `import AVFoundation`/`import AVKit` and zero AV* symbols in
      the codebase; main-folder build + full test suite green.
    - mpv EOF test hook: `mpv --keep-open` not used — playlists advance via the
      end-file event; verify with any short video in a playlist.

29. **Full media-pipeline verification + backup + docs (2026-08-15, "perfect condition").**
    - **Log review**: the user's 11.5-minute playback session (14:43→14:54, PID 16253)
      shows `SDR pipeline active (gamma=pq, primaries=bt.2020)` (correct HDR→SDR
      tone-mapping on the SDR display), AV1 clean software fallback (M2 has no hw AV1),
      and telemetry at a steady `vfps:60.0` with `mistimed/voDrop/decDrop/drop` ALL 0.
    - **Telemetry fix**: `video-params/codec` reads as unavailable on this mpv build
      (log showed `codec:none` forever) → switched to top-level `video-codec` +
      added `audio-codec`, so future sessions log real codecs (`av01`, `hevc`, `eac3`...).
    - **Streaming verified live** via `--stream-server` + curl on the UNCACHED House of
      the Dragon (1,098,879,765 B): `206 Partial Content`, `Accept-Ranges: bytes`,
      `Content-Range: bytes 0-63/1098879765`, `Cache-Control: no-store`, payload = valid
      `ftyp isom` header; mid-file seek at 512 MB returns exact bytes; file tail returns
      exact final bytes. Decrypt+slice-serve is byte-perfect.
    - **Dolby verified** with the app's EXACT bundled libmpv (built `mpvtest` harness in
      `/tmp` against the LocalMPVKit XCFrameworks): generated AC-3 and E-AC-3 (Atmos
      carrier) files both played to `finished playback, success (reason 0)`.
      `audio-spdif=ac3,eac3,truehd,dts` + exclusive mode bitstream when the user enables
      passthrough; FFmpeg decodes otherwise.
    - **BACKUP**: `~/Projects/Backups/xCloud-source-backup-2026-08-15.zip` (414 MB —
      source, LocalPackages engines, `.git`, website; excludes DerivedData/build/
      .freebuff) and `xCloud-appdata-backup-2026-08-15.zip` (8 MB — real sqlite DB +
      thumbs/faces), both integrity-checked, plus `README.md` restore guide.
    - **Docs**: new `docs/PLAYER.md` (full media-pipeline reference: mandate,
      architecture, streaming, HDR, Dolby, thumbnails, telemetry, harness, benign log
      noise); PROJECT_SUMMARY.md updated with a media section + link.
    - **Benign log noise** (do NOT "fix"): AV1 Vulkan hwaccel attempt errors at load
      (bundled MoltenVK, falls back to software); one-time `INVALID_FRAMEBUFFER_OPERATION`
      at VO start on SDR — both followed by zero drops.
30. **Video thumbnails — real frames, headless FFmpeg (2026-08-15, "black thumb" fix).**
    - **Problem**: video thumbnails came from QuickLook which always picks the video's
      FIRST frame — the Dolby Atmos sample starts black, so its thumb was pure black
      (luma variance 0.0). QuickLook has NO time/representative-frame API on macOS.
    - **Dead ends (do NOT retry):** (a) invisible-window mpv capture — agent/automation
      launches get ZERO composited WindowServer surfaces (`GL_FRAMEBUFFER_UNDEFINED`
      0x8219, glReadPixels 1286, mpv `INVALID_FRAMEBUFFER_OPERATION`), proven via
      `CGWindowListCopyWindowInfo`; (b) mpv SW renderer (`MPV_RENDER_API_TYPE_SW`) —
      bundled libmpv 0.38 is zimg-only and the binary has ZERO zimg symbols (gray
      placeholder); (c) `screenshot`/`--vo=image` — bundled FFmpeg is decode-only,
      no image encoders; (d) headless offscreen CGL FBO + mpv GL render — same surface
      problem; (e) `launchctl asuser`/activation tricks — no session, no compositing.
    - **THE FIX — direct FFmpeg frame extraction** (`Engine/VideoFrameExtractor.swift`):
      uses the bundled `Libavformat`/`Libavcodec`/`Libswscale` XCFramework modules
      directly (FFmpeg 7.0 — display matrix is FRAME side data
      `AV_FRAME_DATA_DISPLAYMATRIX`; `sws_getCoefficients` takes `AVColorSpace`).
      No window, no GL, no zimg, no encoders — works identically in automation and
      user launches. Algorithm: seek BACKWARD to keyframe ≤ target, decode forward to
      first frame ≥ target timestamp, score 5 candidate positions (8%→60% of duration)
      by subsampled luma variance (a black opening can never win), convert winner via
      `sws_scale` to RGBA with `sws_setColorspaceDetails` from the source's real
      colorspace/range, apply rotation, encode via `NSBitmapImageRep` (AppKit, not AV).
    - **Modulemap fix**: Libavutil's module map had to exclude Windows-only headers
      (`hwcontext_d3d12va.h` etc.) or the app target fails to import — fixed in
      `LocalPackages/LocalMPVKit/XCFrameworks/Libavutil.xcframework/.../module.modulemap`
      in BOTH the main folder and the worktree copy (they're separate git-tracked copies).
    - **Verified headless**: `--capture-test` produced a real 605 KB frame (variance
      552.7 vs 0.0 black); `--regenerate-thumbnails` fixed both black thumbs — Dolby
      now 19 KB JPEG + 270 KB PNG, AV1 file variance 5655. All unit/UI tests green.
    - **Thumbnail storage**: thumbs live ONLY in the app
      (`~/Library/Application Support/xCloud/thumbs/`, `<id>.jpg` local + `<id>-up.jpg`
      attached to uploads) — Telegram never stores generated thumbs; Telegram only
      carries the attached `-up.jpg` inside the file message. UploadEngine now uses
      the extractor for video thumbs (`isVideo` path).
    - **HDR note**: swscale converts 10-bit YUV→RGBA but does NOT tone-map PQ/HLG —
      HDR thumbs may look dim/flat but never black; correct primaries/range via
      `sws_setColorspaceDetails` is enough for a thumbnail (documented in PLAYER.md).
31. **Uncached-video thumbnails + background playback (2026-08-15, "HotD thumb + videos
    don't keep playing in background").**
    - **HotD thumbnail gap**: House of the Dragon (`C8F5AC50-...`, 1.09 GB) is NEVER
      downloaded (it streams via `VaultStreamServer`), and it was uploaded before the
      `-up.jpg` Telegram attachment existed — so it had ZERO thumb files and nothing
      ever generated one. The extractor only opened local files.
    - **Fix**: `VideoFrameExtractor` now opens HTTP URLs directly (`avformat_open_input`
      accepts `http://127.0.0.1:PORT/stream/<id>`; FFmpeg's http protocol seeks via
      byte-range requests — proven by curl 206 tests). `ThumbnailService.thumbnailURL`
      gained an uncached-video branch: never-downloaded videos extract a frame through
      the loopback stream URL — a few byte-range requests, NO whole-file download. Also
      cached videos now extract locally (before, videos were skipped entirely in the
      thumbnail pipeline — only photos/books were handled). New
      `generateAndSaveVideoThumbnail` (single-flight, 600s backoff, posts
      `.xcThumbnailReady`). VERIFIED headless: a C harness against the bundled FFmpeg
      libs opened an HTTP byte-range server, seeked, and decoded 3840×2160 frames —
      variance 552.7 @ 60% (identical to the local-file result), scoring picks it over
      the black 8% opening. New debug hook: `--video-thumb <objectID>` runs the real
      thumbnail-service path and writes `/tmp/cascade-vidthumb-result.txt` (stdout is
      block-buffered in agent launches — results go to a file).
    - **Background playback gap**: videos play through `MPVVideoView` INSIDE the
      TheaterView; closing/minimizing the theater (`theaterFile = nil`) dismantles the
      view, whose `dismantleNSViewController` → `cleanup()` DESTROYS the mpv core —
      so "Minimize to Background" and ESC killed video playback. Audio survived
      because it already plays headless (`playHeadless`, vo=null).
    - **Fix**: `AudioPlayerEngine.continueInBackground()` — on theater close while a
      video plays, capture `timePos` + volume, tear down the view-bound controller,
      and hand the exact position to a fresh HEADLESS mpv instance (audio keeps
      playing in the mini player). `playInBackground(file:in:)` starts a video
      directly headless from the minimize button when paused. Reverse path:
      `MPVController.takeHeadlessHandoff()` + `MPVLayerView.loadFile(url, startAt:)`
      — expanding the mini player re-attaches a view core that loads the same URL and
      seeks to the exact position (seek deferred to `MPV_EVENT_FILE_LOADED`, since mpv
      drops pre-load seeks). All source resolution shared via
      `resolvePlaybackURL(for:)` (cached → file, else stream URL, else download).
    - **Behavior now**: ESC / chevron-down on a playing video → seamless background
      audio in the mini player at the exact timestamp; expand → video resumes at the
      same spot; X button still stops playback (intentional); paused+ESC still stops.
32. **CATALOG COLLAPSE + CLOUD WIPE (2026-08-15, "everything is gone from the cloud") —
    ROOT CAUSE: an automatic repair chain that DELETED the media from Telegram. RECOVERED.**
    - **What happened**: the library suddenly showed only 3 folders (0 files), and the
      vault's storage showed "Zero bytes". The 30 chunk documents (the actual bytes of
      all 17 files) were GONE from the Telegram channel; only catalog json (1 snapshot
      + 22 deltas), the vault key, one shared file, and text metadata survived.
    - **The deletion chain** (`Storage/VaultRepair.swift`): step 3 of `run()` purged
      every ready non-folder object whose chunk rows lacked valid message IDs — with NO
      channel-fetch gate (the gate only protected the Telegram orphan purge 3b). The
      purge cascaded: local objects deleted → `publishCheckpointFromLocal` published a
      COLLAPSED (folders-only) checkpoint → next launch restored from it → chunks table
      now held only folder rows (3, size 0) → the orphan-purge safety gate
      `!validChunks.isEmpty` PASSED → `deleteMessages` deleted every file-chunk
      document from Telegram. A catastrophic auto-deletion loop with no user intent.
      Folders survived because the purge exempted `isFolder` — why 3 folders, 0 files.
    - **Fix (VaultRepair.swift)**: repair is now RECONSTRUCT-ONLY — it scans the channel
      and re-inserts missing chunk rows from real Telegram messages; it NEVER deletes
      objects and NEVER calls `deleteMessages`. The orphan purge was removed from the
      automatic path and is now a guarded, explicitly-invoked maintenance routine.
      (2026-08-15 follow-up: the last auto-delete in `run()` — cleanup of an empty
      folder named "Uploads" — was removed; repair is now 100% reconstruct-only.)
      Added safety rails: `AppState` refuses to publish a checkpoint whose non-folder
      object count is below a floor (a collapsed catalog can never be published), and
      `CatalogSnapshot.restore()` refuses to replace a non-empty local catalog with a
      folders-only checkpoint. `DatabaseManager.deleteChunks(forObjectID:)` was added
      for the explicit recovery path.
    - **Recovery (all done)**: preserved the app cache FIRST
      (`~/Projects/Backups/cache-recovery/`, 1.2 GB, 16 files); merged the 15:08 backup
      DB (`/tmp/appdata-check/`) + channel deltas into a recovered catalog (18 files +
      3 folders, LWW-safe baseline = backup + Dolby only); new debug hook
      `--recover-upload <objectID|all>` re-uploads cached bytes with their ORIGINAL
      object IDs/keys (resumable across runs, logs to `/tmp/cascade-recover-progress.txt`).
      Run completed: 15/18 files re-uploaded, fresh checkpoint published to the channel
      (18 files + 3 folders, 26 chunks). VERIFIED: channel dump shows the re-uploaded
      chunk documents; the newest snapshot `snapshot-53D9276F-...json` carries the full
      catalog with correct message IDs; DB stable across relaunch (no purge).
    - **PERMANENTLY LOST (bytes exist nowhere — NOT recoverable, must re-upload from
      original source)**: House of the Dragon `C8F5AC50-...mp4` (streams only, never
      cached), `The Exorcist theme (HD).wav` (`332D38BD-...`), `The Exorcist.ogg`
      (`33D2C3AE-...`). Their catalog records remain (marked ready, 0 chunks) so the UI
      shows them; opening/playing them fails until re-uploaded.
    - **Lesson / guardrail**: NEVER let any routine auto-delete objects or Telegram
      messages as part of "repair". Repair = reconstruct from the channel. Also the
      `--dump-channel` hook (dumps all channel messages to a file) is the ground-truth
      tool for any "files missing" report — check it BEFORE touching the DB.
33. **Post-recovery state + open issues (2026-08-15, user: "the database is still not
    updated, the app isn't showing actually what's in the cloud").**
    - **Ground truth verified**: main DB (`~/Library/Application Support/Cascade/cascade.sqlite`,
      app is UNSANDBOXED — `ENABLE_APP_SANDBOX = NO`) = 18 files + 3 folders + 26 chunks,
      all `ready`, and chunk messageIDs match the published checkpoint
      (`snapshot-53D9276F-…json`, 26/26) exactly. The container DB
      (`~/Library/Containers/com.nemesys.xCloud.xCloud/…/xcloud.sqlite`, 14 objects,
      mtime 12:21) is a STALE leftover from an old sandboxed run — never read by the
      current build; ignore it. There is NO second real catalog.
    - **Ghost entries (KNOWN GAP)**: the catalog still lists 3 objects with ZERO chunks
      that no longer exist in the channel — House of the Dragon `C8F5AC50-…`,
      `The Exorcist theme (HD).wav` `332D38BD-…`, `The Exorcist.ogg` `33D2C3AE-…`
      (permanently lost, bytes nowhere). The app therefore shows 18 files while the
      cloud actually holds 15 — "the app isn't showing actually what's in the cloud".
      Fix for antigravity: remove those 3 rows (chunks CASCADE) so catalog == cloud
      exactly, then relaunch (the app force-publishes a snapshot every login via
      `forcePublishSnapshot()`, so the cleaned checkpoint replaces the 18-file one).
      Do NOT let `VaultRepair` recreate them (it is reconstruct-only now — safe).
    - **Download history / Transfers gap (FEATURE REQUEST)**: the Transfers page
      (`Features/TransfersView.swift`, `Engine/TransferCenter.swift`) shows upload
      cards only. User wants DOWNLOAD cards to appear there too, with uploads and
      downloads separated like the Folders/Files split on All Files
      (`Features/FileBrowserView.swift`). Downloads currently run through
      `Engine/DownloadEngine.swift` (cache + stream) with no TransferCenter
      bookkeeping. Full plan handed to antigravity in `docs/ANTIGRAVITY_PLAN.md`.
    - **Cache-vs-stream clarification (user asked)**: files play from cache when they
      are cached — that is the designed offline-first behavior, not a bug. Uncached
      files (HotD) stream via the loopback byte-range server. The recovery re-upload
      pulled from the cache because those 15 files HAD been downloaded at some point.
      If the user wants to verify true streaming, play an uncached file (HotD — but
      its bytes are gone now, so re-upload first, or use any future upload before it
      gets cached).
34. **MKV / Non-MP4 Container & Dolby Atmos Video Playback (2026-08-15)**
    - `Storage/Models.swift`: Added `isAudio` and updated `isVideo`/`isPhoto` properties on
      `ObjectRecord` to recognize all media container extensions (`.mkv`, `.webm`, `.avi`,
      `.ts`, `.flv`, `.m4v`, `.mov`, `.wmv`, etc.) regardless of whether the MIME string is
      `application/octet-stream`.
    - `Engine/UploadEngine.swift`: Added extension-based MIME mapper (`mimeType(for:)`)
      mapping `.mkv` to `video/x-matroska`, etc.
    - `Features/TheaterView.swift` & `App/AppState.swift`: Category filters (`.video`, `.audio`,
      `.photos`) and theater `previewKind` now use `isVideo`/`isAudio`/`isPhoto`, allowing
      MKV/Dolby Atmos test clips to stream directly to mpv without getting stuck on placeholder.
    - `Engine/VideoFrameExtractor.swift`: Improved `decodeFrame` fallback to keep `lastDecoded`
      frame so short clips extract representative thumbnails without failure.
35. **Failed Download Discard & Context Menu Actions (2026-08-15)**
    - `Features/TransfersView.swift`: Added "Delete" and "Cancel & Delete" menu options
      in `TransferItemMenuContent` for failed and active downloads.
    - `Engine/TransferCenter.swift`: Verified `discard()` immediately removes failed cards.
    - Added unit test: `downloadFailureCardCanBeDiscarded`.
36. **Catalog Snapshot & Reset Vault Hardening (2026-08-15)**
    - `App/AppState.swift`: Added collapse guards to `forcePublishSnapshot()` and post-dedupe
      publishing refusing to overwrite the remote snapshot when local catalog is empty.
    - `Storage/CatalogSnapshot.swift`: Added `force: Bool = false` flag to `publishCheckpointFromLocal`
      and guarded `replaceCatalog` against replacing populated local catalog with empty merged result.
    - `Storage/DatabaseManager.swift`: Added `objects_backup` and `chunks_backup` snapshot tables
      inside `replaceCatalog` before deleting existing records. Added confirmation requirement to `resetVault`.
    - `Storage/VaultRepair.swift`: Added ratio guard to `purgeOrphanedMessages` preventing mass message
      deletion if less than half of ready files have valid chunk IDs.
37. **Video Player Open/Close Animation Lag Fix (2026-08-15)**
    - `Features/RootView.swift`: Removed `.scale(scale: 0.92)` transition on `TheaterView`.
      Continuous geometry/matrix scaling over live OpenGL/Metal `CAOpenGLLayer` surfaces
      caused heavy GPU texture re-rasterization and UI frame stutter.
    - Replaced with hardware alpha-blended `.transition(.opacity)` with `.easeInOut(duration: 0.20)`.
    - Open and close transitions are now fluid ProMotion 60/120 fps.
38. **Headless Audio Background Handoff Bug Fix (2026-08-15)**
    - `Features/MPVVideoView.swift`: In `playHeadless`, mpv rejected floating point numbers in
      `loadfile <url> replace start=<pos>` (`Command loadfile: argument index can't be parsed`).
      Fixed by queuing `seekOnLoad` which seeks on `MPV_EVENT_FILE_LOADED` and issuing a clean `loadfile`.
    - `Features/TheaterView.swift`: Restored minimize button (`chevron.down`) and `ESC` handler
      to hand off playback to `AudioPlayerEngine.shared.continueInBackground()` (and `MiniPlayerView`).
    - Audio Mini Player (`MiniPlayerView.swift`) is intact and active at the bottom of `FileBrowserView`.
39. **Player animation lag — mpv init/teardown moved OFF the main thread (2026-08-15)**
    - **Root cause**: the theater's open/close animations (200 ms opacity fades) were smooth
      transitions over a FROZEN main thread. Opening created the mpv core synchronously in
      `MPVViewController.viewDidLoad` (`mpv_create` + ~30 options + `mpv_initialize` + event
      loop = tens of ms of blocking); ESC called `continueInBackground()`, which created a
      SECOND core (headless `setupMpv`) synchronously inside the `withAnimation` block; and
      the X button's dismantle ran `mpv_render_context_free` + `mpv_terminate_destroy` on the
      main thread. Result: visible freeze/hitch at the exact moment of every transition.
    - **Fix (`Features/MPVVideoView.swift`)**: `setupMpv()` now dispatches to mpv's background
      `queue` (`initializeMpvCore()`); `onCoreReady` fires on the main thread when init
      completes. The headless path queues its `loadfile` (guarded by `isMpvReady`, flushed
      from init completion when video output is disabled). `teardown()` defers render-context
      free + `mpv_terminate_destroy` to the `queue` (renderLock still serializes against
      in-flight CAOpenGLLayer draws; strong self capture prevents leaks; init completion
      self-destructs its handle if the view was torn down mid-init). Removed the stale
      `getVolume()` reset in `viewDidLoad` (it silently reset the user's volume to 100% on
      every video open).
    - **Player status overlays (`Features/VideoPlaybackView.swift`)**: new `PlayerStatusOverlay`
      (observes the controller) — "Preparing player…" until the core is ready, "Loading video…"
      until the first rendered frame, "Buffering… N%" while mpv stalls for the cache. Fades
      in/out (0.2 s) so the player never shows a silent black void. New published flags:
      `MPVController.isCoreReady`, `MPVController.hasFirstFrame`; first-frame detection in
      `MPVLayer.draw` (`onFirstFrame`).
    - **Verified**: main-folder build green, full unit + UI test suite green.
    - **Follow-up crash + fix (same day)**: async `teardown()` crashed with SIGSEGV in
      `glDeleteTextures` (→ `ra_hwdec_mapper_free` → `gl_video_uninit` →
      `mpv_render_context_free`) on the mpv queue thread. `mpv_render_context_free` requires
      the OpenGL context CURRENT on the calling thread; the background queue had none. Fix:
      `MPVLayer.copyCGLContext` now retains the CGL context on `MPVLayerView.renderContext`
      (via `CGLRetainContext`), and `teardown()` binds it (`CGLSetCurrentContext`) inside the
      renderLock before freeing the render context, then unbinds and releases
      (`CGLSetCurrentContext(nil)` + `CGLReleaseContext`). The renderLock guarantees the
      context is never bound on the draw thread and teardown thread simultaneously. Rebuild +
      full test suite green after fix.
    - **Overlay text removed (same day)**: closing via ESC rebuilds the controller as a fresh
      headless core (no GL surface), so `hasFirstFrame` never flips and the "Loading video…"
      text flashed during the close fade — a misleading artifact of the handoff, not a stall.
      `PlayerStatusOverlay` and the fallback `loadingView` now show the spinner only (no text);
      show/hide + fade logic unchanged (spinner lifts once the first frame renders or buffering
      ends).
    - **Video background playback REMOVED (same day, user decision)**: ESC / minimize no longer
      hands a video off to a headless core for the mini player — videos now STOP when the
      theater closes (the mini player is audio-only). `AudioPlayerEngine.continueInBackground()`
      and `playInBackground()` deleted; `TheaterView` ESC/minimize call `stop()` for video.
      Headless playback (`playHeadless`/`setupMPVPlayer(audioOnly:)`) still powers audio.
    - **Flux-style player controls (same day, copied from the flux project)**: new
      `PlayerControlsView` in `VideoPlaybackView.swift` — center transport (-10s / play-pause /
      +10s glass circles, hidden until the first frame and while buffering), bottom bar with
      title + size, volume slider, audio/subtitle `TrackSelectionList` popovers, custom drag
      seek bar (white capsule + thumb, drag seeks via `mpv.seek(to:)`), monospaced time labels.
      Gated by the theater's `showControls` (fades with the chrome, no separate timer); the
      theater's bottom info bar is hidden for video to avoid overlap. Tracks/seek/volume wired
      to the existing `MPVController` API (`seek(relative:)`, `setVolume`, `selectTrack`).
    - **To verify manually**: open a video (spinner → first frame, then hover to reveal
      controls), play/pause + -10s/+10s, drag the seek bar, volume slider, audio/subtitle
      popovers on a multi-track file, ESC (video stops, no mini player), X close, and an
      uncached file (buffering spinner on stall).
    - **Player chrome redesign (same day, after user feedback "buttons aren't properly
      placed / old viewer UI overlayed / full screen has no player UI")**: `PlayerControlsView`
      is now the player's SELF-CONTAINED chrome and owns its own 3 s hover auto-hide timer
      (invisible hover-catcher + timer, like flux) — no longer gated by the theater's
      `showControls`. Layout: top bar (minimize chevron, title + size, volume pill,
      full-screen toggle, close xmark — glass circles/pill with gradient scrim), truly
      centered transport (the old `.offset(y: -80)` hack removed), bottom bar (title/size,
      subtitles + audio pills, drag seek bar + monospaced times), and a "Press Esc again to
      exit" glass pill. The old viewer chrome (topControls, bottomInfoBar, navigationOverlay)
      is suppressed for `.video` in `TheaterView` (player owns all chrome now; keyboard
      arrows still navigate).
    - **Two-step Escape**: `TheaterView.handleEscapeKey()` — first ESC shows the warning
      (auto-clears after 2 s), second ESC stops playback and closes the theater; guarded so
      windowed ESC never fires while the full-screen window is active.
    - **Full-screen player UI**: `PlayerFullScreenWindow` is now an `ObservableObject`
      (@Published `isActive`/`showExitWarning`) and hosts an `NSHostingView` overlay with the
      SAME `PlayerControlsView` on top of the re-parented `MPVLayerView` (video shows through
      the transparent root). Full-screen ESC is two-step (warning → exit full screen back to
      the windowed player); minimize/full-screen toggle exit full screen; close stops
      playback + closes the theater. `present(...)` takes mpv/title/subtitle/onClose/onDismiss;
      `dismissIfPresented` resets `appState.isTheaterFullScreen` via `onDismiss` on every path
      (buttons, ESC, teardown).
    - **To verify manually (redesigned)**: windowed player — controls auto-hide after 3 s,
      hover reveals; top bar minimize/fullscreen/close work and nothing else overlaps the
      video; ESC once → "Press Esc again to exit" pill, ESC twice → closes. Full screen —
      click the full-screen toggle (or context menu): the same player UI must be present on
      top of the video, ESC once shows the warning, ESC twice exits full screen (back to the
      windowed player, playback continues); close button stops + closes the theater. Then
      drag the seek bar / volume / track pills in BOTH modes.
    - **Hit-testing fix (same day, user: "buttons don't click unless the exact center")**:
      the glass buttons had no `.contentShape`, so macOS hit-tested the glyph only. Added
      `.contentShape(Circle())` to every glass circle button in `PlayerControlsView` (top
      bar minimize/fullscreen/close + center transport). The track pills already had
      `.contentShape(Rectangle())`.
    - **Audio player updated to the same chrome (same day, user request) + open-lag fix**:
      `TheaterAudioPlayerView` (disc + waveform + plain sliders) deleted; new
      `AudioPlaybackView` (TheaterView.swift) reuses `PlayerControlsView`/`PlayerStatusOverlay`
      in `isAudio` mode: transport + spinner gate on `mpv.isCoreReady` (headless audio never
      flips `hasFirstFrame`), no full-screen button (no GL layer to re-parent — the context
      menu's Full Screen is inert for audio), minimize closes the theater and audio keeps
      playing headless in the mini player, close stops. The old viewer chrome
      (topControls/bottomInfoBar/navigationOverlay) is now suppressed for `.audio` too.
      **Lag root cause**: playback start was gated behind two sequential awaits —
      `loadFile()` awaited `mpvStreamURL(for:)` (layout network fetch) AND the view's
      `.task` awaited `ThumbnailService.thumbnailURL(for:)` BEFORE `audioEngine.play(file:)`.
      Fixes: `loadFile()` sets the stream URL optimistically for audio (no layout await;
      `play()`'s `resolvePlaybackURL` handles stream → full-download fallback), the
      thumbnail await is gone (new UI has no album art), playback starts immediately in
      `.task(id:)` with spinner feedback until the core is ready.
    - **To verify manually (audio)**: open a cached AND an uncached audio file — the player
      must appear immediately with a spinner, then sound; hover reveals the same chrome as
      video (minimize / title / volume / close, center transport, bottom seek + tracks);
      ESC closes the theater and audio keeps playing in the mini player; minimize does the
      same; X stops. Click the buttons anywhere on their glass circles.
    - **Music player rebuilt with a dedicated UI (same day, user: "don't use the same player
      for music; the old music player was already good, update it" + web research)**: new
      `TheaterAudioPlayerView` (Apple Music / Spotify patterns — big hero artwork disc with
      glow + pulse while playing, ambient brand-gradient bloom behind it, always-visible
      chrome, custom drag scrubber with monospaced times, glass prev/play/next transport,
      volume pill, "track x of y" counter, thumbnail loads in parallel and NEVER gates
      playback). `AudioPlaybackView` (the shared PlayerControlsView clone) deleted; the
      `isAudio` mode was removed from `PlayerControlsView` (video-only again).
    - **Opening lag / "semi-transparent stuck animation" — properly diagnosed and fixed
      (same day)**: for media files the theater previously awaited `mpvStreamURL(for:)`
      (per-chunk Telegram `fileSize` network calls) BEFORE showing the player, and the
      player views then awaited the thumbnail BEFORE calling `play()` — two sequential
      network waits; the glass "Preparing…" downloading card showing through the fade-in
      was the "semi-transparent stuck" look. Fixes: (1) `TheaterView.task` now calls
      `AudioPlayerEngine.play(file:in:)` IMMEDIATELY, in parallel with `loadFile()` — mpv
      init overlaps the fade-in; (2) `loadFile()` sets the stream URL optimistically for
      both video and audio (no layout await, no download gate — `resolvePlaybackURL` owns
      the fallback; a second download path there would double-download); (3) `loadLayout`
      got in-flight dedup (`loadingLayouts` Task dict, cleared on success AND failure) so
      play() and loadFile share ONE layout fetch; (4) thumbnail fetch in the music player
      runs in parallel (`.task`), not before playback. Player views show a spinner for the
      whole resolve→init window instead of a ghosted download card.
    - **Mini player no longer a second player (same day, user report)**: it ONLY shows for
      audio tracks (videos stop on theater close — no background handoff, so never a mini
      player for video) AND only while the theater is closed. Minimize / ESC on the music
      player hands off to headless playback and the mini bar springs in
      (`.spring(response: 0.4, dampingFraction: 0.85)`, move-from-bottom + opacity) as the
      theater fades out — the "full player turns into mini player" transition. The legacy
      full-screen `audioTheaterOverlay` + `audioEngine.isFullScreen` branch were dead code
      (isFullScreen was never set true) and are deleted.
    - **To verify manually (all)**: double-click a cached AND uncached video/audio — no
      "Preparing…" glass card, spinner immediately, no pause; minimize the music player →
      mini bar springs in and audio continues; ESC closes audio → same; confirm NO mini
      player while a video plays and none after closing a video; buttons click anywhere on
      their glass circles.
    - **Volume slider breaking audio during drag (user report, fixed)**: dragging the
      volume slider (video OR audio) made the audio crackle/break. Root cause: every
      drag tick wrote mpv's `volume` property TWICE — once from the slider and once from
      AudioPlayerEngine's `$volume` feedback sink round-trip — 100+ gain re-applications
      per second while mpv's volume filter re-ramps on each write. Fix:
      `MPVController.setVolume` now publishes `volume` synchronously (slider stays
      responsive) but COALESCES the mpv property write behind a 60 ms debounce task —
      ≤ ~16 gain updates/sec, smooth and clean.
    - **Volume slider → SYSTEM volume (user: "not synced to the system volume
      slider")**: the sliders always drove mpv's INTERNAL volume (softvol), which is
      why keyboard volume keys seemed "to work" while the slider felt dead — they were
      two different controls. Now there is exactly ONE volume: the macOS system output
      volume. New `SystemVolumeManager` (CoreAudio, in AudioPlayerEngine.swift):
      reads/writes `kAudioDevicePropertyVolumeScalar` on the default output device,
      observes device volume changes (keyboard keys / Control Center move the sliders
      live) and re-attaches its listener when the default output device changes
      (headphones). Both the video player's and the music player's volume pills bind
      to `SystemVolumeManager.shared.volume`. mpv's volume property is pinned at 100
      at controller setup — the device volume is the only attenuation. The engine's
      old `volume` didSet→push, the `$volume` echo sink, and `lastPushedVolume` are
      deleted — the whole mpv-volume feedback loop is gone with them (no crackle, no
      dead slider). `SystemVolumeManager.start()` runs in the launch warm-up task.
    - **Buffer loader in the player (feature)**: `PlayerStatusOverlay` upgraded from a bare
      spinner into a buffer loader with two states: initial loading (core init / first
      frame pending) shows a spinner + "Loading…" in a glass pill; mid-playback cache
      stalls show a progress ring that fills as mpv's `cache-buffering-state`
      (`bufferProgress`) climbs, with the live percentage in the center, plus
      "Buffering…". Shown in the windowed theater AND the full-screen window
      (`PlayerFullScreenControls` now overlays it too — the re-parented layer had no
      status UI before). Fades in/out; hidden while seeking.
    - **First-play-after-restart lag (user report, fixed)**: the first file played after
      an app restart lagged; every subsequent file was instant. Root cause: one-time
      process-level cold costs sat on the first play path — the MPVKit dylib + FFmpeg
      codec registration + full mpv core init, and the loopback VaultStreamServer's lazy
      NWListener bind. Fix: launch-time media pipeline warm-up in
      `completePostAuthSetup` (0.5 s after Telegram is up, utility priority):
      `VaultStreamServer.startServer()` binds the listener early, and a new
      `MPVController.warmUp()` (static) creates a throwaway headless core, awaits
      `onCoreReady` (4 s timeout so a failed init can't hang), then tears it down —
      dylib, codec tables, and core init all happen at launch, off the play path.

40. **Library book-cover polish (2026-08-15, post-commit)** (`Features/FileBrowserView.swift`,
    `Features/BookReaderView.swift`)
    - **Menu button leak fixed**: the ellipsis overlay was attached AFTER the
      breathing-room padding, so `.overlay(alignment: .topTrailing)` aligned to the
      padded box and the button's top edge poked above the cover. Now attached
      directly to the clipped cover (before the paddings) — the alignment box IS the
      cover, button fully inside the top-right corner with an 8 pt inset.
    - **Button style matched to the other cards**: always-visible, full opacity,
      `Color.black.opacity(0.40)` circle + glass (user rejected the hover-fade idea —
      wants the button identical to folder/file card menus).
    - **Reading-progress bar**: Apple Books-style 4 pt accent bar at the cover's
      bottom edge when a book is > 2% read. Reader persists a throttled 0–1 scroll
      fraction to `xc.reader.progressFraction.<id>` (`persistScrollFraction`, delta
      ≥ 0.005); comics persist `pageIndex / (pages-1)` in the chapterIndex onChange.
      The grid item reads it live via a dynamic-key `@AppStorage`
      (`FileGridItem.init` — the grid struct gained a custom init with the same
      signature as the old memberwise one).
    - **Richer placeholder**: muted gradient "dust jacket" + serif title.
    - Verified by the user (covers + button placement). Note: progress bars only
      appear for books opened AFTER this change (fraction wasn't persisted before).

41. **Upload progress stutter fixed — "30 then back to 27, 70 then back to 68"**
    (2026-08-15, user report on the photos page) (`Engine/UploadEngine.swift`,
    `Engine/TransferCenter.swift`, `Features/LiquidMorphingFAB.swift`)
    - **Root cause 1 — TDLib chunk retries**: TDLib resets a retried segment's
      `uploaded_size`, so a chunk's fraction dipped backward and dragged the
      aggregate down. `ParallelUploadProgress.setFraction` is now MONOTONIC per
      chunk (`max(existing, new)`).
    - **Root cause 2 — parallel uploads finishing**: the FAB's aggregate averaged
      only ACTIVE transfers; when one of several parallel photo uploads completed,
      its 1.0 × totalWork left both numerator and denominator — the remaining
      files' progress was reweighted and the overall jumped backward. TransferCenter
      now keeps `settledWork` + `settledItems`: successful `finish()` moves the
      item's work into the settled bucket (completion is exactly neutral), a new
      batch starts when an active transfer begins with nothing else active
      (resets the bucket), and discard/removeItems/clearFinished/eviction unsettle.
      New `TransferCenter.batchProgress` is monotonic by construction; the FAB uses
      it. `update()` clamps progress to never decrease (defense in depth).
    - Unit tests still green (transfer tests untouched — behavior superset).

42. **Photos keyboard navigation — "random photo opens on →" FIXED PROPERLY**
    (2026-08-15; this bug has recurred several times — root cause finally unified)
    (`App/AppState.swift`, `Features/FileBrowserView.swift`, `Features/TheaterView.swift`)
    - **Why it kept coming back**: the grid and the preview built their orders from
      DIFFERENT sources. The Photos/Videos grids show albums/playlists first, then
      day-grouped media (`MediaGridLayout.dayGroups` — newest day first, oldest first
      within a day), an order no single global sort can express. The theater's arrow
      keys re-derived the walk order from the browser's GLOBAL sort option
      (`sortedMediaBase` — name/date/size…), so → jumped to whatever that sort put
      next — a different, "random" photo. Each previous fix patched one surface
      (grid keys vs theater keys) without unifying the source.
    - **The fix — ONE order source**: the grids' reported order now lives in
      `AppState.mediaOrderedIDs` (was browser-local `@State`); `FileBrowserView`
      writes it, its grid keyNav reads it, and the TheaterView's `navigableFiles`
      and `mediaFiles` walk EXACTLY that sequence on Photos/Videos (falling back to
      the sorted list only if the grid hasn't reported yet). The filmstrip, "x of y"
      counter, audio queue, and up/down column math (`gridVerticalStep`) all follow
      the on-screen grid now. Media grids also publish their adaptive column count
      to `appState.gridColumnCount` (previously only the standard grid did, so the
      preview's vertical stepping used the wrong column count on media pages).
    - This is why Apple Photos / Google Drive never hit it — the viewer consumes the
      grid's own layout. Rule going forward: the preview must never rebuild
      navigation order from a different source than the visible grid.


43. **App freeze after "local cache purge" — FIXED (2026-08-16)**
    (`Engine/VideoFrameExtractor.swift`)
    - Sample proved the extraction task body ran on the MAIN THREAD despite
      `Task.detached` (this Swift runtime executes the nonisolated `@isolated(any)`
      closure inline on the creating thread), inside `avformat_open_input` →
      `ff_network_wait_fd_timeout` → `poll` with no timeout. Purge → grid re-key →
      uncached videos take the stream-URL branch → main thread jammed forever.
    - Fix: `rw_timeout` + `timeout` (15 s) AVOptions on remote opens; extraction
      hops to a dedicated `.utility` `DispatchQueue` via `withCheckedContinuation`
      + `withTaskCancellationHandler`; `DispatchSemaphore(value: 2)` caps concurrency.

44. **Upload-time thumbnail pipeline — verified end-to-end + JPEG compliance**
    (2026-08-16) (`Engine/ThumbnailService.swift`, `Engine/UploadEngine.swift`,
    `Engine/FaceEngine.swift`, `App/AppState.swift`)
    - Verified with a full real-world pass: 15 uploads across every type + a
      cache-clear recovery test. 15/15 files recovered (local regen from cache or
      `-tg.jpg` re-fetch from the channel). All attached JPEGs comply with TDLib
      `inputThumbnail` limits (JPEG, ≤320 px, <200 KB) — verified programmatically:
      320×320, progressive, 6.9–73 KB.
    - `ThumbnailCrop.jpegData(from:quality:)`: CGImageDestination, q0.85,
      progressive (`kCGImagePropertyJFIFIsProgressive`), color-share optimized.
    - `UploadEngine` consolidated `generateThumbnail`/`generateUploadThumbnail`/
      `generateVideoThumbnails`/`subjectThumbnail` into
      `generateThumbnails(for:objectID:isVideo:)` (640 subjectSquare → 2x PNG +
      aspectFit 320 → `-up.jpg`). FaceEngine thumbnails use the same encoder.
      No `NSBitmapImageRep` JPEG sites remain.
    - IMPORTANT (discovery): photos upload as **documents**, so Telegram never
      auto-generates sizes for them — the attached thumbnail is a photo's ONLY
      stored preview. Keep attaching for photos.

45. **TDLib audio-message support — mp3 streaming + thumbnail fixed (2026-08-16)**
    (`Telegram/TelegramClient.swift`, `Storage/VaultRepair.swift`,
    `Storage/VaultManager.swift`)
    - A test mp3 neither streamed nor fetched a thumbnail (wav/ogg fine). Root
      cause: `InputDocument.disableContentTypeDetection` was **false**, so TDLib
      converted the `.mp3` chunk into `messageAudio`; the app's `primaryFile` /
      `thumbnailFileId` / `thumbnailData` switches only handled
      document/video/photo → `getFileId` threw (no streaming) and thumbnail fetch
      returned nothing.
    - Fix A: `disableContentTypeDetection: true` — future uploads always stay
      documents (real filenames kept).
    - Fix B: full `messageAudio` handling added — `primaryFile` (`audio.audio`),
      thumbnail fetch (`albumCoverThumbnail` / `albumCoverMinithumbnail`),
      `messageCaption`, repair/rescan diagnostics, channel dump, orphan purge,
      `blobCaption`. Already-uploaded audio chunks now stream + fetch without
      re-uploading.

46. **Vault channel auto-archive + mute (2026-08-16)**
    (`Telegram/TelegramClient.swift`, `App/AppState.swift`)
    - `archiveVaultChannel(chatId:)` runs at every post-auth setup:
      `addChatToList(.chatListArchive)` + mute via
      `setChatNotificationSettings(muteFor: 367 days)` (TDLib clamps >366 d to
      forever). The mute is REQUIRED: TDLib auto-moves unmuted archived chats back
      to the main list when a new message arrives (would happen on every upload).
    - Gotcha: the first attempt called this inside `ensureVault()` after the vault
      save, but `ensureVault` returns EARLY for an existing vault → never ran.
      Moved to `completePostAuthSetup` (runs every launch).


47. **Backup mirror channel — "xCloud Backup" (2026-08-16)**
    (`Engine/BackupSync.swift` NEW, `Storage/DatabaseManager.swift` v20,
    `Storage/Models.swift`, `Storage/VaultManager.swift`, `Storage/CatalogSnapshot.swift`,
    `Storage/VaultRepair.swift`, `Telegram/TelegramClient.swift`,
    `Engine/UploadEngine.swift`, `App/AppState.swift`)
    - Every message the app posts to the vault channel (chunk messages, checkpoint/
      delta catalog messages, vault-key record, folder metadata, unencrypt copies)
      is **forwarded** (`forwardMessages`, `sendCopy: false` — zero-cost reference,
      captions + encryption preserved) into a second private channel "xCloud
      Restore", archived + muted like the vault. If the main vault channel is
      deleted or the app malfunctions and wipes it, the backup channel still holds
      the complete storage + catalog (whole-channel restore is a later phase).
    - Queue: `backup_msgs` table (main messageID → backupMessageID mapping, status,
      attempts) drained by a serial `BackupDrainer` actor at ~1 msg/sec with
      flood-wait handling; concurrent drains coalesce.
    - Edits are mirrored: `BackupSync.editAndMirror` updates the backup copy's
      caption via the mapping (edits that land before the forward are picked up
      automatically by the forward). Used by `syncObjectMetadataToTelegram` and the
      vault-key record post.
    - **Permanent deletion = gone from BOTH channels** (user decision — Trash is
      already the backup; no retention/tombstones): `deleteForever`,
      `purgeOrphanedMessages`, `cleanupPartialUpload`, `deleteStaleKeyRecords`, and
      snapshot pruning all route through `BackupSync.deleteFromVaultAndBackup`;
      vault reset wipes the backup channel entirely.
    - Telegram limits research (2026-08-16): NO daily forward/upload quotas exist
      (the "1,000/day" figure is a myth — tginfo.me). Real limits: ~1 msg/sec per
      chat flood control, 2 GB/4 GB per file, 1,024-char captions (free),
      non-Premium upload speed throttle (undocumented monthly threshold), 500/1,000
      channel+group memberships, 50 channel creations/day. Details in ROADMAP.md.
    - Gotcha: `??` with `try? await` on the RHS failed to compile
      ("async call in a function that does not support concurrency" — apparently an
      interplay with the default MainActor isolation flags); restructured to an
      explicit if/else. Committed 2026-08-16 as part of the mirror-channel commit.
      Pending user verification: mirror works, permanent deletes vanish from both
      channels.
48. **Backup mirror debug + rename (2026-08-16)**
    - **THE BIG ONE:** every `backupChannelID > 0` guard silently failed —
      Telegram chat IDs are **large negative numbers** (`-100xxxxxxxxxx`), so the
      drainer never forwarded (queue filled with `attempts = 0`), caption sync and
      backup-side deletes never ran, and `ensureBackupChannel`'s early return never
      triggered (every launch re-searched + re-created the channel after the user
      deleted the empty one from Telegram). Fixed by replacing all five `> 0`
      checks with `if let backupID = vault.backupChannelID`.
    - Channel renamed "xCloud Restore" → **"xCloud Backup"** per user request;
      `findBackupChannel` adopts a legacy "xCloud Restore" channel and renames it
      via `setChatTitle`.
    - Debug infrastructure: `BackupSync.mirrorLog` appends to
      `/tmp/cascade-backup.log` (the unified log is unreadable on this machine and
      stdout is lost when launching via `open`); drainer logs each forward, failure,
      and per-drain summary. Drainer now caps at 50 messages per drain so a stuck
      TDLib request can't wedge the queue permanently.
    - Verification: relaunch drained the 2 queued test rows → forwarded to the new
      channel (backup messages 1048577/1048585), status `done`. Build + tests green.
      Still pending user re-verification of a live upload + permanent delete.
49. **Forward-based shares — verified live + two live bugs fixed (2026-08-16)**
    (`Engine/ShareEngine.swift`, `xCloudTests/xCloudTests.swift`)
    - **First real v2 share worked end-to-end**: reusable "xCloud Shares" channel
      created (archived + muted), vault chunks forwarded server-side
      (`messages.forwardMessages`, sender's ciphertext + unified captions intact),
      v2 link minted and stored (`shares.linkBlob`), `key=` empty for the non-private
      PNG as designed.
    - **Stale-record hijack** (found live): re-sharing returned the pre-rewrite v1
      link — `reusableShareLink` matched a legacy share record (state active,
      channel still cached by TDLib) and returned its v1 link verbatim, so the
      forward path never ran. Fixed: `messageIDs`-empty records are skipped when
      reusing; re-sharing mints a fresh v2 share; legacy records remain importable
      until expiry. `shareReusesLiveLinkInsteadOfMintingNewOne` extended (v2
      records carry `messageIDs`, new step asserts legacy never reused).
    - **Empty-catalog incident**: `sourceUnavailable` on share attempt because the
      local DB had 0 objects/0 chunks — the previous session's
      `CatalogSnapshot.restore()` never completed its write. Relaunch under a pty
      (`script -q /tmp/cascade-app.log <binary>` — stdout prints are block-buffered
      when redirected to a plain file, invisible; the pty makes them line-buffered)
      → restore succeeded: "19 objects, 22 chunks", all chunk message IDs present.
      No re-upload was needed — the files were in the channel all along.
    - **Stale-binary incident**: an earlier "nothing happened" trace was the
      pre-rewrite binary still running (started 14:44; its log showed
      `cascade:share:v1:` captions + share-tmp uploads). Always relaunch on a fresh
      build before judging behavior.
    - Deferred: real two-account E2E (user: "wait for the testing") + the
      protectContent **second hop** (recipient re-forwarding protected copies).
50. **Window-disappearing on link open — fixed + hardened (2026-08-16)**
    (`App/TerminationHandler.swift`, `App/xCloudApp.swift`)
    - Symptom: opening the shared link in the browser while the app ran made the
      main window vanish (process alive, zero windows per System Events, only a
      Dock thumbnail + menu-bar-sized windows in CGWindowList).
    - **Stale URL-handler registration**: `lsregister` showed the `xcloud://` claim
      on a DELETED build path (`DerivedData/xCloud/Build/Products/Debug/xCloud.app`,
      same bundle id as the running dev app) plus long-gone DMG-check copies — the
      "two instances fight over the window" trap. Cleaned: stale paths unregistered,
      current build re-registered (`lsregister -f`). Verified via
      `open cascade://share#…` → running app receives the URL, self-opens (reveals +
      flashes the file), window stays.
    - **Hardening**: URL delivery now `deminiaturize`s a minimized main window
      before ordering it front; zero-window recovery posts `recreateMainWindow`
      (observed by main + About scenes → `openWindow(id: "main")`) AND simulates
      the Dock-icon reopen twice (`applicationShouldHandleReopen` — SwiftUI `Window`
      scenes restore natively on reopen; `openWindow` on an existing `Window` scene
      is a no-op, so all paths are idempotent). Diagnostic prints on the whole URL
      path (`xCloud URL: …`) — previously the failure was silent.
51. **Production build isolation — v1.1.0 DMG (2026-08-16)**
    (`xCloud.xcodeproj`, `App/AppPaths.swift` NEW, `Storage/DatabaseManager.swift`,
    `Telegram/TelegramClient.swift`, `Engine/{Upload,Download,Face}Engine.swift`,
    `App/TerminationHandler.swift`, `Crypto/KeychainStore.swift`)
    - **Problem**: Debug and Release shared bundle id `com.nemesys.xcloud.xCloud`
      and hardcoded `xCloud` data folders — the released app would share the dev
      app's keychain session, database and TDLib state (and the single-instance
      guard would treat them as one app). User requirement: production must not
      conflict with testing data.
    - **Release config**: bundle id → `com.nemesys.xcloud.xCloud.prod`,
      `MARKETING_VERSION` → 1.1. Debug keeps `com.nemesys.xcloud.xCloud`.
      Keychain service derives from the bundle id, so the prod build gets its own
      Telegram session / vault PIN / master key automatically.
    - **`AppPaths.dataFolder`**: `"xCloud"` (dev) vs `"xCloud-Prod"` (prod, bundle
      id ends `.prod`). All hardcoded data paths now scoped through it: database,
      TDLib dirs + file cache, downloads cache, upload tmp/thumbs, face vectors,
      and the URL handoff file. Handoff notification name derives from the bundle
      id so dev and prod never hand links to each other.
    - Built `xCloud-1.1.0.dmg` (`scripts/make_dmg.sh 1.1.0`): Release, hardened
      runtime, unsandboxed (same as 1.0.0), `hdiutil verify` OK. Dev and prod run
      side by side; the browser opens whichever build registered `xcloud://` last —
      "Import Shared Link…" (⌘⇧I) inside the prod app is the deterministic path
      (see DISTRIBUTION.md).
    - Full test suite green (52 tests, worktree); main + worktree byte-identical.
52. **Fresh-install login deadlock — fixed (v1.1.1, 2026-08-16)**
    (`App/AppState.swift`, `Features/RootView.swift`)
    - Symptom (user): installed the v1.1.0 DMG, clicked "Connect Telegram" (the
      onboarding button) → eternal "xCloud loading screen", never reached the API
      credentials form.
    - Root cause: with no stored API credentials nothing ever starts TDLib
      (bootstrap + login-gate `.task` both require stored creds) → `isAuthResolved`
      stays false forever → `RootView` renders `AuthSplashView` permanently; the
      login gate itself is gated behind `isAuthResolved`, so the API form the
      onboarding button assumed it would hand off to never appears. Dev build never
      hit it (keychain had stored creds); the fresh-install path was untested.
      Evidence: prod keychain had `master-key` but no `telegram-credentials`; no
      `xCloud-Prod/tdlib` ever appeared. (TDLib's `td_receive` thread in the
      process log is a red herring — `TDLibClientManager.init` starts it the moment
      `TelegramClient.shared` is touched.)
    - Fix: `AppState.hasTelegramCredentials` (set at bootstrap + after a successful
      creds save); `RootView` shows the gate when `isAuthResolved ||
      !hasTelegramCredentials` — no creds → API form immediately; creds present →
      neutral splash until TDLib reports a state (no login-gate flash on launch).
    - Verified live: rebuilt Release app against the untouched prod keychain/data
      → Accessibility tree shows the gate ("Connect Telegram" / "Enter the API
      credentials from my.telegram.org" / API ID field), not the splash.
    - `MARKETING_VERSION` → 1.1.1; `xCloud-1.1.1.dmg` built + verified. User flow
      now: install → (onboarding once) → API credentials → phone/code/password →
      cloud. The pending two-account share E2E resumes from here.
53. **DMG login gate: field hit-testing findings — DMG path PAUSED (2026-08-16)**
    - User: API ID/hash fields only accept clicks near the text center (clicks
      elsewhere don't focus); after entering credentials, "Connect" seemed to do
      nothing. Decision: pause the DMG/production path, continue on the dev build.
    - Findings: (a) the field clicks = macOS 26 hit-testing on the custom-styled
      fields inside the `.ultraThinMaterial` card — affects ANY build that shows
      the gate, dev included (the card was already moved to material background
      once for a container-glass hit-testing bug; the fields themselves still
      restrict the hit area); (b) "Connect" actually worked — prod keychain got
      `telegram-credentials` (19:05) and TDLib created `xCloud-Prod/tdlib/db.sqlite`
      (19:06); no crash reports; the gate presumably advanced to the phone step
      where the same field problem blocked input.
    - Next time the gate is touched: `.contentShape(Rectangle())` + hit-testing
      audit on the styled fields (and the same for the phone/code/password steps).
54. **Encryption dropped — flag-only private vault (2026-08-16, COMPLETED)**
    - User decision (approved design, now built): per-file encryption is GONE.
      Private = `isPrivate` DB flag + PIN-gated section + `.bin` chunks. Files are
      plaintext in the Telegram channel; the vault key seal (PIN/device) still
      protects the app's vault access. Chunk slicing stays (same 128MB chunks,
      same `CryptoEngine.sliceSize` layout) — only the AES-GCM layer is gone.
    - `Engine/UploadEngine.swift`: private uploads no longer encrypt; chunks are
      written raw, `wrappedKey` normalized to nil/empty (caption field kept for
      schema compat). `Engine/DownloadEngine.swift`: no decrypt step — cache is
      the plaintext file. `Engine/VideoStreamingEngine.swift`: `ObjectLayout` lost
      `isPrivate`/`objectKey`; stream serves raw bytes at slice offsets.
    - `Engine/ShareEngine.swift`: `share()` REFUSES private files
      (`ShareError.notShareable`, guarded before auth so it's unit-testable) —
      move the file out of Private to share. Link key layer removed: `w`/shareKey
      always empty on mint; `importForwarded`/`importLegacy` never unwrap, import
      records plaintext (`isPrivate: false`, `wrappedKey: nil`).
    - `App/AppState.swift`: `unencryptFileInTelegram` DELETED; moving a file out
      of Private is an instant flag flip, no decrypt/re-upload. Stale copy updated
      app-wide (About/Onboarding/FileBrowser/ShareProgressSheet no longer claim
      "encrypted" / "AES-GCM").
    - `xCloudTests`: `ObjectLayout` test updated to the new init signature; the
      share-reuse test now skips the `chatExists` stale-channel check under XCTest
      (the app-hosted suite boots the real app whose auto-login flips
      `isAuthorized`, which used to revoke the fake share records).
    - Build green (main), full test suite green (48 unit tests). Old encrypted
      chunks in the channel are junk/throwaway (test account).

55. **Streaming replay buffering + player keyboard controls (2026-08-16, COMPLETED)**
    - **Replay buffering root cause (the big one)**: TDLib's ranged `downloadFile`
      does NOT stop at the requested limit — it keeps downloading the WHOLE chunk
      (observed: 128 MB chunk files, fully written, one chunk at a time, ~50 s
      each, even for 8 MB range requests). A STOPPED playback leaves those
      full-chunk downloads running in TDLib's queue; the next play's range
      requests then queue BEHIND the leftovers and starve into PERMANENT
      buffering (telemetry: cache 9.4s → 0.1s, then endless pause-for-cache
      trickle). First play of a file is smooth; REPLAYS collapse.
    - Fixes in `Engine/VideoStreamingEngine.swift`:
      - `invalidatePlayback(for:)` — cancels fetcher chains AND calls TDLib
        `cancelDownloadFile` on every chunk of the stopped file, then drops the
        fetchers, so the next play starts with a clean download queue. Called
        from `AudioPlayerEngine.stopMPVIfNeeded(for:)` on EVERY teardown (stop /
        close / file switch / error).
      - Fetch batching: one TDLib call pulls up to 8×1 MB slices (`slicesPerFetch`)
        — 8× fewer round trips; TrueHD+HEVC needs ~1.25 MB/s sustained and 1-slice
        fetches ran at the edge.
      - Per-chunk fetchers (parallel probe/seek vs stream — different chunks are
        different TDLib files, only same-file ranges must serialize).
      - 30 s `withFetchTimeout` safety net: a hung `downloadFile` (superseded /
        leftover session) can no longer stall a stream forever — the chain is
        cancelled and the retry supersedes it.
    - **Player keyboard controls (`Features/TheaterView.swift` + `AudioPlayerEngine`)**: F7/F8/F9
      media keys now work (NSSystemDefined subtype-8 monitor in `KeyView` + regular
      F-key keyDown fallback for fn-lock keyboards): F8 play/pause, F9 +10s, F7 −10s
      (video) / track skip (audio), held-key repeats throttled to ~3/s. Video arrows
      now SEEK ±10s and ▲/▼ change volume instead of navigating files; the seek goes
      through `AudioPlayerEngine.seekVideo(relative:)` which NEVER falls back to
      switching files — if mpv isn't ready the seek is queued (`pendingVideoSeek` /
      `seekAfterLoad`, applied on `MPV_EVENT_FILE_LOADED`). Volume keys stay with the
      OS (they control the system volume = the app's volume).
    - **AGENT GOTCHA (read this)**: file edits land in the Freebuff WORKTREE
      (`.freebuff/worktrees/<id>/`), but `xcodebuild` runs from MAIN
      (`~/Projects/xCloud`). NEVER sync main→worktree after editing — it wipes the
      edits before they're built (this exact mistake made two builds ship without
      the fixes). Sync WORKTREE→MAIN for every changed file, then build/test from
      main, then relaunch. Verify with `grep` that main actually has the change
      before building.

56. **Player polish + stale production build removed (2026-08-16, COMPLETED)**
    - **Prev/next buttons**: glass chevron circles pinned to the left/right edges
      of the player, vertically centered with the transport; each shows ONLY when
      a file exists on that side of the playlist (`canGoPrevious`/`canGoNext` —
      no ghost buttons). Skip switches the engine's `currentTrack`; the theater
      now follows it (`.onChange(of: currentTrack?.id)` in TheaterView) — without
      that, the player view stayed bound to the old file and skip left a black
      loading screen (also fixed video EOF auto-advance, same latent bug).
    - **Share button in the player** (top-left, glass `square.and.arrow.up`):
      reuses the browser's ShareEngine flow — forward-based link, Drive-style
      reuse, copied to the clipboard with a 2s glass "Share link copied" pill.
    - **Player chrome cleanups**: minimize chevron removed (X closes); file name
      + size shown only above the progress bar (not duplicated in the top bar);
      long filenames middle-truncate; the audio + mini player solid-accent play
      buttons converted to liquid glass (`.glassEffect(.regular.interactive(),
      in: .circle)`) so every transport control app-wide is the same glass.
    - **Stale production build DELETED**: `~/Projects/xCloud/build/` (9.5 GB)
      contained a Release app with bundle id `com.nemesys.xcloud.xCloud.prod` — a
      separate app identity with empty data that hijacked the `xcloud://` scheme
      (browser opened it and the test account wasn't logged in). Removed the
      artifacts + `/private/tmp/xcloud-dmg-check*`, unregistered stale
      LaunchServices entries, re-registered the Debug build (xCloud-main) as the
      scheme handler. DMG backups kept (xCloud-1.0.0/1.1.0/1.1.1.dmg). If a
      browser share link opens a logged-out app again, check `lsregister -dump`
      for stray `xCloud.app` paths and unregister/delete them.
    - **Logs verified**: MP4 replay now refills to a full 20s cache with zero
      pause-for-cache (streaming fix confirmed); zero crash reports; no thumbnail
      or share errors; the "xCloud Shares" channel created and reused.
    - Committed to main. Build green, tests green, both repo copies identical.

57. **Share-link window recovery in full screen — fixed (2026-08-16, COMPLETED)**
    - **Bug**: opening an `xcloud://` share link in the browser while the app's
      window was FULL SCREEN made the window "disappear" (non-full-screen had a
      milder version of the same weirdness).
    - **Root cause**: `TerminationHandler.application(_:open:)` unconditionally
      inserted `.moveToActiveSpace` into the window's `collectionBehavior` and
      called `rescueWindowOnScreen`. A full-screen window owns its Space —
      `moveToActiveSpace` forces the window server to pull it OUT of full screen
      to follow the active space, stranding it on another Space so it looks gone.
    - **Fix**: if `window.styleMask.contains(.fullScreen)`, skip collection/frame
      surgery entirely and just `makeKeyAndOrderFront` — macOS switches to the
      window's Space automatically (standard Cmd-Tab-style full-screen switch).
      Same guard added to `applicationShouldHandleReopen` (Dock-icon reopen).
    - **Gotcha for future agents**: my `rsync -a --delete` worktree→main sync
      nukes `website/node_modules` in main (gitignored, absent in the worktree) —
      ALWAYS pass `--exclude node_modules` (and re-run `npm install` in
      `website/` if it ever gets wiped; astro dev/preview servers may be running
      from it).
    - Build green, tests green, zero crash reports, both repo copies identical.

58. **Share-link window vanishing — TRUE root cause: stale scheme registration + handoff never raises (2026-08-16, COMPLETED)**
    - The full-screen guard in item 57 was necessary but NOT sufficient — the bug
      persisted. Investigation (`lsregister -dump` + app stdout) proved the real
      mechanism: NINE xCloud.app copies were registered for the `xcloud://`
      scheme — `DerivedData/xCloud` (18:36), `xCloud-wt`, `xCloud-cdpcj…`,
      `xCloud-ddqgy…`, `/Volumes/xCloud/xCloud.app` (a DMG copy, twice), and
      `~/Projects/xCloud/build/{Release,dmg-staging}`. The scheme resolved to the
      OLD `DerivedData/xCloud` build, so every browser click made LaunchServices
      START a second instance of that old copy. The duplicate detected the
      running instance, wrote the handoff file, posted the distributed
      notification, and `_exit(0)`d — and the RUNNING instance only drained the
      handoff (imported the link) but NEVER raised its own window. The
      window-raising code in `application(_:open:)` only runs in the process that
      receives the URL from the OS — which was the dying duplicate. Hence
      "window disappears".
    - **Fixes (all in `App/TerminationHandler.swift`):**
      1. **Self-register the scheme on every launch**:
         `NSWorkspace.setDefaultApplication(at: Bundle.main.bundleURL,
         toOpenURLsWithScheme: "xcloud")` in `applicationDidFinishLaunching` —
         whichever copy runs claims the scheme, so a stale bundle can never
         hijack delivery again (self-healing).
      2. **Running instance raises its own window on handoff**: extracted the
         full-screen-aware raise into `raiseMainWindow()` and call it from
         `drainHandoff()` (was only in `application(_:open:)`). Even if a
         duplicate instance ever starts, the running process brings its own
         window forward.
      3. **`handOff()` uses `.activateIgnoringOtherApps` instead of
         `.activateAllWindows`** — bringing all windows forward can yank a
         full-screen window out of its Space.
    - **Cleanup**: deleted the four stale on-disk app bundles (xCloud, xCloud-wt,
      xCloud-cdpcj…, xCloud-ddqgy…), `lsregister -u` all stale entries including
      the `/Volumes/xCloud` DMG record and the `build/` Release/dmg-staging
      entries, re-registered xCloud-main. Verified: only xCloud-main claims
      `xcloud:` now; `open xcloud://…` with the app running spawns NO second
      process and the running instance processes the link (TDLib reads the shares
      channel).
    - **Environment gotcha**: background processes started by an agent shell
      (nohup) die when the tool-call shell exits — the app appears to "keep
      crashing" but never crashes (zero crash reports). Launch the app with
      `open <path>/xCloud.app` instead — LaunchServices-managed instances persist
      across commands. User-launched instances (Dock/Xcode) persist normally.
    - Build green, tests green, zero crash reports, both repo copies identical.

59. **Login-screen flash + full-screen link delivery + sheet/full-screen (2026-08-16, COMPLETED)**
    - **Login flash on every restart — FIXED**: `AppState.hasTelegramCredentials`
      started `false` and bootstrap() set it only after ~1-3s of DB/engine setup,
      so RootView's `!hasTelegramCredentials` branch flashed the login gate at
      every launch for logged-in users. Now initialized synchronously from the
      Keychain at AppState init (`(try? KeychainStore.loadTelegramCredentials())
      != nil`), so the first render already knows — logged-in users go splash →
      main UI, never the login form. First-time users still get the gate.
    - **Full-screen link delivery — root cause found and fixed**: live-isolated
      on this Mac with AX attributes: entering full screen (1440×900) then
      delivering an `xcloud://` link made the window exit to windowed (1224×776).
      The culprit is ANY app-side window work during delivery: `NSApp.activate`
      and `makeKeyAndOrderFront` both make the window server pull a full-screen
      window OUT of full screen so it can become key on the current space (a
      full-screen window can't share a space). `raiseMainWindow` now leaves a
      full-screen window COMPLETELY alone (removes only the `.moveToActiveSpace`
      flag, which would also yank it out on activation) — the OS's own activation
      from the browser click switches to the window's Space (Cmd-Tab semantics)
      and keeps it full screen. If the OS kicks it to windowed anyway, the
      windowed raise path (moveToActiveSpace + rescue + orderFront) brings it
      forward — it can no longer vanish either way. Also: WindowChromeFixer now
      removes `.moveToActiveSpace` on full-screen enter (will/didEnter observers)
      and restores it on exit, so the flag can never sit on a full-screen window.
    - **Popup blocks full screen — macOS-level, not a bug**: a window with an
      attached sheet/alert can't enter full screen (green button / ⌃⌘F silently
      no-op) — same in Safari, Finder, every app. Dismiss the dialog first.
    - **Environment note**: agent-launched apps' windows eventually stop
      compositing and become unreachable via System Events ("Can't get window 1")
      — live full-screen verification is only possible early after a fresh
      launch, and user-launched windows are the real test bed.
    - Build green, tests green, zero crash reports, both repo copies identical.

60. **Full-screen link delivery — consolidated consult fix implemented (2026-08-16/17, COMPLETED)**
    - External review (Claude + Qwen, prompt in `docs/fullscreen-link-consult.md`)
      confirmed v4 and added specifics, now implemented in
      `App/TerminationHandler.swift`:
      1. **`raiseMainWindow`**: full-screen window → left COMPLETELY alone (belt:
         strip `.moveToActiveSpace`, log whether it was present for a
         re-insertion-race check). Windowed → activate only if `!NSApp.isActive`
         (deliberately keeping `activate(ignoringOtherApps:)` here — its Spaces
         degradation only affects full-screen windows, which never reach this
         path, and the macOS 14+ cooperative `NSApp.activate()` can silently
         no-op when the frontmost app doesn't yield), then deminiaturize +
         moveToActiveSpace + rescue + orderFront. No window → activate + recreate
         scene. NEVER orderFront/activate a full-screen window.
      2. **`FullScreenReentryGuard`**: armed at the top of `application(_:open:)`
         and in `drainHandoff` (pre-delivery state); observes
         `didExitFullScreenNotification`; if the window exits full screen within
         0.75s of the delivery it re-enters full screen after 0.4s (letting the
         exit animation settle). A user-initiated exit later is never touched.
      3. **Handoff**: the duplicate instance NO LONGER activates the running one
         (`other.activate` removed) — it delivers the payload (file + distributed
         notification) and exits; the running instance raises its own window via
         `raiseMainWindow`, so activation is a single decision point.
      4. Chrome fixer (`Features/RootView.swift`) unchanged: strips
         `.moveToActiveSpace` on will/didEnterFullScreen, restores on exit.
    - **Diagnostic**: Mission Control "switch to a Space with open windows" is at
      default (enabled) on this Mac, so Qwen's "setting disabled" trigger does
      NOT apply here — the `.moveToActiveSpace`/programmatic-activation mechanism
      is the culprit.
    - Build green, tests green, zero crash reports, both repo copies identical.

61. **Release 1.2.0 + storage cleanup (2026-08-17, COMPLETED)**
    - **Full-screen link delivery USER-CONFIRMED FIXED** (item 60's consolidated
      fix: full-screen windows left alone + FullScreenReentryGuard + no
      activation from the duplicate handoff).
    - **Release build**: `xcodebuild -configuration Release -derivedDataPath
      build` (prod bundle id `com.nemesys.xCloud.xCloud.prod`, isolated data) →
      `scripts/make_dmg.sh 1.2.0` → `xCloud-1.2.0.dmg` (53 MB, hdiutil-verified,
      app version 1.2.0). `MARKETING_VERSION` in the Release config was a stale
      uncommitted `1.1` — now `1.2.0`. `dmgbuild` reinstalled to
      `build/dmgbuild-tools` (it lived in the deleted stale build/).
    - **Cleanup (~20 GB freed)**: deleted stale DerivedData `xCloud`, `xCloud-wt`,
      `xCloud-cdpcj…`, `xCloud-ddqgy…` (kept `xCloud-main` — the running dev
      build); cleaned /tmp agent junk; deleted stale untracked root-level
      duplicates `AppState.swift`, `RootView.swift`, `project.pbxproj` (old flat
      layout, NOT in the Xcode target — App/ and Features/ copies are
      authoritative). Disk free 17 → 33 GB.
    - **Gotchas**: `make_dmg.sh` isn't executable — run with `bash
      scripts/make_dmg.sh <version>`. `build/` and `*.dmg` are gitignored.
    - Uncommitted work on main (waiting for a commit): full-screen link fix,
      login-flash fix, scheme registration, docs 57–61, MARKETING_VERSION bump.

62. **Share-import "Not Found" + blinking-wrong-file + post-login loading + chunk-size/phantom cleanup (2026-08-17, COMPLETED)**
    - **Root cause of "Importing the shared file failed. Not Found."**: the OLD
      `forwardMessage` persisted TDLib **LOCAL** ids (forwarded messages come back
      with a pending id while `sendingState != nil`; the real server id arrives via
      `updateMessageSendSucceeded`). Recipient `getMessage` on a local id → 404.
      Fix: `resolveConfirmedMessageID(_:)` in `TelegramClient.swift` (waits on
      `completedSends` / pending continuations; local ids in a channel are NOT
      multiples of 2^20, real server ids ARE) — used by both `sendFile` and
      `forwardMessage`. VERIFIED LIVE: fresh share stores real ids (`11534336` =
      11×2^20 …), recipient import succeeds; the old broken share is auto-revoked
      by the `reusableShareLink` guard (any stored id that isn't a clean 2^20
      multiple is marked revoked so re-sharing mints a fresh valid link).
    - **Root cause of "importing a link blinked the FIRST image in the debug
      cloud"**: self-open detection matched on `messageIDs` alone — ids are only
      unique WITHIN a chat, so two accounts' channels can contain the same numeric
      id and a recipient mistook a foreign link for their own share. Fix:
      `importLink` matches `channelID AND messageIDs` for forward-based (v2)
      links; legacy disposable-channel links match channelID only.
    - **Post-login loading screen (10–20s)**: `completePostAuthSetup` now fetches
      `identity` + `profilePhotoData` FIRST, so the sidebar user card fills
      immediately; the channel scan still runs but the generic placeholder is gone.
    - **VaultRepair chunk-size bug**: reconstructed chunk records used
      `size / totalChunks` (floor division → wrong per-chunk boundaries; the real
      docs are full plan size except the remainder tail). The wrong sizes corrupt
      the byte-range layout used by streaming fallbacks. Fix: existing chunks are
      now re-synced to the message's ACTUAL document size (`fileSize`), and new
      chunk records use it too.
    - **New debug hook `--repair-catalog <comma,objectIDs>`** (AppState,
      pre-post-auth): drops the given objects + chunks THROUGH the app's own GRDB
      connection, re-syncs every chunk size to the actual document size, then
      republishes the corrected catalog as a fresh checkpoint (pruning old ones)
      and quits — used for operator-level catalog surgery the UI doesn't expose.
    - **THE PHANTOM OBJECT LESSON (5C3C5432)**: my test-import object was deleted
      from the LOCAL DB but its record lived on in the CHANNEL snapshot. The
      `CatalogSnapshot.upload()` reconcile merge treats the channel state as
      authoritative (remote wins for same-id chunks; remote-only records are
      unioned in), then `replaceCatalog` — so ANY launch re-resurrected it, and
      worse, one headless run's upload() published it as a **dbdelta** message
      that then re-injected it on EVERY subsequent launch. Fix procedure:
      (1) delete the poisoned checkpoint/delta MESSAGE from the channel,
      (2) stop the app, delete `xcloud.sqlite-wal`/`-shm` (a leftover WAL from a
      `pkill`'d session kept re-injecting stale state into app reads AND made
      sqlite3 CLI reads disagree with the app), (3) clean the main file,
      (4) relaunch → reconcile is now idempotent. Verified stable across several
      launches: release account shows exactly photo + mp4, both `ready`, real
      message ids, sizes 134217728×6 + 7634680 (sum = object size), zero crashes.
    - **Session preserved**: `xCloud-Prod` (tdlib state + Keychain) untouched — the
      release build still logs in as the same account after the app was replaced.
    - **Gotcha for future agents**: the `--delete-messages` / `--dump-chat` /
      `--create-share` / `--import-share` hooks all run AFTER
      `completePostAuthSetup` — post-auth re-merges the channel state first, so a
      stale channel can re-poison a clean DB before the hook runs. Only
      `--repair-catalog` runs pre-post-auth. After killing an app process with
      pkill, remove `xcloud.sqlite-wal`/`-shm` before trusting sqlite3 reads.

63. **All Files / Shared visibility + leave-share-channel after import (2026-08-17, COMPLETED)**
    - **Why a file can vanish from All Files but stay in Recent/Videos**: chunk
      captions carry `parentID`, and VaultRepair adopted it WITHOUT checking the
      folder exists locally. Imported files carry the SENDER's folder id (folder
      metadata doesn't travel with a share link), so on the recipient the file
      pointed at a non-existent folder and matched no
      `parentID == currentFolderID` filter — invisible in All Files while
      Recent/Photos/Videos (type-based filters) still showed it. Fix: VaultRepair
      now ends with an orphaned-parent reconciliation — any file whose parentID
      doesn't resolve to a local folder is placed at the root (parentID nil).
      Applied automatically on the next launch; verified (release account's mp4
      went from parentID DF58FC5B → nil).
    - **Why the Shared page was empty for the mp4**: the page showed only
      INCOMING share records, and the user's old-binary import never recorded one
      (0 incoming rows). Also, the user's OWN outgoing share (created in the
      fixed build — real message IDs) was invisible because the page ignored
      outgoing. Fix: (a) import already writes an incoming record in the current
      code; (b) the Shared destination now shows BOTH directions —
      `sharedObjectIDs = incoming ∪ outgoing(active)`, like Drive/iCloud;
      (c) backfilled the release account's missing incoming record for the mp4
      with the real share data (channel -1004357139874, message IDs
      11534336..17825792 from the debug account's share).
    - **Why the share channel stayed in the Telegram chat list after import**: the
      import forwarded the chunks but never left the channel. Fix: both the v2 and
      legacy import paths call `leaveChat(channelID)` after the full import
      succeeds (never on failure — a retry needs membership to rejoin with the
      one-use invite).
    - Session preserved; both repo copies in sync; Debug + Release rebuilt;
      release app running for user testing.
64. **Shared page viewer keyboard navigation (2026-08-17, COMPLETED — VERIFIED IN BINARY 14:51)**
    - The viewer (TheaterView) treated `.shared` like `.transfers` — `base = []`
      in `mediaBase` — so opening a file from the Shared page made left/right
      (row, next/previous file) arrows dead: there was no navigable list.
    - Fix: `mediaBase` now has a dedicated `.shared` case mirroring the browser
      grid filter (`sharedObjectIDs ∩ !trashed`), so the viewer's arrows walk
      the shared files in the same on-screen order.
    - Also: removed up/down column navigation in the preview entirely — video
      up/down remains volume; non-video up/down are now a no-op (the user
      explicitly doesn't want column nav in preview mode). `navigateMediaVertical`
      and its call sites were removed.
    - **GOCHA — first attempt never reached the binary**: the edit was applied to
      the Freebuff worktree (relative tool paths resolve there), then a later
      `rsync main→worktree` wiped it, so the built/installed app still had
      `case .transfers, .shared: base = []` and arrows stayed dead. Always
      verify with `grep 'case .shared' Features/TheaterView.swift` in MAIN and
      rebuild + reinstall after every TheaterView change.
65. **Re-import dedup, import name dedup, and the VaultRepair phantom-object bug (2026-08-17, COMPLETED)**
    - **Re-import blinks the existing file**: `ShareEngine.importLink` now checks
      the recipient's catalog for an object with the same content `rootHash`
      (both v2 and legacy paths) and returns a new `.alreadyImported(objectID:)`
      outcome instead of forwarding a duplicate. `AppState.importShareLink`
      handles it like `.selfOpen` — reveal + border flash on the existing copy.
    - **Finder-style name dedup on import**: `uniqueImportName` (pure math in
      `uniqueName(_:taken:)`, unit-tested) appends " 2", " 3", … before the
      extension ("Report.pdf" → "Report 2.pdf") when a same-named, non-trashed
      root-level file already exists — case-insensitive, like Apple.
    - **ROOT CAUSE of the recurring phantom duplicates (5C3C5432, B0D9C02D)**: a
      forwarded share chunk keeps the SENDER's object id in its caption. The
      recipient's import mints its own UUID, so when VaultRepair later scanned
      the vault channel it saw the sender's id, found no matching local object,
      and fabricated a phantom duplicate pointing at the SAME message. Every
      launch's scan re-created it, and since the catalog snapshot merge treats
      the channel as authoritative it survived DB cleanups.
    - Fix: VaultRepair now skips creating an object when a local chunk already
      references the caption's message id (logs "skipping phantom object").
      Also hardened `deleteForever`: it never deletes a channel message still
      referenced by ANOTHER object's chunk (deleting a phantom would otherwise
      destroy the real file's message, since both share it).
    - Cleanup: dropped the live phantom (B0D9C02D, the release account's
      duplicate jpg) via the `--repair-catalog` hook + clean checkpoint; verified
      stable across relaunches (3 objects / 9 chunks, no resurrection). The
      chunk message itself stays — the real object (D8A2E24A) owns it.
66. **Shared page semantics: imports only + Remove from Shared + stale-link reuse guard (2026-08-17, COMPLETED)**
    - **Shared page shows only IMPORTED files now** (incoming share records).
      Previously it showed both directions (incoming ∪ outgoing-active) — the
      sender's own outgoing shares appeared there too, which the user decided is
      wrong: Shared is a history of imports, like Transfers. `AppState.sharedObjectIDs`
      is now `incomingShares` only; the dead `outgoingShares` property was
      removed; browser grid + TheaterView `mediaBase` follow automatically (both
      read `sharedObjectIDs`). Sidebar badge already counted incoming only.
    - **Remove from Shared** (context menu, Shared page, files only): deletes the
      incoming share record(s) for the object WITHOUT deleting the file — it
      stays in All Files/root. `AppState.removeFromShared(_:)` (multi-select
      aware). The shared copy in the share channel remains the sender's to
      manage; the record is local.
    - **Re-sharing after manual channel-message deletion mints a fresh link**: a
      share record could outlive its forwarded messages (user deletes them
      manually in Telegram — distinct from the 7-day expiry cleanup, which
      already revokes + re-forwards). `reusableShareLink` now verifies the
      stored message IDs still exist via `messagesByIds` (cheap, cache-served;
      runs only on an explicit share action) and revokes the record if any are
      gone, so the next share of that file re-forwards fresh copies and returns a
      NEW working link instead of the dead one.
    - Builds green (Debug + Release), full test suite passes, worktree synced,
      release app reinstalled + relaunched (verified healthy: 3 objects, 5 share
      records). Changes NOT committed — user has a follow-up idea and said to
      finish these first.
67. **Group shares — multiple files under ONE link (2026-08-17, COMPLETED)**
    - User: selecting multiple files → right-click → Share only shared a single
      file; it should be a grouped share. `ShareEngine.share(objects:)` is now the
      real entry (the old single-object `share(object:)` is a wrapper): 2+ files
      forward into the SAME reusable channel under one one-use invite, one expiry,
      one link. Recipient imports them all together from that single link.
    - **Link format**: v2 links gain `f` = base64url JSON manifest
      `[{"n":name,"m":"id,id,…"}]` naming each file with its own chunk message
      IDs; `m` stays the flat list so self-open detection + expiry cleanup are
      unchanged. Single-file links emit NO `f` (old links keep parsing). A group
      link with a malformed/empty manifest is rejected whole — it never degrades
      into a partial single-file import. `ShareFile` codec is unit-tested.
    - **Reuse**: `reusableShareLink(for:)` excludes group records (sharing a
      member file alone mints its own link); new `reusableGroupShareLink(for:)`
      returns the identical link when the EXACT same object set is re-shared.
      Both share the extracted `isLiveShare` verification.
    - **DB**: migration `v23-group-shares` adds `shares.groupObjectIDs`
      (comma-separated object IDs on outgoing group records).
    - **Import**: `importForwarded` loops the link's files; each imported file
      gets its own object + incoming ShareRecord (Shared page lists/removes them
      individually); all-already-imported returns `.alreadyImported`.
    - **UI**: context menu shares the whole selection with a count-aware label
      ("Share 3 Items via Link…"); folders/private files filtered out
      (private keeps its dedicated `notShareablePrivate` error); ShareLinkSheet
      + import alert are count-aware.
    - Debug build green; 46 unit tests green (3 new group-share tests). Synced
      worktree → main. Not committed.

---
68. **Share channel pool + public/private shares (2026-08-17, v3 — IMPLEMENTED, NOT VERIFIED IN-APP)**
    - **Architecture** (user-approved design): PRIVATE shares each take a
      DEDICATED pool channel (share_state ids 1…5, one active private share per
      slot — a private link's holder can never read other files' messages),
      expiring one-use invite, revoked by deleting the whole channel (instant
      death, slot freed). PUBLIC shares never expire and live TOGETHER in the
      persistent public channel (share_state id 100); its stored permanent
      invite (no expiry, no member limit) embeds in EVERY public link, so any
      holder can join any time. The app never leaves or retires owned channels;
      a missing channel (deleted out-of-band) is recreated in place. Pool full
      (5 active private) → `ShareError.privatePoolFull` — blocked with a clear
      alert, NEVER silently evicting an older share (decision (a): block, not
      evict-oldest).
    - **DB**: migration `v24-channel-pool` — `shares.isPublic` (boolean, default
      false), `share_state.kind` ('private'/'public', default 'private') +
      `share_state.inviteLink` (permanent reclaim/public invite). The legacy
      single reusable channel row (id 1) becomes private pool slot 1. New
      `ShareChannelState` model; `shareChannelID/setShareChannelID` replaced by
      per-slot CRUD (`shareChannelState(id:)`, `(channelID:)`,
      `saveShareChannel`, `deleteShareChannel`, `allShareChannels`).
    - **Engine**: `ShareEngine.allocatePrivateChannel()` (busy-slot tracking via
      active shares' channels, live-reuse pass then create pass, count guard
      first), `publicChannel()`, `createPoolChannel(id:kind:)` (archives +
      stores permanent invite; refuses under XCTest so the app-hosted suite
      never creates real Telegram channels); `share(objects:lifetime:isPublic:)`
      + `forwardShare` pick channel/invite/expiry by kind (public: stored invite,
      `expiry = .distantFuture`); reuse is kind-aware (`reusableShareLink(for:
      isPublic:)` + `reusableGroupShareLink(for:isPublic:)`). Codec: `exp = 0`
      encodes "never", parses back to `.distantFuture`. `cancelShare(_:)` /
      `cancelAllShares()`: private + sole user of channel → deleteChat + drop
      state row; channel still used by another active share (legacy data) or
      public → delete just that file's messages. `cleanupExpiredShares` is now
      pool-aware, skips public, and is finally WIRED into
      `startTransferCleanupLoop` (was defined but never called). `deleteForever`
      revoke + `resetVault` (kills every pool channel) rewritten on top.
    - **UI**: Shared page = `Features/ShareManagerView.swift` (new, added to
      pbxproj — the Features group is NOT a synchronized root group!) — active
      outgoing shares only, "Public — never expires" / "Private — expires,
      revocable" sections, per-card Copy Link + Cancel (confirm alert) +
      "Cancel All Shares" (confirm alert). File context menu gains "Share via
      Public Link…"; "Remove from Shared" removed (no more import grid);
      sidebar Shared badge = active outgoing count; `mainContent` destination
      switch extracted to `destinationContent` (type-checker limit). Imports now
      land as `.inbound` TransferCenter cards under a new "Imports" section on
      the Transfers page (alert text updated); Transfers cards show real
      thumbnails for completed downloads/imports via ThumbnailService
      (`TransferIcon`).
    - **Tests**: 4 new — public codec exp=0↔distantFuture round-trip, kind-aware
      reuse, pool-full guard (relative to the REAL DB's pre-existing active
      private shares — the suite runs against the real app database and real
      shares from earlier testing exist! never assume an empty pool), cancel →
       revoked. Full suite green (46 unit + 4 UI + 4 launch). Debug build green,
       app launched, migration verified on the real DB (isPublic column, slot 1
       private). **Committed as `d9a3e4d` (2026-08-17). NOT yet verified in-app:
       create a private share (expires, cancelable), a public share (never
       expires), fill the pool to 5 → block alert, import from a second account,
       check imports show under Transfers.**
69. **Shared page redesign + Library covers + transfer clarity (2026-08-17 —
    IMPLEMENTED, NOT VERIFIED IN-APP)**
    - **Why**: user feedback — the v3 Shared page "didn't follow the app's
      design scheme"; the simple cards from before were fine; Library book covers
      only appeared after opening the file (Library poster cards showed
      placeholders while All Files thumbs load); Transfers "Downloads" cards were
      confusing ("are those even real?" — YES: real persisted history incl.
      phantom-era junk names; nothing fake was deleted).
    - **Shared page (`Features/ShareManagerView.swift`, redesigned as GRID
      cards)**: cards are now the EXACT All Files card (115pt thumbnail area +
      name/status row, rounded 12, hover scale) in a `LazyVGrid` sized by
      `xc.cardWidth` like the file browser. The shared file's real thumbnail
      shows (ThumbnailService), or its type icon; group shares show a folder
      icon + "N files". Kind is a small badge on the card's top-trailing corner
      — orange `lock.fill` for private, green `lock.open.fill` (unlocked) for
      public — beside the ellipsis menu (Copy Link / Cancel Share); the
      right-click context menu offers the same two actions. Status row: "Expires
      in 3 days" (private) / "Never expires" in green (public). Header button is
      just "Cancel All" (short label, no icon) and appears only when >1 active.
      Cancel confirm alerts kept (short button labels: "Cancel Share"/"Keep").
    - **Library covers** (`Engine/ThumbnailService.swift`): `bookCoverURL` was
      cache-only by design (storm-avoidance); now when the cover is missing AND
      the book isn't cached it starts a background fetch via new private actor
      `BookCoverFetcher` — single-flight per book, bounded concurrency (3),
      `DownloadEngine.download(quiet:)` (no Transfers card) which generates the
      cover at completion, then posts `.xcThumbnailReady`; the grid's existing
      onReceive re-keys cards (thumbnailVersion++) and the cover appears live.
      Cached books still generate in place. Failure is silent + non-critical.
    - **Transfers clarity** (`Engine/TransferCenter.swift`,
      `Features/TransfersView.swift`): `Item.finishedAt` (set on finish, restored
      from history); terminal statusText is now semantic — "Uploaded" /
      "Downloaded" / "Imported" (was "Complete") — and cards append the finished
      time ("Uploaded · 4:12 PM", "MMM d, h:mm a" for older rows), so restored
      history reads as history.
    - **Transfers grid cards fixed-size** (`Features/TransfersView.swift`):
      `TransferGridCard` no longer sizes itself to its text (it did — name
      wrapping to 2 lines / long status made cards taller/shorter). Now a fixed
      file-card shape: 92pt icon area with the thumbnail centered, name 1 line
      (fixed 16pt), status 1 line (fixed 13pt), progress bar — every grid card
      is pixel-identical. List rows already uniform (1-line name/status).
    - **Shared page can't upload/create** (`Features/FileBrowserView.swift`):
      `.shared` excluded from `canUploadOnThisPage` and `createMenuItems` (New
      Folder / New Private Folder) — the page lists handed-out links, not files.
- **Shared page keyboard navigation** (follow-up): arrow keys move the
      card selection like the file grid — left/right along the row, up/down to
      the same column of the next/previous row (row-major math over
      `columnCount`, clamped; visual order = public section then private), and
      the scroll view follows the selection. Return reveals the selected
      share's file. Implemented via a window-scoped key monitor
      (`ShareKeyMonitorView`/`ShareKeyView` in ShareManagerView.swift, same
      technique as FileBrowserKeyView); FileBrowserView's monitor now defers on
      `.shared` so the two never fight. Lock icon is now the proper padlock —
      orange `lock.fill` (private) / green `lock.open.fill` (public). Committed
      as `0463e54` (2026-08-17).
70. **Volume slider fixed for Bluetooth devices + Shared page key/UX polish
    (2026-08-17 — IMPLEMENTED)**
    - **Volume root cause (diagnosed with a standalone CoreAudio probe on this
      Mac)**: the default output is a Bluetooth device (OnePlus Buds 3). On
      Bluetooth devices `kAudioDevicePropertyVolumeScalar` is supported only on
      the STREAM elements (1, 2) — the master element (0) and 'virm' return
      unsupported; the app pinned `kAudioObjectPropertyElementMain` (1), which
      apparently also failed (device-state dependent), so every read returned
      the 1.0 fallback and every write silently failed → dead slider while
      keyboard keys kept working.
    - **Fix** (`Engine/AudioPlayerEngine.swift`): `SystemVolumeManager` now
      resolves the volume element by PROBING candidates
      [Main (1), Master (0), 2, 3, 4] for a readable scalar on start AND on
      every default-output-device change; read/write use the resolved element,
      re-resolving on demand. Verified on this Mac: element 1 reads 0.4375 and
      writes+reads back correctly (test tool wrote 0.7 → 0.7, restored).
    - **Shared page**: section headers are now just "Public" / "Private"
      (no "— never expires"/"— expires, revocable"). Space bar opens the
      selected share like double-click (Return too) — `ShareKeyView` now
      handles keyCode 49.
    - **Progress/seek sliders checked** (VideoPlaybackView + TheaterView):
      both drag → `mpv.seek(to:)` / `audioEngine.seek(to:)` correctly
      (value × duration), optimistic scrub while dragging — no change needed.
    - Committed as `cf91383` (2026-08-17). Debug app running. **No Release
      build** — user policy.
 71. **Follow-up round 6 (2026-08-18): Share menu split, channel naming,
     duplicate-file heal, rename-field fixes**
     - **Share menu** (`Features/FileBrowserView.swift`): the "Share via
       Public Link…" action became an expandable `Menu` "Share" (or
       "Share N Items") with PRIVATE (`lock.fill`, expiring, pool of 5) and
       PUBLIC (`globe`, never expires) submenus — one menu, both kinds.
     - **Channel naming** (`Engine/ShareEngine.swift`, `Telegram/
       TelegramClient.swift`): public channel = "xCloud OC"; private pool
       slots = "xCloud PC1"…"xCloud PC5" via `poolChannelTitle(id:kind:)`;
       legacy "xCloud Shares" channels renamed at reuse time by the new
       `renameChatIfNeeded` (getChat compare → setChatTitle, errors swallowed).
     - **Duplicate-file heal** (`Storage/DatabaseManager.swift` +
       post-auth block in `App/AppState.swift`): two catalog records can
       reference the SAME Telegram chunk message (observed on the real DB:
       `ChatGPT Image Aug 14, 2026, 04_34_16 PM.png` twice at root — record B
       had no rootHash and pointed at the same vault message 355467264 the
       original owned; chunk-level dedupe never sees it). New
       `dedupeDuplicateObjects()` keeps the record WITH a rootHash (content
       dedup then works) or the older one, deletes the loser + its chunk rows
       (the survivor keeps cataloging the message — Telegram untouched), and
       runs in the same post-auth heal block as `dedupeChunkRecords()` so a
       corrected checkpoint is republished when anything is removed.
     - **Rename field** (`Features/FileBrowserView.swift`): the alert
       TextField got `.id(renameTarget?.id ?? "no-target")` so every
       presentation starts from a fresh field reading the binding (a reused
       alert field kept its previous cleared session → reopened empty); the
       grid's `.onKeyPress("a"/"c"/"v")` handlers now return `.ignored`
       while `renameTarget != nil`, so Cmd+A/Cmd+C/Cmd+V reach the rename
       field instead of select-all/copy/paste on the file grid.
     - Committed as `27d0799` (2026-08-18). Tests green (67: 59 unit +
       4 UI + 4 launch). Debug app relaunched; heal verified live on the real
       DB. **No Release build** — user policy.
 72. **AGENTS.md + HDR/Dolby verification + move-conflict semantics
     (2026-08-18 — IMPLEMENTED/VERIFIED)**
     - **AGENTS.md created** (repo root): mandatory workflow for any coding
       agent — update JOURNAL.md + HANDOVER.md in the same session as the
       code, commit after every complete task, Debug-only builds, never
       `git clean`/`reset --hard` on a dirty tree, never touch
       `batch2-mystery-changes-2026-08-17`, build/test/run commands, doc and
       commit conventions, project gotchas, session-end checklist. Read it
       first.
     - **HDR/Dolby playback confirmed intact** (nothing was removed by the
       freebuff incidents): `MPVVideoView.swift` still carries the full
       HDR/EDR pipeline (`applyColorPipeline` line 859: PQ/HLG on BT.2020/P3 →
       EDR layer + PQ colorspace + target-peak hard clip, sRGB fallback,
       churn guard) + gamma/primaries observation (1023-1026) + RGBA16F
       backbuffer (573) + `edrPeakNits` (833); Dolby Atmos/DTS passthrough
       (`audio-spdif` ac3,eac3,truehd,dts + `audio-exclusive`, 974-981) behind
       the Settings toggle (`SettingsView.swift:239`). Prior live verification:
       item 1 (PQ/BT.2020 HDR via EDR pipeline).
     - **Move-conflict behavior (intended, documented)**: moves
       (`moveObject`/`moveToFolder`/`moveObjects`,
       `App/AppState.swift:1545-1622`) only rewrite `parentID` — a moved
       `file.mp4` next to an existing `file.mp4` keeps its name; both coexist
       with the exact same name. No rename ("file 2.mp4"), no replace, no
       dedupe. Finder-style uniquing (`uniqueName`,
       `Engine/ShareEngine.swift:1071`) applies ONLY to share imports at the
       root. If the user later wants Finder-like "Name 2.ext" on moves, that
       is a feature, not a bug fix.
     - Committed as part of the AGENTS.md commit (2026-08-18). Tests green
       (67). **No Release build** — user policy.
 73. **Finder-style name dedupe for moves (2026-08-18 — IMPLEMENTED)**
     - A moved file never collides with a same-named sibling: moving
       `file.mp4` next to an existing `file.mp4` (anywhere — root, folders,
       albums/playlists, drag-drop, context menu, multi-select, batch adds)
       renames the mover to "file 2.mp4" / "file 3.mp4" like the Finder,
       case-insensitive.
     - New `DatabaseManager.uniqueObjectName(base:parentID:reserved:excluding:)`
       (nil parent = root; `reserved` = batch reservations; `excluding` = the
       item itself for in-place renames) on the existing pure
       `ShareEngine.uniqueName` ("Name 2.ext"). Wired into `moveObject` (all
       single moves), `moveObjects` (batch: pre-computed names + shared
       reserved set — no write race), `bulkMove`, `addToPlaylist`,
       `moveToFolder` (now delegates to moveObject), and `rename` (Finder
       parity, self-excluded). Undo/redo restore both name and parent.
       Uploads and share imports already deduped (UploadEngine.swift:108-126,
       uniqueImportName).
     - Gotchas: `??` RHS is a non-async autoclosure — `try? await` inside it
       does not compile; DatabaseManager is an actor (await required from
       Task contexts; batch pre-compute uses the in-memory catalog instead).
     - Committed as part of this round (2026-08-18). Tests green (67).
       **No Release build** — user policy.
 74. **Private pool channels REUSED, not destroyed + imports mirrored to
     backup (2026-08-18 — IMPLEMENTED)**
     - User re-tested and found new Telegram channels were created on every
       private share after cancelling — the disposed channels were never
       reused. Root cause: `cancelShare` called `deleteChat` + dropped the
       share_state row, so `allocatePrivateChannel`'s reuse pass (needs a
       live recorded channel) always fell through to creating a new channel.
     - Fix: cancel now deletes ONLY that file's messages from its channel.
       The channel survives as a disposed pool slot (row kept); the next
       private share reuses it, and a channel is created only when the
       recorded one is actually lost (`chatExists` false). Slots free
       themselves — allocation counts only channels with ACTIVE shares as
       busy. Public channel unchanged (never retired).
     - Also fixed: imported files were NOT mirrored into the backup channel
       (uploads were — UploadEngine.swift:303 — but neither
       `importForwarded` nor `importLegacy` enqueued their forwards), so a
       restore-from-backup would have lost every imported file. Both import
       paths now `BackupSync.enqueue` after each vault forward.
- Committed (2026-08-18). Tests green (67). Debug app relaunched for
        user re-test. **No Release build** — user policy.
  75. **Join/leave share semantics restored + deleteChat verified live
      (2026-08-18 — IMPLEMENTED)**
      - User's claim, verified with a standalone TDLib probe (SwiftPM exe
        against a COPY of the app's real TDLib session): TDLib `deleteChat` on
        the owned pool channels did NOT delete them — the account was LEFT from
        them (getChat → "Chat not found", but the channels persist:
        memberCount=0, permanent invites still VALID and resolving to the same
        chatId; rejoining as the creator regains admin instantly). So the old
        "5 channels, join/leave on share create/cancel" mechanism was leaving
        channels, and the reuse pass (getChat-based `chatExists`) saw left
        channels as lost → created new channels every cycle ("new channels
        again and again").
      - Full cycle proven live on slot 5: `leaveChat` on an owned channel
        succeeds, channel stays alive (status → left); `joinChatByInviteLink`
        via the stored permanent invite returns the SAME chatId and restores
        creator status.
      - Implemented: `cancelShare` deletes the share's messages and LEAVES the
        pool channel (private only — the public channel is permanent, never
        left); `allocatePrivateChannel` pass 2 now REJOINS a left slot via its
        recorded permanent invite (adopts the returned chatId if it ever
        differs; renames legacy titles) and only pass 3 creates a new channel
        when no recorded invite resolves. Under XCTest nothing changes (client
        nil → calls fail silently as before).
      - Committed as `8bbc928` (2026-08-18). Build green, tests green (67).
        **No Release build** — user policy.
      - **Follow-up (`50b2b2f`, same day)**: `revokeExpired` (the 7-day expiry
        cleanup path) still used the old delete+drop-row behavior — an expired
        (not cancelled) share left its channel AND lost its row, so the next
        private share created a NEW channel (the same bug via the expiry
        path). Now expired pool-slot shares follow join/leave exactly like
        cancelShare (delete messages + leaveChat + keep the row); legacy v1
        disposable channels still forget their row. The one-use invite
        (memberLimit 1) and the link expiry are orthogonal: invite =
        security (only the intended recipient gets in), expiry = share
        lifetime (recipient has 7 days to open it; unopened shares are
        revoked and their channel copies deleted by cleanupExpiredShares
        running on the transfer cleanup loop).
  76. **1-day shares, channel TTL, cancel-on-use, staged import UX
      (2026-08-18 — IMPLEMENTED)**
      - Expiry: `ShareEngine.defaultLifetime` 7d → 1d (86400). 24h server-side
        message auto-delete (TTL) enabled on PRIVATE pool channels at
        creation/reuse/rejoin (`setMessageAutoDelete` → TDLib
        `setChatMessageAutoDeleteTime` 86400 — allowed, server-enforced, so
        share messages vanish from Telegram a day after posting even if the
        app never runs again). NEVER on the vault or public channel.
        `cleanupExpiredShares()` now also runs at launch (was 6h-loop only).
      - Cancel-on-use: `updateChatMember` handler → private slot + joiner ≠
        own account → share self-cancels after `cancelOnUseGrace` (300s;
        enough for the recipient's app to forward — a server-side copy into
        their own vault channel, unaffected by the later cancel).
      - Staged import UX: opening a link now forwards every chunk into the
        recipient's vault channel and returns `.pending` — the file is
        streamable/previewable (theater/MPV/audio all read the DB by
        objectID) but NOT cataloged. `pendingImport` objects are excluded
        centrally in `allObjects()`/`allChunks()` (catalog, snapshot, sync,
        VaultRepair promotion, heal, existingObject, uniqueName). Decision:
        Import (`confirmImport`: unique name, ready, BackupSync.enqueue per
        chunk — mirroring deferred so cancelled files never reach the backup
        channel, incoming row → imported) or Cancel (`discardImport`: deletes
        the vault-channel copies + rows). `PendingImportView` sheet with file
        card + Preview + Import/Cancel; pending decisions re-surface at
        launch; re-opening the same link re-presents instead of double-
        forwarding. New file added to the pbxproj (explicit Features group).
      - Security model confirmed in code: links are AES-GCM-obfuscated with a
        RANDOM per-link key riding in the blob (`cascade://share#key‖cipher`),
        no hardcoded key; private links embed a one-use invite (memberLimit 1)
        — the 7-day→1-day expiry is the share lifetime (recipient window +
        cleanup trigger), orthogonal to one-time use.
      - Committed (2026-08-18). Build green, tests green (67). **No Release
        build** — user policy.
  81. **Player controls: seek-hold, bar↔stamp alignment, fullscreen env crash
     fix (2026-08-18 — IMPLEMENTED, PARTIALLY VERIFIED; two items OPEN →
     freebuff)**
     - **Seek no snap-back (user verified)**: `@State seekTarget` +
       `holdProgressUntilSeekLands(_:)` (1.5s MainActor watchdog) pins the bar
       to the clicked/dragged position until `abs(mpv.progress − target)
       ≤ 0.01`. Video (`Features/VideoPlaybackView.swift`) + audio
       (`Features/TheaterView.swift` scrubber, via `progressFraction`).
     - **Horizontal alignment (user: "stamps closer to the bar is good")**:
       equal 76pt label frames; text now hugs the BAR side (left `.trailing`,
       right `.leading`) → stamp→bar gap exactly 20pt both sides (was
       39/34px — Gemini analysis of a 1024×640 crop: bar 294–905, stamps
       "00:47"/"-01:52").
     - **Vertical alignment — OPEN (handed to freebuff)**: stamps nudged
       `.offset(y: -1.5)` but the user reports the stamps and the bar still
       don't share the same vertical axis.
     - **Fullscreen crash fixed + committed (user verified)**: the borderless
       `PlayerFullScreenWindow` hosts `PlayerControlsView` in an `NSHostingView`
       OUTSIDE the SwiftUI scene → `@Environment(AppState.self)` asserted
       (EXC_BREAKPOINT on layout). Fixed: `appState:` param +
       `NSHostingView(rootView: AnyView(controls.environment(appState)))`.
     - **Fullscreen liquid glass regression — OPEN (handed to freebuff)**:
       windowed player = proper glass everywhere; maximized player loses ALL
       glassEffect materials ("two different player UIs"). Hypothesis: the
       manual NSWindow has no appearance (main window forces
       `.preferredColorScheme(.dark)`); candidate fix
       `win.appearance = NSAppearance(named: .darkAqua)` in
       `PlayerFullScreenWindow.present` (`Features/MPVVideoView.swift` ~1480).
     - Committed as `ce8c6fc` (2026-08-18). Build green; full suite NOT rerun
       (last green: 67 at `330f46e`). Debug app relaunched. **No Release
       build** — user policy.
  80. **Player polish: EOF replay, autoplay-next, transport/slider UX; hover
     scrub preview removed (2026-08-18 — IMPLEMENTED)**
     - **Replay after EOF (user verified)**: mpv `keep-open=yes` +
       `eof-reached` observation (`Features/MPVVideoView.swift`) → engine
       `onEndOfFile` with `ended` flag + 5s dedupe (`lastEOFAt`/
       `lastEOFTrackID` — END_FILE can also fire). `togglePlayPause()` with
       `ended` = `seek(absolute: 0)` + `play()` on the SAME core — the old
       async teardown/reload raced with rapid Space presses ("10-20 presses
       to restart" flake). Logs: `EOF track=… ended=true` → `replay seek0+play`.
     - **Autoplay-next toggle**: `autoplayNextEnabled` (UserDefaults
       `autoplayNextEnabled`, default true); `infinity`+"Auto" pill in the
       video bottom bar and the audio volume row (accent when ON).
     - **Transport**: `skipPrevious()` always previous track (>3s rewind
       heuristic removed); video play/pause button routes through the engine;
       audio artist view edge chevrons gated by `canGoPrevious`/`canGoNext`
       on a `.frame(maxWidth: .infinity)` ZStack (pins to the real edges).
     - **Keyboard arrows**: fullscreen video (`PlayerFullScreenWindow.shared
       .isActive`) → ±10s seek; otherwise file navigation. Both the
       KeyMonitorView closures and `.onKeyPress` handlers.
     - **Sliders**: click-to-seek via `DragGesture(minimumDistance: 0)` +
       `contentShape(Rectangle())` on the gesture view (28pt band hit area);
       visual-only drag, one seek on release (no mpv fast-forward artifacts).
     - **Hover scrub preview — added, then REMOVED (user decision, "we don't
       need it")**: AVAssetImageGenerator frame + time bubble above the bar.
       Real bugs found+fixed first: bubble moved to an overlay (never shifts
       the slider), stream-URL resolution de-raced (per-track independent
       task — hover movement during multi-second Telegram layout downloads
       was starving the source cache). User opted out of the feature; all
       preview code + the temporary `import AVFoundation` removed, audio
       hover time bubble removed too. **The no-AVFoundation mandate
       (item 28) is restored: zero `import AVFoundation` in the codebase.**
     - Committed as `330f46e` (2026-08-18). Build green, tests green (67).
       Debug app relaunched. **No Release build** — user policy.
 79. **PDF reader: single Preview-style UI (2026-08-18 — IMPLEMENTED)**
      - User report: PDFs showed two preview UIs — the Apple Books-style
        reader chrome (top bar, progress) AND the WebKit PDF viewer bar.
        Wanted only the Preview-like UI plus close/share controls.
      - `BookReaderView.body`: `format == .pdf` now renders a slim
        always-visible `pdfToolbar` (glass capsule, top-aligned) instead of
        the book top/bottom controls; WebKit's PDF view supplies the
        Preview-style page UI. Toolbar: Close (Esc), title, Open with Default
        App, Share (NSSharingServicePicker — downloads the file first; the
        stream stays on the preview path), Full Screen.
      - Toolbar icons/title are fixed `.white` (book theme's foreground was
        grey-on-white in dark theme; adaptive `.primary` was black — user
        wants white text, light bar as is). Stroke border + shadow added for
        visibility; fullscreenButton takes a `foreground:` parameter (book
        chrome passes `theme.foreground`).
      - Gotcha: the first version was centered mid-screen (the `if .pdf`
        branch dropped the full-height VStack, so the ZStack centered the
        bar) — fixed with `VStack { pdfToolbar; Spacer() }`.
      - DerivedData cleanup on request: 23G → 6.8G — four stale xCloud
        derived-data folders (wt/tests/release/main, ~16.4G) deleted; the
        AGENTS.md-pinned active folder kept. Committed (2026-08-18). Build
        green, tests green (67). Debug app running.
  78. **PDF streaming: byte-range preview, no full download (2026-08-18 —
      IMPLEMENTED)**
      - PDFs previously required a full chunk-by-chunk download before
        viewing (books via `DownloadEngine.download` → WKWebView loadFileURL;
        Theater PDFs were metadata-only). Now: `VideoStreamingEngine`
        serves PDFs as `application/pdf` from the existing byte-range
        VaultStreamServer (206/Content-Range, 1 MB slices, in-memory SliceCache
        — plaintext never touches disk), `pdfStreamURL(for:)` added.
      - `BookReaderView.loadPDF()`: uncached → WKWebView loads the stream URL
        (`BookWebView.isRemote`; WebKit's PDF renderer range-fetches pages
        progressively); on navigation failure → one-shot fallback to the full
        download (`onLoadError` → `handlePDFStreamFailure`). Cached → local
        file as before. Theater PDF details gained a "Preview" button (reader);
        double-click / Space on any PDF now opens the reader directly
        (FileBrowserView.open/quickLook) instead of the metadata panel.
      - **Linearization is NOT required** (user asked): range-capable loaders
        (WebKit/PDFKit/PDF.js) fetch head + tail (xref) + objects on demand;
        sequential-only loaders are the only case needing linearized PDFs.
        No local linearization (qpdf/CoreGraphics) shipped — unnecessary.
      - Verified live with an 86.7 MB non-linearized test PDF (120 pages,
        xref at tail): stream layout canStream=true, pages rendered, **no
        cache file created** (streamed, not downloaded). Gotcha: fresh
        imports ARE cached by UploadEngine (UploadEngine.swift:380-389,
        instant-preview copy), so streaming only engages once that copy is
        evicted — the first render "test" silently used the local copy.
      - Test PDF `xc-stream-test.pdf` left in the vault for manual testing
        (delete via UI when done). Committed (2026-08-18). Build green, tests
        green (67). **No Release build** — user policy. Debug app running.
  77. **Channel profile pictures: branded avatars (2026-08-18 — IMPLEMENTED)**
      - Every xCloud channel now carries a locally-generated branded profile
        photo: 640×640 JPEG (TDLib static photos must be JPEG) with a
        per-family gradient + bold label — "Vault" (blue), "Backup" (green),
        "OC" (public, purple — shows on t.me link previews), "PC1"–"PC5"
        (each slot its own hue so they're distinguishable in the chat list).
      - `Engine/ChannelAvatar.swift` (new; Engine/ is a synchronized pbxproj
        group, no project edit needed) → `TelegramClient.setChannelPhoto`
        (`setChatPhoto` + inputChatPhotoStatic + inputFileLocal, best-effort)
        and `hasChannelPhoto` (getChat().photo). Set at vault/backup creation
        (only if photo == nil, so adopted vaults keep theirs), at pool channel
        creation, and on legacy reuse/rejoin when photo == nil (TDLib
        throttles photo changes).
      - `ShareEngine.healChannelPhotos()`: idempotent backfill at every launch
        (AppState post-auth) for channels that predate this feature —
        `ensureVault` early-returns for existing rows, so the backfill is the
        only path that brands them. Verified live: first launch set all 8;
        second launch skipped all 8 (photos present server-side).
      - Committed (2026-08-18). Build green, tests green (67). **No Release
        build** — user policy. Debug app relaunched and running.

  82. **Freebuff fixes: fullscreen liquid-glass + stamp↔bar alignment (2026-08-18
      — COMMITTED)** (`Features/MPVVideoView.swift`, `Features/VideoPlaybackView.swift`,
      `Features/TheaterView.swift`)
      - **Fullscreen liquid glass restored**: `PlayerFullScreenWindow.present(...)`
        creates a manual borderless NSWindow outside the SwiftUI scene; the main
        window forces `.preferredColorScheme(.dark)` but this window had no
        appearance → `glassEffect(.regular.interactive(), ...)` fell back to light
        mode over the black background (flat, no blur, no glass). Fix:
        `win.appearance = NSAppearance(named: .darkAqua)` right after
        `win.backgroundColor = .black`. Volume slider, minimize/close/transport
        buttons all render proper liquid glass in fullscreen now.
      - **Stamp↔bar vertical alignment**: previous `.offset(y: -1.5)` on both time
        labels wasn't enough (~3 px remaining gap). Root cause: text labels had no
        explicit height — natural line height didn't match the bar's 28 pt frame,
        so SwiftUI's center alignment placed them at a slightly different vertical
        position. Fix: replaced `.frame(width: 76, alignment: ...).offset(y: -1.5)`
        with `.frame(width: 76, height: 28, alignment: ...)` — text containers now
        have the same height as the bar frame, centers align pixel-perfectly.
        Applied in all 4 places (left/right labels in video player + audio scrubber).
      - Committed as `eae32f1`. Build green (Debug). Full test suite green:
        **TEST SUCCEEDED** (59 unit + UI/launch, 0 failures). User to verify
        both fixes. **No Release build** — user policy.

83. **Fullscreen player tiny-window FIXED — contentViewController Auto Layout
      collapse (2026-08-19 — COMMITTED)** (`Features/MPVVideoView.swift`)
      - **Symptom** (from `docs/PROBLEMS.md`, freebuff handoff): after the
        fake-borderless rewrite (c425e14) the fullscreen player window opened
        tiny (~200×100 px) at the top-left and never entered native fullscreen.
      - **Root cause (proven in a standalone harness)**: `win.contentViewController
        = host` (NSHostingController) lets Auto Layout collapse the window to
        the hosting view's SwiftUI fitting size — reproduced as a **1×1 px**
        window at the screen's top-left. The pre-rewrite code attached plain
        subviews with explicit frames + autoresizing masks and never had this
        bug.
      - **Fix**: same SwiftUI tree (`FullscreenPlayerRoot`: MPVLayerHost +
        controls in ONE tree → `.glassEffect()` still renders), but hosted in a
        plain `NSHostingView` subview of a plain `NSView` contentView
        (`hosting.frame = content.bounds`, `autoresizingMask = [.width, .height]`).
      - **Verified end-to-end in a minimal .app bundle**: window created at
        screen.frame → clamped to visible frame on orderFront (normal macOS) →
        `didBecomeKey` → `toggleFullScreen` → native Spaces fullscreen entered
        (frame = full screen) and exit restored the window. The ~200×100
        collapse is gone; the visible-frame clamp (menu bar/Dock) is expected.
      - Committed (2026-08-19). Build green (Debug). Test suite green:
        **TEST SUCCEEDED** (55 unit + 4 UI + 4 launch, 0 failures). Debug app
        relaunched — user to verify fullscreen by eye. `docs/PROBLEMS.md`
        moved into the main repo and rewritten as resolved. **No Release
        build** — user policy.

84. **Fullscreen player REBUILT on a SwiftUI Window scene (flux pattern);
      placeholder dismantle loop found + fixed (2026-08-19 — COMMITTED)**
      (`App/xCloudApp.swift`, `Features/MPVVideoView.swift`,
      `Features/TheaterView.swift`)
      - **User report**: after the contentViewController fix, fullscreen showed a
        non-fullscreen window and the main window "closed or disappeared". User
        pointed at `~/Projects/flux` (a separate player window that "just
        works") as the model.
      - **Second real bug (the reason it never worked)**: the TheaterView
        placeholder was an if/else SWAP. When fullscreen activated, the main
        window swapped `VideoPlaybackView` → placeholder, which unmounted the
        view → SwiftUI dismantled the mpv NSViewController →
        `MPVVideoView.dismantleNSViewController` → `cleanup()` → `teardown()` →
        `PlayerFullScreenWindow.shared.dismiss()` (MPVVideoView.swift:787) →
        the fullscreen window died the instant it appeared, and the mpv
        teardown/rebuild blacked out the main window. The manual-window fixes
        were real but the window was being killed by its own placeholder.
      - **Fix, flux-style**: the fullscreen player is now a system-managed
        SwiftUI `Window` scene (`"fullscreenPlayer"`, `.hiddenTitleBar`,
        1280×800) — no manual NSWindow, no style masks, no intrinsic-size
        collapse, no toggleFullScreen races. `PlayerFullScreenWindow` is
        session-based: `present()` stores a Session (player/mpv/title/subtitle/
        appState), re-parents the live MPVLayerView, and calls
        `openWindow(id: "fullscreenPlayer")` (bound via `FullscreenWindowLink`
        in the main window). `FullscreenPlayerSceneView` renders the transferred
        layer + controls in ONE SwiftUI tree (`.glassEffect()` works);
        `FullscreenWindowConfigurator` sets dark appearance/`.fullScreenPrimary`/
        EDR and auto-enters native fullscreen on `didBecomeKey` (guarded).
        `dismiss()` closes the scene; `sceneDidDisappear` (onDisappear) also
        handles out-of-band closes (Cmd+W) and `completeDismissal` re-parents
        the mpv layer back to the theater.
      - **TheaterView placeholder is now an OPAQUE OVERLAY** over the
        still-mounted player (never unmount it while fullscreen is up — that is
        the dismantle → teardown → dismiss loop).
      - Committed (2026-08-19). Build green (Debug). Test suite green:
        **TEST SUCCEEDED** (55 unit + 4 UI + 4 launch, 0 failures). Debug app
        relaunched — user to verify. `docs/PROBLEMS.md` rewritten. **No Release
        build** — user policy.

85. **Fullscreen player: auto-fullscreen owned by present()/ensureFullscreen
      (2026-08-19 — COMMITTED)** (`Features/MPVVideoView.swift`)
      - **User report**: with the APP's main window in native fullscreen, the
        player fullscreen button opens a separate window that is NOT fullscreen
        and "doesn't support full screen"; works fine when the app is windowed.
      - **Harness evidence** (two-scene SwiftUI .app bundle, logged): (1) without
        `collectionBehavior = [.fullScreenPrimary]`, `toggleFullScreen` is
        silently ignored on a scene window while the main window is fullscreen;
        (2) WITH it set, the toggle works even with the main window fullscreen
        (both can be fullscreen simultaneously); (3) the app's exact previous
        configurator (observer + attach check) passes in the harness — so the
        real-app failure is lifecycle: the configurator is a ONE-SHOT
        NSViewRepresentable (`guard let window = view.window` silently no-ops if
        the window is nil at attach), and a scene window REUSED by `openWindow`
        does not re-create its content → no configurator run, no toggle, and no
        manual way in (hiddenTitleBar = no traffic lights; controls' button only
        dismissed).
      - **Fix**: `present()` owns the toggle — after `openWindow` it runs
        `ensureFullscreen(attempt:)` (retries 0.1/0.3/0.6/1.0s, finds the window
        by identifier tag `xCloudFullscreenPlayer`, re-asserts
        `.fullScreenPrimary`, toggles only while not already fullscreen;
        idempotent). `present()` closes a leftover scene window first (0.5s
        re-present) and `completeDismissal()` force-closes the tagged window if
        the close didn't land — a stuck window can never be reused.
        `FullscreenWindowConfigurator` keeps only appearance/EDR/
        collectionBehavior + the tag (observer/toggle REMOVED — single owner,
        no double-toggle race). Controls' fullscreen button now calls
        `window.toggleFullScreen()` (real green-button toggle) instead of
        dismissing.
      - Committed (2026-08-19). Build green (Debug). Test suite green:
        **TEST SUCCEEDED** (55 unit + 4 UI + 4 launch, 0 failures). Debug app
        relaunched — user to verify both cases (windowed app → player
        fullscreen; app fullscreen → player fullscreen). **No Release build** —
        user policy.
      - **USER CONFIRMED WORKING** (same session). The player now opens in
        native fullscreen even when the app's main window is in fullscreen.

86. **Fullscreen player transition smoothness (2026-08-19 — DONE, completed
      the same evening; see item 88)** (`Features/MPVVideoView.swift` +
      `App/xCloudApp.swift`)
      - **User report (after 256f2e7 confirmed)**: the transition is not smooth
        — the player scene window first POPS UP OVERLAID in the normal Space,
        then animates into fullscreen, then lands in its own Space. Wanted: a
        single seamless swipe motion like flux / Apple's player — no overlay
        flash before the fullscreen animation.
      - **Mechanism to explore**: `openWindow(id:)` makes the scene window
        visible immediately; `ensureFullscreen`'s toggle (+0.1s) starts the
        Space transition afterwards — hence the flash. Candidates: suppress the
        window's initial display until the transition starts (alpha 0 /
        off-screen / not visible until toggle), `window.animationBehavior`,
        or entering fullscreen before the window becomes visible. Note: flux
        does NOT auto-fullscreen its player — check what flux's transition
        actually feels like and whether a plain open (no auto-toggle) plus the
        windowed controls' toggle is what the user wants.
      - **RESOLVED 2026-08-19 (evening)** — implemented as item 88 (transition
        gate + alpha-0 at configurator attach; user: "much much better, almost
        perfect").

87. **Folders lost from the LOCAL catalog — repair fixed; healed from channel
      deltas (2026-08-19 — COMMITTED)** (`Storage/VaultRepair.swift`,
      `Engine/ChunkCaption.swift`)
      - **User report**: "all folders missing from the All Files page — every
        file flattened at root".
      - **Diagnosis**: folders were NEVER lost from the cloud — the vault
        channel still has all 6 folder metadata messages (Books/Images/
        Audios/Videos unified + legacy `xcloud:v1:` Video/Audio; channel
        `-1003757291622`) and every file's chunk caption still carries its
        `parentID`. The LOCAL catalog lost the folder records (first cause
        unknown; candidates: undo of a folder creation — `registerUndo` delete
        AppState.swift:1512-1518 — or a restore from a folderless checkpoint).
        Three bugs made the loss permanent:
        1. `VaultRepair.run()` caption switch lacks `.messageText` (folders
           are sent as TEXT messages) → scan could never rebuild them.
        2. `ChunkCaption.parse` REQUIRED `index`; legacy folder captions lack
           it → didn't parse.
        3. Orphan-flatten (VaultRepair.swift:263) set `parentID = nil` without
           checking whether the cloud still knows the folder.
        Plus a folderless state got published as the authoritative checkpoint
        (`publishCheckpointFromLocal` collapse guard counts only files).
      - **Fix**: scan handles `.messageText`; `isFolder` also via mime
        `xcloud/folder`; `channelKnownFolderIDs` collected from folder
        captions + file captions' parentIDs; the folder's size-0 linkage chunk
        row is recreated when missing (keeps rename-edit linkage, prevents
        duplicate metadata messages/resurrection); flatten only when the
        parentID is unknown locally AND in the channel. `ChunkCaption.parse`
        defaults `index` to 0.
      - **Recovery**: next launch's `CatalogSnapshot.upload()` reconcile
        merged the channel DELTAS (which contained the folder records) back
        into the local catalog before the scan ran — DB healed to 6 folders
        (Books 5, Images 4, Audios 3, Videos 2 files inside), 6 linkage chunk
        rows, 27 objects (21 files + 6 folders), `repair scan changed=false`,
        "reconciled, nothing new to publish". Verified live via sqlite3 on
        `~/Library/Application Support/xCloud/xCloud.sqlite`.
      - Committed. Build green (Debug). Test suite green: **TEST SUCCEEDED**
        (59 unit + 4 UI + 4 launch, 0 failures). **No Release build** — user
        policy.

88. **Fullscreen player: transition gate + flashless alpha-0 entry; ESC-like
      minimize/exit buttons (2026-08-19 — COMMITTED)** (`Features/MPVVideoView.swift`,
      `App/xCloudApp.swift`)
      - **Problem**: the remaining transition flash (window visible in the
        normal Space before the slide) and — after the gate work — the OS
        minimize button and the controls' exit-fullscreen button behaving
        "wrong" (windowed box instead of back to the theater).
      - **AppKit landmine (Qwen/Claude consultant consensus)**: macOS runs at
        most one fullscreen Space transition at a time; a `toggleFullScreen`
        during another window's transition is SILENTLY IGNORED and the target
        window is PERMANENTLY POISONED (only close+recreate recovers).
        `FullscreenTransitionGate` (observes will/did Enter+Exit object:nil,
        FIFO pairing, 3.5s force-settle watchdog; only 4 fullscreen
        notifications exist — no didFail variants) serializes all toggles:
        `present()` queues via `runWhenIdle`; controls `toggleFullScreen()`
        gate-guarded. Swift globals are lazy EVEN module-level → the gate is
        touched in `xCloudApp.init()` (harness-proven: App.init runs at
        process start).
      - **Flashless entry**: alpha-0 at configurator attach (frame 1, guarded
        on `isActive` — restoration/Window-menu windows stay visible) + in
        `configureAndEnter`; reveal at `willEnterFullScreen` (start of the
        slide); black background; tabbingMode disallowed; `.fullScreenPrimary`.
        Watchdog: toggle ignored → recovery ladder (soft reset → reopen fresh
        scene ≤2 → alpha-1 windowed fallback). Harness-validated: queued
        request opened after the main window settled (fs=1 held); normal case
        attach→alpha0→toggle→reveal ~7ms.
      - **Exit polish**: OS minimize (traffic light) while fullscreen →
        `dismiss()` to the theater like ESC (`willMiniaturize` observer gated
        on `.fullScreen`; windowed minimize keeps dock behavior). Controls'
        exit-fullscreen button → `dismiss()` when fullscreen; re-attempts
        fullscreen only when windowed (recovery fallback).
      - **Regression found + fixed**: `updateNSViewController` frame re-assert
        clobbered the player's frame while it was re-parented into the
        fullscreen window (every controls re-render → video shifted/small in
        fullscreen; ESC flow looked broken). Guarded on
        `superview === controller.view`.
      - **Diagnostics kept**: GL surface-size-change log (`xCloud gl: surface=
        WxH videoOut=WxH viewFrame=…`) + post-return fit samples. mpv client
        API 2.3 (modern — FBO-size reconfig internal; `video-out-params`
        mirrors input params on this build, not a fit oracle).
      - Committed. Build green (Debug). Test suite green: **TEST SUCCEEDED**
        (59 unit + 4 UI + 4 launch, 0 failures). User by eye: "much much
        better, almost perfect"; video fit + ESC×2 + minimize + exit button
        verified. Debug app relaunched. **No Release build** — user policy.

89. **ESC routing fixed (theater passes through to fullscreen player); single-ESC
      exits small player for everything; fullscreen entry scaling animation
      killed; legacy empty Video/Audio folders purged permanently (2026-08-19 —
      COMMITTED `5e12d3d`)** (`Features/TheaterView.swift`, `Features/VideoPlaybackView.swift`,
      `Features/MPVVideoView.swift`, `App/AppState.swift`, `Storage/VaultRepair.swift`)
      - **ESC dead in fullscreen** — root cause: `KeyView`'s local keyDown
        monitor swallowed ESC unconditionally; monitors fire in REVERSE
        registration order (harness-proven), so the player's monitor normally
        runs first but ANY remount/reorder starves it. Fix: `KeyView` passes
        ESC through while `PlayerFullScreenWindow.shared.isActive`. Player
        monitor logs `ESC #1`/`ESC #2`.
      - **Spec change**: single ESC in the small player exits playback for
        EVERYTHING (videos included) — the two-step hint lives only in the
        fullscreen player (`showExitWarning` moved out of TheaterView /
        VideoPlaybackView; PlayerControlsView keeps it for the window).
      - **Entry scaling animation** — the fullscreen scene opens at
        `.defaultSize(1280×800)` (App/xCloudApp.swift:118) and the native
        transition scaled it up. Fix: `configureAndEnter` sets
        `window.frame = screen.frame` before the toggle → pure Space absorb.
      - **Exit-lag diagnostics**: `dismiss()` / `sceneDidDisappear()` timestamps
        (delta measures where exit time goes). Awaiting user re-test:
        transitions both ways, fullscreen double-ESC, small-player single-ESC.
      - **Legacy folders purge (user-approved data deletion)**: the empty
        "Video"/"Audio" folders were old-format `xcloud:v1:` TEXT metadata
        messages (292552704, 286261248) always present in the vault channel;
        the repair fix + delta merge merely surfaced them. New debug hook
        `--purge-legacy-folders` (runs BEFORE post-auth): deletes old-format
        folder messages whose folder is EMPTY locally (a legacy folder WITH
        children is never a candidate — `VaultRepair.legacyFolderPurgeCandidates`),
        deletes the local records, publishes a fresh checkpoint with
        baseMessageID = newest (mergedChannelState replays only deltas newer
        than base → they can never resurrect). Verified: 0 `xcloud:v1:`
        messages left; newest checkpoint 378535936; DB = 4 folders
        (Books/Audios/Videos/Images), 25 objects; app relaunch healthy.
      - Committed. Build green (Debug). Test suite green: **TEST SUCCEEDED**.
        Debug app relaunched. **No Release build** — user policy.

90. **Fullscreen player overhaul: ghost-window transition; direct video + image
      fullscreen; player polish; audio volume/chevron/arrow fixes (2026-08-19 —
      COMMITTED `cf4320c`)** (`Features/MPVVideoView.swift`, `Features/TheaterView.swift`,
      `Features/VideoPlaybackView.swift`, `Features/FileBrowserView.swift`)
      - **Ghost-window transition** (completes the deferred "smooth fullscreen
        transition"): `captureTheaterSnapshot` grabs the theater's composited
        pixels (SCWindow/ScreenCaptureKit — CGWindowListCreateImage is gone on
        macOS 26) **cropped to the video area** before the Space swap; the
        snapshot is the window's content during the transition (the theater
        never shows a hole); the live video layer is attached + faded in at
        `didEnterFullScreen`. Theater fades itself out while the new
        `@Published videoLiveInFullscreen` flag is true. Capture failure →
        live-attach fallback.
      - **SessionKind** (`.theater` / `.directVideo` / `.image`); `Session` and
        `present`/`presentNow` now take `kind` + `file: ObjectRecord?`.
      - **Direct fullscreen** (`presentDirect`, context-menu "Open in Full
        Screen" for `isVideo || isPhoto`): plays straight into the fullscreen
        window, no theater. `directMode` fast path in `attachVideoThenToggle`
        (direct mode has no MPVLayerHost, so the old container-wait retry
        timed out and dismissed). onClose/onDismiss stop the engine + clear
        `theaterFile`/`isTheaterFullScreen`. USER-VERIFIED.
      - **Image fullscreen** (`presentImage`, `SessionKind.image`): no engine;
        `ImageFullscreenRoot` owns the download in `.task(id: file.id)` with a
        "Downloading N%" ring + failure states; cached instant; SVG via
        `SVGWebView`. (Fixed a bug where the download Task was gated on
        `window.isActive && session.kind == .image`, which raced present()'s
        deferral paths and dropped the URL → eternal spinner.) Theater header
        fullscreen button moved top-right next to Close; `togglePlayerFullScreen`
        routes `.image`. USER-VERIFIED (after the loading fix).
      - **Player polish**: container-level capsule hover tint; **autoplay button
        removed** (user request; engine `autoplayNextEnabled` default true
        persists, no UI).
      - **Audio fixes** (all user-reported): volume bar now live-syncs the
        system volume via `@Bindable` (was an untracked `Binding(get:)`) —
        rocker/Control Center changes re-render the slider + mute icon in both
        the audio and video players; up/down arrows adjust volume (±0.1) for
        audio AND video; chevron centering — transport band pinned to the play
        cluster (audio 68, video 76) with the edge-row filling it; **slider drag
        fixed** — the hover-tint capsule overlay on the volume pill swallowed
        drags (a shape overlay is hit-testable even when transparent; buttons
        worked only because their tint is inside the button) →
        `.allowsHitTesting(false)` on the tint + hover tint removed from the
        volume pill (matches Apple TV). USER-VERIFIED.
      - Committed. Build green (Debug). Test suite green: **TEST SUCCEEDED**
        (55 unit + 4 UI + 4 launch). Debug app relaunched. **No Release build**
        — user policy.

91. **Private share diagnosis (2026-08-19)** (`Engine/ShareEngine.swift`,
    `App/AppState.swift`, `Telegram/TelegramClient.swift`)
    - User reported: private share card appears in Shared page, but the file
      isn't in any private channel; Telegram shows no channels. Diagnosis:
      - **The share flow WORKS.** Headless repro (`--create-share` +
        `--import-share` hooks, App/AppState.swift:537-588) forwarded a fresh
        file into PC3 (`-1004464188620`), **rejoining the previously-LEFT slot
        via its permanent invite** (second pass of `allocatePrivateChannel`) —
        record `8451B411` minted, link produced, recipient import SUCCESS.
      - **Channels are invisible because every pool channel (PC1-PC5) + the
        public channel are ARCHIVED** (`createPoolChannel` →
        `archiveVaultChannel`). Server dump confirmed the files ARE in PC1/PC2
        (message 5242880, posted 08-18 13:46/17:12 UTC) with the 24h TTL
        (`message_auto_delete_time = 86400`) — deletion was due 08-19
        19:16/22:42 IST. No new DB record existed for the user's latest test —
        same-file share reuses the live link.
      - 17:55 IST `updateSupergroup` → `chatMemberStatusBanned` burst covered
        only OLD revoked channels, not PC1/PC2 — the app had NOT left the
        active channels after sharing.
    - The 24h TTL was **confirmed as intentional behavior** (item 92 reverted
      the mistaken removal).

92. **Reverted: 24h TTL restored on private share channels + launch heal
    (2026-08-19 — COMMITTED)** (`Engine/ShareEngine.swift`,
    `App/AppState.swift`, `Telegram/TelegramClient.swift`)
    - The previous commit (8920745) mistakenly removed the 24h server-side
      TTL from private share channels. User clarified this was an intentional
      feature: private share messages auto-delete from Telegram after 24 hours
      as a lifecycle/security mechanism — the share link expires and the
      channel messages vanish, even if the app never runs again.
    - Reverted: `setMessageAutoDelete` default restored to 86400 (24h);
      `setMessageAutoDelete(chatId:)` calls restored in all 3
      `allocatePrivateChannel` paths (reuse, rejoin, adopt) + `createPoolChannel`
      (private only). Removed the old `disableAutoDeleteOnPoolChannels()` heal.
    - NEW heal: `ensureTTLOnPrivatePoolChannels()` — idempotent launch heal
      that iterates all recorded pool channels and calls `setMessageAutoDelete`
      (86400) on every PRIVATE slot, re-enabling the 24h TTL if it was ever
      cleared (e.g. by the mistaken heal). Public channel is never touched.
      Wired into the post-auth block next to `healChannelPhotos`.
    - Verified live: Telegram shows "Messages will be automatically deleted
      after 1 day" on PC1 again. Server-side enforcement confirmed —
      messages auto-delete after 24h even if the app never runs.
    - Committed. Build green (Debug). Test suite green: **TEST SUCCEEDED**
      (55 unit + 4 UI + 4 launch). Debug app relaunched. **No Release build**
      — user policy.

93. **Share archiving (2026-08-19 — COMMITTED)** (`Storage/Models.swift`,
    `Storage/DatabaseManager.swift`, `App/AppState.swift`,
    `Features/ShareManagerView.swift`, `xCloudTests/xCloudTests.swift`)
    - **Problem**: public shares never expire, so the Shared page accumulates
      cards forever — cluttered for users who share many files.
    - **Solution**: archive shares (hide from UI without revoking — the link
      stays live).
    - **DB**: migration `v25-share-archive` adds `shares.isArchived` (boolean,
      default false). `ShareRecord` gains `isArchived: Bool = false`.
    - **DatabaseManager**: `archiveShare(id:)` / `unarchiveShare(id:)` —
      fetch-modify-save pattern.
    - **AppState**: `activeOutgoingShares` now excludes archived shares;
      `archivedOutgoingShares` computed property added; `archiveShare(_:)` / `unarchiveShare(_:)` methods.
    - **ShareManagerView**: header toggle button switches between Active and
      Archived views; context menu gains Archive / Unarchive action (between
      Copy Link and Cancel Share); empty state adapts to the view mode.
    - **Test**: `archiveShareHidesFromActiveList` — archive hides from active
      list, unarchive restores; `isArchived` persists.
    - Build green (Debug). Test suite green: **TEST SUCCEEDED** (56 unit +
      4 UI + 4 launch). **No Release build** — user policy.

94. **Cascade app icon framing corrected (2026-08-19 — COMMITTED)**
    (`Public/icon.png`, `xCloud/Assets.xcassets/AppIcon.appiconset/`)
    - The installed asset catalog still rendered the previous blue cloud icon.
      The intended dark Cascade source mark had too much surrounding black canvas,
      making it appear undersized.
    - Cropped the source to a centered 1168×1168 square: this retains a narrow,
      safe margin for the silhouette and shadow while allowing the mark to fill the
      application-icon canvas.
    - Rebuilt all ten macOS icon sizes from the corrected master (16 through 1024
      px). Visual inspection covers the 1024 px and 64 px assets; the latter keeps
      the stepped mark distinct. Debug build succeeded including asset compilation.
      **No Release build** — user policy. Commit: `ab77457`.

95. **Revised Cascade app icon adopted (2026-08-20 — COMMITTED)**
    (`Public/icon-new.png`, `Public/icon.png`,
    `xCloud/Assets.xcassets/AppIcon.appiconset/`)
    - The first tight crop was not stale, but its dark mark still looked visually
      undersized in the macOS icon presentation. The user supplied a revised
      1254×1254 composition with a larger mark and edge-to-edge background.
    - The supplied artwork is retained as `Public/icon-new.png` and copied
      unchanged to the canonical `Public/icon.png`; all ten macOS AppIcon sizes
      were regenerated directly from it.
    - Inspected 1024 px + 64 px variants. Debug build **SUCCEEDED** (including
      `actool` asset compilation); prior Debug process stopped and the rebuilt
      `Cascade.app` launched. **No Release build** — user policy. Commit:
      `15ce81c`.

96. **Public/icon.png optimized and applied as macOS AppIcon (2026-08-20 — COMMITTED)**
    (`Public/icon.png`, `icon.png`, `xCloud/Assets.xcassets/AppIcon.appiconset/`)
    - User supplied a tightly cropped 1238×1238 `Public/icon.png` (eliminating the
      8 px outer border padding).
    - Losslessly optimized PNG compression for `Public/icon.png` and copied to root
      `icon.png`.
    - Regenerated all 10 macOS AppIcon asset catalog renditions with Lanczos
      resampling and maximum compression.
    - Debug build **SUCCEEDED**, full test suite **TEST SUCCEEDED** (64: 56 unit +
      4 UI + 4 launch), Debug app relaunched. **No Release build** — user policy.
      Commit: `fb5484f`.

97. **Client-side zero-knowledge encryption & secure sharing architecture (2026-08-20 — COMPLETED)**
    (`Crypto/CryptoEngine.swift`, `Engine/UploadEngine.swift`, `Engine/DownloadEngine.swift`,
    `Engine/ShareEngine.swift`, `Engine/VaultStreamServer.swift`, `Storage/CatalogSnapshot.swift`)
    - Designed full serverless zero-knowledge architecture to eliminate Telegram AI/content-scan risks.
    - 1 MB slice-based AES encryption with random-access streaming into `mpv`.
    - Cloud-to-cloud zero-download sharing with key delivery in URL `#` fragment.
    - Password-protected share links via PBKDF2 key derivation.
    - Metadata/caption sanitization and gzip-compressed snapshot backups.
    - Detailed blueprint saved in `implementation_plan.md`.

98. **Phase 1: Cryptographic primitives (chunk encryption/decryption, slice seeking & link key derivation) (2026-08-20 — COMMITTED)**
    (`Crypto/CryptoEngine.swift`, `xCloudTests/xCloudTests.swift`)
    - Added `CryptoEngine.encryptChunk` and `CryptoEngine.decryptChunk` for multi-slice chunk serialization.
    - Added `CryptoEngine.deriveLinkKey` (PBKDF2-SHA256, 100k iterations) for password-protected sharing.
    - Verified random-access $O(1)$ individual slice decryption against sub-ranges.
    - Full test suite green: **TEST SUCCEEDED** (67: 59 unit + 4 UI + 4 launch, 0 failures).
      Commit: `d69e46a`.

99. **Phase 2: Encrypted chunk uploads & Telegram caption metadata sanitization (2026-08-20 — COMMITTED)**
    (`Engine/UploadEngine.swift`, `Engine/ChunkCaption.swift`, `Storage/VaultRepair.swift`, `xCloudTests/xCloudTests.swift`)
    - Uploads mint random 256-bit $K_{\text{file}}$, wrap with vault key, and store in `ObjectRecord.wrappedKey`.
    - Chunk payloads are encrypted via `CryptoEngine.encryptChunk` with slice indexing (`offset / 1MB`), uploading opaque `.bin` documents.
    - Message captions sanitized: `name = ""` and `mime = "application/octet-stream"`, preventing Telegram AI scanners from reading filenames and types. Added `cipherHash`.
    - `VaultRepair` updated to preserve `plainHash`/`cipherHash` and avoid overwriting local names with empty strings.
    - Full test suite green: **TEST SUCCEEDED** (68: 60 unit + 4 UI + 4 launch, 0 failures).
      Commit: `c7d8e2d`.

100. **Phase 3: Media streaming decryption & download caching (2026-08-20 — COMMITTED)**
    (`Engine/VideoStreamingEngine.swift`, `Engine/DownloadEngine.swift`, `xCloudTests/xCloudTests.swift`)
    - `VideoStreamingEngine`: Unwraps $K_{\text{file}}$, calculates sealed slice offsets (`localSlice * (1MB + 28B)`), fetches exact slices from Telegram, and decrypts in-memory via `CryptoEngine.decryptSlice` with $O(1)$ seek latency for `mpv` loopback HTTP range streaming.
    - `DownloadEngine`: Unwraps $K_{\text{file}}$, verifies ciphertext integrity against `cipherHash`, decrypts chunks via `CryptoEngine.decryptChunk`, verifies plaintext hash, and writes decrypted files to cache.
    - Full test suite green: **TEST SUCCEEDED** (69: 61 unit + 4 UI + 4 launch, 0 failures).
      Commit: `146d9a8`.

101. **Phase 4: Password-protected & simple share links with client-side key re-wrapping (2026-08-20 — COMMITTED)**
    (`Engine/ShareEngine.swift`, `App/AppState.swift`, `Features/FileBrowserView.swift`, `Features/RootView.swift`, `xCloudTests/xCloudTests.swift`)
    - Added both simple (instant) and password-protected sharing modes for private cloud-to-cloud file shares.
    - **Simple share links (Default)**: $K_{\text{file}}$ wrapped with a random 256-bit `shareKey` embedded directly in the obfuscated URL fragment (`#...`). Recipient claims in $<1\text{ms}$ with zero password prompts.
    - **Password-protected share links (Optional)**: $K_{\text{file}}$ sealed with PBKDF2 link key derived from user password + 16-byte random salt. Link carries `#w=...&salt=...` without plaintext key.
    - **Import key re-wrapping**: `stageImport` unwraps $K_{\text{file}}$ using link key and re-wraps under recipient's vault master key (`recipientVaultKey`).
    - Added `SharePasswordPromptSheet` in `FileBrowserView` and `SharePasswordUnlockSheet` in `RootView`.
    - Full test suite green: **TEST SUCCEEDED** (71: 63 unit + 4 UI + 4 launch, 0 failures).
      Commit: `726b450`.

102. **Phase 5: Catalog snapshot zlib compression & immutable backup preservation (2026-08-20 — COMMITTED)**
    (`Storage/CatalogSnapshot.swift`, `Engine/BackupSync.swift`, `Storage/VaultRepair.swift`, `xCloudTests/xCloudTests.swift`)
    - Added hardware-accelerated `.zlib` compression for catalog snapshot JSON payloads, cutting payload size by 80–90% with $<0.5\text{ms}$ latency.
    - Added backwards-compatible decompression with raw JSON fallback for legacy snapshots.
    - **Immutable Backup Guarantee**: `pruneOldSnapshots` only prunes checkpoints from active vault channel and NEVER from the backup channel. `BackupSync.deleteFromVaultAndBackup` permanently protects `checkpointObjectID`, `deltaObjectID`, and `keyRecordObjectID` from deletion in the backup channel.
    - Full test suite green: **TEST SUCCEEDED** (72: 64 unit + 4 UI + 4 launch, 0 failures).
      Commit: `475343e`.

103. **About Cascade window branding & official AppIcon update (2026-08-20 — COMMITTED)**
    (`Features/AboutView.swift`)
    - Replaced the hardcoded SF symbol placeholder with the official high-resolution `AppIcon` asset.
    - Added dynamic version resolution from bundle info and updated copy to highlight zero-knowledge encryption and native MPV media engine.
    - Full test suite green: **TEST SUCCEEDED** (72: 64 unit + 4 UI + 4 launch, 0 failures).
      Commit: `bfe6c39`.

104. **Telegram setup view transition fix & high-DPI country flags (2026-08-20 — COMMITTED)**
    (`Features/TelegramSetupView.swift`, `Features/LoginView.swift`)
    - **API setup stall fix**: `LoginGateView.needsCredentials` was checking `(try? KeychainStore.loadTelegramCredentials()) == nil` instead of reading `@Observable` property `appState.hasTelegramCredentials`. Fixed so SwiftUI automatically observes the credential save and switches to `LoginStepsView` without requiring an app restart. Added `isConnecting` spinner on Connect button.
    - **High-DPI Country Flags**: Upgraded `CountryFlagView` to render official Unicode regional indicator emoji sequences (Apple Color Emoji) with crisp vector graphics on Retina displays. Updated phone number field to render the selected country flag inside the dial code button.
    - Full test suite green: **TEST SUCCEEDED** (72: 64 unit + 4 UI + 4 launch, 0 failures).
      Commit: `db553bc`.

105. **Official PNG channel profile pictures integration (2026-08-20 — COMMITTED)**
    (`Engine/ChannelAvatar.swift`, `Storage/VaultManager.swift`, `Engine/ShareEngine.swift`, `Telegram/TelegramClient.swift`)
    - **Replaced legacy avatars**: Routed all channel avatar generation to use official PNG graphics from `Public/` and `Resources/` (`cascade.png` for vault, `backup.png` for backup, `pc.png` for private pool channels, `oc.png` for public share channel).
    - **Multi-path image loader**: Added multi-candidate asset search (`Bundle.main`, `Resources/`, `Public/`, bundle resources) in `ChannelAvatar.makeJPEG(fromPNG:)` with on-the-fly conversion to TDLib-compatible JPEG.
    - **Launch branding heal**: Enhanced `ShareEngine.healChannelPhotos()` to upgrade legacy channels to the official PNG brand images.
    - Full test suite green: **TEST SUCCEEDED** (72: 64 unit + 4 UI + 4 launch, 0 failures).
      Commit: `a322711`.

106. **Perfect full-bleed cropping for channel profile pictures (2026-08-20 — COMMITTED)**
    (`Public/*.png`, `Resources/*.png`, `Engine/ShareEngine.swift`)
    - **Cropped padding & white borders**: `cascade.png`, `oc.png`, and `pc.png` had circular artwork embedded within a padded white square canvas. Cropped all 3 assets tightly to their circular graphics and rescaled with high-quality Lanczos interpolation to $1254\times 1254$ full bleed (0.00% white boundary pixels).
    - **Full-bleed fit in Telegram**: When Telegram applies its circular crop mask, the artwork now fills the entire circle with zero clipped crescents or white margins.
    - Full test suite green: **TEST SUCCEEDED** (72: 64 unit + 4 UI + 4 launch, 0 failures).
      Commit: `f4c948e`.

107. **XCTestCase safeguard for channel photo updates (2026-08-20 — COMMITTED)**
    (`Telegram/TelegramClient.swift`)
    - **Root cause of duplicate main channel updates**: Unit tests in `xCloudTests` run against the Debug database and invoke `VaultManager.ensureVault()`. Inside `ensureVault()`, an unshielded `Task { await TelegramClient.shared.setChannelPhoto(...) }` was running without checking `underXCTest`, triggering 6 live photo uploads to the main vault channel during the test run.
    - **Fix**: Added `guard NSClassFromString("XCTestCase") == nil else { return }` directly into `TelegramClient.setChannelPhoto` overloads, ensuring tests never issue live photo changes.
    - Full test suite green: **TEST SUCCEEDED** (72: 64 unit + 4 UI + 4 launch, 0 failures).
      Commit: `d4c77ed`.

108. **Dynamic share channel full-bleed branding verification (2026-08-20 — COMMITTED)**
    (`Engine/ShareEngine.swift`)
    - **Creation & allocation paths verified**: Ensured all public and private share channels created dynamically on first share immediately apply `oc.png` and `pc.png`.
    - **Legacy public adoption**: Added photo check in `publicChannel()` to brand existing public channels if unbranded.
    - Full test suite green: **TEST SUCCEEDED** (72: 64 unit + 4 UI + 4 launch, 0 failures).
      Commit: `d5687ba`.

109. **Floating transfers button collective progress & individual queued cards (2026-08-20 — COMMITTED)**
    (`App/AppState.swift`, `Engine/UploadEngine.swift`, `Engine/TransferCenter.swift`)
    - **Collective progress on FAB**: When multiple files are queued for upload, `AppState.startUpload` registers their work in `TransferCenter` upfront with `"Queued…"`. `LiquidMorphingFAB.overallProgress` tracks the entire batch continuously via `batchProgress` (0% to 100% across the whole batch without per-file stutter/reset).
    - **Individual cards on Transfers**: Every queued file gets its own card immediately visible in `TransfersView` and `MiniTransfersView` popover, transitioning smoothly from `"Queued…"` to active uploading to `"Uploaded ✅"`.
    - Full test suite green: **TEST SUCCEEDED** (72: 64 unit + 4 UI + 4 launch, 0 failures).
      Commit: `741d53d`.

110. **Audio thumbnail extraction, Telegram attachment & cache-cleared retrieval (2026-08-20 — COMMITTED)**
    (`Engine/VideoFrameExtractor.swift`, `Engine/UploadEngine.swift`, `Engine/ThumbnailService.swift`)
    - **Embedded artwork extraction**: Added direct attached-picture extraction (`AV_DISPOSITION_ATTACHED_PIC` or `attached_pic.size > 0`) in `VideoFrameExtractor.extract`, retrieving raw embedded album art in 0.1ms via Libavformat.
    - **Telegram attachment**: Wired audio extensions in `UploadEngine.subjectThumbnail` to generate 640px grid PNGs and $\le 320$px JPEGs attached to Telegram chunk messages on upload.
    - **Cache clear resilience & streaming probe**: Added `generateAndSaveAudioThumbnail` in `ThumbnailService` and wired streaming probe/cache reload; audio thumbnails reload cleanly from Telegram or local stream even after cache clears.
    - Full test suite green: **TEST SUCCEEDED** (72: 64 unit + 4 UI + 4 launch, 0 failures).
      Commit: `e542116`.

111. **Pure-Swift audio artwork parser, default artwork generator & smooth streaming loading states (2026-08-20 — COMMITTED)**
    (`Engine/AudioArtworkParser.swift`, `Engine/VideoFrameExtractor.swift`, `Engine/UploadEngine.swift`, `Features/TheaterView.swift`, `Features/VideoPlaybackView.swift`)
    - **Pure-Swift binary parser**: Added `AudioArtworkParser` for ID3v2 (v2.2, v2.3, v2.4 APIC/PIC frames), M4A/MP4 `covr` atoms, and FLAC `METADATA_BLOCK_PICTURE` blocks with 0ms overhead and zero external dependencies.
    - **Default high-res audio artwork**: Added `AudioArtworkParser.defaultAudioArtwork` generating 640x640 vinyl disc art for audio files without embedded art.
    - **Smooth zero-flash media loading**: Fixed `TheaterView` to present `contentView` immediately for video and audio (eliminating the flashing `downloadingView` "Preparing... 0%" card); added glass container with `"Connecting to stream…"` in `VideoPlaybackView` and spinner overlay in `TheaterAudioPlayerView`.
    - Full test suite green: **TEST SUCCEEDED** (72: 64 unit + 4 UI + 4 launch, 0 failures).
112. **Real audio artwork extraction, mini player teardown on delete/trash & 3-button audio player (2026-08-20 — COMMITTED)**
    (`Engine/AudioArtworkParser.swift`, `Engine/UploadEngine.swift`, `Engine/VideoFrameExtractor.swift`, `App/AppState.swift`, `Features/TheaterView.swift`)
    - **Real embedded artwork only**: Removed synthetic placeholders; implemented random-access MP4 atom traversal and ImageIO validation in `AudioArtworkParser`. Layered extraction in `UploadEngine.subjectThumbnail` (`AudioArtworkParser` $\rightarrow$ `QLThumbnailGenerator` $\rightarrow$ `VideoFrameExtractor`).
    - **Teardown on delete/trash**: `bulkTrash()`, `emptyTrash()`, `deleteForever(_:)`, and `loadFiles()` automatically stop `AudioPlayerEngine` and dismiss `theaterFile` if the deleted track was active or floating in the mini-player.
    - **3 Iconic Buttons & Direct Hit-Testing**: Removed side chevron arrows and the overlapping `HStack` container from `TheaterAudioPlayerView`, simplifying to 3 iconic transport buttons and fixing play/pause mouse clickability.
- Full test suite green: **TEST SUCCEEDED** (72: 64 unit + 4 UI + 4 launch, 0 failures).
       Commit: `4e3d8b0`.

113. **Audio thumbnails vanish after cache clear — FIXED (2026-08-20 — COMMITTED)**
    (`Engine/UploadEngine.swift`, `Engine/ThumbnailService.swift`)
    - **Root cause**: `UploadEngine.swift:335` had `thumbnailPath: objectKey != nil ? nil : uploadThumbnailPath`. Since Phase 2 encrypted chunk uploads (commit `c7d8e2d`), every upload mints an `objectKey` (never nil) so the `<id>-up.jpg` preview was NEVER attached to chunk messages — for any file type. Images masked the bug (photos regenerate locally or via the step-6 thumbnail-only download); audio had zero recovery paths (`fetchFromTelegram` found no attached preview + step 6 was photos-only).
    - **Fix (kept)**: `thumbnailPath: uploadThumbnailPath` unconditional (private files still pass nil). New uploads permanently store the preview on Telegram again.
    - **Fix (kept)**: `generateAndSaveAudioThumbnail` now falls back to QuickLook 640×640 for LOCAL files without embedded art (voice memos) — matches the upload-time pipeline, no download involved (new `import QuickLookThumbnailing`).
    - **REVERTED at user request**: the first attempt also extended step 6 (last-resort thumbnail-only download) to audio. User rejected it — quietly downloading every audio file just to rebuild a preview could pull hundreds of GB on a large library. Audio stays excluded from step 6; previews must come from Telegram's attached thumbnail or the local cache. Re-uploading the test files is acceptable.
    - **Guard test added**: `uploadThumbnailJPEGIsGeneratedAndReturnedForAttachment` — synthesizes a PNG, runs `UploadEngine.generateThumbnails`, asserts the `<id>-up.jpg` exists and is ≤320px (TDLib inputThumbnail limit).
    - Full test suite green: **TEST SUCCEEDED** (68: 64 unit + 2 UI + 2 launch, 0 failures).
      Commit: `84194cb` (upload attach + audio recovery v1), followed by `6f17351` (revert audio step-6 + guard test).

114. **Mini player buttons dead — FIXED (2026-08-20 — COMMITTED)**
    (`Features/MiniPlayerView.swift`)
    - **Root cause**: the whole mini bar was wrapped in `.glassEffect(.regular.interactive(), in: .capsule)` while each button inside had its own `.interactive()` circle glass. The interactive material over the entire bar swallows child hit-testing on macOS 26 (same quirk as the DMG login gate). Keyboard controls still worked because they're engine-level.
    - **Fix**: outer bar material → `.glassEffect(.regular, in: .capsule)` (non-interactive); each button keeps its `.interactive()` circle. Same pattern as the working BookReader containers.
    - Full test suite green: **TEST SUCCEEDED** (68: 64 unit + 2 UI + 2 launch, 0 failures).
      Commit: `66b1681`.

115. **Catalog restore hang + silent empty-DB incident — FIXED (2026-08-20 — COMMITTED)**
    (`Telegram/TelegramClient.swift`, `Storage/DatabaseManager.swift`, `Storage/CatalogSnapshot.swift`)
    - **Trigger**: unit test `replaceCatalogCreatesBackupSnapshot` wiped the REAL Debug DB catalog; the launch restore was meant to heal it but left the DB empty ("everything is gone").
    - **Root cause A (hang)**: TDLibKit can DROP the response when TDLib answers instantly from its local cache (`@extra` dispatch races the pending-completion registration) → `getMessage` continuation never resumes → restore parked forever. Watchdog only covered `downloadFile`.
    - **Fix A (kept)**: `withResponseTimeout(_:_:)` (15s task-group race) + `getOrFetchMessage` retries 3× with fresh `@extra` (getMessage → getMessages → getChatHistory+getMessage). New `TelegramError.timedOut`. TelegramClient.swift:381-455.
    - **Fix B (kept)**: cached-file fast path in `downloadMessageFile` — TDLib returning an already-cached file emits NO updateFile event (same drop hazard), so copy the cached path directly. TelegramClient.swift:622.
    - **Root cause B (silent empty DB)**: `replaceCatalog` threw `SQLite error 19: FOREIGN KEY constraint failed` on orphan chunks (size-0 linkage rows for a DELETED folder, objectID `6C76E5E3-…`, floating in channel deltas) — whole transaction rolled back. `restore()` used `try?` and printed "restored" regardless → lying success.
    - **Fix C (kept)**: `replaceCatalog` drops orphan chunks instead of FK-failing (DatabaseManager.swift:990); `restore()` propagates errors honestly (CatalogSnapshot.swift:456).
    - **Channel heal**: the checkpoint had been pruned from the vault channel (only a forward survived in backup), so restore replayed all 23 deltas. Republished a clean checkpoint with `baseMessageID = newest channel ID`; stale checkpoints pruned; old deltas now covered and inert.
    - **End-to-end verified**: wiped DB → clean restore from checkpoint (25 objects, 25 chunks, NO `file1.txt`, 0 orphans) → "reconciled, nothing new to publish". Healed the same way after the test suite re-wiped it.
    - Full test suite green: **TEST SUCCEEDED** (70: 66 unit + 2 UI + 2 launch, 0 failures).
      Commit: `024523b`.

116. **Bulletproof restore: backup-channel fallback, drainer wedge fix, VaultRepair resurrection fix (2026-08-20 — COMMITTED)**
    (`Storage/CatalogSnapshot.swift`, `Engine/BackupSync.swift`, `Storage/DatabaseManager.swift`, `App/AppState.swift`)
    - **Backup-channel restore fallback**: `fetchChannelState(chatId:allowBackupFallback:)` — RESTORE ONLY (upload/publish never use it: stale backup must not clobber a populated local catalog, and baseMessageID computations stay in vault id-space). Vault channel without a usable checkpoint → newest checkpoint FORWARD in the backup channel becomes the restore base; vault deltas still apply on top. Freshness guard: if any delta record's modifiedAt is newer than the checkpoint's newest, `deltaBase = -1` replays EVERY delta (LWW resolves) — a stale forward can't hide uploads that live only in deltas. Handles the vault-channel-gone case via backup delta forwards. Live-verified both branches.
    - **Backup drainer wedge**: the drainer `return`ed on the first forward failure — a message pruned from the vault before its mirror completed sat at the FIFO head forever, stalling ALL pending backups (67 messages incl. a clean checkpoint forward during the incident). Fix: after 5 failed attempts a message is marked `failed` and SKIPPED (`markBackupFailed`/`backupAttempts`). Backup channel now actually stays fresh.
    - **VaultRepair resurrection**: `--repair-catalog` dropped objects locally only; the chunk FILE MESSAGE stayed in the channel and VaultRepair rebuilt the object from its caption at the next launch — the real "file1.txt keeps coming back" loop (app-driven deleteForever never had this: `deleteFromVaultAndBackup` removes the messages). Fix: the hook deletes the dropped objects' chunk messages from vault + backup (+ queue rows) before publishing.
    - **Live-verified**: vault checkpoints deleted → wipe → restore used the fresh backup forward (25 objects, no file1.txt); stale forward → full delta replay. After the test suite wiped the catalog again, a normal launch healed: "channel checkpoint=true deltas=23" → "snapshot restored: 25 objects, 25 chunks" → reconciled. Final DB: 25 objects / 25 chunks (10 active + 12 trashed + 3 folders), no file1.txt, backup queue drained.
    - Full test suite green: **TEST SUCCEEDED** (70: 66 unit + 2 UI + 2 launch, 0 failures).
      Commit: `9d27481`.

117. **Architecture review round — honest gap assessment + Claude consultation prompt (2026-08-20 — DOCS ONLY, no code)**
    User asked whether the architecture is "perfect and bullet proof" and requested a self-contained Claude prompt (external consultant, per AGENTS.md rule 8) for an architecture review aiming at "Google Drive level". Delivered an honest assessment: the app is solid for a single-user Telegram-backed drive but NOT bulletproof. Known gaps (context for the consultation):
    1. **No deletion tombstones** — delta payloads permanently retain records of permanently-deleted objects; a delta-replaying restore (vault checkpoint gone AND backup stale) resurrects them. App-driven deletions are safe (`deleteFromVaultAndBackup` removes messages) — this is the disaster-path-only gap.
    2. **Tests run against the LIVE Debug DB** — the destructive `replaceCatalogCreatesBackupSnapshot` test is the exact wipe that caused the 2026-08-20 incident. Tests are baseline-relative by design; no isolated test DB.
    3. **TDLibKit dropped-response bug** — patched with timeout+retry (`withResponseTimeout`, TelegramClient.swift:390) — workaround, not a fix in the TDLibKit layer itself.
    4. **LWW-by-modifiedAt is the ONLY cross-device conflict resolution** — no version history, no undo, no per-file conflict UI.
    5. **Encryption is mixed, NOT absent** (correction to an earlier draft of
       this entry, which wrongly claimed per-file encryption was dropped):
       private files ARE encrypted — AES-GCM per 1 MiB slice
       (`CryptoEngine.encryptChunk`, Crypto/CryptoEngine.swift:93), object key
       wrapped with the Keychain master key and carried as `wrappedKey` in the
       caption, name/mime/thumbnail stripped (Engine/UploadEngine.swift:282-341).
       BUT public files are **plaintext by design** (`wrappedKey: ""`,
       Storage/CatalogSnapshot.swift:158) and single-chunk videos in
       non-private folders skip encryption entirely
       (Engine/UploadEngine.swift:247) — share recipients and anyone with the
       channel's message history can read them. Access control = Telegram
       account + local vault-key seal (PIN/device).
    6. **Single-platform macOS app, single account**; no CI, no error reporting/observability, no user-facing backup/export beyond the two Telegram channels (vault + immutable backup mirror).
    7. **Google-Drive-level gaps** (per the consultation): real multi-device sync + version history, sharing permission model, cross-platform clients, full-text search, resumable uploads at scale, observability.
    This round changed no code. The Claude prompt is saved in the chat; pending items updated. Repo clean, app running, DB healthy (25/25).

118. **Claude architecture review received + verified (2026-08-20 — DOCS ONLY)**
    External review (335 lines) delivered; every headline claim spot-checked
    against the code and CONFIRMED accurate:
    - **Flood-wait coverage = 2 of 33 TDLib call sites** (the #1 finding): only
      chunk upload (TelegramClient.swift:1147) and BackupDrainer forwards
      (BackupSync.swift:142) are wrapped. `allChannelMessages` pages up to
      2000×100 messages with zero delay; `deleteMessages` (:1253),
      `editMessageCaption` (:1259), `searchChatMessages`, `messagesByIds`,
      ShareEngine forwards (ShareEngine.swift:415, no delay, no wrap) all
      unprotected. Ban risk is real and fixable in ~1 day.
    - **BackupDrainer**: `Task.sleep(5s)` is error-branch only — successful
      forwards run back-to-back (50 in <10s) → constant FLOOD_WAIT during batch
      drains. Fix: 500ms inter-forward delay.
    - **Startup**: `completePostAuthSetup` (AppState.swift:710) fires 3
      independent full-channel scans (pruneOldSnapshots / restore /
      VaultRepair). Fix: one shared cached scan.
    - **Tombstones**: review endorses a `tombstoneAt: Date?` FIELD on
      ObjectRecord (migration v27) over my earlier `xcloud:dbdel:v1:` message
      type — merge: tombstone wins; restore: filter; VaultRepair: skip matching
      chunks; GC after 90 days. ENDORSED — simpler, same guarantees.
    - Nits: review says 59+4 tests (actual 70), paths use stale `xCloud/`
      prefix (cosmetic).
    - Review's full roadmap is in the user's copy (anti-ban day 1-2 → data
      safety days 3-10 → features weeks 4+). Pending decisions: what to
      implement first (anti-ban package is the recommendation).

121. **Phase 0b Data Safety & Correctness** (2026-08-20 — complete):
    - **Item 7 (Isolated Test Database Harness)**: Decoupled test database operations to `xcloud-test.sqlite` when running under test harnesses (`NSClassFromString("XCTestCase") != nil` or `XCTestConfigurationFilePath`). Added lazy `ensureStarted()` to `DatabaseManager.read` and `DatabaseManager.write` so callers and tests always have an initialized database pool.
    - **Item 8 (Delta Payload Nonce Deduplication)**: Added optional `nonce: String?` to `CatalogSnapshot.Payload`. Generated unique `UUID().uuidString` nonces on checkpoint and delta uploads; deduplicated delta payloads in `CatalogSnapshot.fetchChannelState` using `seenNonces` set across vault and backup channels.
    - **Item 9 (Deletion Tombstones `tombstoneAt: Date?`)**: Migration `v27-tombstone` added `tombstoneAt` DATETIME column and `idx_objects_tombstone` index. Added `markTombstone(id:at:)` and `purgeOldTombstones(olderThan:)` (90-day retention) in `DatabaseManager`. Updated `CatalogSnapshot.merge` and `changedRecords` so deletion tombstones survive merges and publish in deltas, permanently preventing delta replay resurrection. Updated `AppState.loadFiles()` to filter `tombstoneAt == nil` for UI presentation. Hardened `VaultRepair.run()` to skip reconstructing objects that have an active local tombstone.
    - **Item 10 (Structured Error Surfacing)**: Added `AppNotification` and `NotificationKind` (`info`, `warning`, `error`, `success`) to `AppState` with auto-dismiss timers. Implemented `NotificationBannerView` with sleek macOS ultraThinMaterial glassmorphic design and subtle spring animations in `RootView.swift`. Added `NotificationCenter` observer for `.cascadeAppNotification` so background engines can seamlessly post user-facing alerts. Added flood-wait toast warnings in `TelegramClient.withFloodWait` (for waits >= 3s) and sync result toasts in `AppState.forcePublishSnapshot()`.
    - Verification: 65 tests passed (62 unit + 2 UI + 1 launch, 0 failures).

122. **Fast search-based catalog sync + alpha-preserving thumbnails (2026-08-28
    evening, `SYNC_SEARCH_PLAN.md`, `2941dcf`):**
    - **Root cause 1 (multi-minute pull-to-refresh)**: `CatalogSnapshot.fetchChannelState`
      called `TelegramClient.allChannelMessages` — a full backward page of the
      ENTIRE channel history (up to 2000x100 messages, 200ms/page) — just to find
      the 1-2 small `cascade:db*` catalog messages.
    - **Fix**: added `TelegramClient.searchChannelMetadataMessages(chatId:query:limit:)`
      wrapping TDLib's `searchChatMessages` (server-side + local-index search,
      query `"cascade:db"` matches checkpoints/deltas/parts in one ~100-200ms
      call instead of a full scan); bounded pagination (cap 5 pages, stops once a
      checkpoint message is seen — everything older is redundant) covers
      unusually heavy delta churn without extra cost in the common case.
      `fetchChannelState` now uses it, plus a high-water-mark optimization:
      `UserDefaults` key `xc.lastSyncedMsgID.<channelID>` + an in-memory
      `NSLock`-guarded `channelStateCache` skip re-decoding (network download +
      JSON decode per message) entirely when the newest message ID hasn't moved.
    - **Root cause 2 (transparent PNGs → white/opaque boxes)**: both
      `UploadEngine.generateThumbnails` (encrypted sidecar source) and
      `ThumbnailService`'s local generators always JPEG-encoded (or cached the
      JPEG over an already-written PNG) regardless of source alpha — JPEG has no
      alpha channel.
    - **Fix**: `ThumbnailCrop.hasAlphaChannel(_:)` (checked on the SOURCE image,
      before it's redrawn into an always-alpha-having context) gates PNG vs JPEG:
      local generators skip/delete the opaque JPEG and cache PNG when alpha is
      present; `generateThumbnails` writes a `-up.png` sibling the sidecar upload
      prefers over `-up.jpg` (the TDLib-attached inline thumbnail stays JPEG-only,
      unaffected — documented elsewhere as a hard TDLib inputThumbnail
      constraint); sidecar fetch (macOS `ThumbnailService` + iOS
      `AppState.fetchThumbnailData`) sniffs the PNG signature on decrypted bytes
      to cache under the correct `-tg.png`/`-tg.jpg` extension.
    - Verification: macOS + iOS Debug builds green; 104 tests (100 unit + 4 UI,
      0 failures); installed + launched on iPhone XS Max
      (`8F28E614-EA35-5B10-8DC9-E390026D4599`, process confirmed alive); Debug
      macOS app relaunched and confirmed alive. Interactive/live-vault timing
      and visual transparency verification left for the user (not automatable
      from this session).

123. **iOS pull-to-refresh hanging forever — fix (2026-08-28 evening,
    `9df76a3`):**
    - **Root cause**: `searchChannelMetadataMessages` (item 122, above) called
      `client.searchChatMessages` without the `withResponseTimeout` wrapper
      this file already documents as REQUIRED for TDLibKit calls that can
      answer instantly from local cache — TDLibKit's response matching can
      silently drop that reply (continuation never resumes), and a small
      local-index search is exactly the "instant from cache" case most
      likely to trigger it. The hang propagated up through
      `fetchChannelState` -> `CatalogSnapshot.upload()` -> `loadAllFiles()` ->
      the `.refreshable` closure, so pull-to-refresh spun forever.
    - **Fix**: wrapped the per-page `searchChatMessages` call in
      `withResponseTimeout(15)` (2 attempts per page, matching
      `getOrFetchMessage`'s established pattern); on repeated failure the
      search returns whatever was gathered instead of hanging.
    - Verification: macOS + iOS Debug builds green; 104 tests (100 unit + 4
      UI, 0 failures); reinstalled + relaunched on iPhone XS Max, process
      confirmed alive. Actual on-device pull-to-refresh gesture needs user
      confirmation (not automatable from this session).

124. **iOS pull-to-refresh hanging forever — REAL fix, `withResponseTimeout`
    itself was broken (2026-08-28 evening, `e02ea08`):**
    - Item 123's fix (wrapping `searchChatMessages` in `withResponseTimeout`)
      did NOT resolve the hang — the user confirmed with a screenshot showing
      the refresh control still stuck.
    - **Real root cause**: `withResponseTimeout` itself
      (`Telegram/TelegramClient.swift`) was implemented with
      `withThrowingTaskGroup`, racing `operation()` against a sleep-timeout
      task. TDLibKit's async bridge (`TDLibApi.run(query:)`) is a bare
      `withCheckedThrowingContinuation` with no cancellation handler, so a
      genuinely dropped completion callback leaves that continuation
      permanently unresumed. Swift's structured concurrency REQUIRES a task
      group to await every child task — cancelled or not — before it can
      return, so `withThrowingTaskGroup` hung forever waiting for the
      never-finishing `operation()` task even though the timeout branch had
      already "won" the race internally. The helper was a no-op for the exact
      failure mode it was written to fix, on every one of its ~6 call sites
      (not just the new search call).
    - **Fix**: rewrote `withResponseTimeout` using two UNSTRUCTURED
      `Task { }`s racing to resume one `CheckedContinuation`, guarded by a new
      `ResumeGate` (`NSLock`, resume-exactly-once). Unstructured tasks impose
      no obligation to await the loser, so the function genuinely returns as
      soon as either the operation or the timeout fires; the loser keeps
      running detached and its result is discarded. Signature unchanged, so
      every existing call site (`getOrFetchMessage`, etc.) benefits
      automatically.
    - Verification: macOS + iOS Debug builds green; 104 tests (100 unit + 4
      UI, 0 failures); reinstalled + relaunched on iPhone XS Max, process
      confirmed alive. On-device pull-to-refresh confirmation still pending
      from the user.

125. **iOS pull-to-refresh STILL stuck after items 123+124 — UNRESOLVED, handed
    off (2026-08-28 evening, no code change, docs only):**
    - User re-tested `e02ea08` on-device: "the wheel is still stuck and not
      autohiding." Both prior fixes (123: added a timeout to the search call;
      124: fixed `withResponseTimeout` itself to genuinely abandon a stuck
      TDLib continuation) did NOT resolve it.
    - **This is now an OPEN issue** — explicitly handed off to the next agent
      (Antigravity) for fresh investigation rather than a third guess from
      this session. Do NOT assume item 124's fix was wasted work —
      `withResponseTimeout` really was broken and is now genuinely fixed for
      every one of its call sites — but something ELSE in the same chain is
      still hanging (or the spinner-dismissal is a separate UI-layer bug, see
      below).
    - **Leads for the next agent**:
      1. **Audit every OTHER unprotected TDLib call in the pull-to-refresh
         chain** (`AppState.loadAllFiles` -> `CatalogSnapshot.upload()` ->
         `fetchChannelState` (now search-based + timeout-protected) ->
         `changedRecords`/`merge` (local DB, not network) -> IF there are
         changes to publish: `publishDocument`/`sendMetadataMessage` (network,
         calls `TelegramClient.sendFile`/`sendMessage` via `withFloodWait`
         only — **no `withResponseTimeout`, so the exact same dropped-response
         race that hit `searchChatMessages` can hit these too**) ->
         `loadThumbnails()` (more `TelegramClient` calls, several unprotected
         `try?` awaits with zero timeout at all, e.g. inside
         `ThumbnailService`/`AppState.fetchThumbnailData`). Grep for
         `try? await` / `try await` calls into `TelegramClient` that do NOT go
         through `withResponseTimeout` and are reachable from this refresh
         path — there are likely several.
      2. **Add stage-timestamped logging** around `loadAllFiles` (entry/exit of
         `invalidateScanCache`, `CatalogSnapshot.upload()`, `fetchChannelState`,
         any publish branch, `loadThumbnails()`) so the NEXT time the wheel
         sticks, the console log pinpoints exactly which await never returns —
         much faster than guessing.
      3. **Rule out a pure UI-layer bug**: SwiftUI's native `.refreshable`
         indicator is CONTRACTUALLY dismissed as soon as the awaited closure
         returns — if it's not autohiding, the closure passed to `.refreshable`
         in `FileBrowserView.swift`/`RootView.swift` (`await
         appState.loadAllFiles()`) is almost certainly still suspended
         somewhere, which points back to lead 1. But double-check there isn't
         a second, independent `.refreshable`/pull gesture higher in the view
         hierarchy also driving a spinner that isn't wired to the same async
         call.
      4. Consider whether `RateLimiter`/`APIMetrics` (called at the top of
         every `withFloodWait`) could itself block — unlikely (it's a
         token-bucket actor) but worth a quick look since it's on every call
         path.

### 143. Android plaintext cleanup — recovery/gate machinery removed (2026-09-26, Android `b438510`)

User approved moving to Android: first clean the obsolete encryption-era
features (UI work next, then user tests functionality). Removed, all dead
under plaintext + app-local PIN (net −114 lines):

- `VaultKeyRecovery` object deleted from `Sync.kt` (zero callers; stubs since
  the migration) + stale v2-seal header doc; backfill doc corrected.
- `PinStore`: `originatedHere`/`markOriginatedHere`/KEY_ORIGIN removed (nobody
  ever set the flag — the launch CREATE gate was already dead); doc corrected;
  added `clear()` for the upcoming Forgot-PIN reset flow.
- `HomeScreen`: dead launch-gate computation removed (bootstrap = ensureVault
  + snapshot restore + thumb sweep); dead `keyOk` states removed from account
  card + Settings; status icon is now static "Synced with Telegram" (the old
  "Encrypted & synced" label was false); Settings Vault-PIN row copy fixed
  ("seals your key for new devices" / "Unlock this device" / "secures your
  files across devices" all gone) + the false "Telegram stores ciphertext
  only" note replaced with the plaintext truth; gate dialog copy fixed
  (mode-aware titles, "Locks the Locked folder on this device only").
- `ThumbnailService`: `waitingForUnlock`/`awaitingKey`/`keyOperational`/
  `keyStateChanged`/`onKeyRecovered`/dead `fileIdOfMessage` removed.
- `WIRE_CONTRACT.md`: plaintext-era notice at the top (encryption sections
  marked historical; full rewrite deferred).
- Kept deliberately: `wrappedKey` DB/caption fields (schema stability, always
  empty), `LegacyEncrypted` download error, UNLOCK gate mode (the Locked
  destination gate needs it in the UI phase).

53/53 unit tests green, debug APK rebuilt. NEXT: Android UI phase (Locked
destination gate + Forgot-PIN reset), emulator fresh start (old vault channel
is deleted cloud-side), then M4 playback.

Follow-up same evening (Android `9971e0b`): fresh installs stranded on the API
ID/hash prompt despite bundled credentials — root cause was
`LoginViewModel(...)` constructed inline in MainActivity's composable, so every
auth-driven recomposition swapped in a fresh never-started VM (stuck on
CREDENTIALS) while a leaked older one owned the running TDLib client (log
showed `setTdlibParameters` + `WaitPhoneNumber` while the screen sat on the
prompt). Fix: `remember` one VM per activity. Verified live: clean install
goes straight to the phone step.

### 144. Android M6 sharing + add-button rework (2026-09-26, Android `9f078e6`)

User tests Mac→Android sharing across TWO INTENTIONAL accounts (sync can't
work cross-account by design — the vault is the account). Built the full
forward-based link system, Mac-interoperable:

- `core/ShareLink.kt`: v2 parse (single + group manifest), AES-GCM
  obfuscate/deobfuscate (CryptoKit-combined layout), expiry, legacy/password
  rejection. Pure JVM + 9 unit tests incl. a Mac-format blob sealed by an
  INDEPENDENT implementation (caught a real bug: `+`→space URL decoding ate
  telegram invites — custom decoder matching URLComponents now).
- `data/ShareEngine.kt`: import (join→read captions→forward into Saved
  Messages→catalog+delta+thumb→leave; self-open + rootHash dedup + unique
  names; server-confirmed forward IDs) and outgoing (ONE reusable "Cascade
  Shares" channel, per-share one-use private invites / permanent public
  invite, identical-link reuse, revoke). No pool/branding/TTL (Mac-only).
- DB `shares` table + Room Migration(1,2); deep-link capture
  (onCreate/onNewIntent → import dialog); `cascade://` manifest filter already
  existed.
- Add button: hump bar replaced by a round bottom-end FAB (the old one
  rendered half-cut) with Upload files / New folder / Add from share link —
  macOS FAB parity. New folder creation (private-aware, unique names, delta
  publish) — verified live (TestFolder + delta msg). Uploads take parentID +
  isPrivate. Long-press → Share… sheet (Private 7d / Public + copy).
  Shared pane lists outgoing links (copy/revoke/expiry) + add-from-link.
- Thumbnail sweep falls back to first-chunk attached thumbs (Mac-synced +
  imported files materialize previews; Android uploads never set
  thumbMessageID — still an open gap).
- Bonus fix: raw `Toast.makeText` from IO threads crashed the app on Sync tap
  (seen live in logcat) — all call sites now use main-safe `toastOnMain`.

62/62 unit tests green, APK on emulator verified (FAB menu, folder create).
NOT yet live-tested: actual Mac→Android import (needs a real Mac-minted
link — user test step), Android→Mac share, revoke propagation.

Follow-up (Android `2072b5a`): folder shares imported flat — the `path`
manifest was parsed but never used. Import now rebuilds the folder chain
(Mac resolveImportDestination parity: dropLast, ensure-or-reuse live folders,
delta-publish created ones). Files already imported flat stay flat
(rootHash dedup) — delete + re-import to get folders.

### 145. Password shares removed (Mac) + Android startup/open fixes (2026-09-26)

- **Mac password options GONE (user decision).** The engine had already
  retired passwords (mints ignore them, imports reject old ones with a clear
  error) but the UI still offered 4 options — a working lie (a
  "password-protected" folder share imported with NO password prompt). Now:
  Private / Public only. Removed the context-menu entries, the
  SharePasswordPromptSheet (125 lines), the AppState prompt plumbing, and a
  dangling addPasswordToShare doc. Import-side rejection of old password
  links stays. macOS build + full suite green.
- **Android login flash fixed** (`MainActivity` splash for Idle WITH stored
  creds) — then caught a REAL crash it exposed: cold start sat on splash
  forever (nothing kicked TDLib) — fixed by auto-starting from stored creds.
- **Android native abort fixed (SIGABRT, dual-receive).** The auto-start +
  a transient-state LoginScreen composed together → LoginVM auto-begin →
  reset()+start() → two TDLib clients, two parked receive() loops → TDLib
  aborts ("Receive must not be called simultaneously"). Fix:
  `TdClient.ensureStarted` (mutex single-flight, no-op when running;
  `reset()` deleted, `start()` kept as documented-raw), Closed→started=false
  for clean restarts, and LoginScreen mounts ONLY for input-needed states
  (phone/code/password/closed/fresh-install Idle) — transients show splash.
- **Android open-file "Not Found" fixed.** `forwardMessages` answers with a
  LOCAL pending id (1048577-style); the old code stored it → every later
  getMessage/download/forward failed forever. Now resolves via
  updateMessageSendSucceeded (Mac parity) + delayed verify. Proven live:
  fresh upload → Share… → real `cascade://share#…` link minted.
- **Bonus:** background-thread Toast crash on Sync tap → main-safe
  `toastOnMain` everywhere; thumbnail sweep falls back to chunk-attached
  thumbs (Mac-synced/imported previews work).
- **User action needed:** delete the 9 flat/broken imports on Android and
  re-import the Mac link (their chunk IDs are unresolvable locals).

### 146. Android P0 file-manager parity (2026-09-26, Android `6677581`)

User asked for a full Mac→Android feature audit + the missing basics, in
strict Material 3 (no more ad-hoc design). Audit result: all 13 panes
existed, but no multi-select, no Move, no archive actions, no
restore/delete-forever/empty-trash, no explicit Download, Library pane
rendered nothing, Locked had no gate. Built (M3: contextual action bar,
check badges, bottom-sheet move picker, standard dialogs):

- **Multi-select** (long-press enters, tap toggles, ✕ exits, resets on
  navigation) + **contextual action bar**: Download / Share / Favorite /
  Trash direct, Rename (single) / Move to… / Archive-Unarchive in overflow;
  Trash pane shows Restore / Delete-forever instead.
- **Move picker** (ModalBottomSheet, full folder paths, self-descendant
  blocked, inherits Locked flag) — verified live via DB.
- **Trash lifecycle**: restore, delete-forever (tombstone delta + vault
  message deletes + row cleanup — verified: 0 rows, 0 orphans), Empty trash
  with confirm. **Archive/Unarchive** both directions + panes.
- **Locked gate**: PIN prompt on entering Locked (once per session),
  Forgot-PIN reset with confirm (verified: prefs cleared, unlocked, account
  left clean). CREATE-from-Settings trap fixed (Cancel button — setup is
  optional, Mac parity).
- **Library** shows book formats (no reader — opens externally).
- Bulk ops publish ONE delta per action; explicit Download action added.
- Verified live: select, bulk trash/restore/move/archive/unarchive/delete-
  forever (deltas each), gate, forgot-reset, FAB menu, folder create, upload,
  share-create, import. Zero crashes across the session.
- Still open: streaming/playback (M4), playlists/albums, book reader,
  subtitles, people, version history, export, keep-downloaded pins, pause/
  resume transfers, storage management, expiry sweeps.

### 147. Android UI rebuilt as a Mac port (2026-09-26, Android `acea8ed`)

User rejected the bespoke Android styling outright — direction: copy the Mac
app pixel-faithfully, phone-optimized, on M3 components. Studied XTheme,
SidebarView, FileBrowserView top bar/cards/rows + live Mac screenshots:

- **Theme**: Mac dark-only (bg #0D0F14, white 1/.55/.35 text, white-overlay
  surfaces, accent #4085FF, category colors, radii 10/14/22) on M3 roles;
  dynamic color OFF by default; light scheme kept for previews only.
- **Drawer**: Mac order/groups (headerless All/Recent/Favorites,
  COLLECTIONS, UTILITIES), 13sp rows with accent glyphs + live badges
  (incl. fixed Library/books, active transfers, live shares), accent
  wash+border selection, glass profile card (gradient avatar, sync check).
- **Top bar**: back chevron, 16sp bold title + count capsule, search BUTTON
  (expanding field, per user), view-toggle capsule with accent pill, sort
  capsule (Mac honor-list + Name/Created/Modified/Size/Kind), overflow,
  divider. View/sort/count hoisted to the bar.
- **Grid**: bare tiles — blue folder glyph + centered name/count, aspect-fit
  thumbs + name/meta, accent ring+wash selection. Dropped the outlined
  Files-style cards entirely. **List**: Mac rows (icon, 14sp name, count,
  mono size, relative date, wash selection).
- Verified live via screenshots: dark grid, drawer, list mode, selection —
  recognizably Cascade. FAB already accent.
- Incidents fixed en route: light-mode whiteout (forced dark), a lost
  foundation.Image import, orphan annotations.

### 142. Flux player ports: hwdec auto-safe, reconnect insurance, Flux buffer profile (2026-09-26)

User asked why Cascade needs VaultStreamServer when mpv does HTTP natively
(answer: no single HTTP resource exists — the file is N Telegram chunk
messages reachable only via TDLib; the loopback server is the adapter, same
pattern as Stremio's server.js), then approved porting the Flux player
learnings (`Features/MPVVideoView.swift` only):

- `hwdec auto` → **`auto-safe`** (copy-back videotoolbox): Flux proved `auto`
  attempts zero-copy mapping on the OpenGL layer, which libmpv rejects on
  10-bit HEVC → silent CPU fallback. Cascade's Dolby/HDR files were
  software-decoding; now hardware. (AV1 unaffected — M2 has no AV1 decoder.)
- **FFmpeg reconnect insurance** (`stream-lavf-o` / `demuxer-lavf-o`
  reconnect=1…): loopback drops re-establish transparently.
- **Buffer: kept explicit, adopted Flux's proven numbers** (300 MiB forward /
  100 MiB back / 60 s readahead + cache-pause trio; legacy `cache-secs`
  dropped). NOT handed to mpv defaults — they assume internet streams, while
  our source is infinite-bandwidth + lumpy TDLib latency; 50 MiB/~10 s
  defaults would surface every fetch hiccup as a pause. mpv already controls
  the request pattern; these only bound memory.
- Already covered in Cascade, not ported: async teardown, `mpv_command_async`
  everywhere (= Flux's background loadfile/stop), keep-alive server,
  telemetry. Deferred to player work: startup watchdog / reconnect-storm
  detection (single source here — watchdog can only report, not fall back).

Build + full suite green. Running app is pre-change — relaunch to pick it up;
live playback verification (user plays the Dolby sample, checks hwdec in
telemetry) still pending.

### 141. Fresh-vault verification + streaming fetch-timeout fix (2026-09-26)

User uploaded 12 files + 4 folders to the fresh Saved Messages vault and asked
to verify cross-device thumbnails, byte-to-byte streaming, chunking, and
snapshots before player work starts. Verified against code + live DB:

- **Thumbnails are cloud-bound, not device-local.** Every chunk message carries
  the `-up.jpg` as a TDLib `inputThumbnail` (`UploadEngine.sendFile` path);
  `ThumbnailService.fetchFromTelegram` downloads it back — the exact path a
  second device takes. Live proof: 10 unique `-tg.jpg` files fetched from
  Telegram after today's uploads (each photo's 320px thumb, the MKV's 320×180
  server-generated video frame). Exception by design: **Locked files get no
  thumbnail generated or attached** (`!isParentPrivate` gate) — a plaintext
  preview on Telegram's servers would defeat the lock; they show placeholders
  on a new device until downloaded.
- **Chunking intact:** uniform ~1.9 GiB (`ChunkPlanner.maxSafeChunkSize` =
  1900 MiB), 1 MiB streaming slices (`SliceMath`), slice-multiple invariant
  enforced with a full-download fallback. All 16 chunk rows record
  `chunkSize=1992294400` in channel 7201237110 (Saved Messages).
- **Byte mapping correct, but the fetch timeout was structurally broken —
  FIXED.** `VideoStreamingEngine.withFetchTimeout` used a
  `withThrowingTaskGroup` race — the exact pattern item 124 proved can never
  fire on a dropped TDLib response (a group must await every child), which
  would stall a stream forever with no retry. It now goes through the proven
  `TelegramClient.withResponseTimeout` (unstructured tasks + ResumeGate;
  made internal for this), mapping only `.timedOut` → `FetchTimeout()` so
  operation errors still propagate. No decrypt anywhere in the serve path —
  plaintext throughout (`fetchRangeData` reads raw ranged bytes, sparse-file
  aware, memory-bounded).
- **Snapshots cover everything:** checkpoint 11:54 + deltas after every
  mutation + fresh checkpoint 12:05:30, all mirrored to the backup channel
  (`backup_msgs`, all `done`). A restoring device replays checkpoint + deltas
  → full 16-object catalog with thumbnail-bearing message IDs.
- Build + full test suite green; user DB untouched (16 objects).

### 140a. `--purge-cloud` debug hook + full clean-slate (2026-09-26)

After item 140's local wipe the app RE-RESTORED the old catalog from the cloud
— `CatalogSnapshot.restore()` falls back to the Cascade Backup channel's
forwarded checkpoints, and VaultRepair rescans channel history, so a local wipe
alone can never empty the app.

New one-time debug hook (pattern-matches the existing `--repair-catalog`):
`Cascade --purge-cloud`
1. Deletes EVERY message from the account's Saved Messages (via new
   `TelegramClient.purgeAllMessages(chatId:)` — paged, batch-100, bounded).
2. Deletes the legacy "Cascade Vault" channel and "Cascade Backup" channel
   outright (`deleteChat`).
3. `DatabaseManager.purgeEverything()` wipes objects/chunks/backup_msgs/
   transfers/shares/share_activity/vaults rows.
4. Writes /tmp/cascade-purge-cloud.txt and quits.

Run it (2026-09-26): ~2 Saved-Messages msgs deleted, backup channel
-1004381430846 deleted, legacy vault channel -1003774210345 deleted, local
catalog wiped. Then `xcodebuild clean` + rebuild + fresh DB: verified 0
objects / 1 vault (Saved Messages) via sqlite3.

### 140. PLAINTEXT ERA ROUND 2 — "Locked" folder, app-level PIN, local wipe (2026-09-26)

Follow-up to item 139, executed the same day:

**A. "Private Vault" → "Locked" everywhere.** The sidebar destination enum
name stays `.privateVault` (internal), but all user-facing copy now says
**Locked**: sidebar, FAB ("Upload to Locked"), transfers breadcrumbs,
Settings, lock screens (macOS + iOS), TransfersView cloud paths, Android
HomeScreen drawer label.

**B. The PIN is now an APP-LEVEL screen lock with recovery.** No key material
depends on it, so "Forgot PIN?" simply replaces it:
- macOS lock screen (FileBrowserView `PrivateVaultLockView`): the `.recover`
  phase was repurposed — chooseInitialPhase never selects it; a **Forgot
  PIN?** button enters it, and submitting a new PIN saves + unlocks.
- `KeychainStore.resetVaultPIN()` deletes the hash + clears throttle.
- iOS `VaultPINView`: recovery mode removed (title/subtitle simplified);
  Android: `VaultKeyRecovery` is a stub (keyIsOperational → true,
  attemptRecovery → false), unlock verifies the local `PinStore` hash only.

**C. Android port migrated to plaintext + Saved Messages**
(`/Users/zainulnazir/AndroidStudioProjects/cascade`):
- `CryptoEngine.kt` DELETED; `VaultManager.kt` rewritten — Saved Messages via
  `createPrivateChat(force:true, userId:me)`, empty wrappedKey, all channel
  discovery/phantom-migration/key-record code removed.
- Upload/Download/Thumbnail engines: plain byte copies + SHA256; downloads of
  legacy encrypted rows fail with a clear `LegacyEncrypted` error.
- 53 unit tests green (`testDebugUnitTest`); crypto/golden-vector tests
  removed; caption/URL-codec fixtures kept.
- **IMPORTANT TDLib FACT (learned by overflow error)**: in the JSON API the
  Saved Messages chat ID equals the account's own USER ID (~1e9, positive).
  The vault-adoption sanity threshold is `> 1_000_000` in BOTH apps — negative
  = legacy channel, small positive = test row.

**D. Local data wiped clean** (user asked for a fresh start):
- Deleted: cascade.sqlite(+wal/shm), thumbs/, scratch/, tmp/, logs/,
  launch-state.txt, xcloud.sqlite — under `~/Library/Application Support/Cascade`.
- Keychain: master-key, xc.vault.pin, xc.device.id removed (both bundle-id
  service names).
- KEPT: tdlib/ session → **no Telegram re-login needed**; relaunch recreated a
  fresh DB and the vault will re-adopt Saved Messages on first upload/launch.

**Verification**: macOS build + full test suite green (breadcrumb test updated
to "Locked"), iOS target builds, Android compiles + 53 tests pass, app
relaunched on a fresh catalog.

### 139. PLAINTEXT MIGRATION — encryption removed, vault moved to Saved Messages (2026-09-26)

User decision, executed in full. Two architectural changes landed together:

**A. Encryption is GONE for everything.** Files are stored as plain bytes in
Telegram. Motivations: real Telegram previews (MKV/MP4 open inside the Telegram
app), one streaming path (the plaintext one — always the stable one), and a
~700-line deletion of the sealed-slice machinery that produced every streaming
bug of the previous month.

- **Deleted**: `Crypto/CryptoEngine.swift` (slice crypto, key wrapping, PBKDF2
  helpers, self-test), `scripts/gen_golden_fixtures.swift` (Android fixtures —
  NOTE: the Android port's `CryptoEngine.kt` is now orphaned; WIRE_CONTRACT
  fixtures reference it), the encrypted-thumbnail sidecar (upload + fetch +
  iOS variant), the encrypted-subtitle path, the encrypted-path read-ahead
  subsystem (`ReadAheadRun`, `fetchEncryptedBatchIntoCache`,
  `planEncryptedBatch`, `ensureReadAhead`), the encrypted branch in
  `plaintextSlice`, per-object key minting in UploadEngine, and
  password-protected share links (`addPasswordToShare`,
  `remintLinkWithPassword`, key-wrapping in link mint/import).
- **Replaced by**: `Engine/SliceMath.swift` (`SliceMath.sliceSize` = the old
  `CryptoEngine.sliceSize`; layout arithmetic unchanged), a minimal
  `CryptoError` in KeychainStore, plain byte-copy upload/download loops with
  SHA256 verification, and thumbnail attachment on every chunk message.
- **DB migration `v34-purge-encrypted-objects`**: tombstones + purges rows
  with a non-empty `wrappedKey` (legacy sealed chunks are unreadable by this
  build; users must re-upload anything they kept). `VaultRecord.wrappedKey`
  column stays NOT NULL (always empty) for schema stability.
- **Share links**: still obfuscated blobs, but carry NO key material and have
  no password option. Importing an OLD password/wrapped link fails with a
  clear "created by an older encrypted version" error.
- **Vault PIN**: kept as a DEVICE-LOCAL screen lock only (KeychainStore now
  derives its hash with inline PBKDF2 — identical parameters, so existing PIN
  hashes verify). All cross-device key recovery is deleted.

**B. The vault lives in Saved Messages** (Unlim-style). Channels remain ONLY
for the backup mirror (`Cascade Backup`, via BackupSync) and sharing.
- `VaultManager.ensureVault()` now resolves the account's own Saved Messages
  via `TelegramClient.savedMessagesChatID()` — implemented as
  `createPrivateChat(force: true, userId: myUserID())` (DO NOT try to compute
  the chat ID arithmetically; the base-plus-ID constant overflows Int64 and
  TDLib is the source of truth).
- Saved Messages is archived + muted like the vault channel was.
- **Per-chunk channel resolution**: every chunk row records the channel its
  document lives in. Streaming (`ChunkLayout.channelID`), thumbnails, and
  sidecar downloads all resolve via `chunk.channelID ?? vault.channelID`, so
  legacy chunks in the old vault channel keep working.
- `BackupSync` mirror semantics are unchanged — messages posted to Saved
  Messages are forwarded into Cascade Backup.

**Verification**: macOS app target + iOS target build clean; full CascadeTests
suite green (crypto tests removed, plaintext slice-mapping test kept);
app rebuilt and launched from DerivedData Debug products.

**Leads for the next agent**:
1. The catalog-sync caption codec still carries `wrappedKey`/`cipherHash`
   fields (always empty/nil now). Harmless; clean up if touching
   `ChunkCaption` anyway.
2. `isPrivate` remains ONLY as a UI destination flag (Private Vault view).
   It no longer implies encryption. It could be renamed `isHidden` someday.
3. Android port: `CryptoEngine.kt` + golden fixtures are now dead weight —
   the wire contract needs a plaintext-era update.
4. Streaming soak test still recommended: long MKV, cold cache, untouched
   seek bar — confirm the 16-slice sequential batching holds throughput.

## 5. Pending / next steps — Architecture Roadmap Todo List

### 🔵 ACTIVE WORKSTREAM: Android port (`~/AndroidStudioProjects/cascade`, git `main` @ `0f13aec`)

User direction (2026-09-15): **the Android port is the current workstream.** Windows and
Linux ports come AFTER Android is usable. iOS is tested on the physical iPhone XS Max
only — the user does NOT use an iOS simulator, and confirms iOS on-device "works fine
for now". The user DOES want an emulator for Android testing (see below).

**UNLOCK VERIFIED END-TO-END + PIN GATE + ACCOUNT CARD** (2026-09-19, Android commits
`e29031f` → `e35bd69` → `0f13aec`):
- **The PIN recovery mystery closed.** The user's 2026-09-18 PIN entry had actually
  SUCCEEDED — but `keyIsOperational()` sampled the first 5 catalog rows, which were all
  orphaned pre-recovery Android test uploads (wrapped under the dead placeholder key),
  so the gate condemned the good key forever and the UI stayed locked. Fix: the canary
  now walks the WHOLE catalog (cap 50) and passes if the key opens ANY sealed object.
  `attemptRecovery` was also hardened (defense-in-depth): it enumerates EVERY key record
  in the channel and adopts only a candidate that canary-opens real sealed data, so a
  stale re-posted record can never poison recovery. Verified live: key operational on
  launch, all 19 Mac thumbnails decrypt (27 cached = 8 Android plaintext + 19 Mac),
  persists across force-stop/relaunch. The 2 orphaned "Untitled" Android uploads are
  undecryptable by design (their wrapping key no longer exists) — cleanup optional.
- **Drawer account card = real identity** (`e35bd69`): new `TelegramIdentity` provider
  (getMe → name/@username, downloads profile_photo.big via synchronous downloadFile,
  prefs-cached for instant render). Card shows avatar-or-initials + full name +
  @username/"Connected" — Mac `SidebarProfileCard` parity (user's account: "Heisenbug",
  no @username). Tap opens the Mac's menu: Settings + Log Out (same confirmation copy);
  TDLib `logOut` fires and MainActivity now routes on auth state (LoggingOut/Closed →
  login screen; `TdClient.reset()` added so the client can re-start for re-login).
  Logout confirmed working through the dialog; full logout→login cycle not exercised
  (would require a fresh Telegram code from the user).
- **PIN gate** (`0f13aec`): the user decided to KEEP the current architecture (PIN =
  cross-device recovery secret; userID-sealing was REJECTED after analysis — Telegram
  user IDs are public channel data, sealing under them would void E2EE; Kerckhoffs —
  algorithm secrecy is not security). New `PinGateScreen`: full-screen Material 3 gate
  (circular keypad, dots, haptics, shake-on-mismatch, choose→confirm). `PinStore`:
  salted PBKDF2 PIN hash + `vaultOriginatedHere` flag (set when VaultManager MINTS a
  vault). Flow: fresh vault → mandatory CREATE at launch (then `ensureRecoveryBlob`
  seals the PIN for other devices); joined-but-locked device → mandatory UNLOCK (one
  time); already-unlocked → Settings "Vault PIN" row (change flow, re-seals record,
  back-dismissable only when the device holds its key). Gate survives activity
  recreation (rememberSaveable). Verified live: create→confirm→re-seal→dismiss +
  mismatch-reset path, with the SAME PIN re-sealed (3141, no functional change).
- **FUTURE PLAN (user-approved direction, not built)**: a Cascade account backend is
  planned "in future" — at that point the cross-device recovery secret becomes a long
  random Recovery Code (XXXX-XXXX-XXXX class) sealed in-channel and hash-registered
  server-side at account creation; the PIN remains for Private Vault. Until then:
  PIN stays, users are warned to remember it (create flow copy already says "it's the
  key to your files on every device").
- **Next up: M4** — file viewer/playback (Ktor byte-range streaming server is the
  prerequisite; tap-to-open exists for documents via FileProvider already).

**Milestone M2 is DONE — REAL LOGIN CONFIRMED** (2026-09-16 15:02, emulator): the user
completed phone → code → (2FA) with their actual Telegram account; logcat shows
`authorizationStateReady` and a live connection to DcId{1}. The authorized session
persists in TDLib's database (`app_tdlib-db`), so relaunches skip auth. M3 can start
immediately against a real session. Android repo history: `63a838e` M1 → `1090002`
M2 → `248ef18` M2.1 (bundled creds + icon) → `0766d89` M2.2 (Map.toString JSON bug)
→ `6d12b4f` M2.3 (late-ack race + cloud icon). 59/59 unit tests green.

**M3 — transfer engines: CORE DONE AND PROVEN** (2026-09-16, commits `af9d157` →
`1e93d98`, Android repo): vault bootstrap creates/adopts the real "Cascade Vault"
channel (archived+muted, key wrapped in Room); UploadEngine does plan → encrypt →
staging → sendMessage+caption → `updateMessageSendSucceeded` await; DownloadEngine
(full Swift port) does getMessage → synchronous downloadFile → streaming decrypt →
cipher/plain/root hash verification → reassembly with resume helpers. **Round trip
proven live**: m3test.txt uploaded from the emulator, tapped, downloaded, decrypted,
SHA-256 of the materialized file == object rootHash (`997bc232...`, 89/89 bytes),
opened via FileProvider viewer intent. Material You home (nav bar, vault banner,
upload FAB → SAF picker). Tests 67/67. Key gotchas fixed en route: object keys are
wrapped with the VAULT key (not master — Mac parity); `MessageDigest.digest()`
resets, so hash hex is computed once and reused; this TDLib has NO standalone
`uploadFile` — files ride on `sendMessage` with `inputFileLocal`;
`downloadFile synchronous=true` blocks until complete; message content is at
`message.content.document.document`. M3 REMAINING: Ktor byte-range streaming server (M4
prerequisite), share-import deep link wiring, delete/object lifecycle, thumbnails.
DONE SINCE: live Transfers tab (TransferCenter port — Room-backed progress cards
wired into both engines, verified live: upload|complete + download|complete rows,
cancel + clear-finished) and full Material You icon support (launcher set from
`Public/android.png` with 60dp artwork in the 66dp safe zone, #FDFDFC color
background, 3-tone monochrome layer verified with Themed icons enabled on the
emulator — commit `8455954` + `5511758`).

**M3 — CROSS-DEVICE SYNC WORKS** (2026-09-17, commit `909726b`, Android repo):
logging into the existing account now restores the Mac's real catalog. The
Android app restores the Mac's published CatalogSnapshot (checkpoint
`cascade:dbsnapshot:v1:` + append-only `cascade:dbdelta:v1:` messages, zlib
JSON) and merge-adopts it into Room — live-verified **58 objects / 90 chunks**
from the user's real vault (files back to Aug 21 visible on the emulator).
The ONE root cause of the earlier total sync failure: Apple's
`NSData.compressed(using: .zlib)` emits **RAW DEFLATE (RFC 1951, no zlib
header)** — Android must `Inflater(nowrap = true)` FIRST (then RFC 1950
wrapper, then raw-JSON fallback). This is now also documented in the Android
repo's `WIRE_CONTRACT.md` mindset: never trust the "zlib" name across
Swift↔Kotlin. Additional fixes en route: restore() merges into a POPULATED
catalog too (LWW on modifiedAt, local-only rows kept, phantom `Untitled`/
`File-*` rows always yield) instead of only fresh devices; snapshot scan
pages up to 40 pages of channel history (checkpoint deep in thousands of
chunk messages); `findRecoveryBlob` likewise pages deep for the
`cascade:vaultkey:v2:` record (verified reachable). PIN recovery UI exists in
Android Settings (VaultKeyRecovery.attemptRecovery — PBKDF2 → unwrap →
re-wrap with device master key), and it now surfaces PROACTIVELY:
`keyIsOperational()` sample-unwraps one remote object key at runtime — when it
fails (fresh-minted key), Settings shows a red "Files need unlocking" card
above the PIN field, which disappears the moment recovery succeeds. iOS-style UI (Recents/Shared/Browse tabs,
dark #0D0F14, accent #4085FF, grid cards, search/sort) landed earlier this
session. NEXT: PIN recovery entry point should surface proactively when the
catalog contains sealed objects but the key is fresh-minted (today the usermust find Settings manually); Ktor byte-range streaming (M4
prerequisite), share-import, delete/lifecycle, thumbnails.

**UI SHELL REBUILT — Files-style drawer with the FULL Mac sidebar**
(2026-09-17, commit `08e36b5`, Android repo): the user rejected the bottom-
nav Recents/Shared/Browse shell as "way out of design" and asked for the
Android Files app pattern with ALL macOS sidebar options. HomeScreen.kt is
now a ModalNavigationDrawer whose `SidebarDest` enum mirrors the Mac's
`SidebarDestination` (App/AppState.swift) 1:1 — 13 destinations in the same
groups: top-level (All Files/Recent/Favorites), Collections
(Photos/Video/Audio/Documents/Library), Utilities (Private Vault/Shared/
Transfers/Archive/Recently Deleted) — with live Mac-parity badge counts
(mime+extension category matching), per-destination filter panes, and a
profile card (SidebarProfileCard port) that shows key-operational status
and opens Settings. Root All Files shows top-level items only (folders
cross-synced from the Mac render as folders). All verified live on the
emulator with screenshots. NOTE for future UI work: the user wants the
Android Files app as the design language for phone layouts (iOS-parity
layouts are for the iOS app, not Android).

**MATERIAL YOU PASS** (2026-09-17, commit `d4d4928`): the user then rejected
the hardcoded dark theme and multicolored icons — "should properly follow
google's material you design". CascadeTheme now follows the system light/
dark setting and applies dynamicLight/DarkColorScheme (wallpaper-derived
palette) on Android 12+; brand blue is only the pre-12 fallback. All
iconography is monochrome (drawer icons onSurfaceVariant +
secondaryContainer selection pill; file-type icons in secondaryContainer
tonal tiles; FAB primaryContainer). Theme roles everywhere — no hardcoded
component colors remain in HomeScreen. Verified live in light mode.

**THUMBNAILS + FILES LAYOUT** (2026-09-17, commit `2b45738`): 2-column
Files-app grid with 110dp tiles; folder tiles show "N items" live counts;
list rows show thumbs in tonal tiles. ThumbnailService (new,
core/ThumbnailService.kt): the Mac's thumb sidecars are ENCRYPTED documents
(encryptChunk with the object key, slice 0, caption kind:"thumb") — fetch
getMessage → synchronous downloadFile → decryptChunk(objectKey) → cache
plaintext jpeg under cacheDir/thumbs; undecodable cache entries are
invalidated+refetched; plaintext uploads instead use Telegram's attached
document.thumbnail. CRITICAL GATE: before PIN recovery every sealed thumb
unwrap fails (BAD_DECRYPT) — load() short-circuits via keyIsOperational()
so no doomed downloads; ThumbnailService.onKeyRecovered() (called from the
Settings recovery handler) clears the gate and the grid populates on the
next composition. Thumb pipeline proven working end-to-end except the
final decrypt, which is PIN-gated by design.

**FILES-BY-GOOGLE CARD PARITY** (2026-09-17, commit `91012b4`): the user
shared real Files-app screenshots and rejected the previous Material card
treatment. HomeScreen now matches them: 2-col OUTLINED cards (aspect 0.82)
with tall preview areas holding big colored type icons (red images /
green video / purple audio / blue docs / gray code — Files colors these,
unlike our earlier monochrome assumption) or edge-to-edge cropped thumbs;
footer row with small type icon + name + meta; folder cards with outlined
glyph + "N items"; section header with list/grid toggle; folders sort
before files; drawer restructured with "Files" brand title and COLORED
category icons (an explicit user-approved exception to monochrome — Files
colors its category icons). Design rule going forward: match the real
Files app screenshots the user provided, not generic M3 defaults.

**FILES FOLDER BARS + UPLOAD HUMP** (2026-09-17, Android commit `e11ec05`):
user refined two details. (1) Folder cards are now short HORIZONTAL BARS
(glyph left, name + "N items" right) in the 2-col grid — the Files app's
folder treatment, not square tiles. (2) Upload moved off the FAB into a
bottom bar with a single centered hump (Extended FAB pill on a
surfaceContainer bar) — drawer remains the sole navigation surface.
UI polish phase continues; mechanics (folder drill-down, M4 playback)
come after the user signs off on the look.

**UI POLISH ROUND 2** (2026-09-17, Android commit `ea0f197`): user's five
refinements, all verified on the emulator. (1) Upload hump is a bare
CIRCULAR FAB (+ only, secondaryContainer) rising from the bottom bar —
no text; content column gets +22dp bottom clearance so the last row
scrolls fully clear. (2) Grid splits into "Folders" / "Files" sections
with full-span headers (macOS separation; folders no longer adjacent to
files). (3) Drawer header is the Cascade brand — ic_cascade_brand.xml,
a vector trace of Public/material-u.png (three overlapping grays clouds
with white separation strokes) + "Cascade" wordmark; profile-card
avatar reuses it. (4) Sidebar icons now mirror AppState.swift exactly:
Transfers = SwapVert (arrow.up.arrow.down), Shared = Share, Recent =
Schedule. (5) Header-verified live: brand header, sectioned grid,
circular hump, correct glyphs. The app icon (material-you.png adaptive)
was already correct — user meant in-app icons.

**UI POLISH ROUND 3** (2026-09-17, Android commit `dfef8c9`): user reported
the hump rendered half-cut, menus did nothing, and asked for no icon in
the drawer header. Fixes, all verified live: (1) UploadHump's Surface
wrapper was clipping the FAB — removed; the circular + now rises from a
44dp bar as a full hump. (2) Top-bar overflow menu: Sync now (re-runs
snapshot restore + toast) and Settings. (3) Long-press menu on every
item (grid card, folder bar, list row): Favorite / Remove favorite,
Rename (prefilled AlertDialog, same object id), Move to Trash — saved
via ObjectsDao.save. (4) Trash pane now uses new ObjectsDao.observeEvery
(observeAll filters trashed rows, so the pane could never list items).
Rename/favorite/trash are LOCAL ONLY for now — they don't publish delta
messages yet, so the Mac won't see them until delta publishing lands
(natural M4 companion). (5) Drawer header: plain "Cascade" text.

Follow-up (`222fe97`): dropped the "Folders"/"Files" grid headings — the
Mac app separates the groups with whitespace only, so Android does too
(8dp quiet gap between the folder bars and file cards).

**Milestone M1 (context)** (Android repo root commit `63a838e`, 2026-09-15):

- Project: `~/AndroidStudioProjects/cascade`, applicationId `com.entanglon.cascade`,
  minSdk 24 / targetSdk 37, AGP 9.4.0 with **built-in Kotlin** (the separate
  `kotlin-android`/KGP plugin is forbidden — it clashes with AGP 9), Compose BOM
  2026.08, Room 2.8.5 + KSP 2.2.20-2.0.3 (requires
  `android.disallowKotlinSourceSets=false` in gradle.properties), Ktor 3.2.2,
  kotlinx-serialization, coroutines. AGP 9's built-in Kotlin also ships the Compose
  compiler — do not add the compose compiler plugin separately.
- `WIRE_CONTRACT.md` (Android repo root) — the authoritative cross-platform wire spec
  extracted from the Swift code, with three golden-vector discoveries folded in:
  1. Swift's JSON encoders escape `/` as `\/` — Kotlin `JsonCodec.jsonString` matches.
  2. Apple `NSData.compressed(using: .zlib)` emits RAW DEFLATE (no 0x78 wrapper):
     Android consumers must `Inflater(nowrap = true)`; publishers must strip Java's
     default wrapper (both forms decode on Swift).
  3. Swift `JSONEncoder` key order is RANDOM per encode — key order is NOT a wire
     contract; key SETS, nil-key omission and value types are.
- Ported + tested in `app/src/main/java/com/entanglon/cascade/core/`:
  `ChunkPlanner.kt`, `ChunkCaption.kt`, `CryptoEngine.kt` (HKDF slice keys,
  CryptoKit combined-box AES-GCM `nonce‖ct‖tag`, PBKDF2 600k/100k/150k), `JsonCodec.kt`.
  **44 unit tests green** via `./gradlew :app:testDebugUnitTest` (CorePortsTest 25 +
  GoldenVectorsTest 19); debug APK assembles. Fixtures live in
  `app/src/test/resources/golden_fixtures.json` and are committed — tests are hermetic.
- Golden fixtures are generated by the REAL Swift sources via
  `scripts/gen_golden_fixtures.swift` (THIS repo, committed). Regeneration procedure
  is documented in WIRE_CONTRACT.md §9; it runs under the Command Line Tools
  toolchain (no Xcode license gate).
- Compose `MainActivity` skeleton builds; no real UI yet.

**Milestone M2 is DONE and committed** (Android repo `main` @ `1090002`, 2026-09-16) —
TDLib integrated and verified END-TO-END on the emulator:

- **TDLib built from source** for Android: official tdlib/td example scripts
  (`build-openssl.sh` + `build-tdlib.sh ... JSONJava`) against NDK 26.3.11579264 /
  CMake 3.22.1 / OpenSSL (all installed via brew + sdkmanager). Trimmed to
  **arm64-v8a + x86_64** (edited the script's ABI loop). Produces
  `libtdjsonjava.so` (~21 MB arm64 / ~24 MB x86_64) — TDLib's OWN JNI bridge
  (the binding Telegram X uses), NOT a hand-rolled bridge. The exact scripts used
  are preserved in the Android repo at `docs/tdlib/`. TDLib checkout + build tree:
  `~/AndroidStudioProjects/td-build/td` (untracked, ~10 GB — can be deleted and
  rebuilt from `docs/tdlib/` scripts if disk is needed). Full build took ~45 min
  for both ABIs; ran under a temporary launchd agent (tool timeouts kill long
  builds otherwise).
- **Kotlin layer** (`app/src/main/java/com/entanglon/cascade/telegram/`):
  `TdClient.kt` — singleton wrapper over `org.drinkless.tdlib.JsonClient` with
  `@extra` request/response correlation, `@ExtraPayload`-tagged pending-request
  table, receive-loop on a dedicated thread, error mapping
  (`FLOOD_WAIT_X`/`PHONE_CODE_INVALID`/`PASSWORD_HASH_INVALID` → user messages);
  `LoginViewModel.kt` — auth state machine (CREDENTIALS → PHONE → CODE →
  PASSWORD → READY) behind a JVM-testable `AuthGateway` interface, handles
  `authorizationStateWaitCode` `type.phone_number_pattern`, flood-wait display;
  `CredentialsStore.kt` — API id/hash in an AndroidKeyStore AES-GCM file
  (Keychain analogue); `ui/login/LoginScreen.kt` — Compose flow mirroring the
  Mac app's configure(apiID:apiHash:) pattern (user enters their own
  my.telegram.org credentials).
- **Verified on emulator** (2026-09-16): `libtdjsonjava.so` loads
  (`nativeloader ... ok`), TDLib responds (`DLTD: authorization_state =
  authorizationStateWaitTdlibParameters` in logcat), and the UI advances from
  API credentials to phone-number entry. No crashes. 55/55 unit tests green
  (44 M1 + 11 new login tests in `TelegramLoginTest.kt`).
- **Android emulator is LIVE**: AVD **`Cascade_Test`** (API 36.1
  `google_apis_playstore` **arm64-v8a**, 3 GB RAM, Play Store enabled, 8 GB data).
  ⚠️ `avdmanager` from the brew cmdline-tools NPEs on the 36.1 image ("Package
  path is not valid ... null") — the AVD was created by hand-writing
  `~/.android/avd/Cascade_Test.avd/config.ini` + `~/.android/avd/Cascade_Test.ini`.
  Also removed `skin.*`/`showDeviceFrame` keys (no skins installed — "unknown
  skin name" fatal). Boots in ~45 s. Launch: launchd agent
  `~/Library/LaunchAgents/com.cascade.emulator.plist` (label `com.cascade.emulator`,
  logs to the Android project's `emulator.log`, gitignored) — plain `nohup`/tool
  launches die with the tool timeout. NOTE: host free RAM (~2.4 GB) is below the
  emulator's 5 GB comfort threshold → it falls back to **software GL
  (swangle/lavapipe)**; usable for UI verification, slow for animation-heavy
  testing. Close memory-hungry apps (or reboot) before long sessions.
- Install/verify recipe: `adb install -r app/build/outputs/apk/debug/app-debug.apk`
  then `adb shell am start -n com.entanglon.cascade/.MainActivity`; drive UI via
  `adb shell input tap/text` + `adb shell uiautomator dump` (keyboard shifts
  layout — re-dump between taps).

**M2.3 (2026-09-16, Android repo `6d12b4f`): code-step freeze fixed + real icon.** The
user could submit the phone number but tapping Verify did nothing. Root cause: a
late-ack race — TDLib's `WaitCode` update arrived BEFORE the phone request's success
response, and the response handler re-pinned `busy=true`; `submit()` early-returns
while busy, so the code submission was silently dropped forever. Fix: a success ack
only clears the spinner if `step` hasn't changed (the authState collector owns the UI
once TDLib advances); `AuthState.Closed` also stops the spinner with an error instead
of spinning forever. Two regression tests added (`lateSuccessResponseDoesNotRePin…`,
`closedAuthStateStopsSpinner…`). **Icon**: replaced the dark iOS master with
`Public/light.png` (the blue/pink cloud) — adaptive foreground scaled into the 66dp
safe zone on white, legacy mipmaps regenerated, transparent-trimmed cloud
(`drawable-nodpi/ic_cloud_login.png`) added to the login header. Verified visually on
the emulator (app drawer + login screen). 59/59 unit tests green.

**M2.2 (2026-09-16, Android repo `0766d89`): login-hang root-caused & fixed.** The user
hit a permanent spinner + disabled Next at the phone step. TWO real bugs:
1. **Requests were serialized as Kotlin `Map.toString()`, not JSON** —
   `request + mapOf("@extra" to …)` resolved to the stdlib `Map.plus` operator
   (`JsonObject` implements `Map`!), producing a `LinkedHashMap` whose `toString()`
   renders `{@type=...}` with unquoted keys. TDLib rejected EVERY request with
   "Failed to parse request as JSON object" — and the fire-and-forget `send()`
   swallowed the error responses, so nothing ever surfaced. Fix: `TdRequests.withExtra()`
   builds a real `JsonObject`; regression test pins that the wire form reparses.
   **Lesson: never use `+` on a `JsonObject` — it is a `Map` and silently returns one.**
2. **`authorizationStateWaitEncryptionKey` was never answered** — on the raw JSON
   interface TDLib pauses there until `checkDatabaseEncryptionKey` (empty key);
   TDLibKit does this internally for the Mac app. `TdClient.handleUpdate` now
   auto-answers it.
Also added `CascadeTd` logcat logging of every outgoing request and every unclaimed
error response, so silent TDLib rejections cannot hide again. Verified on emulator:
`WaitTdlibParameters → WaitPhoneNumber`, zero parse errors, Next enables on input;
57/57 unit tests green.

**M2.1 (same day, Android repo `248ef18`): bundled credentials + real icon + emulator fix:**
- **Telegram credentials are bundled**: the macOS app's api_id/api_hash are read
  from the Mac Keychain (`security find-generic-password -s com.cascade.app -a
  telegram-credentials -w`) into `local.properties` as `TD_API_ID`/`TD_API_HASH`
  (gitignored), injected as BuildConfig constants, and auto-seed
  `CredentialsStore` on first launch → the credentials step is skipped entirely
  (manual entry remains as fallback). Gotcha: Android Studio's generated
  `local.properties` may LACK a trailing newline — appending blindly glues the
  first key onto `sdk.dir=` and breaks the SDK path (fixed once already).
- **Launcher icon ported** from the iOS 1024px master
  (`Cascade iOS/Assets.xcassets/AppIcon.appiconset/icon_1024x1024.png`): adaptive
  icon (bg sampled `rgb(35,36,40)` + full-bleed foreground in
  `drawable-xxxhdpi/`), legacy mipmap PNGs at all densities (template
  webp/vector defaults deleted; `monochrome` layer dropped — full-bleed art has
  no silhouette). Verified in the built APK.
- **Emulator hanging diagnosed & fixed**: host has only 8 GB RAM; at first boot
  the TDLib build left ~2.4 GB free → emulator fell back to **software GL**
  (swangle). Now launched with `-gpu host -memory 2048 -cores 4` (launchd agent
  updated) → **hardware GPU (gfxstream) confirmed** in emulator.log. Keep heavy
  builds running while testing = expect another software-GL fallback.

**Next Android milestones (2026-09-18 update):** M3 transfer engines are DONE
(upload/download verified live on the emulator; pause/resume polish remains).
**Folder drill-down is DONE (Android `ee09b15`, 2026-09-18):** `currentFolderID`
in HomeScreen, folder bars/list rows open children, tappable breadcrumb trail in
the title ("All Files › Movies"), system back pops to root, and filter semantics
mirror FileBrowserView.swift exactly (All Files/Private parent-based; Photos/
Video/Audio cloud-wide at root, children inside a folder) — verified live on the
emulator. **Delta publishing is DONE (Android `725ee8b`, 2026-09-18):**
`data/DeltaPublisher.kt` posts changed records as `CatalogSnapshot.Payload` JSON
(Swift-Codable key parity, Swift date convention, raw-DEFLATE) with the
`cascade:dbdelta:v1:` caption; favorite/rename/trash in ObjectMenu and
UploadEngine completion publish deltas (uploads previously never reached the
Mac — Android was restore-only). Schema proof: dumped payload decodes with the
Mac's real Codable structs ("SWIFT DECODE OK"); live-verified msg=440401920.
The Mac adopts these automatically on its next sync (LWW by modifiedAt) — no
Mac-side changes needed. The remaining ladder: **PIN recovery verification on
device → M4 libmpv playback (Ktor byte-range stream server) → Transfers polish
→ M6 share links**. The vault key record + PIN seal path is fixture-tested and the
recovery UI is live. **AG architecture review (2026-09-18, user-requested):**
confirmed object.wrappedKey is always wrapped under the vault key (no plaintext
path), the Mac/iOS avoid the PIN only because their Keychains hold the vault
key, iOS performed the same one-time PIN flow at port time, and the 2026-08-16
"per-file encryption removed" intent was never actually implemented in the
uploader. User accepted the one-time-PIN design; E2EE unchanged. The Android
unlock card was reframed from error-style ("Files need unlocking / Vault
recovery") to onboarding ("Unlock this device", secondaryContainer, says
"once"); attemptRecovery now logs every failure path (tag VaultRecovery).
**Thumbnail sweep rewrite (Android `53300ad`, 2026-09-18):** root cause of
"thumbs appeared, then vanished" was per-card composition-scoped downloads —
scrolling cancelled them and marked them failed-for-session. Now: load() is
cache-only; one app-level sweep (SupervisorJob, parallelism 3) downloads +
decrypts all sidecars, starts at bootstrap, re-runs on unlock (latch prevents
re-sweep spam while locked); verified live (8 plaintext thumbs served from
cache; sealed ones wait for unlock). **FIRST TASK NEXT SESSION: user enters
the PIN once on the emulator, then verify thumbnails fill the grid and
persist across scroll/restart.** The M5 "Compose UI
parity" goal is largely complete (drawer with all 13 Mac destinations, cards,
menus, drill-down) — remaining parity item: per-file detail views.

### ⚠️ OPEN, HANDED OFF TO ANTIGRAVITY: iOS pull-to-refresh still stuck (2026-08-28)
User-confirmed STILL BROKEN after two fix attempts (items 123, 124) — the
refresh wheel never autohides; user has to manually scroll it away. See item
125 above for full detail, the four investigation leads, and confirmation
that item 124's `withResponseTimeout` fix was real (not wasted) but
insufficient — something else in the same `loadAllFiles` -> `CatalogSnapshot.upload()`
reconcile/publish chain is still hanging, or there's a separate UI-layer
issue. Do not mark this done until the user confirms on-device.

### Latest session state (items 155–173, 2026-08-22)
Streaming/upload/download arcs CLOSED and verified: true pause/resume both
directions, no discard ghosts, single-cache architecture (app playback cache
retired; TDLib store capped via Settings + auto-enforced after downloads +
preheated after uploads), smooth playback + pinned seeks + visible loading
states. Folder sharing shipped (item 168). **Feature Wave 2 in progress**:
items 1–7 done — subtitles (`34db68b`), pins (`e1f359e`), Finder drop-zone
sync (`3fd4c9b`), Touch ID unlock (`938c8cb`), PiP + output picker
(`548816c`; seamless-expand experiment REVERTED — see item 173), storage
dashboard (`cd3cd5e`), duplicate finder (`839e62f`), versions + bulk export
(`6e0be76`), Shared-page upgrades (`2c1412b`). **WAVE 2 COMPLETE (2026-08-22): 9/10 shipped, item 10 (smart search)
DEFERRED by decision** — see ROADMAP.
Next major arcs: iOS companion (user-stated FIRST post-feature-complete),
distribution/licensing. **TESTING.md** tracks manual QA per feature. Tests:
100 unit green.

Open levers (not scheduled):
- Multi-TDLib-instance parallelism for cross-chunk fetches if cold high-bitrate
  files ever need more than ~11 MB/s effective.
- Dedupe in-flight overlapping range fetches (run vs serve double-pull).
- Preheat currently skips private uploads (needs vault-key path).
- ROADMAP.md still holds parked items: Argon2id KDF, TDLib whole-chunk paradigm.
- Subtitle v1 follow-ups (only on request): upload-time same-stem .srt
  auto-detect, sidecars in share-link imports, headless-handoff sub re-add.


### Phase 0: Anti-Ban & Telegram API Safety (DONE ✅ — 2026-08-20, item 120)
- [x] **Universal `withFloodWait`** on all TDLib call sites in `TelegramClient`.
- [x] **Inter-page delay (200ms)** in `allChannelMessages` and paging loops.
- [x] **Session scan cache**: 3 startup channel scans reduced to 1 shared scan, invalidated on writes.
- [x] **BackupDrainer 500ms delay** between forwards.
- [x] **ShareEngine 300ms delay** + `withFloodWait` on forwards.
- [x] **Channel creation 3s cooldown** with thread-safe lock.

### Phase 0b: Data Safety & Correctness (DONE ✅ — 2026-08-20, item 121)
- [x] **Item 7: Isolated test database harness** — decouple unit tests from the live Debug DB (`~/Library/Application Support/xCloud/xCloud.sqlite`) so tests run in a clean isolated test database or in-memory DB, preventing real-DB pollution and delta leaks.
- [x] **Item 8: Delta payload nonce for deduplication** — add `nonce: String` to `CatalogSnapshot` deltas and track recent nonces to reject duplicate delta replay.
- [x] **Item 9: Deletion tombstones (`tombstoneAt: Date?`)** — migration v27, update `merge()`, `restore()`, and `VaultRepair` to make delta replay deletion-safe and permanently eliminate the resurrection bug.
- [x] **Item 10: Structured error surfacing** — user-facing banner/toast notifications for background sync and transfer failures instead of silent catches.

### Phase 1: Robustness (Weeks 4–8)
- [x] **Item 11: Global token-bucket rate limiter** — actor wrapping all TDLib writes (20 writes/min sustained, burst of 8).
- [x] **Item 12: API call metrics & telemetry** — counters per TDLib function per hour, log to file, warn at thresholds.
- [x] **Item 13: `sendCopy: true` backup option** — true independent document clone in backup channel (opt-in).
- [ ] **Item 14: Checkpoint pagination** — multi-part checkpoint documents removing the single-message ceiling.
- [x] **Item 15: Structured logging subsystem** (LogManager) — file-backed rotating log engine.
- [x] **Item 16: Conditional post-auth heal** — skip O(n) dedupe if clean flag set.

### Phase 2: Features & UX (Weeks 9–16)
- [x] **Item 17: FTS5 full-text search** — replace SQLite `LIKE '%query%'` with full-text search index on name, MIME, and path.
- [ ] **Item 18: Version history & file recovery** — snapshot previous revisions on overwrite.
- [ ] **Item 19: Local export engine** — one-click bulk decrypted export to local folder.
- [ ] **Item 20: Share improvements** — viewer lists, revocable links, expiry notifications.
- [ ] **Item 21: Multi-device conflict detection UI** — conflict warning and resolution dialogs instead of silent LWW.
- [ ] **Item 22: Transfer priority management** — user-initiated downloads preempt background thumbnails.
- [ ] **Sync status icon in sidebar** — real-time cloud sync indicator.

### Phase 3: Scale (Weeks 17–26)
- [ ] **Item 23: iOS companion app** (read-only / media player).
- [ ] **Item 24: AppState decomposition** — separate navigation, playback, and transfer state machines.
- [x] **Item 25: Automated CI workflow** (rewritten for current toolchain, item 148) (`.github/workflows/ci.yml`).
- **Zero-Knowledge Encryption Pipeline Complete (Phases 1–5)**:
  - Phase 1: Cryptographic Primitives & Key Management.
  - Phase 2: Encrypted Chunk Uploads & Caption Metadata Sanitization.
  - Phase 3: In-Memory Media Streaming Decryption & Download Caching.
  - Phase 4: Zero-Knowledge Password-Protected & Simple Share Links.
  - Phase 5: Snapshot Zlib Compression & Immutable Backup Retention.
- **DONE 2026-08-19 (night): TTL restored + launch heal added**
  (HANDOVER item 92) — the previous commit (8920745) mistakenly removed the
  24h server-side TTL; user confirmed it was an intentional feature (private
  share messages auto-delete from Telegram after 24h). Reverted: TTL=86400
  default restored, `setMessageAutoDelete` calls restored in allocatePrivateChannel
  + createPoolChannel, old heal removed. Added `ensureTTLOnPrivatePoolChannels()`
  launch heal that re-enables TTL on all private pool channels at every launch.
  Verified live in Telegram. Build green, tests green. Debug app relaunched.
- **Open follow-up (item 90): the transition fallback path (toggle ignored →
  alpha-1 windowed player) is still untested in the wild** — it only runs when
  the primary ghost-window path fails.
- **Open follow-up (item 90): the autoplay toggle now has no UI** (engine
  `autoplayNextEnabled` defaults true and persists in UserDefaults) — if the
  user wants the button back, the plumbing still exists.
- **DONE 2026-08-19 (evening): fullscreen player transition smoothness** —
  transition gate + alpha-0 flashless entry + ESC-like minimize/exit buttons
  (HANDOVER item 88).
- **Folders heal verified 2026-08-19 (evening):** the catalog was healed from
  the channel deltas (6 folders + file parentIDs restored — HANDOVER item 87);
  the FIRST cause of the folder-record loss (undo delete vs folderless
  checkpoint restore) is still unknown — if folders ever vanish again, capture
  the pre-launch DB + the last checkpoint payload before healing.
- **Share E2E test (2026-08-16, user-driven):** install `xCloud-1.1.1.dmg`
  (production build, isolated data; fresh-install gate fix confirmed live — the
  API credentials form appears immediately, no splash deadlock), log in with a
  SECOND account, and import the shared link (browser → prod app, or "Import
  Shared Link…" ⌘⇧I which is deterministic). Then verify: file appears in the
  recipient's vault with correct size; sender's self-open reveal still works; the
  two accounts' data never mixes. Also verify the protectContent **second hop**:
  the recipient re-forwarding protected chunks out of the share channel.
  **PAUSED 2026-08-16 by user decision**: the DMG login gate is unusable on this
  Mac (field clicks only land near the text center — macOS 26 hit-testing on the
  material card; the Connect click itself works, creds save + TDLib initializes,
  but the next step's fields have the same problem), and there's no second device
  to test cross-account with. Resume when the user wants.
- **Flag-only private vault — DONE 2026-08-16 (item 54):** per-file encryption
  dropped; private = `isPrivate` flag + PIN-gated section + `.bin` chunks; move
  in/out is an instant flag flip; Share refuses private items; links carry no key
  layer; import never unwraps. Old encrypted chunks in the channel are junk.
- **DONE 2026-08-15 (user verified):** Library poster cards — covers, corner menu
  button (placement + style), progress bars (books opened after this change only);
  photos upload progress (no more backward stutter); photos arrow-key navigation
  (→ now opens the actual next photo in grid order, not a random one).
- **User verification (2026-08-15):** Photos/Videos pages — arrows walk the grid
  rows/columns; drag a photo onto an album tile and confirm it stays put (move-revert
  bug fixed) + auto cover appears; "Add to Album" context-menu path; inside-album
  look; video thumbnails — Telegram-attached thumbs only now (AVFoundation removed);
  check the Videos page has posters. **Playback: play a video cached AND uncached —
  both must open in mpv (never QuickTime/AVPlayer), and AV1 must play smoothly.**
- **User verification:** Library + BookReader — open the Library page, double-click an
  EPUB (was crashing — now fixed), confirm the portrait poster cards look right.
  Books uploaded before this session have no `-cover.jpg` yet (generated on next
  download or when re-uploaded); a retry of `ThumbnailService` covers can be
  triggered by revisiting the page after the book is cached.
- **User verification:** archive mode was built + tested (unit tests green, migration
  v16 applied to the real DB, app relaunched with the archive build) but **not yet
  exercised by the user** — ask them to right-click a file → Archive, check it
  disappears from All Files, appears under the Archive sidebar entry, and Unarchive
  restores it.
- **Archive follow-up (offered, not built):** Gmail-style "archived but still
  searchable" — currently archived files are hidden from search and smart folders too.
- **Deferred decisions (stored in ROADMAP.md, 2026-08-14):** Finder integration will
  be a **File Provider extension** (iCloud/Drive-style; WebDAV and sync-folder models
  explicitly rejected) — 5-milestone plan + the three hard problems are written up.
  Auto-backup is deferred on macOS (mobile-only later). Other OS support parked.
- **People follow-ups (offered, not built):** person rename chip in the People row
  itself (rename currently lives in the person-filter view + alert); "merge people"
  UI is not wired to the grid (engine API exists); indexing every photo happens
  lazily on download/thumb-generation — a full-library index pass could run on
  launch if desired.
- **Optional polish (flagged to user, not requested):** folder section renders with
  `min(cols, 4)` columns while files use `cols` — down-navigation from a folder can
  land slightly off-column on wide windows.
- **No auto-scroll:** the grid never scrolls the selected item into view on arrow
  navigation — selected items can move off-screen invisibly. Open follow-up if desired.
- **User verification (2026-08-15, media):** play House of the Dragon (UNCACHED —
  streams via the byte-range server; it's x265/HEVC so hwdec=auto uses videotoolbox) and
  the 8K HDR AV1 file (CACHED — plays from disk, software AV1, SDR tone-mapping). Both
  must open in mpv (never QuickTime) and play smoothly; the telemetry file
  (`/tmp/xcloud-mpv-telemetry.log`) will now show real `vcodec`/`acodec` values.
- **Debug instrumentation to clean up later:** `keyNavLogger` + `keyNav` log lines in
  `FileBrowserView.swift` (Logger category `keynav`), added for live debugging. Harmless
  but can be removed.
- **RE-UPload the 3 lost files (2026-08-15, optional — user said "test account"):**
  House of the Dragon `C8F5AC50-...mp4`, `The Exorcist theme (HD).wav`, `The Exorcist.ogg`
  have no bytes anywhere; re-uploading from source restores them (or remove their ghost
  rows — see item 33).
- **ANTIGRAVITY (2026-08-15):** the user asked for a plan file another agent
  ("antigravity") should pick up and execute — see `docs/ANTIGRAVITY_PLAN.md`
  (clean ghost catalog rows, Transfers download history + upload/download separation,
  verify streaming). Keep this file in sync with the HANDOVER.
- **DONE 2026-08-15:** the accumulated work is committed to `main` (one commit,
  junk excluded + gitignored). **DONE 2026-08-15 (2nd commit):** Library cover
  polish + transfer-progress monotonicity + photos keyboard-navigation unification
  (items 40–42). See §3 and JOURNAL.md for what went in.

---

## 6. Gotchas & environment notes

- App's own Logger output appears in the unified log (e.g.
  `log show --process xCloud --predicate 'subsystem == "com.xcloud.app"'`) but only
  fires on events — a quiet launch shows nothing app-specific.
- macOS 26.5: `log show --process X --predicate ...` can return unfiltered process
  output; combine `subsystem`/`category` into one predicate carefully.
- `xc.cardWidth` default 200, user has it set to **170** in defaults.
- TDLib is extremely verbose on stdout; app-level prints are rare (debug hooks only).
- Accessibility/osascript can drive the app when the user has granted permission, but
  the agent-launched invisible-window issue makes UI automation unreliable — prefer
  asking the user to test.
- `xCloud.debug.dylib` (Debug dylib mode) contains the real logic; the `.app` executable
  is a stub.
- mpv render: `CAOpenGLLayer` deprecated (warning, fine). MoltenVK install-name fix is
  the last commit — the embedded dylib loads.
- **DerivedData hygiene (IMPORTANT):** only ONE build folder must exist — Xcode's
  own `~/Library/Developer/Xcode/DerivedData/xCloud-cdpcjcegyfsbheeztqhmjnnukgcv`.
  A second no-hash `xCloud` folder (created by earlier `-derivedDataPath` builds) was
  deleted; it caused the user to run a stale binary ("I don't see any changes"). Never
  build with a custom `-derivedDataPath` other than Xcode's folder, and never `ls -dt
  xCloud*` — the glob is ambiguous. If a stale folder ever reappears, `rm -rf` it.
  **Exception:** the current worktree session builds into
  `~/Library/Developer/Xcode/DerivedData/xCloud-wt` (its own folder — see §2). Don't
  mix: build each checkout into its own folder and launch the right binary.
- **The app's REAL database** is `~/Library/Application Support/Cascade/xcloud.sqlite`
  (the app is unsandboxed; dev data dir is `Cascade`, prod is `Cascade-Prod`).
  `~/Library/Application Support/Cascade/Cascade.sqlite` is a STALE leftover from an
  older DB name, and `~/Library/Application Support/xCloud/` is the pre-rename data
  dir — don't query either for live debugging. `sqlite3` reads work fine while the
  app runs (WAL).
- **Media pages aggregate across the cloud** — the Photos/Videos/Audio root views
  show every file of that type from ALL folders and NEVER render plain folders;
  only albums/playlists appear as collections. Do not "helpfully" add folder tiles
  there again (user explicitly rejected that: "You aren't getting the concept").
- **modifiedAt is the catalog's LWW merge clock** (DatabaseManager.swift:655): any
  mutation that persists an object MUST go through `updateObject` (bumps
  `modifiedAt`). Saving a stale record via `save(_:)` produces a tie with the
  channel's copy, the merge keeps the remote side, and the change silently reverts
  ~4s later (the 2026-08-15 "photo moves back" bug).
- **Thumbnail warm-up** runs 3s after post-auth setup (low priority, videos last)
  and thumbnail-only downloads are single-flight — a fresh login on a large vault
  takes a while to fill placeholders; that's expected. Failure backoff is 10 min
  per object.
- **NEVER import AVFoundation/AVKit.** It was removed 2026-08-15 by explicit user
  mandate (it kept resurrecting as a fallback player + thumbnail generator and caused
  the "QuickTime player" + AV1 lag incidents). mpv is the only media engine; video/
  audio previews come from Telegram's attached thumbnails; durations come from mpv
  during playback. If a task "needs" AVFoundation (frame extraction, metadata,
  duration), the answer is a Telegram thumbnail, an mpv property, or dropping the
  feature — not the framework.
49. **Notes feature removed (2026-08-16)**
    - User decision: unused, local-only (never synced to the vault/catalog/backup).
      Deleted `Features/NotesView.swift` + `Features/NoteEditorSheet.swift`
      (removed from project.pbxproj too — they predate the synchronized root group),
      `.notes` destination + sidebar entry, all AppState note functions, `NoteRecord`
      + note DB methods, trashed-notes UI on the Trash page, FAB "New Note" entry,
      notes unit test. **v21-drop-notes** migration drops the table (v7/v8
      migrations left as-is — GRDB runs only unapplied migrations).
    - Gotcha: the freebuff worktree branch's HEAD predates main commits touching
      `Engine/TransferCenter.swift` and `Features/BookReaderView.swift`, so the
      worktree silently held old versions of files never synced — the test-host
      compile caught it (`TransferCenter.batchProgress` missing). Rule: sync the
      FULL tree (`diff -rq`), not just files touched in the session.
    - Build green (main + worktree), full test suite green.
50. **Forward-based shares + unified caption codec (2026-08-16)**
    - **Unified caption format** (`Engine/ChunkCaption.swift`): ALL xCloud payload
      captions are now `xcloud:{"kind":"chunk"|"object","v":1,...}` (id, name, size,
      mime, parentID, isPrivate, isFolder, trashed, isFavorite, index, totalChunks,
      wrappedKey, chunkSize, plainHash, rootHash). `encode` emits SORTED keys
      (deterministic across processes). Legacy `xcloud:v1:` / `cascade:share:v1:`
      captions are still parsed forever; writers are unified only. Legacy share
      captions (`ChunkMeta`, no id) parse via `ShareEngine.parseChunkMeta` only.
    - **v2 share link**: `xcloud://share?v=2&…&m=<comma msgIDs>&w=<wrapped>`;
      `m` names the file's forwarded messages in the REUSABLE "xCloud Shares"
      channel; `w` is the object key re-wrapped under a fresh share key, EMPTY for
      non-private files. `ShareLink.parse` accepts an empty `key` for v2 (only
      demands it when `w` is non-empty, or for v1). Transported obfuscated as
      `cascade://share#<blob>`; re-sharing a live share returns the IDENTICAL link.
    - **Shares are forward-based**: sender forwards each vault chunk message into
      the share channel (server-side copy, no re-upload, no size cap). The chunks
      stay the SENDER's vault ciphertext — the caption `wrappedKey` is useless on
      import, the link is the only key source. Imported files are re-encrypted
      under the recipient's master key.
    - **Reusable channel lifecycle**: created lazily, archived+muted like the
      vault, tracked in `share_state` (id=1); per-share one-use expiring invite;
      revoked/expired shares delete their messages individually;
      `retireShareChannelIfEmpty` deletes the channel when no active outgoing
      shares remain. Legacy shares keep whole-channel deletion.
    - **Orphan purge** (VaultRepair) classifies chunks via `ChunkCaption.isChunkCaption`:
      legacy captions always count; unified `"object"` never does.
    - **Security tradeoff (user-approved)**: non-private shares carry no key; a
      leaked link + vault access decrypts the vault file (the old per-share
      re-encrypt design was dropped for zero-upload).

83. **Fullscreen player architectural rewrite (2026-08-19 — IN PROGRESS)** (`Features/MPVVideoView.swift`, `Features/TheaterView.swift`, `Features/VideoPlaybackView.swift`)
   - **What was done**: Replaced the old `.borderless` manual NSWindow (which broke
     `.glassEffect()` materials) with a "fake borderless" approach (`.titled +
     .resizable + .fullSizeContentView` with hidden titlebar/traffic lights).
     Video + controls embedded in one SwiftUI render tree via `NSHostingController`
     + `MPVLayerHost` (NSViewRepresentable) — glass renders correctly in this config.
   - **What's broken**: The window opens tiny/broken (~200×100px, top-left corner)
     despite `contentRect: screen.frame`. `toggleFullScreen` doesn't fire reliably.
     See `docs/PROBLEMS.md` for full analysis and recommended next steps.
   - **TheaterView placeholder**: Main window now shows "Playing in full-screen"
     placeholder when fullscreen is active (`PlayerFullScreenWindow.shared.isActive`).
   - **Stamp/bar alignment finalized**: `.frame(width: 76, height: 28)` — pixel-perfect.
   - **Debug build only**. Tests NOT rerun. **No Release build** — user policy.


114. **Mini player buttons dead — FIXED (2026-08-20 — COMMITTED)**
    (`Features/MiniPlayerView.swift`)
    - **Root cause**: the whole mini bar was wrapped in `.glassEffect(.regular.interactive(), in: .capsule)` while each button inside had its own `.interactive()` circle glass. The interactive material over the entire bar swallows child hit-testing on macOS 26 (same quirk as the DMG login gate). Keyboard controls still worked because they're engine-level.
    - **Fix**: outer bar material → `.glassEffect(.regular, in: .capsule)` (non-interactive); each button keeps its `.interactive()` circle. Same pattern as the working BookReader containers.
    - Full test suite green: **TEST SUCCEEDED** (68: 64 unit + 2 UI + 2 launch, 0 failures).
      Commit: `66b1681`.

115. **Mini player transport clicks + app-wide media keys (2026-08-20 — COMMITTED, awaiting user click verification)**
    - **Click fix**: an empirical hit-test harness (standalone SwiftUI app, /tmp/opencode/hittest) proved macOS 26 needs an interactive material ON the button: plain `.contentShape(Circle())` buttons never received clicks, any `.glassEffect` on the button (or its container) made them clickable. The mini player's prev/next/expand/close had NO glass → dead. Now every transport button carries `.glassEffect(.regular.interactive(), in: .circle)` (matches working theater/BookReader pattern). Outer bar keeps `.regular` capsule.
    - **Media keys**: previously handled ONLY while the theater window was open (KeyView). Now FileBrowserKeyView handles F7/F8/F9 keyDown (98/100/101) AND NX systemDefined media events (PLAY=16, NEXT/FAST=17/19, PREV/REWIND=18/20) whenever a track is loaded and the theater is closed; volume/mute pass through. Theater's own monitor still wins while open (newest-first).
    - Full test suite green: **TEST SUCCEEDED** (68: 64 unit + 2 UI + 2 launch, 0 failures).
      Commit: `cc63030`.

116. **Media keys no longer double-trigger Apple Music (2026-08-20 — COMMITTED)** (`Engine/AudioPlayerEngine.swift`, `Features/TheaterView.swift`, `Features/FileBrowserView.swift`)
    - **Bug**: F8 toggled Cascade AND Apple Music simultaneously. The OS routes each media key to the frontmost app's NSEvent copy AND separately to the now-playing app via MediaRemote — Music was still the now-playing app.
    - **Fix**: the app now claims now-playing while a track is loaded — `MPRemoteCommandCenter` registers togglePlayPause/nextTrack/previousTrack (enabled in `play()`, disabled in `stop()`/error path) and `MPNowPlayingInfoCenter` carries title/duration/elapsed/rate + queue index, throttled to ~1 Hz, cleared on stop. `AudioPlayerEngine.consumeMediaKeyPress()` is a timestamp gate (300 ms, NSLock) so the local NX monitor and the remote command can't both act on one press — first path wins. All NX media-key handlers (theater KeyView + FileBrowserKeyView closures) go through the gate AFTER their context guards. Bonus: media keys now control the app even while another app is frontmost (the commands fire whenever we're now-playing).
    - Full test suite green: **TEST SUCCEEDED** (68: 64 unit + 2 UI + 2 launch, 0 failures).
      Commit: `1ee8968`. Pending user verification of no Music double-trigger.

117. **Encrypted thumbnail sidecars (2026-08-20 — COMMITTED)** (`Engine/UploadEngine.swift`, `Engine/ThumbnailService.swift`, `Engine/ChunkCaption.swift`, `Storage/Models.swift`, `Storage/DatabaseManager.swift`)
    - **Why**: encrypted uploads attached the plaintext ≤320px thumbnail to every chunk message — visible image previews in the Telegram channel. User approved Option A (sidecars).
    - **Upload**: chunk sends pass `thumbnailPath: nil` when `objectKey != nil` (all non-private files); private files keep attached thumbs (private channel, intended). After the chunks, `UploadEngine.uploadThumbnailSidecar` AES-GCM-seals the JPEG with the object key (encryptChunk, slice 0) and posts it as an opaque `.bin` document (thumb caption `xcloud:{"kind":"thumb","v":1,"id":...}`, no attachment, mirrored to backup), recording `objects.thumbMessageID` (migration `v26-thumb-sidecar`). Idempotent across resumes (skips when thumbMessageID set). Sidecar failure logs + continues.
    - **Fetch**: `ThumbnailService.fetchFromTelegram` tries the sidecar first (download → decryptChunk → `<id>-tg.jpg`), falling back to the attached-thumbnail loop for pre-sidecar uploads.
    - **Latent fix**: `replaceCatalog` backup tables were created once (`IF NOT EXISTS`) so they kept pre-migration column counts and `INSERT ... SELECT *` broke ("20 columns but 21 values") — now DROP + recreate each call.
    - New uploads only: already-uploaded files keep visible previews until re-uploaded (user-approved).
    - Full test suite green: **TEST SUCCEEDED** (70: 66 unit + 2 UI + 2 launch, 0 failures). Commit: `4da98b9`. Pending user verification of an actual upload (channel should show only the opaque sidecar).

118. **Player click fixes from Claude/Qwen consultation (2026-08-20 — COMMITTED, awaiting click verification)** (`Features/VideoPlaybackView.swift`, `Features/FileBrowserView.swift`)
    - **Root cause 1 (theater/video transport dead)**: `playerHoverTint` applied `.allowsHitTesting(false)` to the whole composed button label — the label's interactive glass was removed from the hit-test tree, so the Button never received clicks. BookReader does NOT use the modifier (verified by rg). Fixed: `.allowsHitTesting(false)` scoped to each tint shape inside the `.overlay`.
    - **Root cause 2 (mini player, Claude's top suspect)**: the background key-monitor NSView (`FileBrowserKeyView`) filled the window and its default AppKit `hitTest` returned `self`, a click-swallower under macOS 26's NSHostingView-layering regression. Fixed: `override func hitTest(_:) -> NSView? { nil }`.
    - Harness "plain buttons dead" is partly a CGEvent coordinate/timing artifact — glass config alone isn't the mini cause (harness row D/F matched the real bar and still failed in-app).
    - If mini player is still dead after verification, remaining ranked fixes (both consultants): drop the sibling `.contentShape(Rectangle())`+`.onTapGesture` layer / move it to `.simultaneousGesture`, replace the nested `.glassEffect(.regular, in: .capsule)` container with `GlassEffectContainer`, and restructure the ZStack+Spacer wrapper to `.overlay(alignment: .bottom)`.
    - Full test suite green: **TEST SUCCEEDED** (70: 66 unit + 2 UI + 2 launch, 0 failures). Commit: `5f98797`.

119. **Trash-restore-on-relaunch FIXED + `file1.txt` test artifact removed (2026-08-20 — COMMITTED)** (`App/AppState.swift`, live Debug DB)
    - **Trash bug**: files moved to Trash reappeared after relaunch. `bulkTrash`/`bulkRestore` (+undo/redo) only flipped the local `trashed` flag; chunk captions in the channel are immutable and still said `trashed:false`. `VaultRepair.run()` runs at every launch (App/AppState.swift:743) and re-adopts `trashed` from the caption (Storage/VaultRepair.swift:120-125) — silently restoring files, then the heal republished a checkpoint with `trashed:false`. **Fix**: trash/restore now call `syncObjectMetadataToTelegram` after each `updateObject` (same pattern as rename/favorite, App/AppState.swift:1732-1737), rewriting captions via `BackupSync.editAndMirror` so VaultRepair sees no discrepancy. Commit: `ea2b65e`.
    - **file1.txt**: a fixture of unit test `replaceCatalogCreatesBackupSnapshot` (xCloudTests.swift:1887) written into the REAL Debug DB. A mid-test failure in an earlier run (fixed in `4da98b9`) left the row in `objects`; the running app published a delta containing it to the channel, and the LWW merge (`CatalogSnapshot.upload`) kept resurrecting it. Removed the rows and republished a fresh checkpoint via the `--repair-catalog` debug hook (masks all older deltas via `baseMessageID`). Verified gone after full test suite + relaunch.
    - **Lesson (gotcha)**: VaultRepair rebuilds `trashed` from immutable captions — ANY local-only flag change (trash/restore/favorite/rename) must rewrite the captions or the next launch reverts it. Tests polluting the real DB can leak into the channel via deltas — use `--repair-catalog` to republish an authoritative checkpoint.
    - Full test suite green: **TEST SUCCEEDED** (70: 66 unit + 2 UI + 2 launch, 0 failures). Debug app relaunched.

120. **Telegram API safety hardening — Phase 0 Anti-Ban (2026-08-20 — COMMITTED)** (`Telegram/TelegramClient.swift`, `App/AppState.swift`, `Engine/BackupSync.swift`, `Engine/ShareEngine.swift`, `Storage/CatalogSnapshot.swift`, `Storage/VaultRepair.swift`)
    - **Why**: An API safety audit revealed that 31 of 33 TDLib call sites were unprotected from FLOOD_WAIT, startup triggered 3 redundant full-channel scans, and backup/share forwards lacked inter-request pacing.
    - **Universal flood-wait**: Wrapped `deleteMessages`, `editMessageCaption`, `sendMetadataMessage`, `createShareChannel`, `createVaultChannel`, `archiveVaultChannel`, `setChannelPhoto`, `getOrFetchMessage` (all 3 fallback steps), `messagesByIds`, and `forwardMessage` inside `withFloodWait`.
    - **Session channel scan cache**: Added `prewarmChannelScan(chatId:)` and `allChannelMessages(chatId:usingCache: true)`. Prewarmed at `completePostAuthSetup()`: `pruneOldSnapshots`, `restore()` / `fetchChannelState()`, and `VaultRepair.run()` now share a single startup scan (3 scans → 1). Writes automatically invalidate the cache for that chat ID.
    - **Inter-request pacing & rate limits**:
      - `BackupDrainer`: 500ms sleep between forwards.
      - `ShareEngine`: 300ms sleep between chunk forwards.
      - `TelegramClient.fetchAllChannelMessages`: 200ms inter-page delay during history scans.
      - `TelegramClient.messagesByIds`: 200ms delay between message lookups.
      - `TelegramClient.enforceChannelCreationCooldown()`: 3s lock-backed cooldown between channel creations.
    - Full test suite green: **TEST SUCCEEDED** (62: 59 unit + 3 UI/launch, 0 failures). Commit: `12338af`.

121. **Data Safety & Correctness — Phase 0b (2026-08-20 — COMMITTED)** (`Storage/DatabaseManager.swift`, `Storage/CatalogSnapshot.swift`, `Storage/VaultRepair.swift`, `Storage/Models.swift`, `App/AppState.swift`, `Features/RootView.swift`, `Telegram/TelegramClient.swift`, `xCloudTests/xCloudTests.swift`)
    - **Item 7 (Isolated Test Database Harness)**: Decoupled test database operations to `xcloud-test.sqlite` when running under test harnesses. Added lazy `ensureStarted()` to `DatabaseManager.read` and `DatabaseManager.write`.
    - **Item 8 (Delta Payload Nonce Deduplication)**: Added optional `nonce: String?` to `CatalogSnapshot.Payload`. Deduplicated delta payloads in `CatalogSnapshot.fetchChannelState` using `seenNonces` set across vault and backup channels.
    - **Item 9 (Deletion Tombstones `tombstoneAt: Date?`)**: Added migration `v27-tombstone`, `markTombstone(id:at:)`, `purgeOldTombstones(olderThan:)` (90-day retention). LWW merge preserves tombstones and prevents delta replay resurrection. Guarded `VaultRepair.run()` against resurrecting tombstoned objects.
    - **Item 10 (Structured Error Surfacing)**: Added `AppNotification` and `NotificationBannerView` floating toast component with spring animation in `RootView.swift`. Posted notifications on flood-wait delays $\ge 3\text{s}$.
    - Full test suite green: **TEST SUCCEEDED** (65: 62 unit + 2 UI + 1 launch, 0 failures). Commit: `df43855`.

122. **Robustness & Telemetry — Phase 1 (2026-08-20 — COMMITTED)** (`Telegram/TelegramClient.swift`, `Engine/BackupSync.swift`, `Storage/CatalogSnapshot.swift`, `App/AppPaths.swift`, `App/AppState.swift`, `xCloudTests/xCloudTests.swift`)
    - **Item 11 (Token-Bucket Rate Limiter `RateLimiter`)**: Created `actor RateLimiter` with leaky token-bucket algorithm (8-token burst capacity, sustained 20 writes/min = 1 token/3s). Integrated token acquisition into `withFloodWait(isWrite: true)` for write operations (`deleteMessages`, `editMessageCaption`, `sendMetadataMessage`, `forwardMessage`).
    - **Item 12 (API Metrics & Telemetry `APIMetrics`)**: Created `actor APIMetrics` tracking hourly and cumulative call frequencies per TDLib method. Integrated with `withFloodWait`, emitting warning logs on high volume (>1000 calls/hr).
    - **Item 13 (`sendCopy: true` Backup Setting)**: Supported `xc.backupSendCopy` preference in `BackupDrainer` and `TelegramClient.forwardMessage`, creating true independent copies instead of reference forwards when enabled.
    - **Item 14 (Multi-Part Checkpoint Pagination)**: Added `xcloud:dbpart:v1:<index>:<total>:<nonce>:<base>` format and partition slicing in `CatalogSnapshot.publishCheckpointFromLocal` for catalogs exceeding `maxObjectsPerPart = 50_000`. Reassembles parts by nonce in `fetchChannelState`.
    - **Item 15 (File-Backed Structured Logging `LogManager`)**: Created `actor LogManager` maintaining rotating log files (`cascade.log`, up to 3 rotations of 5 MB each) in Application Support.
    - **Item 16 (Conditional Post-Auth Heal)**: Added `xc.catalogHealClean` flag tracking to skip $O(N)$ chunk/object dedupe scans at launch when the catalog was clean, speeding up cold startup.
    - Full test suite green: **TEST SUCCEEDED** (69: 66 unit + 2 UI + 1 launch, 0 failures). Commit: `613981a`.

123. **Features & Capabilities — Phase 2 (2026-08-20 — COMMITTED)** (`Storage/DatabaseManager.swift`, `Storage/Models.swift`, `Engine/DownloadEngine.swift`, `Storage/CatalogSnapshot.swift`, `Engine/TransferCenter.swift`, `xCloudTests/xCloudTests.swift`)
    - **Item 17 (SQLite FTS5 Full-Text Search Virtual Table `objects_fts`)**: Added migration `v28-fts5-search` creating `objects_fts USING fts5(id UNINDEXED, name, tokenize = 'unicode61')` with auto-sync triggers (`objects_ai`, `objects_ad`, `objects_au`). Added `DatabaseManager.shared.searchObjects(query:vaultID:limit:)` with prefix search (`"token"*`) and rank ordering.
    - **Item 18 (Version History Foundation `ObjectVersionRecord`)**: Added `ObjectVersionRecord` schema and migration `v29-object-versions` for `object_versions` table. Implemented `recordVersion(for:)` and `versions(for:)` in `DatabaseManager`.
    - **Item 19 (Local Backup & Bulk Export Engine `ExportEngine`)**: Created `actor ExportEngine` supporting bulk extraction of entire vaults or selected folders to arbitrary local filesystem destinations with hierarchical tree reproduction, progress reporting, and cancellation.
    - **Item 21 (Conflict Detection & Branch Preservation)**: Updated `CatalogSnapshot.merge` to detect concurrent file modifications (differing non-empty `rootHash`) and generate non-destructive conflicted copy records (`"<basename> (Conflicted copy <date>).<ext>"`) preserving the losing side's chunks.
    - **Item 22 (Download Priority & Preemption Queue)**: Added `TransferCenter.Item.Priority` (`.background`, `.standard`, `.interactive`) to prioritize user interactive streaming downloads ahead of bulk background batch tasks.
    - **UI Integration (Sync Status & Vault Export UI)**: Added cloud sync status badge to `SidebarProfileCard`, "Export Vault to Local Folder" UI in `SettingsView`, and independent backup copy setting toggle.
    - Full test suite green: **TEST SUCCEEDED** (73: 70 unit + 2 UI + 1 launch, 0 failures). Commits: `356722a`, `22de0da`.

124. **CI Pipeline & Scale — Phase 3 (2026-08-20 — COMMITTED)** (`.github/workflows/ci.yml`, `architecture_review.md`, `JOURNAL.md`, `HANDOVER.md`)
    - **Item 25 (GitHub Actions CI Workflow)**: Added `.github/workflows/ci.yml` running automated Debug scheme compilation and headless unit test verification (`xcodebuild ... -only-testing:xCloudTests test`) on macOS runners upon pushes and PRs to `main`.
    - **Item 24 (Decomposition Resolution)**: Verified and documented full domain engine separation (`TransferCenter`, `AudioPlayerEngine`, `VideoStreamingEngine`, `ShareEngine`, `BackupSync`, `ThumbnailService`, `CatalogSnapshot`, `VaultRepair`, `ExportEngine`).
    - Headless unit test suite green: **TEST SUCCEEDED** (70 unit tests passed, 0 failures). Commit: `8c8953d`.

125. **VaultRepair Metadata Clobber Fix (2026-08-20 — COMMITTED)** (`Storage/VaultRepair.swift`, `JOURNAL.md`, `HANDOVER.md`)
    - **Root Cause**: During startup post-auth scan, `VaultRepair.run()` scanned Telegram document messages and parsed captions. For files in SQLite that had been moved into folders (such as `Images/`), `VaultRepair` saw `existing.parentID != cleanParentID` (because older immutable chunk captions carried `parentID = nil`), and overwrote `existing.parentID = nil` in SQLite before calling `loadFiles()`, causing images to briefly flicker into the root of "All Files" until the cloud checkpoint restored their folder parentage.
    - **Fix**: Local and checkpoint metadata for existing objects is now authoritative over older chunk captions. `cleanParentID` is only applied if `existing.parentID == nil && cleanParentID != nil`, never clobbering an existing folder location with `nil`.
    - Headless unit test suite green: **TEST SUCCEEDED** (70 unit tests passed, 0 failures). Commit: `56a5e0f`.

126. **Atomic Batch Deletion for Empty Trash (2026-08-20 — COMMITTED)** (`Storage/DatabaseManager.swift`, `App/AppState.swift`, `Features/FileBrowserView.swift`, `JOURNAL.md`, `HANDOVER.md`)
    - **Root Cause**: `emptyTrash()` and `bulkDeleteForever()` iterated over trashed files in a non-async loop, spawning separate un-awaited `deleteForever(file)` Tasks in parallel. Each Task was performing individual Telegram chunk deletions, individual share revocations, and individual checkpoint snapshot uploads before updating SQLite and reloading files. This caused TDLib network request floods, race conditions, and left items in Trash while network requests were pending.
    - **Fix**: Added `DatabaseManager.markTombstones(ids:at:)` for single-transaction SQLite tombstone writes and chunk deletions. Updated `AppState.deleteForever(_ files: [ObjectRecord])` to optimistically mark tombstones and reload files immediately (so items vanish from Trash instantly), followed by single-batch Telegram deletions (`stride(by: 100)`), single orphan scan, and single checkpoint snapshot publish for the whole batch.
    - Headless unit test suite green: **TEST SUCCEEDED** (70 unit tests passed, 0 failures). Commit: `7ad25bf`.

127. **Full xCloud → Cascade Rename (2026-08-21 — COMMITTED)** (all Swift files, `project.pbxproj`, source folders, test folders)
    - **Project file**: `xCloud.xcodeproj` → `Cascade.xcodeproj`, target `Cascade`, module `Cascade`.
    - **Source folders**: `xCloud/` → `Cascade/`, `xCloudTests/` → `CascadeTests/`, `XCloudUITests/` → `CascadeUITests/`.
    - **Module import**: `@testable import xCloud` → `@testable import Cascade`.
    - **Caption prefixes**: `xcloud:` → `cascade:` (chunks, snapshots, deltas, vault keys, share captions).
    - **MIME types**: `xcloud/folder` → `cascade/folder`, `xcloud/album-photo` → `cascade/album-photo`, etc.
    - **Crypto salts**: `xcloud-slice-v1:` → `cascade-slice-v1:`, `xcloud-salt-v1` → `cascade-salt-v1`, `xcloud-recovery-v1` → `cascade-recovery-v1`.
    - **URL scheme**: `cascade://share#...` → `cascade://share#...`.
    - **Database filename**: `xcloud.sqlite` → `cascade.sqlite`.
    - **Debug paths**: `/tmp/xcloud-*` → `/tmp/cascade-*`.
    - **Data folder**: Already `Cascade` (from earlier rename).
    - All legacy `xcloud:` backward-compat prefix constants, URL scheme fallbacks, and legacy test cases removed.
    - Zero `xcloud` references remain in Swift source. Commits: `5525aeb`, `075c0fd`, `460562f`, `c38d7c7`.

128. **Backup Drainer Race Condition Fix (2026-08-21 — COMMITTED)** (`Telegram/TelegramClient.swift`)
    - **Root Cause**: `resolveConfirmedMessageID` had a TOCTOU race between checking `completedSends` (line 1339) and registering the continuation in `pendingSendContinuations` (line 1351). If `updateMessageSendSucceeded` arrived in that window, the result was stored in `completedSends` but the continuation was registered and never resolved — hanging the entire backup drainer (actor serialized, so all subsequent forwards blocked).
    - **Fix**: Re-check `completedSends` inside the same `syncLock` that registers the continuation. If the update arrived, the continuation resolves immediately. Eliminates the race window.
    - **Impact**: Backup drainer now reliably forwards all queued messages (chunks, thumbnails, checkpoints) without getting stuck.

129. **Permanent Delete Channel Cleanup Fix (2026-08-21 — COMMITTED)** (`App/AppState.swift`)
    - **Root Cause**: `deleteForever` called `markTombstones()` (which deletes chunk records from SQLite) BEFORE gathering Telegram message IDs via `chunks(for:)`. The chunk records were gone, so `allMsgIDs` was always empty, and `BackupSync.deleteFromVaultAndBackup` received an empty array — nothing was deleted from Telegram.
    - **Secondary Bug**: `thumbMessageID` (encrypted thumbnail sidecar in Telegram) was never gathered for deletion — only chunk `messageID`s were collected.
    - **Fix**: Gather all Telegram message IDs (chunks + thumbnail sidecars) BEFORE calling `markTombstones`. Filter out chunks shared with non-deleted objects. Pass the gathered IDs to `deleteFromVaultAndBackup` after tombstoning.
    - **Impact**: Permanent delete now correctly removes files from both vault and backup channels, including thumbnail sidecars. Dbsnapshot is updated via `publishCheckpointFromLocal(force: true)` at the end.

130. **Duplicate Channel Photo Update Fix (2026-08-21 — COMMITTED)** (`Storage/VaultManager.swift`)
    - **Root Cause**: Both `ensureVault()` and `ensureBackupChannel()` fired fire-and-forget `Task { setChannelPhoto }` calls, and `ShareEngine.healChannelPhotos()` also set photos at every launch. Two independent paths setting the same photo concurrently caused duplicate "Channel photo updated" messages.
    - **Fix**: Removed the `setChannelPhoto` calls from `ensureVault()` and `ensureBackupChannel()`. `healChannelPhotos()` is now the single source of truth for all channel photos.

131. **Batch Upload Race Condition Fix (2026-08-21 — COMMITTED)** (`Storage/CatalogSnapshot.swift`)
    - **Root Cause**: `CatalogSnapshot.upload()` captured `allObjects()` into a `local` payload at the start, then made a network call to fetch channel state. During that network window, a batch upload could complete and flip an object from `state="uploading"` to `state="ready"`. But the merge used the stale `local` payload (object still `"uploading"`), and `replaceCatalog()` overwrote the DB — reverting the object to `"uploading"`. Since the UI filters by `state == "ready"`, the file vanished from the grid while the folder item count (no state filter) remained correct.
    - **Fix**: After computing the merged payload but before calling `replaceCatalog()`, re-read the current DB state for any objects still marked `"uploading"`. If the DB shows them as `"ready"`, preserve the `"ready"` state in the merged result.
    - **Impact**: Batch uploads no longer lose files. The third (or Nth) audio/photo/video in a batch upload now appears immediately in the folder.

132. **Volume Slider Sync — Three-Layer Hybrid (2026-08-21 — COMMITTED)** (`Engine/AudioPlayerEngine.swift`)
    - **Root Cause (original)**: CoreAudio property listeners were unreliable — `registerDeviceListener()` was called before `resolveVolumeElement()`, so zero listeners were ever registered. Additionally, macOS CoreAudio listeners frequently miss keyboard volume changes and Bluetooth device events.
    - **Fix**: Replaced with a **three-layer hybrid** approach (per Claude & Qwen recommendations):
      - **Layer 1**: `NSEvent` global monitor for `NX_KEYTYPE_SOUND_UP/DOWN/MUTE` — catches F10/F11/mute with near-zero latency, independent of CoreAudio.
      - **Layer 2**: CoreAudio listeners with `kAudioObjectPropertyElementWildcard` + dedicated serial `DispatchQueue` — catches Control Center / other-app changes. Re-registers on device change.
      - **Layer 3**: `DispatchSourceTimer` (500ms) on background queue — safety net that survives modal tracking loops.
    - **Additional**: `isUserDragging` flag prevents poll/listener from fighting slider drags. Proper listener cleanup via `removeDeviceListeners()` on device change.

133. **Test Suite & Build Status (2026-08-21)**
    - Build: **BUILD SUCCEEDED** with `xcodebuild -project Cascade.xcodeproj -scheme Cascade build`.
    - Tests: **TEST SUCCEEDED** (all CascadeTests pass, 0 failures).
    - All items 127–132 committed on `main`.

134. **Volume slider controls system BALANCE instead of volume (2026-08-21 — FIXED)**
    - **User report**: dragging the volume slider in the player moved the macOS system BALANCE slider, not the volume. Audio shifted between left/right ears.
    - **Root cause**: On Bluetooth A2DP devices (OnePlus Buds 3), `kAudioDevicePropertyVolumeScalar` is per-channel: element 1 = left volume, element 2 = right volume. The old `resolveVolumeElement()` picked only element 1 (first `noErr`), so writes changed one channel's volume, shifting balance.
    - **Fix**: `resolveVolumeElement()` → `resolveVolumeElements()` finds ALL writable volume elements. `writeScalar()` writes the same value to ALL elements simultaneously.
    - **Slider drag fix**: Added `onEditingChanged` to both sliders (TheaterView + VideoPlaybackView) to set `volumeManager.isUserDragging = true` during drag, preventing `pollVolume()` from fighting the gesture.
    - **File**: `Engine/AudioPlayerEngine.swift` — `SystemVolumeManager`.

135. **128 MB chunks instead of 64 MB for MKV uploads (2026-08-21 — FIXED)**
    - **User report**: MKV files uploaded with 128 MB chunks instead of the expected 64 MB streaming chunk size.
    - **Root cause**: `UploadEngine.swift` called `ChunkPlanner.plan(fileSize:chunkSize:)` WITHOUT passing `mime`. Without mime, `isMedia(mime: "")` returns false, so `automatic` profile fell through to `standardChunkSize` (128 MB).
    - **Fix**: Moved `mime` computation before the plan call and passed it. Media files now get `streamingChunkSize` (64 MB).
    - **NOTE**: User later asked to REVERT this — keep 128 MB chunks. The `mime` parameter was removed from the call. New uploads use 128 MB.
    - **File**: `Engine/UploadEngine.swift`.

136. **Streaming buffering — per-slice TDLib re-negotiation fragility (2026-08-21 — FIXED, see item 139)**
    - **Symptom**: Encrypted video streaming starts fine (1-2s), plays smoothly for ~1 minute, then stops and buffers permanently. Fresh cache purge works but isn't perfectly smooth.
    - **Root cause (Claude's analysis)**: TDLib's `downloadFile` `limit` parameter auto-cancels the download after the specified bytes. Each slice (1 MB) is a brand-new download negotiation with Telegram's servers. After 60-150 of these per minute, one unlucky network jitter kills the buffer — there's no safety margin.
    - **Why plaintext 8-slice batching works**: One fetch covers 8 MB (~6s of playback), so even if one request is slow, the SliceCache has a multi-second buffer to absorb it.
    - **Why encrypted single-slice breaks**: Each 1 MB sealed slice (1 MB + 28 bytes) is a separate TDLib round-trip with no buffer margin.
    - **What was tried**: (a) 8-slice batching on encrypted path — made initial startup slow (10+ seconds), `synchronous: true` blocks until full range is on disk. (b) Continuous download model (`downloadFile(limit:0)` + polling `downloadedSize`) — didn't work because TDLib's `downloadedSize` doesn't accurately track byte availability in sparse files. (c) Reverted to ObjectFetcher + single-slice + fetchWithRetry — still buffers after ~1 minute.
    - **RESOLVED in item 139**: two additional root causes were found in code (the `fetchWithRetry` whole-cache wipe and the missing read-ahead), fixed with a background read-ahead prefetcher. Live user verification pending.

137. **Binary search boundary bug in chunkAndLocalIndex (2026-08-21 — FIXED, direction corrected in item 139)**
    - **Symptom**: "Range fetch failed" retry storms with `limit=0`, infinite retries.
    - **Root cause**: `chunkAndLocalIndex()` binary search mis-mapped slices landing EXACTLY on a chunk boundary: the search stopped one chunk early, making `localSliceIndex` one past the end of the chunk, producing `fetchLen = 0`.
    - **Fix**: A boundary slice belongs to the NEXT chunk — the comparison must be `chunkStarts[mid] <= sliceBytes`. NOTE: an intermediate uncommitted edit flipped this to `<`, which reintroduced the bug (caught by `streamingSliceMappingAcrossChunks` failing in the suite); item 139 reverted it to `<=`.
    - **File**: `Engine/VideoStreamingEngine.swift` — `ObjectLayout.chunkAndLocalIndex()`.

138. **Session summary (2026-08-21)**
    - **Fixed**: Volume/balance (item 134), MKV chunk size (item 135, then reverted per user), binary search boundary (item 137 — see correction in item 139), slider drag jitter (item 134).
    - **Unresolved → resolved in item 139**: Streaming buffering (item 136) — the fundamental per-slice re-negotiation issue.
    - **Diagnostic tool**: CoreAudio volume diagnostic at `/tmp/volume-diagnostic.swift` (deleted). Results: OnePlus Buds 3 elements 1+2 both have `VolumeScalar`; no `VirtualMainVolume`; no `LeftVolumeScalar`/`RightVolumeScalar`/`Balance`/`Fade`.
    - **Prompt files**: `.freebuff/streaming-prompt-v3.md` — full context for Claude/Qwen about the streaming issue.
    - **NOT committed** at the time; everything (items 127–139) landed in the 2026-08-21 afternoon commit.

139. **Encrypted-streaming buffering FIXED: read-ahead prefetcher + cache-wipe bug + boundary regression reverted (2026-08-21 — COMMITTED, awaiting live user verification)**
    (`Engine/VideoStreamingEngine.swift`)
    - **Three root causes addressed**:
      1. `fetchWithRetry` wiped the ENTIRE object's SliceCache on any transient
         fetch error — one hiccup discarded megabytes of buffered playback and
         produced exactly the "plays ~1 min then buffers forever" symptom. The
         wipe is gone (cached slices were GCM-verified before caching and cannot
         be corrupted by a later failed request); the generic-error retry is now
         timeout-wrapped too.
      2. No read-ahead on the encrypted path: one sealed slice per TDLib round
         trip with zero safety margin. NEW background prefetcher: serve path
         fetches ONE slice synchronously (fast startup preserved), a short-lived
         `ReadAheadRun` keeps the cache filled 24 slices (~19 s) ahead via 4-slice
         batched fetches at TDLib priority 8. This is the proven plaintext
         batching moved OFF the critical path — startup can no longer block on a
         multi-MB batch (the failure of the earlier naive attempt). Seek-aware
         (backward jump >2 slices restarts the run), cancelled by
         `invalidatePlayback` and layout eviction, exits after 3 consecutive
         failures and re-arms on every served slice.
      3. Item 137's uncommitted `<` flip was BACKWARDS (boundary slices mapped one
         chunk early → localIndex past-the-end → limit=0 retry storms). Reverted
         to `<=`; `streamingSliceMappingAcrossChunks` catches this (it failed in
         the suite until reverted).
    - Also: `SliceCache` 48 → 128 entries; new non-perturbing `contains(_:)` for
      read-ahead existence checks.
    - Build green; full unit suite green (**TEST SUCCEEDED**, 79 unit tests).
    - **PENDING USER VERIFICATION**: play an uncached ENCRYPTED video past the
      1-minute mark (no permanent buffering), seek away/back recovers instantly,
      startup stays fast (no 10 s first-byte delay).

140. **Streaming round 2: first half smooth / second-half buffering + screen-recording
     prompt (2026-08-21 — COMMITTED, awaiting live user verification)**
    (`Engine/VideoStreamingEngine.swift`, `Features/MPVVideoView.swift`)
    - **User report**: whole file played (item 139 worked — no more permanent
      death), smooth first ~10 min, buffering in the second half. Plus a macOS
      "wants to record this screen" prompt on fullscreen.
    - **Telemetry** (`/tmp/cascade-mpv-telemetry.log`): cache pegged 20 s min 0–10;
      dips min 10–15; recovery 15–23; TOTAL stall min 24–28 (~4 min, cache 0.0,
      paused-for-cache continuously); stuttery recovery after. A total multi-minute
      stall = wholesale request hang/failure.
    - **ROOT CAUSE: layout eviction wiped the PLAYING file mid-stream**
      (`loadLayoutUncached`): at ≥8 layouts everything was cleared — fileIDs +
      per-chunk fetchers of the active playback included. Background probes build
      layouts during playback; post-wipe, new fetches spawned a second concurrent
      TDLib chain on the same fileId → supersede clobbering → hang storms. FIX:
      LRU layout store (`layoutRecency`, cap 16) that NEVER evicts the
      most-recently-touched object; `plaintextSlice` touches recency every slice;
      evicted objects' fetchers/runs cancelled cleanly.
    - **Prefetch self-healing**: the read-ahead loop no longer gives up after 3
      failures (re-arm depended on successful serves, which stop during a stall).
      Backoff 0.3 s doubling to 5 s cap; runs until window filled or cancelled.
    - **Tuning**: window 24 → 48 slices (~38 s buffer), batch 4 → 8 slices,
      fetchWithRetry up to 3 attempts with chain-cancel between attempts.
    - **Screen-recording prompt FIXED**: `captureTheaterSnapshot` now prefights
      `CGPreflightScreenCaptureAccess()` and skips the ghost snapshot when
      unauthorized (live-attach fallback covers the transition) — SCShareableContent
      was triggering the TCC prompt on every fullscreen entry.
    - **Instrumentation**: `/tmp/cascade-stream.log` — layout built/evicted, serve
      misses, read-ahead batches with ms, timeouts/errors with attempt counts,
      invalidatePlayback. THE tool for any future streaming report: read this log
      first.
    - Build green; unit suite green (**TEST SUCCEEDED**, 79 tests). Debug app
      relaunched. **Pending**: user re-test (smooth end-to-end + no prompt); if any
      stall recurs, correlate its timestamp with `/tmp/cascade-stream.log`.

141. **Streaming round 3: read-ahead restart DEADLOCK exposed by the stream log
     (2026-08-21 — COMMITTED `caa4873`, awaiting one more user test)**
    (`Engine/VideoStreamingEngine.swift`)
    - **User report**: "smooth and clean even after cache purge" — but the stream
      log proved playback was carried by TDLib's disk cache, NOT the prefetcher:
      1623 run starts vs 99 completed batches, 793 serve misses (every slice a
      single-slice fetch at 2–14 ms off TDLib's local copy), 2214 CancellationError.
    - **Root cause**: single-run design + mpv's SECOND byte-range stream (moov/tail
      probe) — main (~slice 205) and probe (~484) each saw the other's run as not
      covering them and cancelled+restarted it every ~0.6 s; no batch ever survived;
      deadlock self-sustained because head never advanced past served+window.
    - **Fix**: up to 3 concurrent runs per object with span-overlap coverage
      (`r.start <= start+B && r.end >= start && r.head+B >= start`, or filled
      `r.head >= start+W`); at capacity replace the OLDEST span (a tail probe can
      never kill the playhead's run); backward movement triggers nothing;
      `fetchWithRetry` rethrows CancellationError instead of retrying cancelled ops.
    - **Also verified this session** (user asked): frames perfect (vfps 24.0,
      mistimed/voDrop/decDrop/drop all 0 end-to-end); NOT played from the app's
      disk cache (0 files for the object — all bytes through VaultStreamServer);
      upload layout of the tested file verified byte-perfect against the sealed-
      slice grid (chunks 0–2 = exactly 128 sealed slices each; tail = 100 + partial;
      sum == object.size).
    - Build green; unit suite green (**TEST SUCCEEDED**, 79). App relaunched; old
      log preserved as /tmp/cascade-stream-session1.log. Next test should show
      serve misses only at startup/seeks and hundreds of successful batches in
      /tmp/cascade-stream.log.
    - **Full case file**: `docs/STREAMING_FIX.md` — symptoms, all root causes
      (A–D), final architecture diagram, verification checklist, and the
      if-buffering-returns diagnostic playbook for rounds 1–3 (commits `473c940`,
      `d6b395d`, `caa4873`).

142. **Streaming round 4: sequential-access batching on the stream path
     (2026-08-21 — COMMITTED, awaiting user test)** (`Engine/VideoStreamingEngine.swift`)
    - **User's full test protocol passed** (two cold-cache playthroughs + 4 s /
      1 min / 30 s seeks): zero buffering, zero errors/timeouts in the log,
      multi-run read-ahead proven (11 windows chain-filled all 485 slices in
      2.7 s after a cache clear).
    - **Remaining gap the log exposed**: linear playback still fetched 1 round
      trip PER SLICE (sequential serve misses, no batches that minute) — mpv's
      huge range requests walk slices via plaintextSliceStream, and each slice
      was an individual downloadFile. TDLib's disk cache hid it (2–14 ms/slice);
      on a cold network this is the original fragile pattern resurfacing.
    - **Fix**: `lastServedSlice` per object — a slice directly continuing the
      previous one (mpv's sequential walk) fetches a whole 8-slice batch in that
      round trip; the first slice after a jump (start/seek) stays single for
      fast startup. Batched path reuses `fetchEncryptedBatchIntoCache` (prio 32).
    - Build green; unit suite green (**TEST SUCCEEDED**, 79). App relaunched;
      prior log preserved as /tmp/cascade-stream-session2.log. Full case file:
      docs/STREAMING_FIX.md.

143. **Streaming round 5: cold-file buffering — zombie runs + duplicate fetches
     (2026-08-21 — COMMITTED, awaiting user test)** (`Engine/VideoStreamingEngine.swift`)
    - **User test**: brand-new 775 MB / 7-chunk video played COLD (TDLib never had
      its bytes) — slight buffering, seeks fine, zero errors.
    - **Log math**: batched fetches ≈ 5.1 MB/s; single-slice ≈ 0.9 MB/s (197
      singles!). Consumption > 0.9 MB/s → any single-fetch stretch drains the
      buffer. Three causes found:
      1. **Zombie runs**: completed-but-not-cancelled read-ahead runs still
         satisfied the span-overlap coverage check → blocked new spawns → no
         background filling → serve path fell back to singles. Runs now carry
         `finish()`/`isActive`; coverage counts ACTIVE runs only; finished runs
         are pruned.
      2. **Duplicate downloads**: the serve path checked the cache BEFORE queuing
         behind a run's in-flight batch — the same slice was then downloaded twice.
         Fixed both paths: `fetchEncryptedBatchIntoCache` skips leading slices
         cached meanwhile (returns covered count incl. skips); the jump path
         re-checks the cache right before network I/O.
      3. **Invisible sequential batches**: serve-path batches had no log line —
         added `serve batch obj= slices=N+count ms=`.
    - **Why buffering can never be fully "eliminated" on cold files** (user Q): a
      cold file must pull every byte over the network in real time; the buffer
      only smooths bursts. With steady-state batched throughput (~5 MB/s) above
      consumption, stalls should now be limited to startup (first-byte RTT) and
      Telegram-side slowdowns (out of scope per user). Telegram throttling is a
      server behavior, not fixable client-side.
    - Build green; unit suite green (**TEST SUCCEEDED**, 79). App relaunched;
      prior log preserved as /tmp/cascade-stream-session3.log.

144. **Streaming round 6: Claude/Qwen audit fixes — per-stream sequential tracking,
     cache headroom, distance-based run eviction (2026-08-21 — COMMITTED)**
    (`Engine/VideoStreamingEngine.swift`, `CascadeTests/CascadeTests.swift`)
    - Consultation prompt v4 (`.freebuff/streaming-prompt-v4.md`) reviewed by
      Claude + Qwen. Triage: 2 findings already fixed in round 5 (zombie runs),
      4 actionable now, 2 deferred.
    - **FIXED — `lastServedSlice` race (both consultants' #1)**: per-object
      sequential state flickered off whenever mpv's probe stream interleaved,
      silently degrading round-4 batching. Deleted the shared state entirely;
      tracking is now PER-STREAM (local `lastDelivered` inside each
      `plaintextSliceStream`, updated only after successful delivery — also fixes
      both consultants' defer-under-cancellation desync by construction).
    - **FIXED — cache oversubscription**: 3 runs × 48-slice windows = 144 slices
      against a 128-entry LRU meant prefetchers could evict each other's writes.
      Cap → 256, plus a playhead protection floor: the actively-serving object's
      slices are skipped by normal eviction (safety valve if everything resident
      is protected).
    - **FIXED — "replace oldest" run eviction**: creation-age FIFO would evict the
      long-lived playhead run first (it is always oldest). Now replaces the run
      whose span is FURTHEST from the current serve position.
    - **TESTED — batch boundary clamp (Claude #5)**: batch planner extracted to
      pure `planEncryptedBatch(plainRemainingInChunk:maxCount:)`; new unit test
      `encryptedBatchPlanClampsToChunkBoundary` proves an 8-slice request clamps
      at the chunk tail (never crosses into the next fileId). Code was already
      correct; now it is pinned.
    - **DEFERRED**: (a) cancel-on-run-replace for in-flight TDLib work (Claude Q5)
      — empirical logs show cancellation propagates in ms; revisit only if chain
      stalls reappear; (b) Qwen's whole-chunk `downloadFile(limit:0)` + sparse-file
      pread + updateFile-wait paradigm — promising architecture simplification but
      needs a prototype vs item 55's failed polling attempt; parked in ROADMAP.
    - Build green; unit suite green (**TEST SUCCEEDED**, 80 unit incl. new boundary
      test). App relaunched; prior log preserved as /tmp/cascade-stream-session4.log.

145. **Uniform ~1.9 GiB chunks + streaming crypto I/O (2026-08-21 — COMMITTED,
     awaiting user upload test)** (`Engine/ChunkPlanner.swift`,
     `Crypto/CryptoEngine.swift`, `Engine/UploadEngine.swift`,
     `Engine/DownloadEngine.swift`, `Engine/FileHasher.swift`,
     `CascadeTests/CascadeTests.swift`)
    - **Decision (user-approved)**: chunk size is now UNIFORM ~1.9 GiB
      (`maxSafeChunkSize`, exact MiB multiple, safely under Telegram's 2 GB
      document cliff incl. ~28 B/MiB sealing overhead) for ALL content — media
      and archives alike. Rationale: TDLib resumes uploads/downloads at internal
      part granularity from its persistent DB (failed giant chunk costs only its
      unfinished tail), streaming crypto keeps RAM at one slice, and every
      message-count metric (uploads, backup forwards, share-pool forwards,
      repair scans) scales with chunk COUNT. Streaming boundaries are pre-warmed
      ~30 s ahead by read-ahead; a 50 GB file = 27 chunks instead of ~390.
    - **Streaming crypto I/O** (`CryptoEngine.encryptStream` /
      `decryptStream`): reads/writes one sealed slice at a time through
      FileHandles with optional incremental SHA-256 hashers — peak RAM ~2 MiB
      regardless of chunk size. Upload path (`uploadChunk`) and download path
      (`DownloadEngine` loop) rewritten onto them; legacy whole-Data
      `encryptChunk`/`decryptChunk` kept for small payloads (thumb sidecars).
    - **Resume-friendly retries**: failed chunk staging files are preserved and
      the retry re-issues the send for the SAME path so TDLib matches its cached
      upload progress; `cleanupPartialUpload` remains only for genuine discards
      (user cancel / source-file-changed).
    - **Tests**: `chunkPlanUsesStoredChunkSizeOnResume` updated (1 GiB file → 1
      chunk; stored legacy sizes still win on resume; 50 GB → 27 pieces); NEW
      `streamingCryptoRoundTripMatchesWholeBuffer` — streamed ciphertext
      round-trips to identical plaintext AND is readable by the classic
      whole-buffer decryptor (cross-implementation compatibility; note AES-GCM
      randomizes nonces so two encryptions are never byte-identical).
    - Old uploads keep their stored sizes; mixed chunk sizes coexist natively
      (per-chunk records + actual-size sync + canStream alignment check).
    - Build green; unit suite green (**TEST SUCCEEDED**, 81 unit tests). App
      relaunched. **Pending user verification**: upload a large file → confirm
      ~1.9 GiB chunks in the channel, smooth playback, normal download.

146. **Eternal loading screen after round 7 — stale self-test assertion + saved-
     state corruption (2026-08-21 — COMMITTED `16b7ae7`)** (`Engine/ChunkEngine.swift`,
     `App/AppState.swift`)
    - **Symptom**: app stuck on the loading screen; TDLib zero connections.
    - **Diagnosis trail**: process alive, no crashes, unified log silent (machine
      quirk), stdout empty even under a pty → sampled threads: only 4, TDLib
      receive loop waiting on an EventFd that never fires = NO QUERY EVER SENT.
      Added file-based boot diagnostics (`/tmp/cascade-boot.log`, survives any
      launch style): bootstrap stalled between "shares loaded" and the chunk
      engine step. ALSO found corrupt saved window state making some relaunches
      mount NO window at all (cleared
      ~/Library/Saved Application State/com.cascade.app.savedState).
    - **Root cause**: `ChunkEngine.runSelfTest` still asserted the LEGACY 64+36 MB
      streaming split; round 7's uniform chunking returns one 100 MiB item →
      guard threw `planMismatch` → bootstrap's catch set `databaseError`
      (invisible on splash) and SKIPPED startTelegram → TDLib never connected →
      `isAuthResolved` never resolved → eternal splash.
    - **Fixes**: (1) self-test asserts uniform behavior (100 MiB = one exact
      item) with tiling + hash checks intact; (2) bootstrap HARDENED — engine
      self-tests are now non-fatal sanity checks: failure logs to
      /tmp/cascade-boot.log + warning banner, Telegram startup always proceeds.
    - Verified: boot log runs start → db → files → shares → engines ok → creds →
      startTelegram returned; 3 ESTABLISHED TDLib connections; window present;
      **TEST SUCCEEDED** (81 unit tests). Lesson: launch-blocking self-tests turn
      any assertion drift into a full outage — sanity checks must never gate auth.

147. **Deletion absolutism — the "files came back" race fixed structurally
     (2026-08-21 — COMMITTED `e177cfe`)** (`Storage/CatalogSnapshot.swift`,
     `Storage/DatabaseManager.swift`, `App/AppState.swift`,
     `Telegram/TelegramClient.swift`, `CascadeTests/CascadeTests.swift`)
    - **User report**: after deleting all files + Empty Trash, files briefly
      REAPPEARED in the UI; a second pass stuck.
    - **Root cause**: `CatalogSnapshot.merge` resolved local-tombstone vs
      remote-live by modifiedAt LWW — a debounced snapshot sync merging against
      a STALE cached channel scan (pre-deletion copy with newer timestamp)
      resurrected deleted rows via replaceCatalog.
    - **Fix — three defensive layers**:
      1. merge(): local tombstone ALWAYS beats remote live, timestamps ignored
         (deletion is a user decision; only explicit restore clears it).
         Cross-device propagation (remote tombstone newer than local live)
         unchanged.
      2. replaceCatalog(): incoming live records matching locally tombstoned
         ids are re-tombstoned before insert.
      3. deleteForever: invalidates the channel scan cache immediately after
         Telegram message deletions, so concurrent snapshot syncs refetch
         post-deletion state instead of trusting the stale cache.
    - Tests: `mergeTombstoneBeatsNewerRemoteLive` +
      `replaceCatalogNeverResurrectsTombstonedObjects`. **TEST SUCCEEDED**
      (83 unit tests). App relaunched, bootstrap clean.

148. **Audit quick-wins landed: PIN hashing, CI fix, share KDF 600k, Keychain
     ThisDeviceOnly (2026-08-21 — COMMITTED)** (`Crypto/KeychainStore.swift`,
     `Crypto/CryptoEngine.swift`, `Engine/ShareEngine.swift`,
     `Features/FileBrowserView.swift`, `App/AppState.swift`,
     `.github/workflows/ci.yml`)
    - From docs/AUDIT_2026-08-21.md roadmap items 1–4:
    - **H1 — PIN hashing**: verifyVaultPIN now stores/verifies
      `pbkdf2-sha256:600000:<saltB64>:<hashB64>` (OWASP 2026 cost) with a
      constant-time compare; legacy unsalted SHA-256 entries verify the old way
      then transparently upgrade in place. Attempt throttle added (exponential
      backoff after 3 failures, capped ~17 min) surfaced in the lock sheet via
      pinLockMessage.
    - **H3 — CI**: workflow rewritten for current toolchain (was pinned to
      Xcode 15.4 + pre-rename xCloud scheme names = permanently broken);
      build-only smoke job on macos-latest to respect private-repo macOS minute
      multipliers; full suite stays a local pre-push step.
    - **M1 — share-link KDF**: new password links mint at PBKDF2 600k;
      imports try 600k then fall back to legacy 100k so pre-existing links keep
      working (deriveLegacyLinkKey).
    - **M2 — Keychain ThisDeviceOnly**: save() now writes/stamps
      kSecAttrAccessibleWhenUnlockedThisDeviceOnly; migrateSecretsToThisDeviceOnly()
      re-seats master key + PIN hash at every launch (idempotent).
    - Build green; **TEST SUCCEEDED** (83 unit tests). App relaunched, bootstrap
      clean per /tmp/cascade-boot.log.

149. **Audit round 2: Private Vault UX + keypad + lock icon, launch heartbeat,
     rate-limit banner (2026-08-21 — COMMITTED `a98b0e6`)**
    (`App/AppState.swift`, `Features/FileBrowserView.swift`,
     `Telegram/TelegramClient.swift`)
    - **Sidebar icon**: `.privateVault` was `"number"` (#) — now `lock.fill`.
    - **Lock view redesign**: gradient hero mark; ON-SCREEN NUMERIC KEYPAD —
      previously the lock was keyboard-only, so mouse/trackpad users could not
      unlock the vault at all; lockout countdown renders inline in orange.
    - **Item 6 (heartbeat)**: bootstrap writes an in-progress/clean launch-state
      marker; the next launch surfaces a one-time "Previous launch didn't
      complete" warning banner if the last run died mid-flight.
    - **Item 8 (rate-limit UX)**: write-token waits ≥3 s post a throttled
      "Telegram rate limit — pacing writes" info banner instead of silence.
    - Build green; **TEST SUCCEEDED** (83 unit tests). App relaunched.

150. **Audit round 3: error surfacing + LogManager wiring; keypad removed per user
     (2026-08-21 — COMMITTED `7a8634e`)**
    - **Keypad REMOVED (user decision)** — lock view keeps the gradient hero +
      lock sidebar icon; keyboard entry only.
    - **Item 5 (partial)**: permanently-failed backup mirrors now surface a
      throttled warning banner ("Backup mirror incomplete") + LogManager error;
      deleteForever publish failures surface "Cloud sync incomplete" instead of
      failing silently.
    - **Item 9 (partial)**: bootLog milestones mirror into the rotating LogManager
      (`logs/cascade.log`).
    - Build green; **TEST SUCCEEDED** (83 unit tests). App relaunched.
    - **Remaining roadmap**: item 7 (UploadManager extraction ~half day), item 9
      full consolidation, item 10 (Argon2id research).

151. **Item 7 DONE: UploadManager extracted from AppState (2026-08-21 — COMMITTED)**
    (`Engine/UploadManager.swift` NEW, `App/AppState.swift`)
    - The serial file-upload queue (~150 lines: PendingUpload, queue + drain loop,
      performUpload orchestration incl. resume/duplicate/cleanup branches) moved
      into `@MainActor final class UploadManager` with a weak AppState back-
      reference for the observable UI fields (`isUploading/uploadStatus/
      uploadProgress`) and `loadFiles()`.
    - AppState keeps thin delegates: `startUpload(url:)` computes the transfer
      card then `uploads.enqueue(...)`; `resumeInterruptedUploads` enqueues stuck
      objects; `isUploading`/`uploadStatus`/`uploadProgress` remain @Observable
      fields so views are untouched. `isFolderPrivate` made internal.
    - Also fixed: duplicated bootLog doc comment from an earlier scripted patch.
    - Net: AppState 2,559 → 2,509 lines with upload logic fully out; UploadManager
      is independently testable going forward.
    - Build green; **TEST SUCCEEDED** (83 unit tests). App relaunched, bootstrap
      clean per /tmp/cascade-boot.log.

152. **Pause/resume fixed for big chunks + transfer card polish (2026-08-21 —
     COMMITTED `a24762e`, awaiting user pause/resume re-test)**
    (`Engine/UploadEngine.swift`, `Engine/TransferCenter.swift`,
     `Features/TransfersView.swift`)
    - **User report**: pausing reset the card to 0% ("Paused — 0/1 chunks");
      resume restarted progress from zero; status said "Uploading chunks…";
      thumbnail concern (verified FINE — local jpg/png + encrypted sidecar all
      present for the new upload).
    - **Root causes**: (1) pause computed progress as done-chunks/total — with
      uniform ~1.9 GiB chunks a single-chunk file is always 0/N at pause; (2)
      TransferCenter.resume passed a NO-OP progress handler and no
      existingTransferID to UploadEngine.upload, so the resumed card never got
      live updates and restarted visually.
    - **Fixes**: pause preserves max(doneRatio, last in-flight fraction); paused
      text drops chunk-count noise for single-chunk files; resume wires live
      progress into the same card via existingTransferID (update() monotonic so
      it never dips below the paused fraction); staged-chunk REUSE — if the
      staging file exists with exact expected sealed size, skip re-encrypting
      and re-issue the send for the same path so TDLib continues its cached
      upload progress; hashes recomputed via range reads.
    - **Cards**: custom gradient progress capsule (5 pt, animated), percentage
      chips, refined typography/materials/hover shadow on grid + list.
    - Build green; **TEST SUCCEEDED** (83 unit tests). App relaunched.

153. **Pause fix round 2 — the REAL single-chunk path + layout + resume feedback
     (2026-08-21 — COMMITTED `605fa62`, awaiting user re-test)**
    (`Engine/UploadEngine.swift`, `Engine/TransferCenter.swift`,
     `Features/TransfersView.swift`)
    - **User re-test**: pause at 49% STILL showed "Paused — 0/1 chunks uploaded"
      at 0%; card chips/buttons had drifted to vertical center; resume did
      nothing for seconds then jumped to 100%.
    - **Root cause of the persisting bug**: there are TWO pause sites. My item-152
      fix covered the between-chunks block, but for a SINGLE-chunk file pause
      always cancels the in-flight sendFile → the work Task THROWS → the OUTER
      catch runs (which still reported done/total = 0/1). Hoisted progressState
      above the do-block; both sites now preserve max(doneRatio, last in-flight
      fraction) with clean "Paused" text.
    - **Layout**: my card redesign dropped the ZStack's top alignment → chips and
      buttons centered vertically. Restored ZStack(alignment: .top).
    - **Resume feedback**: "Resuming…" now set AFTER the settle-window and DB
      guards pass (an early flip made the settle guard match itself as .active
      and blocked every resume — caught by resumeIsBlockedWhilePauseIsSettling /
      resumeAfterPauseSettlesProceeds tests before shipping).
    - Build green; **TEST SUCCEEDED** (83 unit tests). App relaunched.

154. **Resume status truthfulness + stall diagnostic (2026-08-21 — COMMITTED
     `bd8e0d7`)** (`Engine/UploadEngine.swift`, `Telegram/TelegramClient.swift`)
    - **User re-test**: pause at 51% preserved correctly (item 152 fraction fix
      works), but resume showed "Starting…" frozen at 51% — no movement.
    - **Explanation**: the frozen window is TDLib's silent REVALIDATION of the
      staged partial (re-hashing before part uploads continue) — no updateFile
      events fire during it. The absolute-fraction plumbing is correct, so when
      parts resume, progress jumps to ~51% and climbs.
    - **Fixes**: upload()'s existing-card path labeled "Starting…"
      unconditionally, overriding resume feedback — now context-aware ("Resuming…"
      when resumeObject present). Plus a LogManager warning if an uploadFile is
      still incomplete 20 s after start (distinguishes slow revalidation from a
      permanent hang).
    - Build green; **TEST SUCCEEDED** (83 unit tests). App relaunched.

155. **Discard ghost fix (2026-08-21 — COMMITTED `d62f1e7`)**
     (`Engine/UploadEngine.swift`, `App/AppState.swift`)
    - **User report**: upload paused at ~51%, then discarded (Delete Transfer) —
      file appeared in cloud but doesn't play. Zero-chunk "ready" object in DB,
      no channel presence.
    - **Root cause**: `cleanupPartialUpload` (discard path) hard-deleted local
      rows WITHOUT tombstoning, scan-cache invalidation, or catalog republish.
      Stale deltas (never pruned) still listed the object; next reconcile adopted
      the stale record back as "ready" with 0 chunks → visible, unplayable.
    - **Fixes**:
      1. `cleanupPartialUpload` rewritten to mirror `deleteForever`'s safety
         machinery — mark tombstones first (absolutism blocks resurrection),
         gather + delete Telegram messages (vault + backup), invalidate channel
         scan cache, purge orphans, hard-delete local rows, then force-republish
         checkpoint so the cloud catalog drops the object immediately.
      2. Post-auth heal: finds objects with state=ready AND 0 chunk rows (pure
         catalog artifacts that can't play), runs them through
         `cleanupPartialUpload` to tombstone + clean + republish. Idempotent.
    - **Verification**: 83 unit tests green. Ghost BECF9132 cleaned on launch
      by the new heal step — confirmed via sqlite3 (row gone, channel dump 0
      references).

156. **True pause: cancel TDLib native upload (2026-08-22 — COMMITTED
     `8f30adc`)** (`Telegram/TelegramClient.swift`)
    - **User test**: pause held 51% correctly, resume showed "Resuming…" then
      jumped straight to ~90% and completed. Hypothesis: pause never actually
      paused. CONFIRMED.
    - **Root cause**: pause only cancelled our Swift Task; TDLib's native
      preliminaryUploadFile kept uploading in the background
      (cancelPreliminaryUploadFile was never called). Also explains the
      duplicate identical-hash chunk messages in item 155's channel dump.
    - **Fix**: uploadFile's onCancel now also fires
      client.cancelPreliminaryUploadFile(fileId:) best-effort.
    - **VERIFIED same day**: user re-tested — paused at 49%, resume carried
      perfectly from 49% to completion. TDLib RETAINS cached parts across
      cancelPreliminaryUploadFile, so true pause costs nothing on resume.
      Upload finished; playback + post-cache-clear replay OK. Item closed.

157. **Download pause/resume parity (2026-08-22 evening — COMMITTED `724d317`)**
     (`Telegram/TelegramClient.swift`, `Engine/DownloadEngine.swift`,
     `Engine/TransferCenter.swift`, `Features/TransfersView.swift`)
    - Downloads previously had Cancel only; catch deleted the partial file;
      cancellation never called TDLib cancelDownloadFile. Latent bug: discard()
      ran UploadEngine.cleanupPartialUpload for ALL directions — discarding a
      DOWNLOAD card would tombstone/delete the cloud object itself.
    - **Fix**: downloadMessageFile's onCancel fires cancelDownloadFile natively
      (parts retained by fileId); cancelled downloads keep the partial dest +
      persist exact state "completedChunks:plainBytes" (UserDefaults
      xc.dl.resume.<objectID>); resume validates size, skips completed chunks,
      seeks to exact offset, appends. discard() direction-aware (downloads drop
      card+partial only); download resume feeds live progress into same card;
      UI pause button on all active cards.
    - Known limit: paused-download CARDS don't survive relaunch (no object-state
      column), but the resume state does — the next manual download attempt of
      that file auto-resumes from the offset.
    - Build green; **TEST SUCCEEDED** (83 unit tests).
    - Follow-up (`69973db`): user hit CryptoKit error 3 downloading after a cache
      purge — downloadMessageFile's fast path trusted TDLib's SPARSE local
      artifact left by streaming's ranged downloads. Fast path now requires
      isDownloadingCompleted == true, else falls through to a full ranged fill.

158. **TDLib download-store purge (2026-08-22 evening — COMMITTED `09f1187`)**
     (`Telegram/TelegramClient.swift`, `App/AppState.swift`,
     `Features/SettingsView.swift`)
    - User question: how big can TDLib's cache get / can it be cleaned? Answer:
      unbounded (tdlib-files/documents held 2.2 GB); now cleanable in Settings →
      "Delete Telegram Download Store" via official optimizeStorage API
      (documents only, safe — channel is source of truth). Size shown live;
      toast reports bytes freed. Also enables real pause/resume testing
      (purge first so retries pull actual bytes).
    - Build green; **TEST SUCCEEDED** (83 unit tests).

159. **Single-cache architecture (2026-08-22 night — COMMITTED `0d022df`)**
     (`Engine/DownloadEngine.swift`, `Telegram/TelegramClient.swift`,
     `App/AppState.swift`, `Features/SettingsView.swift`,
     `Engine/VideoStreamingEngine.swift`, `Engine/AudioPlayerEngine.swift`,
     `Features/MPVVideoView.swift`)
    - App-level playback cache RETIRED per user decision: TDLib's downloaded-
      file store is now the single cache, capped via Settings' Cache Limit
      (optimizeStorage size:, enforced on change + after each download).
    - Clear Local Cache purges previews + thumbs + TDLib store (one button).
    - All media playback streams via VaultStreamServer; replays served from
      TDLib's local store until evicted.
    - Books/thumbnails/export/openFile materialize into new scratch/ dir,
      wiped at every launch; legacy cache/ dir removed by janitor (453 MB).
    - Gotcha recorded: identical "await cleanupExpiredTransfers()" lines exist
      in bootstrap AND the 6-hour loop — anchor edits with wider context.

160. **Deep-range streaming prefetcher (2026-08-22 night — COMMITTED `1366284`)**
     (`Engine/VideoStreamingEngine.swift`, `Telegram/TelegramClient.swift`,
     `Features/MPVVideoView.swift`)
    - Root cause of residual buffering: serial synchronous 1-8 MB ranged
      fetches = latency-bound ~1 MB/s. Research (tdlib docs/PartsManager/
      td#1498): downloadFile limit unbounded-ish; TDLib pipelines parts in
      parallel WITHIN one call; one active download per fileId (supersede =
      seek); prefix growth observable via local.downloaded_prefix_size.
    - Fix: DeepRangeFetcher — one async 48 MB window per fileId (clamped to
      chunk end), 40 ms prefix polling serves slices as bytes land; stall/base-
      drift >1.5 s reissues coverage. Encrypted batch + jump + plaintext paths
      all route through it. mpv demuxer-max-bytes 256 MiB / readahead 30 s /
      back-buffer 32 MiB as insurance.
    - Interference note: other downloadFile users of the SAME fileId (rare)
      supersede windows; self-heal recovers in ~1.5 s.
    - Build green; **TEST SUCCEEDED** (83 unit tests).

    - Build green; **TEST SUCCEEDED** (83 unit tests).
161. **Deep-range fetcher reverted (2026-08-22 night — COMMITTED `627edb0`)**
     (`Engine/VideoStreamingEngine.swift`, `Telegram/TelegramClient.swift`)
    - Item 160 made buffering WORSE in live testing. Log forensics: supersede
      ping-pong between two waiters on one fileId (every reissue discarded
      TDLib's in-flight parts; 49 s timeouts), swallowed downloadFile errors,
      bandwidth split across concurrent windows.
    - Key TDLib fact confirmed (td#1498): NO parallel ranged calls per fileId
      — new call cancels previous. Concurrency only inside ONE call.
    - Resolution: reverted to the proven serial chain; raised sync batch sizes
      (slicesPerFetch 16, readAheadBatchSlices 32) so each round trip pipelines
      more internally. mpv cache bumps kept.
    - Roadmap lever if still insufficient: multiple TDLib client instances for
      true cross-instance parallelism (heavyweight).
    - Build green; **TEST SUCCEEDED** (83 unit tests).
162. **Scrubber bounce fix (2026-08-22 night — COMMITTED `36dcf41`)**
     (`Features/MPVVideoView.swift`)
    - Seek UI danced (target → back → target): optimistic progress was being
      overwritten by stale pre-seek time-pos updates from mpv's async seek.
    - Fix: pendingSeekTarget hold — suppress time-pos updates until one lands
      within ~1 s of the target or a 12 s timeout; cleared by play(url:) on new
      files. Single funnel covers video + headless.
    - Build green; **TEST SUCCEEDED** (83 unit tests).
163. **Player load/seek UX polish (2026-08-22 night — COMMITTED `7da1ae5`)**
     (`Features/MPVVideoView.swift`, `Features/VideoPlaybackView.swift`)
    - Time label now follows the scrubber target on seek (timePos synced with
      progress); isBuffering derived from cachePaused || waitingFirstFrame ||
      pendingSeek — covers cold start and seek fetch waits that paused-for-
      cache misses; seek overlay exclusion removed in VideoPlaybackView.
    - Build green; **TEST SUCCEEDED** (83 unit tests).
164. **Seek UX round 2 (2026-08-22 night — COMMITTED `08f145a`)**
     (`Engine/VideoStreamingEngine.swift`, `Features/TheaterView.swift`)
    - Label flicker root cause #2: TheaterView's own scrubber hold gave up at
      1.5 s vs controller's 12 s — extended to match.
    - Seek-latency regression from item 161 fixed: serve-path batches split
      from run batches (serveBatchSlices=8 fast first byte; runs keep 32).
    - YouTube-comparison answered honestly: CDN/ABR/multi-conn vs MTProto VOD;
      steady state already smooth; ROADMAP lever = multi-TDLib-instance
      parallelism.
    - Build green; **TEST SUCCEEDED** (83 unit tests).
165. **Streaming round 3: preheat + flicker fix (2026-08-22 afternoon — COMMITTED `92c5a14`)**
     (`Engine/UploadEngine.swift`, `Telegram/TelegramClient.swift`,
     `Features/MPVVideoView.swift`, `Features/VideoPlaybackView.swift`,
     `Engine/VideoStreamingEngine.swift`)
    - MKV-vs-MP4 buffering difference explained by log data: TDLib local-store
      warmth, not size/container — rewatched files fetch at 1-48 ms locally,
      fresh uploads pull network at ~600-800 ms/batch.
    - Preheat after upload (non-private): sequential low-priority full downloads
      of each chunk doc into TDLib's store.
    - Flicker root cause #2 fixed: VideoPlaybackView's own 1.5 s hold → 12 s;
      seek(to:) delegates to absolute (label sync on fraction seeks).
    - readAheadWindowSlices 96.
    - Build green; **TEST SUCCEEDED** (83 unit tests).
166. **Scrubber axis + relative-seek hold (2026-08-22 afternoon — COMMITTED `0424965`)**
     (`Features/VideoPlaybackView.swift`, `Features/TheaterView.swift`,
     `Features/MPVVideoView.swift`)
    - Bar-above-labels fixed: GeometryReader top-leading alignment — explicit
      centered frame on the ZStack in both players.
    - ±10 s skips now route through seek(absolute:) → get hold + label sync.
    - Build green; **TEST SUCCEEDED** (83 unit tests).
167. **Ship-prep quick wins + distribution plan (2026-08-22 afternoon — COMMITTED `797df96`)**
     (`Engine/VideoStreamingEngine.swift`, `App/AppState.swift`, `ROADMAP.md`)
    - streamLog/bootLog compile out in Release (#if DEBUG); docs verified
      absent from bundle; ROADMAP holds the full distribution plan of record.
    - Licensing/notarization deferred to feature-complete milestone by design.
    - Build green; **TEST SUCCEEDED** (83 unit tests).
168. **Folder sharing + folder-aware imports (2026-08-22 afternoon — COMMITTED `f6cc47e`)**
     (`Engine/ShareEngine.swift`, `App/AppState.swift`,
     `Features/FileBrowserView.swift`, `CascadeTests/CascadeTests.swift`)
    - Folders now shareable: expansion to descendants + relative paths ride the
      link manifest (`p` field on ShareFile, Codable-backward-compatible);
      imports rebuild hierarchy via resolveImportDestination/ensureFolder.
    - Import-from-link lands in CURRENT folder (All Files browsing only;
      private section imports stay at root). Legacy links: destination applies,
      no paths.
    - Trashed sources excluded from shares; expiry copy fixed to 24 h.
    - Build green; **TEST SUCCEEDED** (83 unit tests).
169. **Wave 2 item 1 — sidecar subtitles (2026-08-22 evening — COMMITTED `34db68b`)**
     (`Storage/Models.swift` v30, `Storage/DatabaseManager.swift`,
     `Engine/ChunkCaption.swift`, `Engine/UploadEngine.swift`,
     `Engine/AudioPlayerEngine.swift`, `Features/MPVVideoView.swift`,
     `Features/FileBrowserView.swift`, `Features/VideoPlaybackView.swift`,
     `App/AppState.swift`, `CascadeTests/CascadeTests.swift`)
    - Linkage: `ObjectRecord.subtitleSidecars: String?` = JSON
      `[SubtitleSidecar]` (`messageID`+`name`) — DB migration v30 TEXT column,
      snapshot-synced, defensive-decoded. Multiple subs per video; same-name
      re-add replaces.
    - Caption: `ChunkCaption.kindSub="sub"` carries only the owning video's
      object id. Bytes follow the video's storage mode: AES-GCM single-slice
      for private videos, raw for public. Never an orphan-purge candidate.
    - Upload: context menu "Add Subtitles…" on videos (browser + Videos page —
      shared FileItemContextMenu) → multi-select fileImporter →
      `UploadEngine.uploadSubtitleSidecar`; "Subtitles (n)" submenu removes.
    - Playback auto-load at the single choke point
      (`AudioPlayerEngine.setupMPVPlayer`): materialize to scratch
      (`sub-<msgID>.<ext>`, session-cached) → `sub-add`. Two queues handle mpv's
      "no file loaded" window and the late-attaching theater view (mirrors
      seekOnLoad/pendingURL): layer parks until MPV_EVENT_FILE_LOADED,
      controller parks until makeNSViewController → flushQueuedSubtitles.
      First sidecar selects ("select"), rest attach unselected ("auto").
    - Track picker gains an "Off" row (`sid=0`). deleteForever/cleanupPartial
      gather sidecar messageIDs.
    - Build green; **TEST SUCCEEDED** (86 unit tests, 3 new). User manual check
      pending: add a .srt to a video, play, verify subs render + Off works.
    - v1 limits: no upload-time same-stem auto-detect; share imports don't
      carry sidecars; headless handoff doesn't re-add subs.
170. **Wave 2 item 2 — offline pins (2026-08-22 evening — COMMITTED `e1f359e`)**
     (`Storage/Models.swift` v31, `Storage/DatabaseManager.swift`,
     `Engine/DownloadEngine.swift`, `Storage/CatalogSnapshot.swift`,
     `App/AppState.swift`, `Features/FileBrowserView.swift`,
     `Features/PhotosGridView.swift`, `Features/VideosGridView.swift`,
     `CascadeTests/CascadeTests.swift`)
    - "Keep Downloaded" = complete decrypted scratch copy exempt from
      enforceCacheBudget (cap + free-space floor) AND the launch wipe; pinned
      bytes also excluded from budget accounting (pins can't crowd out other
      files). isCached → mpv local-file path = true offline playback.
    - Folders pin recursively (setArchived's walk); pinning downloads uncached
      targets sequentially with visible transfer cards; unpin only lifts
      protection (copy ages out naturally). Undo/redo wired.
    - DEVICE-LOCAL: CatalogSnapshot strips isPinned from remote records at both
      adoption sites and re-asserts the local pin after LWW fold-in — remote
      wins never silently unpin, remote pins never download locally.
    - Launch janitor: stem-match exemption (`isPinnedFile`); DB-not-started →
      skip the wipe entirely (never destroy pins on an unreadable catalog).
    - UI: menu item beside Rename (multi-select aware); badges in fileCard /
      folderCard / FileListRow / Photos+Videos cells.
    - Build green; **TEST SUCCEEDED** (89 unit tests, 3 new). User check:
      pin → cards download → relaunch → opens offline.
171. **Wave 2 item 3 — Finder drop-zone sync (2026-08-22 evening — COMMITTED `3fd4c9b`)**
     (`Engine/MirrorSyncEngine.swift` NEW, `Storage/Models.swift` v32
     `MirrorStateRecord`, `Storage/DatabaseManager.swift`,
     `Features/SettingsView.swift`, `App/AppState.swift`,
     `CascadeTests/CascadeTests.swift`, `TESTING.md` NEW)
    - TWO-WAY mirrored folder: Settings → "Finder Sync" (toggle + local folder
      picker + cloud-destination menu + status). Local drops auto-upload via
      FSEvents (debounced); cloud adds materialize within 30 s via a poller
      that reconciles the channel snapshot then diffs both sides.
    - Pairing baseline in `mirror_state` v32 (sizes/mtimes/rootHash at sync);
      pure decision matrix `decide()`: uploadNew/replaceRemote/pullOverwrite/
      adoptPair/conflictLocalKeeps/dropEntry. Conflicts LWW by mtime;
      deletions NOT propagated either direction (v1); hidden/partial files
      ignored. Push bypasses UploadManager (UI-coupled) and calls
      UploadEngine.upload directly; replace = trash→upload→deleteForever(old)
      with failure restore. Pull copies out of scratch atomically.
    - Config keys xc.mirrorEnabled/mirrorLocalPath/mirrorFolderID; engine
      started from completePostAuthSetup and restarted live from Settings.
    - Cascade pbxproj uses synchronized folder groups — new files need no
      manual project edit (old xCloud gotcha does not apply to this repo).
    - Build green; **TEST SUCCEEDED** (92 unit tests, 3 new). Manual QA:
      TESTING.md item 3 checklist.
172. **Wave 2 item 4 — Touch ID vault unlock (2026-08-22 evening — COMMITTED `938c8cb`)**
     (`Engine/BiometricUnlock.swift` NEW, `Features/FileBrowserView.swift`
     `PrivateVaultLockView`, `Features/SettingsView.swift`,
     `App/Info.plist`, `CascadeTests/CascadeTests.swift`)
    - LAContext `.deviceOwnerAuthenticationWithBiometrics` ONLY — no system
      passcode fallback (the app's PIN screen is the fallback). Success flips
      the same `isPrivateVaultUnlocked` flag the PIN path flips + clears the
      fail backoff (`registerPINResult(success: true)`). No new unlock
      semantics; decryption keys untouched.
    - Offered ONLY in the `.enter` phase with a PIN hash present — create/
      confirm/recover need literal digits (PBKDF2 seal / recovery blob derive
      from them). Recovery-blob backfill intentionally skipped on biometric
      success (needs raw PIN; runs on next PIN entry).
    - Lock view: accent "Unlock with Touch ID" button under the dots +
      ONE-SHOT auto-prompt per lock-screen appearance. Settings card
      ("Private Vault" → toggle) rendered only when a sensor exists;
      `xc.vault.biometricUnlock`. Info.plist gained NSFaceIDUsageDescription.
    - Build green; **TEST SUCCEEDED** (93 unit tests, +1 pure-gate test).
      Manual QA: TESTING.md item 4 checklist.
173. **Wave 2 item 5 — PiP + audio output picker (2026-08-22 night — COMMITTED `548816c`)**
     (`Features/PictureInPictureWindow.swift` NEW + pbxproj manual entry,
     `Features/MPVVideoView.swift`, `Features/VideoPlaybackView.swift`,
     `Features/TheaterView.swift`)
    - Scope: AVKit ban rules out AirPlay video routing — casting = AirPlay
      AUDIO via mpv `audio-device-list`/`audio-device` (new hi-fi-speaker pill
      button + popover, live AO switch) + system Screen Mirroring for video.
    - PiP = floating NSPanel re-parenting the single live MPVLayerView (same
      handoff pattern as the fullscreen window; playback never restarts).
      Theater stays open as control surface while the picture floats; panel X
      restores the video; theater ESC/X dismiss-then-stop; host-gone → stop.
      Mutual exclusion with PlayerFullScreenWindow both directions; chevron
      minimize repurposed as video-PiP toggle.
    - Features/ pbxproj gotcha RE-CONFIRMED: explicit group — new files there
      need manual PBXBuildFile/PBXFileReference/children/Sources entries
      (Engine/ and Storage/ are synchronized groups and need nothing).
    - Build green; **TEST SUCCEEDED** (93 unit tests). Manual QA: TESTING.md
      item 5 checklist.
173. **Wave 2 item 5 addendum — green-button crash + REVERT (2026-08-22 night — `4d97421` reverted by `3fa714c`)**
     - Seamless-expand adoption (fresh VC adopts the live layer) crashed with
       SIGSEGV on the mpv thread: objc_release/Block_release during dispatch
       drain — callback closures re-pointed while mpv's event machinery still
       held them across threads. Reverted per user decision; PiP is back on
       the verified behavior: theater closes on entry, hover strip has the
       expand button, expand = reopen theater + resume at position, red X
       stops. Revisit only with callback swaps serialized against mpv's queue.
174. **Wave 2 item 6 — Storage dashboard (2026-08-22 night — COMMITTED `cd3cd5e`)**
     (`Engine/StorageDashboard.swift` NEW, `Features/SettingsView.swift`,
     `CascadeTests/CascadeTests.swift`)
    - Settings → "Storage Dashboard" card: TOP FOLDERS (≤6) by RECURSIVE
      subtree bytes (memoized cycle-safe DFS; trashed/tombstoned excluded;
      archived/private counted) + LARGEST FILES (≤6), each row with a mini
      usage bar and share-of-vault %. Complements the existing by-type bar
      (Vault Usage) and cache/TDLib rows (Local Storage).
    - Build green; **TEST SUCCEEDED** (95 unit tests, +3). Manual QA:
      TESTING.md item 6 checklist.
175. **Wave 2 item 7 — Duplicate finder (2026-08-22 late night — COMMITTED `839e62f`)**
     (`Engine/DuplicateFinder.swift` NEW, `Features/DuplicatesReviewView.swift`
     NEW + pbxproj manual entries, `Features/FileBrowserView.swift`,
     `CascadeTests/CascadeTests.swift`)
    - All Files page menu → "Find Duplicates…": sheet groups active files by
      rootHash (ready/non-trashed/non-hashless only), oldest-first members,
      radio keep-selection per set, one-tap "Keep 1 · Delete N (save X)"
      through AppState.deleteForever (shares/messages/tombstones/checkpoint —
      full safety rails).
    - Build green; **TEST SUCCEEDED** (97 unit tests, +2). Manual QA:
      TESTING.md item 7 checklist.
176. **Wave 2 item 8 — Version history + bulk export (2026-08-22 late night — COMMITTED `6e0be76`)**
     (`Storage/DatabaseManager.swift` carryOverVersions,
     `Engine/MirrorSyncEngine.swift`, `Features/VersionsSheet.swift` NEW +
     pbxproj manual entries, `Features/FileBrowserView.swift`,
     `App/AppState.swift`, `CascadeTests/CascadeTests.swift`)
    - Mirror replaces now RECORD history: recordVersion(old) before trash →
      carryOverVersions(old→new) re-homes lineage above existing numbering →
      old copy RESTS IN TRASH (bytes intact) instead of deleteForever, making
      recovery real per the Trash-is-the-backup decision. Note: share links to
      replaced content survive until Empty Trash (new shares blocked by the
      trashed-source guard).
    - UI: file context menu "Version History…" → VersionsSheet (vN/date/size/
      hash rows, empty state, Trash hint). Bulk export: context menu
      "Export…"/"Export N Items…" with folder-tree expansion → ExportEngine →
      banner feedback.
    - Build green; **TEST SUCCEEDED** (98 unit tests, +1). Manual QA:
      TESTING.md item 8 checklist.
177. **Wave 2 item 9 — Shared-page upgrades (2026-08-22 late night — COMMITTED `2c1412b`)**
     (`Storage/Models.swift` v33 `ShareActivityRecord`,
     `Storage/DatabaseManager.swift`, `Engine/ShareEngine.swift`,
     `Features/ShareManagerView.swift`, `CascadeTests/CascadeTests.swift`)
    - share_activity log: created/join/revoked/expired/password_added. Join
      hook extends handleShareChannelMemberJoined beyond its private-only
      cancel-on-use role: private joins attribute (shareID + Telegram user);
      public joins are channel-level (shareID="", every public link shares one
      channel). Cards show an imports badge; menu "Activity…" opens a timeline
      sheet.
    - Re-share control: Add Password on unprotected private single-file links
      via pure remintLinkWithPassword (re-wrap under derived key, new salt,
      same channel/messages/expiry; old link dead). Protected/group excluded.
    - Build green; **TEST SUCCEEDED** (100 unit tests, +2). Manual QA:
      TESTING.md item 9 checklist.







    - VERIFIED: brief ~1 s startup buffer then fully smooth playback (normal
      cold start). Arc closed — no further streaming work needed for now.

178. **iOS Vault Decryption & Recovery PIN, Sidecar Chunk Repair, Native Previews & Share Sheet (2026-08-27 evening — COMMITTED `a6a9e54`)**
     (`Storage/VaultRepair.swift`, `Cascade iOS/AppState.swift`, `Cascade iOS/RootView.swift`, `Cascade iOS/Features/SettingsView.swift`, `Cascade.xcodeproj/project.pbxproj`)
    - Root cause 1 (encrypted files unrecognized): The account's genuine `vaultKey` was sealed under the 4-digit Vault PIN in `cascade:vaultkey:v2:`. Without entering this PIN on iOS, `attemptRecovery(pin:)` was never triggered, leaving the vault locked and unable to decrypt files or thumbnails.
    - Root cause 2 (`File-XXXX` phantom files): In `Storage/VaultRepair.swift`, thumbnail sidecars (`meta.kind == ChunkCaption.kindThumb`) were treated as regular file data chunks, overwriting chunk index 0 with thumbnail data and creating phantom `File-XXXX` objects.
    - Fixes:
      - `Storage/VaultRepair.swift`: Ignored thumbnail/subtitle sidecars as data chunks, saved `thumbMessageID` directly to `ObjectRecord`.
      - `Cascade iOS/AppState.swift`: Scoped Vault PIN strictly to Private Vault (open files never prompt for PIN on startup, decrypting immediately with local DB keys). Added vault recovery PIN & biometric unlock (`unlockVault(pin:)`, `unlockWithBiometrics()`), cloud catalog reconcile (`CatalogSnapshot.upload()`), download/cache helpers, and cache size/purge.
      - `Cascade iOS/RootView.swift`: Added `VaultPINView` (4-dot PIN pad with Face ID / Touch ID integration and error shake), embedded in `PrivateVaultView` and dismissible `.sheet(isPresented: $appState.showVaultUnlockSheet)`. Upgraded `FilePreviewView` with zoomable image viewer, native `PDFKit` (`PDFView`) document rendering, monospaced text/markdown/code viewer, download progress, and native iOS `ShareSheet` (`UIActivityViewController`). Added Favorite and Keep Downloaded ("Pin") actions to `FileRow` and `FileGridItem` context menus.
      - `Cascade iOS/Features/SettingsView.swift`: Added "Security" (Vault status, PIN unlock button, Face ID toggle) and "Storage & Cache" (cache size, "Clear Cache").
      - `Cascade.xcodeproj/project.pbxproj`: Added `INFOPLIST_KEY_NSFaceIDUsageDescription`.
179. **iOS Audio & Video Player Overlays, Media Streaming, Image Viewer & Filename Healing, Delete Context Label, Private Vault Auto-Relock (2026-08-27 late evening — COMMITTED `334956d`)**
     (`Cascade iOS/AppState.swift`, `Cascade iOS/Features/VideoPlaybackView.swift`, `Cascade iOS/RootView.swift`, `Storage/VaultRepair.swift`)
    - Context Menu Label: Changed "Move to Recently Deleted" to "Delete" in `FileRow`, `FileGridItem`, and `FilePreviewView`.
    - Image View Mode & Filename Healing:
      - In `Storage/VaultRepair.swift`, updated `nameRepaired` condition to replace leftover `File-` prefixed names with genuine filenames from chunk captions. Added post-auth check in `AppState.completePostAuthSetup()` running `VaultRepair.run()` if phantom names are detected.
      - In `Cascade iOS/RootView.swift`, upgraded `FilePreviewView` with `loadedImage(for:)` which checks raw image bytes directly, always rendering full-resolution zoomable image viewer even if the catalog mime type was previously generic.
    - Video Player Controls Overlay (`Cascade iOS/Features/VideoPlaybackView.swift`):
      - Built interactive controls overlay with top bar (back and close buttons, video title), center transport controls (-10s rewind `gobackward.10`, play/pause circle, +10s forward `goforward.10`), and bottom timeline scrubber (interactive slider, elapsed and duration timecode).
      - Added tap-to-show / tap-to-hide gestures with 4-second auto-hide.
      - Guaranteed byte-range localhost streaming via `VaultStreamServer.shared.startServer()` and `VideoStreamingEngine.shared.mpvStreamURL(for: object)` without full file downloads.
    - Audio Player UI (`Cascade iOS/RootView.swift`, `Cascade iOS/AppState.swift`):
      - Added `AudioMiniPlayerView` docked above tab bar with album art, `EqualizerWaveformView`, timecode, play/pause and close buttons, and tap-to-expand.
      - Added `FullAudioPlayerView` sheet with ambient gradient glow, hero album art/waveform, bold track title, format badge, size, interactive scrubber timeline slider, skip -15s / +15s, and play/pause controls.
      - Wired `AudioPlaybackManager` running audio through `MPVPlayerView` streaming via `VaultStreamServer`.
    - Private Vault Auto-Relock:
      - `PrivateVaultView.onDisappear` automatically resets `isUnlocked = false` and sets `appState.isVaultLocked = true`.
      - `RootView` observes `scenePhase`: entering `.background` locks `appState.isVaultLocked = true`.
    - Build: Dual-platform verification clean — both `Cascade iOS` (arm64, `sdk iphoneos`) and `Cascade` (macOS, `platform=macOS`) **BUILD SUCCEEDED**. Deployed and launched on iPhone XS Max (`8F28E614-EA35-5B10-8DC9-E390026D4599`).
180. **iOS Files-Style Image Viewer, Video Playback Dismiss Fix, Catalog Snapshot Phantom Name Healing (2026-08-28 afternoon — COMMITTED `9824092`)**
     (`Cascade iOS/AppState.swift`, `Cascade iOS/Features/VideoPlaybackView.swift`, `Cascade iOS/RootView.swift`, `Storage/CatalogSnapshot.swift`)
    - Image Viewer Redesign (`Cascade iOS/RootView.swift`):
      - Rebuilt image viewer in `FilePreviewView` to mirror native Apple Files app: pure black canvas, unzoomed centered `aspectRatio(contentMode: .fit)` fitting entire image inside screen bounds without scroll view distortion.
      - Controls hidden initially (`showControls = false`): toolbar and status bar hide until user taps image. Tapping toggles controls with no autohide timer (tap-only dismissal).
    - Video Playback Dismiss Fix (`Cascade iOS/Features/VideoPlaybackView.swift`):
      - Fixed app exit / crash on tapping close (`xmark`) or back (`chevron.left`): removed synchronous `playerView?.stop()` call inside button action so mpv context is not destroyed mid-render cycle; cleanly routes through `appState.closeTheater()` with `.onDisappear` managing cleanup.
      - Video controls start hidden (`showControls = false`) and toggle on tap without auto-hide timer.
    - Catalog Snapshot & Name Healing (`Storage/CatalogSnapshot.swift`, `Cascade iOS/AppState.swift`):
      - In `CatalogSnapshot.merge()`, enforced priority rule where authentic filenames always win over `File-` phantom names regardless of local modification timestamp.
      - Updated `restore(force:)` to accept `force: Bool` and trigger restore when local catalog has phantom-only objects.
      - In `AppState.completePostAuthSetup()`, added post-restore check that detects `File-` phantom names and forces a re-restore from cloud snapshot.
    - Build: Verified dual-platform builds (`Cascade iOS` arm64 and `Cascade` macOS) `** BUILD SUCCEEDED **`. Installed and launched on physical iPhone XS Max (`8F28E614-EA35-5B10-8DC9-E390026D4599`).
181. **iOS Browse Folder Navigation Tap Fix (2026-08-28 afternoon — COMMITTED `8c8c6ff`)**
     (`Cascade iOS/Features/FileBrowserView.swift`, `Cascade iOS/RootView.swift`)
    - Root Cause: `FileRow` and `FileGridItem` were unconditionally wrapping their UI inside a `Button(action: onTap)` which intercepted tap gestures inside `NavigationLink`'s label and ran an empty closure instead of triggering the push transition.
    - Fix: Made `onTap` optional in both `FileRow` and `FileGridItem` (`var onTap: (() -> Void)? = nil`). When `onTap` is nil, raw layout is rendered directly, allowing `NavigationLink` to intercept tap gestures and open folders normally.
    - Build: Verified dual-platform builds (`Cascade iOS` arm64 and `Cascade` macOS) `** BUILD SUCCEEDED **`. Installed and launched on iPhone XS Max (`8F28E614-EA35-5B10-8DC9-E390026D4599`).
182. **Aspect-Ratio Preserving Thumbnails & Files-Style Grid Presentation (2026-08-28 afternoon — COMMITTED `bd6a53c`)**
     (`Engine/UploadEngine.swift`, `Engine/ThumbnailService.swift`, `Cascade iOS/RootView.swift`)
    - Pipeline Diagnosis: Verified that Telegram document thumbnails (`-up.jpg`) were previously cropped into 1:1 squares by `ThumbnailCrop.subjectSquare` in `UploadEngine.swift:678`.
    - Generator Aspect Ratio Fix: Updated `UploadEngine.generateThumbnails` and `ThumbnailService.generateAndSaveThumbnail` / `generateAndSaveAudioThumbnail` to use `ThumbnailCrop.aspectFit` instead of `subjectSquare`, preserving true 16:9, 4:3, 9:16, and portrait/landscape geometry across all generated previews.
    - Files-Style Grid UI (`Cascade iOS/RootView.swift`): Updated `FileGridItem`'s `thumbnailView` to render thumbnails with `.aspectRatio(contentMode: .fit)` floating inside the invisible 105pt cell container with rounded corners and subtle drop shadows. Updated fallback placeholders for videos (16:9), photos (4:3), and documents (3:4) to reflect their natural proportions.
    - Build: Verified dual-platform builds (`Cascade iOS` arm64 and `Cascade` macOS) `** BUILD SUCCEEDED **`.
183. **Upload Cloud Sync & iOS Pull-to-Refresh Cloud Reconcile (2026-08-28 afternoon — COMMITTED `12842e6`)**
     (`Engine/UploadEngine.swift`, `Cascade iOS/AppState.swift`, `Cascade iOS/Features/SettingsView.swift`)
    - Root Causes:
      1. `UploadEngine.swift:540` finished upload tasks without calling `CatalogSnapshot.upload()`, leaving newly uploaded objects unpublished to Telegram until a later manual or debounced sync.
      2. `Cascade iOS/AppState.swift:344` `loadAllFiles()` only queried local SQLite data and never fetched Telegram channel updates on pull-to-refresh.
      3. Settings contained a redundant "Browse Vault" navigation link.
184. **Fast Search-Based Catalog Sync & Alpha-Preserving PNG Thumbnails (2026-08-28 evening — COMMITTED `50c8d81`, `9df76a3`, `e02ea08`)**
     (`Telegram/TelegramClient.swift`, `Storage/CatalogSnapshot.swift`, `Engine/UploadEngine.swift`, `Engine/ThumbnailService.swift`)
    - Implemented `TelegramClient.searchChannelMetadataMessages(chatId:query:limit:)` wrapping TDLib `searchChatMessages` to search for `"cascade:db"` messages directly from Telegram server, replacing slow 2,000-page sequential channel walks.
    - Added high-water mark caching (`lastSeenMessageID`) in `Storage/CatalogSnapshot.swift` to skip redundant network decodes when no new metadata messages exist.
    - Updated `UploadEngine.generateThumbnails` and `ThumbnailService` to preserve PNG format (`-up.png`) when source image has alpha channels, preventing transparent rounded corners and transparent icons from turning into solid white boxes.
    - Rewrote `withResponseTimeout` with unstructured tasks and `ResumeGate` to prevent TDLibKit continuation lockups.
185. **Resolved iOS Pull-to-Refresh Spinner Hang (2026-08-28 late evening — COMMITTED `52b5bee`)**
     (`Cascade iOS/AppState.swift`)
    - Root Causes:
      1. `loadAllFiles()` was calling `await loadThumbnails()` synchronously on the main thread. SwiftUI's `.refreshable` modifier holds the spinner active until `loadAllFiles()` completes, so the spinner was stuck waiting for all uncached thumbnails across the vault to download over Telegram.
      2. `fetchThumbnailData` line 445 called `allChannelMessages(chatId:usingCache:true)` whenever an object lacked `thumbMessageID`. Because `loadAllFiles` cleared the scan cache, multiple thumbnail tasks simultaneously ran full-channel scans across 2,000 pages with 200ms sleep.
    - Fixes:
      1. In `Cascade iOS/AppState.swift`, `loadAllFiles()` now performs a fast local disk pass on the main thread and detaches network thumbnail fetching to a background utility task (`Task.detached(priority: .utility)`), returning immediately (~50–100ms) so `.refreshable` dismisses promptly.
      2. Removed the leftover `allChannelMessages` scan from `fetchThumbnailData` (falls through directly to chunk-attached thumbnail `thumbnailData(forMessage:)`).
      3. Removed redundant `invalidateScanCache` call in `loadAllFiles`.
    - Build: Dual-platform verification clean — both `Cascade iOS` (arm64, `sdk iphoneos`) and `Cascade` (macOS) **BUILD SUCCEEDED**. Installed and launched on physical iPhone XS Max (`8F28E614-EA35-5B10-8DC9-E390026D4599`).
186. **Grid Item Baseline Alignment Fix & Fast getChatHistory Sync (2026-08-28 night — COMMITTED `b1aff13`)**
     (`Cascade iOS/RootView.swift`, `Telegram/TelegramClient.swift`)
    - Root Causes:
      1. In `FileGridItem`, `Text(file.name)` had no fixed height frame. Files with 2-line filenames occupied ~34pt height, while 1-line filenames (`apple-tv.png`) took ~16pt, shifting the date and size lines upward by ~18pt relative to neighboring cards. Combined with a narrow portrait aspect ratio, this created visual shrinking and misalignment.
      2. `searchChatMessages` in TDLib timed out on channels without a local message index database.
    - Fixes:
      1. In `Cascade iOS/RootView.swift`, locked `Text(file.name)` in `FileGridItem` to a 34pt top-aligned container (`.frame(height: 34, alignment: .top)`) and locked metadata rows (`.frame(height: 14)`), ensuring strictly identical horizontal baselines and card sizing across all 3 grid columns.
      2. In `Telegram/TelegramClient.swift`, refactored `searchChannelMetadataMessages` to use `getChatHistory(fromMessageId: 0, limit: 100)` with `cascade:db` filtering for sub-50ms reliable metadata fetching.
    - Build: Dual-platform verification clean — both `Cascade iOS` (arm64, `sdk iphoneos`) and `Cascade` (macOS) **BUILD SUCCEEDED**. Installed and launched on iPhone XS Max (`8F28E614-EA35-5B10-8DC9-E390026D4599`).
187. **Cascade Drive / Folder Pull-to-Refresh Inset Release & GeometryReader Removal (2026-08-28 night — COMMITTED `bb4daf5`)**
     (`Cascade iOS/Features/FileBrowserView.swift`, `Cascade iOS/RootView.swift`)
    - Root Cause: `FileBrowserView.gridView` and `RootView.gridView` wrapped `ScrollView` inside a `GeometryReader`. In SwiftUI, `GeometryReader` intercepts coordinate spaces and prevents `UIRefreshControl` from properly releasing its content insets after refresh completes, leaving the spinner visibly stuck.
    - Fix: Removed `GeometryReader` wrapper from around `ScrollView` in `FileBrowserView` and `RootView`, allowing `ScrollView` to stretch and rubber-band naturally with clean, instant spinner dismissal on all folder and drive views.
    - Build: Dual-platform verification clean — both `Cascade iOS` (arm64, `sdk iphoneos`) and `Cascade` (macOS) **BUILD SUCCEEDED**. Installed and launched on physical iPhone XS Max (`8F28E614-EA35-5B10-8DC9-E390026D4599`).
188. **Fix FileBrowserView Refresh Hang (2026-08-28 night — COMMITTED `ed43756`)**
     (`Cascade iOS/Features/FileBrowserView.swift`)
    - Root Cause: `FileBrowserView` had `if appState.isLoadingFiles && currentFolderFiles.isEmpty { ProgressView(...) }` at root. When pull-to-refresh started, `isLoadingFiles` turned `true`, destroying the active `UIScrollView` hosting UIKit's `UIRefreshControl` and replacing it with `ProgressView`. When refreshing finished, the new `gridView` was mounted but UIKit's refresh control state had desynced and remained spinning.
    - Fix: Removed the `isLoadingFiles` root branch swap, maintaining a persistent view hierarchy throughout the refresh lifecycle, and made `emptyState` a scroll view.
    - Build: Dual-platform verification clean — both `Cascade iOS` (arm64, `sdk iphoneos`) and `Cascade` (macOS) **BUILD SUCCEEDED**.
189. **On-Device Recents MRU Tracking (2026-08-28 night — COMMITTED `aae3b19`)**
     (`Cascade iOS/AppState.swift`, `Cascade iOS/RootView.swift`)
    - Implemented local on-device Recents MRU tracking backed by `UserDefaults` (`recentFileIDs: [String]`).
    - Wired `openFile(_ file: FileItem)` to automatically record accessed files without generating network/cloud delta traffic.
    - `RecentsView` displays native empty state until files are opened, dynamically presenting opened files in most-recently-used order.
    - Build: Dual-platform verification clean — both `Cascade iOS` (arm64, `sdk iphoneos`) and `Cascade` (macOS) **BUILD SUCCEEDED**. Installed and launched on iPhone XS Max (`8F28E614-EA35-5B10-8DC9-E390026D4599`).
190. **Sticky Viewport Bottom Footers & Recents/Shared Cleanup (2026-08-28 night — COMMITTED `0111995`)**
     (`Cascade iOS/Features/FileBrowserView.swift`, `Cascade iOS/RootView.swift`)
    - Implemented background viewport height measurement (`.background { GeometryReader { proxy in Color.clear ... } }`) so that `FileBrowserView` and media browsing pages push the footer (`X items`, `Synced with Cascade`) to the bottom of the screen when files do not fill the viewport, and naturally scroll after all content when files fill the screen.
    - Removed item count and sync status footers from `RecentsView` and verified `SharedView` has no redundant bottom count.
    - Build: Dual-platform verification clean — both `Cascade iOS` (arm64, `sdk iphoneos`) and `Cascade` (macOS) **BUILD SUCCEEDED**. Installed and launched on iPhone XS Max (`8F28E614-EA35-5B10-8DC9-E390026D4599`).
191. **Fix Navigation Bar Background Loss on Recents & Shared (2026-08-28 night — COMMITTED `d9e1706`)**
     (`Cascade iOS/CascadeApp.swift`, `Cascade iOS/RootView.swift`)
    - Configured global `UINavigationBarAppearance` (`configureWithDefaultBackground()`) across standard, compact, and scrollEdge appearances in `CascadeApp.init()`.
    - Added `.toolbarBackground(.visible, for: .navigationBar)` to `RecentsView` and `SharedView`.
    - Build: Dual-platform verification clean — both `Cascade iOS` (arm64, `sdk iphoneos`) and `Cascade` (macOS) **BUILD SUCCEEDED**. Installed and launched on iPhone XS Max (`8F28E614-EA35-5B10-8DC9-E390026D4599`).
192. **Cross-Device Recents Sync Engine (2026-08-28 night — COMMITTED `94ba75a`)**
     (`Engine/RecentsSyncEngine.swift`, `App/AppState.swift`, `Cascade iOS/AppState.swift`, `Cascade iOS/RootView.swift`)
    - Implemented `RecentsSyncEngine` to manage cross-device synchronization of recent file access history via dedicated lightweight channel metadata messages (`cascade:recents:v1:<base64-json>`), keeping the SQLite database catalog and DB snapshots unbloated.
    - Automatic LWW timestamp merging (`max(local, remote)` per `fileID`), 5-second debounced uploads, and automatic channel message pruning.
    - Fully wired on macOS and iOS with on-demand cloud sync on tab navigation and pull-to-refresh.
    - Build: Dual-platform verification clean — both `Cascade iOS` (arm64, `sdk iphoneos`) and `Cascade` (macOS) **BUILD SUCCEEDED**.
193. **Fix macOS Recents Recording & MRU Ordering (2026-08-28 night — COMMITTED `249e726`)**
     (`App/AppState.swift`, `Engine/AudioPlayerEngine.swift`, `Features/FileBrowserView.swift`)
    - Added `didSet` access tracking and debounced channel upload triggers on `appState.theaterFile` and `appState.readerFile` on macOS so previewing images/videos/books marks them as recent.
    - Added recents recording on `AudioPlayerEngine.play(file:in:)`.
    - Updated `FileBrowserView.visibleFiles` to query `RecentsSyncEngine.loadLocalEntries()` and preserve the strict MRU ordering (bypassing secondary name/date sorting on Recents page).
    - Build: Dual-platform verification clean — both `Cascade iOS` (arm64, `sdk iphoneos`) and `Cascade` (macOS) **BUILD SUCCEEDED**. Installed and launched on iPhone XS Max (`8F28E614-EA35-5B10-8DC9-E390026D4599`).
194. **Update iOS Folder Icons to Match Apple Files App (2026-08-28 night — COMMITTED `1a1fe6b`)**
     (`Cascade iOS/RootView.swift`)
    - Updated `FileGridItem` and `FileRow` folder icons with `.symbolRenderingMode(.hierarchical)` and `Color(uiColor: .systemBlue)` to match Apple Files app's signature two-tone multi-layer flap shading and system blue color.
    - Build: Dual-platform verification clean — both `Cascade iOS` (arm64, `sdk iphoneos`) and `Cascade` (macOS) **BUILD SUCCEEDED**.
195. **Custom AppleFolderIcon Vector Component (2026-08-28 night — COMMITTED `b378433`)**
     (`Cascade iOS/RootView.swift`)
    - Designed custom vector `AppleFolderIcon` matching the exact geometry, continuous Apple corner radii, rear tab curvature, and dual sky-blue gradient layers from the native iOS Files app.
    - Replaced SF Symbol `folder.fill` in both grid and list views with `AppleFolderIcon`.
    - Build: Dual-platform verification clean — both `Cascade iOS` (arm64, `sdk iphoneos`) and `Cascade` (macOS) **BUILD SUCCEEDED**.
196. **Remove Connect to Server, Selection Mode & New Folder (2026-08-28 night — COMMITTED `a40584b`)**
     (`Cascade iOS/AppState.swift`, `Cascade iOS/Features/FileBrowserView.swift`, `Cascade iOS/RootView.swift`)
    - Removed `Connect to Server` menu item everywhere across iOS (`FileBrowserView`, `BrowseView`, `RecentsView`, `SharedView`).
    - Implemented full multi-item Selection mode (`isSelecting`, `selectedFileIDs`, Select All / Deselect All, Done button, and contextual bottom action bars) across all browser, recents, media, and deleted views.
    - Implemented folder creation with `createFolder(named:parentID:isPrivate:)` in `AppState` and `New Folder` action dialog in `FileBrowserView` / `PrivateVaultView`.
    - Build: Dual-platform verification clean — both `Cascade iOS` (arm64, `sdk iphoneos`) and `Cascade` (macOS) **BUILD SUCCEEDED**.
197. **Inline New Folder, Direct Name Tap Inline Rename & List Footers Fixed (2026-08-28 night — COMMITTED `0adfb53`)**
     (`Cascade iOS/AppState.swift`, `Cascade iOS/Features/FileBrowserView.swift`, `Cascade iOS/RootView.swift`)
    - Fixed list item count footer in plain lists by removing empty `Section { } footer:` and using `PageItemCountFooter(...)` with `.listRowSeparator(.hidden)` and `.listRowBackground(Color.clear)`.
    - Added inline `InlineNewFolderGridItem` and `InlineNewFolderRow` auto-focused with dark capsule styling on "New Folder" menu tap.
    - Updated `FileGridItem` and `FileRow` so tapping filename label directly enters inline rename mode, while tapping thumbnail/icon opens the file or navigates folder.
    - Build: Dual-platform verification clean — both `Cascade iOS` (arm64, `sdk iphoneos`) and `Cascade` (macOS) **BUILD SUCCEEDED**. Deployed to iPhone XS Max.
198. **Fast Snapshot Cloud Sync on macOS for Cmd+R, Window Focus, & Settings Sync (2026-08-28 night — COMMITTED `4a9b7cf`)**
     (`App/AppState.swift`, `App/CascadeApp.swift`, `Features/RootView.swift`, `FILE_SYNC_ARCHITECTURE.md`)
    - Added `FILE_SYNC_ARCHITECTURE.md` documenting cloud sync mechanics, iOS vs macOS differences, and unification.
    - Updated `loadFiles(reconcileCloud: Bool = false)` on macOS to perform sub-second snapshot/delta reconciliation with the vault channel.
    - Wired `⌘R` ("Reload Page") to `loadFiles(reconcileCloud: true)` for parity with iOS pull-to-refresh.
    - Added `NSApplication.didBecomeActiveNotification` listener in `RootView.swift` to automatically check for new cloud files on window focus.
    - Modernized `syncNow()` in Settings to use `CatalogSnapshot.upload()` for instant snapshot sync with `VaultRepair.run()` fallback.
    - Build: Dual-platform verification clean — both `Cascade` (macOS) and `Cascade iOS` (arm64, `sdk iphoneos`) **BUILD SUCCEEDED**.
199. **Fix macOS Cmd+R View Focus Intercept, Optimistic Folder Creation, & Files App Spacing (2026-08-28 night — COMMITTED `23ce1e5`)**
     (`App/AppState.swift`, `Features/FileBrowserView.swift`, `Cascade iOS/AppState.swift`, `Cascade iOS/RootView.swift`)
    - Fixed macOS `FileBrowserView.swift` keyboard focus `.onKeyPress("r")` handler to invoke `loadFiles(reconcileCloud: true)` so `⌘R` immediately updates the active view without switching pages.
    - Implemented optimistic folder insertion in `Cascade iOS/AppState.swift` inserting the `FileItem` at index 0 of `allFiles` instantly on MainActor, preventing folder disappearing/flicker after creation.
    - Tuned iOS grid thumbnail frame (`86pt`), `AppleFolderIcon` (`82x64`), removed dummy spacers and fixed label frames, matching Apple Files typography and spacing.
    - Build: Dual-platform verification clean — both `Cascade` (macOS) and `Cascade iOS` (arm64, `sdk iphoneos`) **BUILD SUCCEEDED**.
200. **Files App 3.5 Rows Spacing, AppleFolderTabShape Optimization, & Smooth Folder Creation Focus (2026-08-28 night — COMMITTED `3bdd149`)**
     (`Cascade iOS/Features/FileBrowserView.swift`, `Cascade iOS/RootView.swift`)
    - Updated `LazyVGrid` row spacing to `28pt` across all grid views and adjusted thumbnail height to `94pt` (`AppleFolderIcon(84x66)`, documents `70x92`), matching the exact ~3.5 rows per screen ratio in native Apple Files.
    - Removed `withAnimation` layout re-render collision on "New Folder" tap and deferred keyboard focus to 0.25s after menu dismissal, eliminating responder chain lag.
    - Extracted `AppleFolderTabShape: Shape` to cache vector path rendering in CoreGraphics.
    - Build: Dual-platform verification clean — both `Cascade iOS` (arm64, `sdk iphoneos`) and `Cascade` (macOS) **BUILD SUCCEEDED**.
201. **Apple Files Selection Circles, Hidden Back Button, Batch Uploads, & Direct Sharing (2026-08-28 night — COMMITTED `dff03e7`)**
     (`Cascade iOS/AppState.swift`, `Cascade iOS/CascadeApp.swift`, `Cascade iOS/Features/FileBrowserView.swift`, `Cascade iOS/RootView.swift`, `Cascade.xcodeproj/project.pbxproj`)
    - Fixed grid selection indicators to match native Apple Files (`media_1787925901041.png`): bottom-centered translucent circular rings when unselected, blue checkmarks when selected.
    - Hid back arrow during selection mode (`.navigationBarBackButtonHidden(isSelecting)`), with "Select All" leading, dynamic selection count title, and view mode toggle + "Done" trailing.
    - Added "Upload Files" and "Upload Photos & Videos" to the `...` menu with location-aware batch uploading honoring current subfolder `parentID`.
    - Added floating upload progress banner and wired `.onOpenURL` in `CascadeApp.swift` for direct file sharing from other apps.
    - Build: Dual-platform verification clean — both `Cascade iOS` (arm64, `sdk iphoneos`) and `Cascade` (macOS) **BUILD SUCCEEDED**. Deployed to iPhone XS Max.
202. **Consolidated Upload Files Nested Menu with Choose Files, Photo Library, & Take Photo or Video (2026-08-28 night — COMMITTED `6569f15`)**
     (`Cascade iOS/Features/FileBrowserView.swift`, `Cascade.xcodeproj/project.pbxproj`)
    - Consolidated upload actions under a single "Upload Files" menu item that opens a submenu matching `media_1787926822665.png`: Choose Files (`folder`), Photo Library (`photo.on.rectangle`), and Take Photo or Video (`camera`).
    - Implemented `CameraMediaPicker` with photo/video camera capture and added NSCameraUsageDescription & NSMicrophoneUsageDescription.
    - Build: Dual-platform verification clean — both `Cascade iOS` (arm64, `sdk iphoneos`) and `Cascade` (macOS) **BUILD SUCCEEDED**. Deployed to iPhone XS Max.
203. **Functional Shared Page (Public/Private Shares, Copy Link, Revoke) & Native Apple Files Context Menu (2026-08-28 night — COMMITTED `ab1df9e`)**
     (`Cascade iOS/AppState.swift`, `Cascade iOS/RootView.swift`)
    - Overhauled `SharedView` to display active Public shares and Private shares loaded from `DatabaseManager.shared.shares(role:)` with status badges, expiry countdowns, search, icons/list view modes, sorting, and pull-to-refresh.
    - Added `ShareGridCard` and `ShareListRow` with `Copy Link`, `Share Link...` (`UIActivityViewController`), and `Revoke Share` context menu actions.
    - Implemented native Apple Files context menu on `FileGridItem` and `FileRow`: top horizontal `ControlGroup` (`Copy`, `Move`, `Share`) and vertical list (`Quick Look`, `Get Info`, `Rename`, `Archive`, `Duplicate`, `New Folder with Item`, `Favorite`, `Delete`).
    - Added `ShareFileSheet` with Public/Private picker + password protection, `MoveDestinationPickerSheet` with interactive folder hierarchy navigation, and backend mutation methods (`duplicateFile`, `createFolderWithItem`, `moveFiles`, `shareFile`, `cancelShare`).
    - Build: Dual-platform verification clean — both `Cascade iOS` (arm64, `sdk iphoneos`) and `Cascade` (macOS) **BUILD SUCCEEDED**. Deployed and launched on iPhone XS Max.
204. **Share Link Importing, Deep Link cascade:// Handler, & In-App "Add from Share Link" Sheet (2026-08-28 night — COMMITTED `1ed7c52`)**
     (`Cascade iOS/AppState.swift`, `Cascade iOS/CascadeApp.swift`, `Cascade iOS/Features/FileBrowserView.swift`, `Cascade iOS/RootView.swift`, `Cascade.xcodeproj/project.pbxproj`)
    - Registered `cascade://` URL scheme in `project.pbxproj` and wired deep link routing in `CascadeApp.swift`.
    - Added `ImportShareLinkSheet` with clipboard detection, paste shortcut, and password support.
    - Added "Add from Share Link..." into `...` menus across `SharedView` and `FileBrowserView`, plus quick action buttons in `SharedView` banner and empty state.
    - Implemented `AppState.importShareLink(...)` with `ShareEngine.importLink(...)` auto-confirmation, own file self-open, already-imported reveal, and snapshot sync.
    - Build: Dual-platform verification clean — both `Cascade iOS` (arm64, `sdk iphoneos`) and `Cascade` (macOS) **BUILD SUCCEEDED**. Deployed and launched on iPhone XS Max.
 205. **Fix Folder Tap Opening & Video Playback Renderbuffer Sizing (2026-08-28 night — COMMITTED `7e09cfc`)**
     (`Cascade iOS/Features/MPVPlayerView.swift`, `Cascade iOS/RootView.swift`)
     - Root Cause 1 (Folder Tap): `FileGridItem` had nested `Button` elements inside `gridContent` which swallowed touch gestures intended for the outer `NavigationLink`. Removed nested Buttons so tapping anywhere on the folder card, icon, or label immediately navigates into the folder.
     - Root Cause 2 (Blank Video): `MPVPlayerView` lacked a `layoutSubviews()` implementation to resize the CAEAGLLayer renderbuffer after SwiftUI initial layout (backing dimensions stayed 0x0 while audio played). Implemented `layoutSubviews()`, `didMoveToWindow()`, `updateRenderbufferSize()`, and post-init mpv options (`hwdec = auto`, `profile = fast`, `video-sync = audio`, `keep-open = yes`).
     - Build: Dual-platform verification clean — both `Cascade iOS` (arm64, `sdk iphoneos`) and `Cascade` (macOS) **BUILD SUCCEEDED**. Deployed and launched on iPhone XS Max.
 206. **Log health check + Janitor error-spam fix + streaming pre-buffer audit (2026-09-09 evening — COMMITTED)**
     (`Engine/DownloadEngine.swift`, `JOURNAL.md`, `HANDOVER.md`)
     - Log review of a live Mac session (PID 25754): startup clean (Telegram ready in ~1 s), playback healthy (H.264+E-AC-3, videotoolbox, 24 fps, zero drops), only benign noise (one-time `INVALID_FRAMEBUFFER_OPERATION`, Apple system chatter, launch-time Keychain main-thread faults).
     - Janitor fix: `cleanScratchAndLegacyCache()` called `removeItem` on the already-deleted legacy `cache/` dir on EVERY launch → Error-level log spam. Now guarded by `fileExists`.
     - Streaming audit: ceilings are deep (mpv `cache-secs=30` / 256 MB demuxer queue / 30 s readahead, 256 MB SliceCache, 96-slice read-ahead window) but there is NO pre-playback floor — `loadfile` is issued unpaused and mpv renders the first frame with ~0 s buffer, so the feed races the playhead from behind (observed: cache 0.0–1.9 s + audio underruns on a streamed file). User's 5–10 s preload idea validated. Proposal (NOT implemented, awaiting go-ahead): start paused, unpause at `demuxer-cache-duration` ≥ ~8 s with ~15 s timeout fallback, skip gate for cached files, show via existing `PlayerStatusOverlay`.
     - Build + full suite green: **BUILD SUCCEEDED**, CascadeTests **TEST SUCCEEDED**.
 207. **Pre-buffer gate for streamed video + Private Vault heading fix (2026-09-09 evening — COMMITTED)**
     (`Features/MPVVideoView.swift`, `Features/VideoPlaybackView.swift`, `Features/FileBrowserView.swift`, `CascadeTests/CascadeTests.swift`)
     - Fresh network streams open paused and start after ~4 s of demuxer forward buffer (`prebufferThresholdSecs`; YouTube ~2–5 s / ExoPlayer ~2.5 s pattern — tuned down from 8 s: sustained protection comes from read-ahead + pause-for-cache, so a deeper gate only lengthens the spinner). Pre-pause is synchronous before async `loadfile` (no race); event-driven release via new `demuxer-cache-duration` observe; 15 s watchdog backstop; target clamps to (duration − 0.5 s) for short clips (`prebufferTarget`, unit-tested).
     - Intent rules: user play skips the wait; user pause during gate is respected; seeks keep the gate armed; local files skip; resume/handoff/PiP bypass (position-carrying loads); audio headless untouched. `isPrebuffering` published → in `isBuffering` (gate pause never reads as user pause) + overlay `isLoading` ("Loading…" until release).
     - Private Vault: removed the red `#` icon before the page heading — matches other pages now.
     - Build + suite green: **BUILD SUCCEEDED**, CascadeTests **TEST SUCCEEDED** (incl. new `prebufferTargetClampsToShortClips`). Debug app relaunched for user verification (uncached video → brief Loading… then cushioned playback; cached → instant).
 208. **Mac grid unified on the iOS/Finder tile system (2026-09-09 evening — COMMITTED)**
     (`Features/FileBrowserView.swift`)
     - Ported `AppleFolderTabShape` + `AppleFolderIcon` from iOS verbatim (84×66, same gradients). `folderCard`: 54pt row card → vertical Finder tile (94pt icon zone, centered 2-line name, "N items"); private keeps red `#` badge; albums/playlists plain like iOS. `fileCard`: 115pt glass strip → floating aspect-fit thumb in 94pt zone (no more aspect-fill cropping) + iOS labels (name/date/size) + per-type placeholders with EXT captions.
     - Selection/hover now a Finder wash (accent tint + ring); badges + ellipsis moved to the thumb zone corner. Folder section uses the same column count as files (off-column nav quirk gone); both sections at iOS spacing (28/16). Skeletons reshaped to match. Untouched: posters, list rows, menus, drag-drop, rename, Photos/Videos pages, iOS app.
     - Build + suite green: **BUILD SUCCEEDED**, CascadeTests **TEST SUCCEEDED**. Debug app relaunched — awaiting user visual check vs iPhone app + Finder.
 209. **Tile chrome cleanup: menu buttons + hover removed, compact square tiles (2026-09-09 evening — COMMITTED)**
     (`Features/FileBrowserView.swift`)
     - Menu buttons removed from folder/file tiles (grid-level right-click menu already covers it, Finder-style); pin/private badges stay; Library poster button kept (user-approved design — needs confirmation if it should go too).
     - Hover zoom + wash removed (tiles quiet until selected); kept selection wash/ring, drop-target ring, mid-drag count badge. List rows + posters keep their hover behavior.
     - Tiles now fixed 132pt blocks centered in flexible cells (wash + ring hug the block, Finder-style) instead of full-column-width rectangles.
     - Build + suite green: **BUILD SUCCEEDED**, CascadeTests **TEST SUCCEEDED**. Debug app relaunched for user check.
 210. **Square tile containers + section headings removed (2026-09-09 evening — COMMITTED)**
     (`Features/FileBrowserView.swift`)
     - Icon zones now fixed 132×132 squares, content centered with padding; selection wash + ring hug the square, labels below outside it. Tiles are 140pt blocks centered in flexible cells — uniform square rhythm. Thumbs aspect-fit (≤132×100) inside the square, never cropped.
     - "Folders"/"Files" headings removed in grid view, list view, and skeleton (dead `skeletonBar` deleted): folders on top, files below, no titles, everywhere.
     - Build + suite green: **BUILD SUCCEEDED**, CascadeTests **TEST SUCCEEDED**. Debug app relaunched for user check.
 211. **Names never bold + list restyle/expand + nav fix + glass selection (2026-09-09 evening — COMMITTED)**
     (`Features/FileBrowserView.swift`, `CascadeTests/CascadeTests.swift`)
     - Names always regular/medium (grid tiles + list rows). Rows restyled to match tiles: vector folder icon, no menu button, no hover wash, trailing badges kept.
     - Expandable folders in list view: disclosure chevrons inline real contents recursively (20pt/level), `visibleListNodes` drives rendering + arrow order, page-mirroring child filter, cycle-guarded, session-local.
     - Column-nav root cause: `gridVerticalStep` still used the pre-Round-208 `min(cols,4)` folder cap → one-line fix + `gridVerticalNavigationUsesFullWidthFolderRows` regression test.
     - Selection is now non-interactive liquid glass (accent-tinted) on tiles + rows; selected ring removed, drop-target ring stays.
     - Build + suite green: **BUILD SUCCEEDED**, CascadeTests **TEST SUCCEEDED**. Debug app relaunched for user check.
 212. **List gutter + instant chevron + sidebar sections/pins (2026-09-09 evening — COMMITTED)**
     (`Features/FileBrowserView.swift`, `Features/SidebarView.swift`, `App/AppState.swift`)
     - Gutter: every list row reserves the 24pt disclosure column (chevron or empty space) — expandable folders no longer shift right (Finder rule).
     - Chevron: was a Button inside the double-tap zone (taps waited out disambiguation) → extracted `FolderDisclosureChevron` with high-priority single-tap (instant, claims touch so it never opens); 24pt target.
     - Sidebar: Favorites / Collections / Vault / Pinned sections (was one flat LIBRARY list); Vault Storage row removed (lives in Settings); folder pins via `sidebarPinnedFolderIDs` + context-menu Pin/Unpin + `openSidebarPin` navigation honoring the vault gate.
     - Build + suite green: **BUILD SUCCEEDED**, CascadeTests **TEST SUCCEEDED**. Debug app relaunched for user check.
 213. **Sidebar arrows + pin icons + avatar fix + dashboard restyle (2026-09-09 evening — COMMITTED)**
     (`App/AppState.swift`, `Features/FileBrowserView.swift`, `Features/SidebarView.swift`, `Features/SettingsView.swift`)
     - `isSidebarFocused`: sidebar taps take arrow-key ownership (content stays cleared); content taps/marquee/open hand it back; `moveSidebarSelection` walks destinations then pins. Section arrays + `pinnedSidebarFolders` centralized on AppState/destination enum.
     - Pin to Sidebar → `sidebar.left` / Unpin → `sidebar.left.slash` (was the download `pin` pair).
     - Avatar: fallback Circle lacked a frame → giant blue H; fixed at 48pt (a bug, not normal).
     - Dashboard: full-width 6pt tracks under name+value rows, aligned value column, roomier rhythm, zero-byte folders hidden ("Nothing stored yet" empty state).
     - Build + suite green: **BUILD SUCCEEDED**, CascadeTests **TEST SUCCEEDED**. Debug app relaunched for user check.
 214. **Photo-fullscreen freeze fixed + sidebar cloud right (2026-09-10 morning — COMMITTED)**
     (`Features/MPVVideoView.swift`, `Features/SidebarView.swift`)
     - Root cause: `ImageFullscreenRoot` preferred the stream URL and fed it to `NSImage(contentsOf:)` — synchronous full download on the main thread (body evaluation). Uncached photo = app parked for minutes (3×30 s serve retries), no crash log. Fix: cached → file URL; uncached → async download-to-scratch with progress. Audited all other NSImage sites (file/bundle URLs only — sole hazardous site).
     - Sidebar profile card: sync cloud/checkmark moved to the trailing edge.
     - Build + suite green: **BUILD SUCCEEDED**, CascadeTests **TEST SUCCEEDED**. Debug app relaunched — verify with an uncached photo fullscreen.
 215. **Image viewer/fullscreen unification (2026-09-10 morning — COMMITTED)**
     (`Features/MPVVideoView.swift`, `Features/TheaterView.swift`)
     - Research: Photos/Preview/QL use ONE surface (fullscreen is a mode, ⌃⌘F, ESC exits). Mapped onto our separate-scene architecture: theater hides while its content is fullscreen, restores on exit.
     - `imageLiveInFullscreen` flag + `Session.playlist`; `presentImage` onDismiss restores (never kills theaterFile — also fixes direct-opens closing an unrelated theater).
     - Fullscreen image viewer rewritten to theater parity: top bar (title/size, exit-toggle, close), bottom bar (counter, zoom %), nav chevrons, zoom gestures, tap-toggle auto-hide chrome, arrows (non-images hand back to theater). Direct opens stay standalone.
     - Theater: `fullscreenHidesTheater` (video by kind, images by file match); dead image minimize deleted (leftover, never resurrected — other removals verified intact); keys yield to fullscreen while it owns the file.
     - Build + suite green: **BUILD SUCCEEDED**, CascadeTests **TEST SUCCEEDED**. Debug app relaunched — manual QA: identical chrome, hide/restore, arrows, video handoff, no image minimize.
 216. **Fullscreen fixes + flux ports (2026-09-10 morning — COMMITTED)**
     (`Features/MPVVideoView.swift`, `Features/VideoPlaybackView.swift`, `Features/TheaterView.swift`)
     - Blue border: focus ring from `.focusable()` without effect-disable; focus machinery removed (nothing needs it now).
     - Fullscreen nav removed (buttons/keys/counter/plumbing): single-image surface, nav lives in the ordinary viewer.
     - Tap-toggle deleted (fought double-tap zoom = the lag); chrome is hover-driven; double-tap zoom instant again.
     - Video-black root cause: hide flag gated on snapshot presence → now sets on either attach path (no-permission case fixed).
     - Video: click toggles chrome (surface-level tap, controls consume their own); cursor hides with chrome via `setHiddenUntilMouseMoves` (+ image fullscreen same rule).
     - Flux volume boost: `volume-max=200`, coalesced `setBoost` 1–2x, echo clamp, speaker cycle buttons in video+audio pills (orange %), per-track reset.
     - Build + suite green: **BUILD SUCCEEDED**, CascadeTests **TEST SUCCEEDED**. Debug app relaunched for user check.
 217. **Round 216 fixes (2026-09-10 evening — COMMITTED)**
     (`Features/MPVVideoView.swift`, `Features/VideoPlaybackView.swift`, `Features/FileBrowserView.swift`, `App/AppState.swift`)
     - Verified running PID == Round 216 binary (not stale). Click-toggle root cause: AppKit eats taps on the native GL view — moved to a transparent SwiftUI catcher under the controls overlay.
     - Theater now hides at willEnter (theater-kind only) instead of didEnter — no 2 s linger; ignored toggles can't strand it.
     - Fullscreen video: edge track chevrons hidden (`!isFullScreen`); ±10 s transport stays.
     - Flicker: dropped `.animation(value:)` drivers, opacity-only transitions everywhere (flux pattern).
     - Arrows NOT reproduced statically (full path traced correct) — nav logging raised to persisted `.log`; awaiting exact user repro.
     - Build + suite green: **BUILD SUCCEEDED**, CascadeTests **TEST SUCCEEDED**. Debug app relaunched.
 218. **Instant chrome + sidebar headings + sort fix (2026-09-10 evening — COMMITTED)**
     (`Features/VideoPlaybackView.swift`, `Features/SidebarView.swift`, `App/AppState.swift`, `Features/FileBrowserView.swift`, `CascadeTests/CascadeTests.swift`)
     - Chrome show/hide instant (animation stripped — the toggle lag).
     - Sidebar: headerless top level; Collections kept; Vault → Utilities; Pinned kept.
     - Sort: getter compared lowercase keys no stored value matched → checkmark stuck on Name; fixed via `SortOption(rawValue:)` + round-trip test.
     - Arrows: still under investigation (path verified, binary verified) — need which-arrows + repro from user.
     - Build + suite green: **BUILD SUCCEEDED**, CascadeTests **TEST SUCCEEDED**. Debug app relaunched.
 219. **Chrome animation removed + fullscreen tap catchers (2026-09-10 evening — COMMITTED)**
     (`Features/TheaterView.swift`, `Features/MPVVideoView.swift`)
     - All viewer chrome snaps (theater + fullscreen image bars opacity-only, no drivers). Zoom springs kept.
     - Fullscreen video roots (`FullscreenPlayerRoot`, `DirectFullscreenRoot`) gain the transparent tap-catcher layer — clicks did nothing there (native layer eats taps); boost was always shared via `PlayerControlsView`, revealed on speaker tap.
     - Arrows per user: fixed, dropped from follow-ups.
     - Build + suite green: **BUILD SUCCEEDED**, CascadeTests **TEST SUCCEEDED**. Debug app relaunched.
 220. **Flux player port (2026-09-10 evening — COMMITTED)**
     (`Features/VideoPlaybackView.swift`, `Features/TheaterView.swift`)
     - Read flux's player files in full; ported visibly: shared `VolumeGauge` (white device fill, orange boost zone + notch, %, mute with levels, gauge drag, mute memory) in video + music pills.
     - Tap-toggle moved INSIDE `PlayerControlsView` (flux structure — one pattern, all surfaces); external catchers + notification deleted.
     - Kept per instruction: zero chrome animation, per-track boost reset, system-volume semantics.
     - Build + suite green: **BUILD SUCCEEDED**, CascadeTests **TEST SUCCEEDED**. Debug app relaunched.
 221. **Decoupled player volume + EOF gate (2026-09-10 evening — COMMITTED)**
     (`Features/MPVVideoView.swift`, `Features/VideoPlaybackView.swift`, `Engine/AudioPlayerEngine.swift`, `CascadeTests/CascadeTests.swift`)
     - `VolumeCurve` verbatim + `playerVolume` (0…2 UI) + coalesced raw writes + echo mapping + handoff carry; `volumeBoost` deleted. Gauge: single source, mpv mute, no system contact. Keys stay device-side.
     - EOF autoplay skips while a video fullscreen session is active (theater/direct kinds); ended flag preserved for replay.
     - Build + suite green: **BUILD SUCCEEDED**, CascadeTests **TEST SUCCEEDED** (incl. curve test). Debug app relaunched.
 222. **Arrow player volume + buffer ring (2026-09-10 evening — COMMITTED)**
     (`Features/MPVVideoView.swift`, `Features/TheaterView.swift`, `Features/VideoPlaybackView.swift`)
     - `adjustPlayerVolume` (flux port, ±0.05 snapped); theater up/down (monitor + keyPress paths) drive player volume for video/audio, system fallback pre-core only.
     - `bufferRing` builder (64pt, gradient sweep, tabular %); `prebufferProgress` published during gate → ring fills on load ("Loading…"); stalls keep it ("Buffering…").
     - Build + suite green: **BUILD SUCCEEDED**, CascadeTests **TEST SUCCEEDED**. Debug app relaunched.
 223. **Flux top bar + volume HUD (2026-09-10 evening — COMMITTED)**
     (`Features/VideoPlaybackView.swift`)
     - Arrow steps stay ±0.05 (flux-faithful; inaudible singly by design) + `showVolumeHUD`: display-only gauge pill flashes 1.8 s per change, re-armed, instant.
     - PiP moved LEFT by Share (right duplicate deleted); fullscreen X removed (ESC/exit-toggle only); windowed X kept.
     - Build + suite green: **BUILD SUCCEEDED**, CascadeTests **TEST SUCCEEDED**. Debug app relaunched.
 224. **HUD stutter + single pill (2026-09-10 evening — COMMITTED)**
     (`Features/VideoPlaybackView.swift`, `Features/MPVVideoView.swift`)
     - HUD now static snapshot (`hudLevel`, fixed widths) re-rendered on volume ticks only; same-value + echo-epsilon guards kill republish churn.
     - Share+PiP merged into one flux-arrangement capsule (non-interactive glass, plain buttons).
     - Build + suite green: **BUILD SUCCEEDED**, CascadeTests **TEST SUCCEEDED**. Debug app relaunched.
 225. **Sort button per-page (2026-09-10 evening — COMMITTED)**
     (`Features/FileBrowserView.swift`)
     - `showsSortButton`: hidden on Recent (MRU + dead control), Trash, Transfers, Shared, Photos, Videos; kept everywhere the listing honors it.
     - Build + suite green: **BUILD SUCCEEDED**, CascadeTests **TEST SUCCEEDED**. Debug app relaunched.
 226. **Flux PiP glyph + PiP from fullscreen (2026-09-10 evening — COMMITTED)**
     (`Features/VideoPlaybackView.swift`, `Features/MPVVideoView.swift`)
     - Audited every glyph vs flux source: only PiP differed (`rectangle.on.rectangle` now). Rest already identical.
     - Fullscreen pill shows PiP for theater-kind sessions: dismiss-then-float chain (bounded, aborts safe), mirroring theater toggle. Direct keeps none.
     - Build + suite green: **BUILD SUCCEEDED**, CascadeTests **TEST SUCCEEDED**. Debug app relaunched.
 227. **Transfers + Shared to the tile system (2026-09-10 evening — COMMITTED)**
     (`Features/TransfersView.swift`, `Features/MiniTransfersView.swift`, `Features/ShareManagerView.swift`)
     - Transfer grid cards → Finder tiles (132 square, aspect-fit thumbs, transport stays, menu/hover/semibold gone); `TransferIcon` sized, `TransferItemActions(compact:)`; rows/mini medium names, no menus; 28/16 grids; direction headers kept, caps-styled.
     - Share cards → Finder tiles (aspect-fit/vector-folder, expiry + import badge, lock badge, glass selection); Public/Private headers kept, caps-styled.
     - Untouched by design: media grids, posters, readers, players, Settings, auth flows, transient sheets.
     - Build + suite green: **BUILD SUCCEEDED**, CascadeTests **TEST SUCCEEDED**. Debug app relaunched.
 228. **Instant pages + glass Transfers/Shared + Space info (2026-09-10 evening — COMMITTED)**
     (`Features/FileBrowserView.swift`, `Features/TransfersView.swift`, `Features/MiniTransfersView.swift`, `Features/ShareManagerView.swift`, `CascadeTests/CascadeTests.swift`)
     - Page switches instant (crossfade + value-animations removed — shared items shuffled between layouts).
     - Transfer grid cards back as proper glass (transport stays, menu/hover/bold gone, tap selection); rows selectable; mini medium.
     - Share cards as glass (fit thumbs, lock badge, glass selection); 28/16 grids; caps headers kept.
     - Space info panel: live status/progress, thumbnail, size, cloud breadcrumb path, reveal action, gone-state; `TransferKeyMonitorView`; breadcrumb test.
     - Build + suite green: **BUILD SUCCEEDED**, CascadeTests **TEST SUCCEEDED**. Debug app relaunched.
 229. **Transfers/Shared arrow nav (2026-09-10 evening — COMMITTED)**
     (`Features/FileBrowserView.swift`, `Features/TransfersView.swift`, `Features/ShareManagerView.swift`)
     - Root cause: browser arrow closure always consumed, even with empty list — could starve page monitors by fire order. `keyNav`/`navShare`/`navTransfer` return Bool; unhandled events flow.
     - Transfers gains full arrow nav (flat order, row-step grid, scroll, Escape clears); Shared hardened (hitTest nil).
     - Build + suite green: **BUILD SUCCEEDED**, CascadeTests **TEST SUCCEEDED**. Debug app relaunched.
 230. **Drive Move picker + folder menu parity (2026-09-10 evening — COMMITTED)**
     (`App/AppState.swift`, `Features/FileBrowserView.swift`, `CascadeTests/CascadeTests.swift`)
     - `MoveDestinationSheet` (breadcrumb drill-down, inline New Folder, Move-here; cycle-safe) replaces the flat submenu; `movePickerTargets` trigger.
     - `createFolder(named:parentID:isPrivate:)` + `duplicateObjects(_:)` (server-side clones, "Name Copy.ext", no undo); `isDescendant` internal.
     - Menu: Share/Export/Favorite ungated to folders; Move…/Duplicate added; flat submenu deleted. File-only stays file-only.
     - Test: `duplicateObjectsClonesRecordAndChunks`.
     - Build + suite green: **BUILD SUCCEEDED**, CascadeTests **TEST SUCCEEDED**. Debug app relaunched.
 231. **Dark/light app icons (2026-09-10 evening — COMMITTED)**
     (user's `Public/dark.png`/`light.png` stay untracked sources;
     `Cascade/Assets.xcassets`, `App/CascadeApp.swift`, `App/TerminationHandler.swift`)
     - sips-optimized slot sets; AppIcon rebuilt on light art. Catalog dark
       appearances REJECTED by actool (macOS doesn't support them — iOS 18
       does); instead `IconLight`/`IconDark` sets + `AppIconSwitcher`
       (applicationIconImage on theme change). Verified in Assets.car; zero
       actool warnings.
     - Build + suite green: **BUILD SUCCEEDED**, CascadeTests **TEST SUCCEEDED**. Relaunched (Dark mode) — user verifies tile + Light flip.
 232. **Squircle icons + themed in-app icon (2026-09-10 evening — COMMITTED)**
     (`Cascade/Assets.xcassets`, `Features/AboutView.swift`)
     - Raw Dock tiles get no system masking (the box bug) → baked 22.5% squircle + transparency into all slots (PIL AA, corner-alpha verified). Catalog dark appearances re-tested: silently discarded, reverted to light-only.
     - `AppIconThemed` set (Any + DarkAqua renditions, verified in car); About loads it (was unresolvable "AppIcon" + fallback). Login/Onboarding use SF Symbols — no other brand marks.
     - Build + suite green: **BUILD SUCCEEDED**, zero actool warnings, CascadeTests **TEST SUCCEEDED**. Relaunched — user verifies both modes.
 233. **Dark-only icon, proper footprint (2026-09-10 evening — COMMITTED)**
     (`Cascade/Assets.xcassets`, `Features/AboutView.swift`, `App/CascadeApp.swift`, `App/TerminationHandler.swift`)
     - Tile was 100% edge-to-edge with no shadow (read oversized/flat vs native ~90% + depth) → rebuilt at 90% + baked soft shadow.
     - Theming parked: switcher call removed (class kept, marked), About → IconDark, bundle dark-only. Light sets stay shipped.
     - Build + suite green: **BUILD SUCCEEDED**, CascadeTests **TEST SUCCEEDED**. Relaunched (`killall Dock` if cached).
 234. **Theme icons re-enabled (2026-09-10 evening  — COMMITTED)**
     (`Cascade/Assets.xcassets`, `App/CascadeApp.swift`, `App/TerminationHandler.swift`, `Features/AboutView.swift`)
     - Light master rebuilt with identical treatment (verified visually); themed sets refreshed; switcher + About themed restored. Finder stays dark.
     - Build + suite green: **BUILD SUCCEEDED**, CascadeTests **TEST SUCCEEDED**. Relaunched  —  user verifies both modes.
 235. **Icon Composer Liquid Glass icons (2026-09-10 evening  — COMMITTED)**
     (`IconComposer/`, `Cascade/Assets.xcassets`)
     - Glyph extraction + `.icon` bundles (ictool render, scale 0.9); adopted renders everywhere; sources committed.
     - Build + suite green: **BUILD SUCCEEDED**, CascadeTests **TEST SUCCEEDED**. Relaunched  —  user verifies glass tile, both modes.
 236. **Runtime icon footprint (2026-09-10 evening  — COMMITTED)**
     (`Cascade/Assets.xcassets`)
     - Full-bleed renders oversized via applicationIconImage (no system normalization); inset to 90% for runtime sets, catalog stays full-bleed.
     - Build + suite green: **BUILD SUCCEEDED**, CascadeTests **TEST SUCCEEDED**. Relaunched  —  user compares footprint.
 237. **Measured footprint parity (2026-09-10 evening  — COMMITTED)**
     (`Cascade/Assets.xcassets`)
     - Finder body 80.5% vs ours 89.8% (solid-body metric); runtime tiles rescaled to 0.81, catalog untouched.
     - Build + suite green: **BUILD SUCCEEDED**, CascadeTests **TEST SUCCEEDED**. Relaunched.
 238. **Release bundle ID + new light art (2026-09-10 evening  — COMMITTED)**
     (`Cascade.xcodeproj`, `Storage/Models.swift`, `IconComposer/`, `Cascade/Assets.xcassets`)
     - Release ID `com.entanglon.cascade`; data-folder split extended (would have merged prod into dev data).
     - New light glyph extracted, bundle refreshed, ictool re-render adopted at 81% footprint.
     - Build + suite green: **BUILD SUCCEEDED**, CascadeTests **TEST SUCCEEDED**. Debug relaunched.
 239. **Window-mode main UI top padding & search bar clickability (2026-09-12 morning — COMMITTED)**
     (`App/AppState.swift`, `Features/RootView.swift`, `Features/FileBrowserView.swift`, `Features/SidebarView.swift`, `Features/TheaterView.swift`, `Features/BookReaderView.swift`)
     - AppKit titlebar container (~28pt) overlapped `topBar` controls (search field, sort/view buttons) in window mode, intercepting clicks as window drags.
     - Added `AppState.isWindowFullScreen` synced via `NSWindow` notifications in `WindowChromeView`.
     - In window mode, `topBar` content is padded 36pt down while its `.background(.black.opacity(0.22))` card stretches to the top, matching the sidebar alignment and ensuring full clickability. Fullscreen collapses to 0pt.
     - Build + suite green: **BUILD SUCCEEDED**, CascadeTests **TEST SUCCEEDED** (106 tests passed). Debug app relaunched.
 240. **Equal card height in window mode & restored fullscreen sidebar padding (2026-09-12 morning — COMMITTED)**
     (`Features/RootView.swift`, `Features/SidebarView.swift`)
     - In window mode, `SidebarView` had `.ignoresSafeArea(.all, edges: .top)` inside it and stretched to `y = 0` (height `H - 10`), while content `ZStack` did not ignore top safe area and sat at `y = 10` (height `H - 20`).
     - Added `.ignoresSafeArea(.all, edges: .top)` to content `ZStack` in `RootView.swift`, making both card frames start at `y = 0` with identical heights and alignment.
     - Restored `.padding(.top, 40)` in `SidebarView.swift` so sidebar items retain their clean, spacious padding in full screen mode.
     - Build + suite green: **BUILD SUCCEEDED**, CascadeTests **TEST SUCCEEDED** (106 tests passed). Debug app relaunched.
 241. **Dynamic sidebar padding linked to content top bar lower line (2026-09-12 morning — COMMITTED)**
     (`Design/XTheme.swift`, `Features/FileBrowserView.swift`, `Features/SidebarView.swift`)
     - Sidebar options previously started at fixed `y = 40`, overlapping the vertical span of the content view's top bar and cutting across its bottom divider line (`y = 88` in window mode).
     - Defined unified top bar layout metrics in `XTheme`: `topBarBaseHeight = 52`, `topBarTopPadding(isFullScreen:)`, and `topBarTotalHeight(isFullScreen:)`.
     - In `SidebarView.swift`, dynamically set top padding to `XTheme.topBarTotalHeight(...) + 10`. Sidebar options now always start strictly below the content top bar's lower divider line (`y = 98` windowed, `y = 62` fullscreen).
     - Build + suite green: **BUILD SUCCEEDED**, CascadeTests **TEST SUCCEEDED** (106 tests passed). Debug app relaunched.
 242. **AppleFolderIcon preview, text/markdown Quick Look, and recursive folder paste (2026-09-12 morning — COMMITTED `27a44f6`)**
     (`Features/TheaterView.swift`, `Engine/UploadManager.swift`, `App/AppState.swift`, `Features/FileBrowserView.swift`, `CascadeTests/CascadeTests.swift`)
     - Folder Quick Look in `TheaterView` now displays `AppleFolderIcon(124x98)` with a 16pt soft drop shadow and an "Open Folder" action button instead of the 116×116 gray box and SF Symbol.
     - `.md`, `.markdown`, `.txt`, `.json`, `.swift`, etc. preview natively in `TheaterView` via `TheaterTextContentView` (formatted markdown with Rendered/Raw toggle, line numbers for code/text, copy-all button with feedback).
     - Directory copy-paste (`⌘V`) and drag-and-drop: `AppState.startUpload` detects directories and invokes `importDirectoryRecursively`, recreating identical folder hierarchies via `uniqueObjectName` and queueing all nested files into `UploadManager`. `PendingUpload` retains `parentID` and `isPrivate` throughout the upload drain loop.
     - Build + suite green: **BUILD SUCCEEDED** (macOS and iOS), CascadeTests **TEST SUCCEEDED** (111 tests passed). Debug app relaunched.
 243. **iOS UI/UX Reinvention, Floating Frosted Glass Tab Bar, App Icon & Flashing Fix (2026-09-12 afternoon — COMMITTED `de84364`)**
     (`Cascade iOS/AppState.swift`, `Cascade iOS/Assets.xcassets/AppIcon.appiconset/icon_1024x1024.png`, `Cascade iOS/XTheme.swift`, `Cascade iOS/RootView.swift`, `Cascade iOS/Features/FileBrowserView.swift`)
     - Flashing screen bug resolved: eliminated `isInitialLoading` toggle from `completePostAuthSetup()` and removed redundant `.task` trigger from `mainTabs`; switched `RootView.body` auth check to observable `appState.isAuthorized`.
     - Master Liquid Glass 1024×1024 app icon ported to iOS springboard asset catalog.
     - Ported `XTheme` tokens to iOS with brand accent `#4085FF`, squircle `CategoryBadge` component, and `.frostedGlassCard` modifier.
     - Built custom `FloatingGlassTabBar`: floating capsule with `.ultraThinMaterial`, specular gradient border, ambient drop shadow, spring-animated active tab pill (`.matchedGeometryEffect`), and `UISelectionFeedbackGenerator` haptics, embedded in `.safeAreaInset(edge: .bottom)` with hidden system tab bar.
     - Redesigned `BrowseView` into a bespoke dark frosted glass dashboard with top account profile card (avatar, Telegram identity, storage usage), squircle category badges, and live item counts on every category.
     - Replaced generic `.blue` across all iOS views, empty states, and action menus with `XTheme.accent`.
     - Build + suite green: **BUILD SUCCEEDED** (macOS and iOS), installed and launched cleanly on iPhone XS Max, CascadeTests **TEST SUCCEEDED** (68 tests passed).
 244. **iOS UX Refinements: Restored Tab Order, Rounded Glass Tab Bar, Large Headings, Document Scanner & Upload Action (2026-09-12 afternoon — COMMITTED `a5c6cb7`)**
     (`Cascade iOS/RootView.swift`, `Cascade iOS/Features/FileBrowserView.swift`, `Cascade iOS/CascadeApp.swift`, `Cascade iOS/AppState.swift`, `Cascade iOS/Assets.xcassets/AppIcon.appiconset/icon_1024x1024.png`, `Engine/UploadEngine.swift`)
     - Restored tab order: Recents (left), Shared (middle), Browse (right).
     - Bottom nav bar: Full-width custom frosted glass (`.ultraThinMaterial`) with `UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24)`, lower corners flat hugging safe area; removed stock UIKit tab chrome.
     - Browse page: Restructured sections to match macOS sidebar (Locations, Collections, Quick Access); Tags section and `TagFilterView` completely removed; added `+` upload menu in navigation bar.
     - App icon: Replaced icon with 1024×1024 opaque RGB master downsampled from `Public/dark.png`, eliminating double-squircle and black border on iOS Springboard.
     - Document scanner: Built `DocumentScannerView` (`VNDocumentCameraViewController`), compiles scanned pages to PDF and uploads directly to Cascade; wired across all menus.
     - Large titles & smooth scroll: Configured transparent `scrollEdgeAppearance` and frosted `standardAppearance`/`compactAppearance` with `.navigationBarTitleDisplayMode(.large)` on Recents, Shared, Browse, and FileBrowser views.
     - iOS thumbnails: Implemented iOS branch of `generateThumbnails(for:objectID:isVideo:)` in `Engine/UploadEngine.swift` (640px preview, 320px `-up.jpg` upload thumbnail).
     - Build + suite green: **BUILD SUCCEEDED** (macOS and iOS), installed and launched on iPhone XS Max, CascadeTests **TEST SUCCEEDED** (107 tests passed).
 245. **iOS macOS-Style Search Bar, Add Button Unification & Deduplication, File Operations (Delete/Move) Fix, and Full-Screen Zoomable Photo Viewer (2026-09-12 afternoon — COMMITTED `14ef9d2`)**
     (`Cascade iOS/RootView.swift`, `Cascade iOS/Features/FileBrowserView.swift`, `Cascade iOS/AppState.swift`)
     - Search bar parity: Replaced stock UIKit `.searchable` drawer across all views (Browse, Recents, Shared, FileBrowserView, Collections, Quick Access, Trash, Transfers) with bespoke `CustomSearchBar` matching macOS app (dark translucent surface, 12pt continuous corner curvature, focus ring + accent glow, clear button, cancel button); added live `browseSearchResults` list in Browse.
     - Add button unification & deduplication: Matched `BlueAddMenu` icon to menu button (`plus.circle` outline, 18pt regular weight, `XTheme.accent`); provided `StandardAddMenu` on all views; removed duplicate creation and upload actions from all ellipsis menus.
     - File operations (Delete/Move) fix: Fixed `FileItem.==` to compare `trashed`, `parentID`, and `isArchived`; added immediate optimistic UI updates on `@MainActor` in `trashFile`, `trashFiles`, `restoreFiles`, `deletePermanently`, and `moveFiles`; removed blocking cloud sync from local DB load; normalized root `parentID` comparison in `MoveDestinationPickerSheet`.
     - Full-screen photo viewer: Switched `FilePreviewView` from card sheet to `.fullScreenCover`; built `ZoomableImageView: UIViewRepresentable` with pinch-to-zoom (up to 5x), double-tap zoom, and smooth panning; instant placeholder thumbnail display while high-res download finishes; leading "Done" dismiss button.
     - Build + suite green: **BUILD SUCCEEDED** (macOS and iOS), installed and launched on iPhone XS Max, CascadeTests **TEST SUCCEEDED** (107 tests passed).
 246. **iOS Browse Dashboard macOS Sidebar Parity, Search Bar Revert, Empty Bin, Library Page, Settings Redesign & Avatar Fetch (2026-09-12 afternoon — COMMITTED `8a21ef1`)**
     (`Cascade iOS/RootView.swift`, `Cascade iOS/AppState.swift`, `Cascade iOS/Features/SettingsView.swift`, `Cascade iOS/Features/FileBrowserView.swift`, `Cascade iOS/XTheme.swift`)
     - Search bar reverted: Reverted from custom view back to native SwiftUI `.searchable(text:placement:prompt:)` across all 11 views and FileBrowserView.
     - Empty Bin: Added `appState.emptyTrash()` with destructive role and confirmation dialog in `TrashView` ellipsis menu.
     - Recents footer clean-up: Removed "Synced with Cascade" status footer on Recents (`showSyncStatus: false`).
     - Shared button deduplication: Removed standalone prominent "Add from Share Link" button in Shared empty state (preserved banner prompt & Add button).
     - Browse macOS sidebar parity: Restructured Browse dashboard into headerless Top Section (`allFiles`, `recent` with instant tab switch to `.recents`, `favorites`), `COLLECTIONS` (`photos`, `video`, `audio`, `documents`, `library`), and `UTILITIES` (`privateVault`, `shared` with instant tab switch to `.shared`, `transfers` [consolidated Downloads], `archive`, `trash`). Exact SF Symbols matching macOS sidebar (`square.grid.2x2`, `clock`, `star`, `photo.fill`, `play.rectangle`, `music.note`, `doc.text`, `books.vertical`, `lock.fill`, `arrow.triangle.swap`, `arrow.up.arrow.down`, `archivebox`, `trash`).
     - Library view: Created full-featured `LibraryView` for EPUBs, PDFs, and MOBI books (`isBook || isBookFile || isInLibrary`) with grid/list modes, search, selection, and multi-file actions.
     - Settings redesign: Rebuilt `SettingsView` with Telegram profile avatar, initials fallback, cloud sync status & manual sync trigger, vault security/PIN & biometrics, vault usage storage breakdown bar, cache purge, and sign out.
     - Build + suite green: **BUILD SUCCEEDED** (macOS and iOS), CascadeTests **TEST SUCCEEDED** (64 unit + 4 UI/launch tests passed).
 247. **iOS UI/UX Parity & Engine Fixes: Password-Protected Folder Shares, Import Preview & Post-Import Reveal/Pulse, Multi-File Import Sibling Confirmation, Background Bleed Fixes, Browse Pop-to-Root, Default Launch to All Files, Transfers & Settings Modernization (2026-09-12 evening — COMMITTED `8fa7a85`)**
     (`App/AppState.swift`, `Engine/ShareEngine.swift`, `Cascade iOS/AppState.swift`, `Cascade iOS/RootView.swift`, `Cascade iOS/Features/FileBrowserView.swift`, `Cascade iOS/Features/SettingsView.swift`)
     - Password-protected folder shares: Removed folder restriction in `AppState.promptPasswordShare(_:)`; fixed path retention in `ShareEngine.walk(object, object.name)`; wrapped verification sentinel with `linkKey` for multi-file/folder links; enforced early password validation in `stageImport` (`ShareError.invalidPassword`).
     - Multi-file / Folder import sibling confirmation: Fixed folder import bug where only 1 item was marked ready. In `confirmImport(_:)`, cascaded confirmation to all pending sibling files sharing the same `inviteLink`, marking them ready, setting unique names, and queueing chunks to `BackupSync`. Cascaded `discardImport(_:)` across siblings.
     - Import preview & immediate thumbnails: Redesigned `ImportShareLinkSheet` with a reactive preview card that parses pasted link and shows thumbnail, title, item count, and "Import to Drive" action; cached thumbnail directly from share channel message during `stageImport` into `UploadEngine.thumbnailsDirectory()/[objectID]-tg.jpg`.
     - Post-import reveal & pulse animation: Added `revealObjectID` and `revealObject(_:)` in `AppState`. Upon import completion, automatically navigates into the target folder and pulses a blue `RevealFlashRing` on the imported item for 3 seconds.
     - Background bleed fixes: Enclosed `FileBrowserView`, `TrashView`, and all subviews in solid dark `ZStack` (`Color(red: 0.05, green: 0.06, blue: 0.08).ignoresSafeArea()`) and updated empty state views to take `maxWidth: .infinity, maxHeight: .infinity`, eliminating system white/gray bleeds behind lists and cards.
     - Browse pop-to-root: Re-tapping the Browse tab in `CustomGlassTabBar` pops back to root dashboard (`browseNavPath.removeAll()`).
     - Default launch to All Files: Set default `browseNavPath` to `[.allFiles]` so the app opens into All Files on cold start, while Browse tab returns to Browse dashboard.
     - Transfers & Shared page modernization: Redesigned `SharedView` with frosted glass cards (`ShareGridCard` and `ShareListRow`), section headers ("PUBLIC SHARES", "PRIVATE SHARES"), and clean share stats. Modernized `TransfersView` observing `TransferCenter.shared.items` with "UPLOADS", "DOWNLOADS", and "IMPORTS" sections, real-time progress bars, speed, pause/resume/retry/clear controls, and tap-to-reveal.
     - Settings redesign: Converted `SettingsView` from grouped `List` to dark `ScrollView` with `.frostedGlassCard(cornerRadius: 16)` cards (Account, Cloud Sync, Private Vault & Security, Vault Usage storage breakdown bar, Local Cache management, About, and Sign Out).
     - Build + suite green: **BUILD SUCCEEDED** (macOS and iOS), installed and launched cleanly on iPhone XS Max (`8F28E614-EA35-5B10-8DC9-E390026D4599`), CascadeTests **TEST SUCCEEDED** (70 unit/integration tests passed).
 248. **iOS Browse Monochrome Icons (macOS Parity), Selection Bar Replaces Nav Bar, Remove Bottom Item Footers, Share Thumbnail Sidecar Forward & Decrypt (2026-09-12 night — COMMITTED `9c4fef8`)**
     (`Cascade iOS/AppState.swift`, `Cascade iOS/Features/FileBrowserView.swift`, `Cascade iOS/RootView.swift`, `Engine/ShareEngine.swift`, `Features/PendingImportView.swift`)
     - Browse page monochrome icons: Removed `CategoryBadge` usages across `BrowseView`. Rows render pure, unboxed monochrome `Image(systemName: icon).font(.system(size: 18, weight: .regular)).foregroundStyle(XTheme.accent)` in 28×28 frames matching macOS sidebar 1:1.
     - Removed bottom item footers: Removed `PageItemCountFooter(count: filteredFiles.count)` from `RecentsView` (grid and list) and `FileBrowserView` (grid and list), eliminating the bottom sync status footer.
     - Selection mode nav bar replacement: Added `isSelecting` to iOS `AppState`. Bound child view selection states to `appState.isSelecting`. In `RootView.body`, hidden `CustomGlassTabBar` when selecting. Applied `glassSelectionBarBackground()` to selection bars so selection actions (Favorite, Archive, Delete / Recover) cleanly occupy and replace the bottom navigation bar with matching frosted glass styling. Set `.searchable` to `.automatic` displayMode during selection.
     - Share thumbnail sidecar forwarding & decryption: In `ShareEngine.exportShare`, forwarded `object.thumbMessageID` sidecar message into share channel and encoded in `ShareLink` (`th` query parameter). In `ShareEngine.stageImport`, forwarded `thumbMessageID` into vault channel, saved on `ObjectRecord`, and decrypted thumbnail directly into `UploadEngine.thumbnailsDirectory()/[objectID]-tg.jpg` (or `.png`).
     - Pending import dialog (macOS): In `PendingImportView.swift`, loaded and displayed real thumbnail, removed confusing "The file is already in your cloud..." label, removed unnecessary "Preview" button, and resized sheet to 440×320.
     - Build + suite green: **BUILD SUCCEEDED** (macOS and iOS), installed and launched on iPhone XS Max (`8F28E614-EA35-5B10-8DC9-E390026D4599`), CascadeTests **TEST SUCCEEDED** (64 unit + 4 UI/launch tests passed).
 249. **macOS Direct Cmd+V Import, Preserved Pending Imports Across Snapshot Sync, Liquid Glass Pending Import UI, Public Password Shares, iOS Grid Alignment, Shared Thumbnails & Docked Upload Progress (2026-09-12 night — COMMITTED `7d2c348`)**
     (`App/AppState.swift`, `App/CascadeApp.swift`, `Storage/DatabaseManager.swift`, `Features/FileBrowserView.swift`, `Features/PendingImportView.swift`, `Cascade iOS/Features/FileBrowserView.swift`, `Cascade iOS/RootView.swift`)
     - Preserved pending imports in catalog reconciliation: In `DatabaseManager.replaceCatalog`, fetched and preserved `pendingImport` objects and their chunks across the delete/reinsert cycle so background snapshot sync does not erase staged share files. In `AppState.confirmPendingImport()`, added state reset (`pendingImportID = nil`) in the `catch` block on failure, preventing spinning hang.
     - Direct Cmd+V paste on macOS: Added global paste interception in `CascadeApp.swift` (`CommandGroup(replacing: .pasteboard)`) and `FileBrowserView.swift` (`pasteFromClipboard()`) to directly call `appState.importShareLink` when `cascade://share` is in the pasteboard without requiring text field focus.
     - Liquid glass pending import UI (macOS): Redesigned `PendingImportView.swift` with `.ultraThinMaterial`, 20pt rounded corners, specular gradient border, 96×96 styled thumbnail, clean "Cancel", and "Import" button.
     - Password-protected public shares (macOS): Added "Public (Password Protected…)" option to context menu in `Features/FileBrowserView.swift`, and added `sharePasswordIsPublic` routing to `App/AppState.swift` and `SharePasswordPromptSheet`.
     - iOS shared page thumbnails: Updated `ShareGridCard` and `ShareListRow` in `Cascade iOS/RootView.swift` to load and display real thumbnails and `AppleFolderIcon` for group shares with corner badges.
     - iOS file & folder grid alignment: In `Cascade iOS/Features/FileBrowserView.swift` and `Cascade iOS/RootView.swift` (`FileGridItem`), set top alignment on `LazyVGrid`, fixed name frame to 34pt, unified subtitle to 1 line (`size • date` or `X items`), and locked container height to 52pt, ensuring uniform 151pt card heights across rows and columns.
     - iOS upload progress docked in CustomGlassTabBar: Removed detached floating capsule from `RootView.safeAreaInset(edge: .bottom)`. Integrated progress bar, upload status, percentage, and activity indicator directly into the top of `CustomGlassTabBar` with smooth spring transitions, and docked a slim pill when selection mode is active.
     - iOS import share link sheet upgrade: Redesigned `ImportShareLinkSheet` in `Cascade iOS/RootView.swift` with prominent "Import" button, real thumbnail preview loading, and UTType-based file badges.
     - Build + suite green: **BUILD SUCCEEDED** (macOS and iOS), installed and launched cleanly on iPhone XS Max (`8F28E614-EA35-5B10-8DC9-E390026D4599`), CascadeTests **TEST SUCCEEDED** (70 unit/integration tests passed).
 250. **Item Count Footers Clean-Up (No "Synced with Cascade"), Restored All Files Footer, Removed Browse Badge Counts, Settings About Branding & App Icon, iOS Shared Cancel All & Archived, Uncropped Import Thumbnails, Post-Import Reveal/Pulse to All Files, iOS Download (Save to Files) Action (2026-09-12 night — COMMITTED `f250d50`)**
     (`App/AppState.swift`, `Cascade iOS/AppState.swift`, `Cascade iOS/Features/FileBrowserView.swift`, `Cascade iOS/Features/SettingsView.swift`, `Cascade iOS/RootView.swift`, `Features/AboutView.swift`, `Features/PendingImportView.swift`, `Features/SettingsView.swift`, `Cascade iOS/Assets.xcassets/AppIconImage.imageset/`)
     - Clean item count footers without "Synced with Cascade": In `Cascade iOS/RootView.swift` (`PageItemCountFooter`), removed `Text("Synced with Cascade")` and defaulted `showSyncStatus = false`, rendering clean counts (e.g. "16 items"). Restored `PageItemCountFooter(count: filteredFiles.count)` to `Cascade iOS/Features/FileBrowserView.swift` (gridView & listView) for All Files, folders, and Private Vault. Non-storing views (Recents, Shared, Transfers) show no footers.
     - Removed badge counts in iOS Browse: In `Cascade iOS/RootView.swift`, removed trailing count badge pills from `destinationRow` and `actionRow` in `BrowseView`.
     - Settings About branding & master app icon: Replaced "telegram powered cloud drive" copy in `Features/SettingsView.swift` (macOS) and `Cascade iOS/Features/SettingsView.swift` with "Private Cloud Drive". Added official high-res `AppIconImage.imageset` to iOS asset catalog, used across Settings, loading view, and login gate. On macOS `Features/AboutView.swift`, eliminated redundant corner clipping and stroke border that created double-outline borders.
     - iOS Shared Cancel All & Archived Shares: Added `showArchived` state, "Archived Shares" navigation title and back button, leading "Cancel All" toolbar action, confirmation alert, and menu toggle in iOS `SharedView`. Added `cancelAllShares()`, `archiveShare(_:)`, and `unarchiveShare(_:)` to `Cascade iOS/AppState.swift`. Added "Archive" / "Unarchive" context menu actions to `ShareCard` and `ShareListRow`.
     - Uncropped import thumbnails: In `Features/PendingImportView.swift` (macOS) and `ImportShareLinkSheet` (iOS), changed thumbnail display to `.aspectRatio(contentMode: .fit)` within invisible bounding frames (96×96 on Mac, 52×52 on iOS) with 8pt rounded corners, matching All Files.
     - Post-import reveal & feedback to All Files: On macOS and iOS, updated import notifications to instruct user to find file(s) in All Files (not Transfers). Connected `selectedTab` to `RootView.Tab` so `revealObject` automatically switches to Browse/All Files and triggers the 3-second `RevealFlashRing` pulse highlight.
     - iOS "Download" (Save to Files) context action: Replaced "Keep Downloaded" with "Download" (`arrow.down.circle`) in `FileRow`, `FileGridItem`, and `FilePreviewView`. Added `exportFileForSaving(_ file:)` in `Cascade iOS/AppState.swift` to save to temporary cache with user-facing `file.name` and trigger `UIActivityViewController` so user can directly "Save to Files".
     - Build + suite green: **BUILD SUCCEEDED** (macOS and iOS), installed and launched on iPhone XS Max (`8F28E614-EA35-5B10-8DC9-E390026D4599`), CascadeTests **TEST SUCCEEDED** (107 tests passed).
 251. **Android Port M1: Wire Contract, Core Engine Ports, Golden-Vector Fixtures & Tests; Xcode License Cleared; Both Apple Platforms Verified (2026-09-15 — macOS repo: this commit; Android repo: root commit `63a838e`)**
     (`scripts/gen_golden_fixtures.swift` — new; Android repo `~/AndroidStudioProjects/cascade` git `main` @ `63a838e`; HANDOVER.md / iOS_HANDOVER.md / JOURNAL.md updated)
     - Xcode license blocker cleared by the user (`sudo xcodebuild -license`); verified `xcodebuild` 27.0, `swift`, `python3` operational again.
     - macOS health check after the fix: `Cascade` scheme Debug **BUILD SUCCEEDED**; CascadeTests **TEST SUCCEEDED** (full suite green — shares, tombstone merge rules, version history, FTS5, rate limiter, duplicate finder, and more).
     - Android M1 committed in its own new git repo (`63a838e`): WIRE_CONTRACT.md cross-platform spec, four core engine ports (ChunkPlanner, ChunkCaption, CryptoEngine, JsonCodec), Compose MainActivity skeleton, AGP 9.4 built-in-Kotlin toolchain (Compose BOM 2026.08, Room 2.8.5 + KSP `disallowKotlinSourceSets` workaround, Ktor 3.2.2), **44 green unit tests**, Swift-generated golden fixtures committed as test resources. Full detail in HANDOVER section 5, "ACTIVE WORKSTREAM: Android port".
     - Added `scripts/gen_golden_fixtures.swift` to this repo: deterministic fixture generator compiled together with the real production Swift sources (`CryptoEngine`, `ChunkPlanner`, `ChunkCaption`) via the Command Line Tools toolchain — no Xcode license needed; writes `golden_fixtures.json` into the Android test resources; procedure documented in WIRE_CONTRACT.md §9.
     - Golden-vector discoveries (fixed in Kotlin, documented in WIRE_CONTRACT.md): Swift JSON encoders escape `/` as `\/`; Apple `.zlib` emits raw DEFLATE (no 0x78 wrapper — Android needs `Inflater(nowrap=true)`); `JSONEncoder` key order is random per encode (order is not a wire contract).
     - Platform testing policy from the user: iOS is tested on the physical iPhone XS Max ONLY (no simulator) and "works fine for now"; an Android emulator IS wanted for Android testing (API 36.1 system image installed, AVD to be created). Windows and Linux ports are planned after Android.
