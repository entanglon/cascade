# xCloud — Development Journal

>> Chronological log of the work on the Freebuff/xCloud macOS app. Companion to
> HANDOVER.md (current state) and ROADMAP.md (deferred plans). Last entry:
> 2026-08-16 — forward-based shares (see end).

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
