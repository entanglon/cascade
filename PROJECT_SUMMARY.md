# xCloud — Project Summary

> Written 2026-08-10. A working log of what the app is and everything we've built, fixed,
> and decided so far. Pair with [ROADMAP.md](./ROADMAP.md) for what's next.

## What the app is

**xCloud** is a macOS-native SwiftUI app that turns a Telegram account into "unlimited" cloud
storage. Files are chunked, uploaded into a private Telegram channel, and catalogued in a
local encrypted SQLite database (GRDB). The vault is encrypted client-side; Telegram only
holds ciphertext. Sessions are restored via the macOS keychain.

### Architecture at a glance

| Piece | Role |
|---|---|
| `Engine/UploadEngine.swift` / `DownloadEngine.swift` | Chunked transfer engines with pause/resume, progress reporting, LRU cache |
| `Engine/ChunkPlanner.swift` | Chunk-size selection (standard 128 MB, archive 256 MB, media 64 MB) |
| `Engine/AudioPlayerEngine.swift` + `Features/MPVVideoView.swift` | **mpv-only media engine** — the single player for audio AND video (see `docs/PLAYER.md`) |
| `Engine/VideoStreamingEngine.swift` + `Engine/VaultStreamServer.swift` | Byte-range streaming of uncached files from Telegram → local loopback HTTP → mpv |
| `Engine/TransferCenter.swift` | Transfer card registry, state machine, refresh notifications |
| `Telegram/TelegramClient.swift` | TDLib wrapper — sendFile/uploadFile/download, flood-wait handling, cancellation |
| `Storage/` (DatabaseManager, Models, VaultRepair) | GRDB catalog + migrations, object/chunk records, orphan/duplicate repair |
| `Features/` | FileBrowserView, SidebarView, TheaterView, MiniPlayerView, TransfersView, LiquidMorphingFAB, RootView |
| `App/AppState.swift` | Global state: selection, sorting, undo/redo stack, bootstrap, TDLib lifecycle |

### Media playback (2026-08-15 state)

**mpv is the only player. AVFoundation/AVKit are removed from the codebase entirely** (user
mandate — it kept resurrecting as a fallback player + thumbnail generator and caused the
"QuickTime player" and AV1 lag incidents). Cached files play from disk via mpv; uncached
files stream byte-by-byte from Telegram through a loopback HTTP range server; audio plays
headless through mpv. HDR tone-mapping (PQ→SDR on this display), Dolby/DTS (FFmpeg decode +
optional bitstream passthrough), EOF playlist auto-advance, and per-second telemetry are all
implemented and verified. Full reference: [`docs/PLAYER.md`](./docs/PLAYER.md).

### Current chunking scheme
- **Standard documents:** 128 MB (a 1 GB file → 8 chunks)
- **Archives > 50 GB:** 256 MB
- **Media (video/audio):** 64 MB
- The chunk size used is **stored per object** (`chunkSize` column, DB migration v6), so
  resumed uploads re-derive identical boundaries even if global constants change later.

### Known platform limits (researched)
- Telegram document cap: 2 GB/message (4 GB Premium) — chunks are ~15× under this.
- `FLOOD_WAIT` throttling handled automatically; chunks upload slowly enough to avoid it.
- Daily message cap (~9 messages per 1 GB file) allows roughly 30–100 files/day.
- Local download cache: **adaptive LRU** — a hard cap (default 5 GB, user-configurable in
  Settings, 0 = unlimited) plus a free-space floor that evicts oldest-accessed files when
  the disk drops below 15 GB; enforced at launch, on a 30-min timer, and around downloads;
  manual "Clear Cache" in Settings; thumbnails are separate.

---

## Session work log (2026-08-09 → 08-10)

### Stability & build
- **Fixed the repeated crashes (test-host TDLib teardown segfault).** When Xcode runs unit
  tests, it launches the full app (TDLib included) as a test host; XCTest ends the process
  with `exit()`, which runs C++ teardown while TDLib's receive thread is still polling →
  `EXC_BAD_ACCESS` in `td::json_receive`. Fix: the app detects XCTest
  (`XCTestConfigurationFilePath`) and **skips starting TDLib during unit tests** — the tests
  only exercise `TransferCenter`, which doesn't need Telegram. All 6 historical crash reports
  matched this signature; no new reports since.
