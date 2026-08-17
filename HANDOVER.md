# xCloud — Session Handover

> Written 2026-08-14, updated 2026-08-16. Read this first in any new chat before touching
> the code. It captures the repo state, the uncommitted work in flight, how to
> build/run/test, known gotchas, and what is still pending.

---

## 1. What this project is

**xCloud** — a native macOS SwiftUI app (the "Freebuff desktop" project) that turns a
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
available). Uses `Logger(subsystem: "com.xcloud.app", ...)` for app logging.

---

## 2. Build / run / test

**CRITICAL — two copies of the project exist and the user's Xcode builds the MAIN
folder, not the worktree.** This caused a multi-hour incident on 2026-08-15: the agent
edited + built the worktree (`xCloud-wt`), the user rebuilt from Xcode (main folder,
`xCloud-cdpcjcegyfsbheeztqhmjnnukgcv`) and saw an "old app" — their work appeared
gone, and every agent fix looked invisible. The main folder was missing whole files
(BookReaderView, MediaGridShared, Photos/VideosGridView, BookLoader, FaceEngine,
ShareEngine) and its pbxproj didn't reference them. FIXED by rsync'ing worktree → main.

**RULE: after ANY agent edit, sync the changed files worktree → main, and build the
MAIN folder** (that is the build the user actually runs):

```bash
WT=/Users/zainulnazir/Projects/xCloud/.freebuff/worktrees/b32b5e13-4ff7-4e37-924e-76f15c4c2d98
MAIN=~/Projects/xCloud
rsync -a --exclude '.git' --exclude '.freebuff' --exclude 'xcuserdata' --exclude 'DerivedData' \
      --exclude '*.dmg' --exclude '*.profraw' --exclude '.swiftpm' "$WT/" "$MAIN/"
cd "$MAIN" && xcodebuild -project xCloud.xcodeproj -scheme xCloud -configuration Debug \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/xCloud-cdpcjcegyfsbheeztqhmjnnukgcv build
```

The user's Xcode / Dock launch uses the MAIN folder's DerivedData
`xCloud-cdpcjcegyfsbheeztqhmjnnukgcv`. The worktree DerivedData `xCloud-wt` is only for
agent-side typecheck/test runs. If you ever `open` an app binary for the user, open the
MAIN folder's build, not the worktree's.

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
    `share_state`); the link is an obfuscated `xcloud://share#...` blob carrying
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
    (`xcloud:share:v1:`, `ChunkMeta`, no id) parse only via
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
      thumbnail-service path and writes `/tmp/xcloud-vidthumb-result.txt` (stdout is
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
      object IDs/keys (resumable across runs, logs to `/tmp/xcloud-recover-progress.txt`).
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
    - **Ground truth verified**: main DB (`~/Library/Application Support/xCloud/xcloud.sqlite`,
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
      `/tmp/xcloud-backup.log` (the unified log is unreadable on this machine and
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
      (`script -q /tmp/xcloud-app.log <binary>` — stdout prints are block-buffered
      when redirected to a plain file, invisible; the pty makes them line-buffered)
      → restore succeeded: "19 objects, 22 chunks", all chunk message IDs present.
      No re-upload was needed — the files were in the channel all along.
    - **Stale-binary incident**: an earlier "nothing happened" trace was the
      pre-rewrite binary still running (started 14:44; its log showed
      `xcloud:share:v1:` captions + share-tmp uploads). Always relaunch on a fresh
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
      `open xcloud://share#…` → running app receives the URL, self-opens (reveals +
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

## 5. Pending / next steps

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
- **The app's REAL database** is `~/Library/Application Support/xCloud/xcloud.sqlite`
  (the app is unsandboxed). The container paths
  (`~/Library/Containers/com.nemesys.xcloud.xCloud/...`) and
  `~/Library/Application Support/xCloud/xcloud.sqlite.bak-*` are STALE — don't query
  them for live debugging (migrations only to v10 there). `sqlite3` reads work fine
  while the app runs (WAL).
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
      (deterministic across processes). Legacy `xcloud:v1:` / `xcloud:share:v1:`
      captions are still parsed forever; writers are unified only. Legacy share
      captions (`ChunkMeta`, no id) parse via `ShareEngine.parseChunkMeta` only.
    - **v2 share link**: `xcloud://share?v=2&…&m=<comma msgIDs>&w=<wrapped>`;
      `m` names the file's forwarded messages in the REUSABLE "xCloud Shares"
      channel; `w` is the object key re-wrapped under a fresh share key, EMPTY for
      non-private files. `ShareLink.parse` accepts an empty `key` for v2 (only
      demands it when `w` is non-empty, or for v1). Transported obfuscated as
      `xcloud://share#<blob>`; re-sharing a live share returns the IDENTICAL link.
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
