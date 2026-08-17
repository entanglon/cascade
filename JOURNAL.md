# xCloud — Development Journal

>> Chronological log of the work on the Freebuff/xCloud macOS app. Companion to
> HANDOVER.md (current state) and ROADMAP.md (deferred plans). Last entry:
> 2026-08-17 (evening) — Post-v3 polish: Shared page redesign, Library covers,
> transfer clarity, Release reinstall to /Applications.

---

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