- Rebuilt with **code signing enabled** (unsigned debug builds logged the session out and
  triggered repeated keychain prompts). Note: each fresh binary signature still triggers one
  "Always Allow" keychain prompt — expected, not a bug.

### Transfer engine
- **Immediate pause:** pause now cancels the in-flight chunk's send instantly (task
  cancellation, no message posted, no record written). Resume restarts that chunk from
  scratch; fully completed chunks are kept. The pause settles without waiting for a 256 MB
  chunk to finish.
- **Resume correctness:** `begin` reuses the paused card instead of duplicating; resume is
  blocked while a pause is still settling (prevents two tasks racing on one object); a stale
  source settles into a clear "Source no longer available — discard" failure.
- **Real-Time Byte Transfer Progress**:
  - Wired `TelegramClient.swift` file progress handlers to TDLib `updateFile` (tracking `uploaded_size` and `downloaded_size`).
  - Progress updates continuously across all chunk boundaries in `TransferCenter` and card popouts.

- **Google Keep-Style Encrypted Notes**:
  - Added `.notes` destination to `SidebarDestination` under Library.
  - Added `NoteRecord` GRDB model and database migration `v7-notes`.
  - Implemented `NotesView.swift` with top expandable quick-input bar (*"Take a note or paste a link..."*), pastel/vibrant glass note cards, link auto-detection (clickable URL badges), color picker, pin toggle, and tag filtering.
  - Implemented `NoteEditorSheet.swift` for editing long notes with Markdown preview mode and timestamps.nt badge when multiple are running. `TransferCenter.Item.totalWork` carries the
  weighting through pause/resume.
- **Realtime file refresh:** uploads that completed via the resume/retry card path never
  refreshed the file list (files only appeared after Cmd+R). `TransferCenter.finish` now
  posts `xCloudUploadFinished`; `RootView` reloads immediately on success. Failed uploads
  deliberately don't refresh.
- **Cancellation plumbing:** `TelegramClient` gained cancellation handlers so
  sendFile/uploadFile/download abort promptly; the stale-send cache is bounded; the upload
  "failed but actually completed" weirdness is cleaned up by `VaultRepair`'s orphan purge.
- **Chunking change:** standard 256 MB → **128 MB**, archive 512 MB → **256 MB**, media
  stays 64 MB; stored per object so in-flight uploads never misalign.

### File management UX (Finder-level)
- **Marquee (rectangle) selection:** drag on empty space in grid or list to draw an
  accent-tinted selection rect; cards report frames via a `GridFrameKey` preference;
  ⌘/⇧-drag adds to the selection.
- **Multi-file drag:** dragging any card in a selection drags the whole selection
  (newline-joined IDs); all drop targets (Trash, Favorites, folder cards, list rows) parse
  multi-ID payloads; the drag preview shows an "N items" capsule.
- **Selection-aware context menus:** right-clicking a file inside a multi-selection applies
  every action (move/trash/restore/delete/favorite/playlist) to the whole selection, with
  count-aware labels ("Move 3 Items to Trash").
- **Unified page context menus:** New Album (Photos), New Playlist (Video/Audio),
  Lock Now (Private Vault), Empty Trash, plus New Folder / New Private Folder / Upload /
  Sort By — attached to grid, list, and empty state. This let us remove page-specific
  buttons from the top bar.
- **Centered top bar:** symmetric 210 pt left/right zones so the search pill is dead-center
  on every page; it shrinks (360 → 140) instead of colliding in narrow windows.
- **Menu bar cleanups:** removed the duplicate "View" menu (`CommandMenu` →
  `CommandGroup(after: .toolbar)`); `WindowChromeFixer` now applies styling in
  `viewDidMoveToWindow` (race-free) and kills the titlebar separator.
- **Quick Look (space bar):** images toggle open/close; **folders** show a details panel
  (kind, recursive size, item count, dates) instead of opening; **unsupported files** show an
  info panel with an "Open with Default App" button; no more auto-downloading just to
  preview. Left/right arrows navigate in the exact on-screen order.
