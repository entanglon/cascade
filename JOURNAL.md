# xCloud — Development Journal

> Chronological log of the work on the Freebuff/xCloud macOS app. Companion to
> HANDOVER.md (current state) and ROADMAP.md (deferred plans). Last entry:
> 2026-08-15 — photos page fixes (see end).

---

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