- **Viewer fixes:** `TheaterView.mediaFiles` mirrors the browser's sort (name/date
  created/date modified/size/kind × ascending) so arrow navigation matches the grid both
  directions; the global key monitor passes keys through once the viewer detaches; focus
  returns to the browser on close so space reopens the last viewed image; browser selection
  syncs with viewer navigation.
- **Undo/redo:** `Cmd+Z` / `Cmd+Shift+Z` for moves, trash/restore, rename, favorite toggle,
  creating folders/playlists/albums/private folders, and add-to-playlist. Permanent
  "Delete Forever" is intentionally not undoable.
- **Row-aware arrow navigation:** up/down no longer jumps by a fixed column count over the
  two-section grid (folder rows ≤ 4 columns + full-width file grid). `gridVerticalStep`
  computes true visual (row, col) positions and moves to the same column in the target row,
  falling back to the closest column; folder-under-folder works too.
- **Skeleton loading:** startup shows a YouTube-style placeholder feed (folder cards + file
  grid, shimmer sweep) gated by `isInitialLoading`, so "Nothing Here Yet" can never flash
  during the DB open / Telegram reconciliation window.
- **Drag-to-Trash sidebar:** fixed by loading the payload with `NSString.self` (matches the
  working folder-drop path) — multi-file drops supported.
- **Transfer cards:** action buttons restyled to match file cards (dark glass circle +
  white ellipsis), with a card menu exposing Pause / Resume / Cancel & Delete (active
  uploads) and the rest.

### Testing
- Test suite grew from 7 → **11 tests**, all passing (`xcodebuild test`).
- Coverage: transfer pause/resume card lifecycle, begin-reuse, download-cancel semantics,
  discard (immediate + stops running task), resume-while-settling, resume-after-settle,
  upload-finish refresh notification, stored-chunk-size plan, and two grid-navigation
  regression tests.
- Crash-report count verified stable after the TDLib fix (6 xCloud reports total, all from
  before the fix).

### Strategy & decisions
- **Uniqueness vs Unlim Cloud:** the core concept (Telegram as storage) is **not unique** —
  the genre includes Unlim, TeleCloud, GigaDrive, and OSS projects. The differentiator is
  execution: real chunked resume, a filesystem layer (folders/albums/playlists/vault),
  Finder-grade UX, and polish. Competing on craft + trust, not on the idea.
- **Open source:** honest expectation — donations would be minimal for this niche; modest
  fame is plausible (Show HN / r/MacOSApps / Product Hunt, current demand signal in mid-2026
  Reddit/dev.to threads). If we open-source: security-audit the keychain/encryption path
  first, strip personal/session data, add README + screenshots, then release. Alternatives:
  keep core closed + open a lite version, or add a paid premium tier.
- **Roadmap:** Tier 1 — parallel chunk uploads, folder watch auto-sync, vault recovery key.
  Tier 2 — menu bar presence/background transfers, duplicate detection, smart folders,
  storage analytics. Tier 3 — Finder integration, offline pinning, share-link bot, AI
  organization. See `ROADMAP.md`.

### Git state
- Everything from this session is committed on `main`:
  `0ae55d9` — "Harden chunked transfers and add Finder-level file management UX"
  (20 files, +2,227 / −481; includes this file, `ROADMAP.md`, and a new `.gitignore`).
- `.freebuff/desktop-v2.db*` (Freebuff's own tool DB) and `build/` (test artifacts) are
  intentionally left out of commits; `build/` is gitignored.

---

## How to verify / run

```bash
# Build (signed debug)
xcodebuild -project xCloud.xcodeproj -scheme xCloud -configuration Debug build

# Run tests
xcodebuild -project xCloud.xcodeproj -scheme xCloud -configuration Debug -derivedDataPath build test

# Launch the built app
open ~/Library/Developer/Xcode/DerivedData/xCloud-*/Build/Products/Debug/xCloud.app
```

The unit tests skip TDLib (no Telegram session needed); the UI test target is the
`xCloudUITests-Runner` bundle.
