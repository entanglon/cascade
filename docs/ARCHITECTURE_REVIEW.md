# Architecture Review — xCloud (→ Cascade)

> Deep-dive analysis of the current codebase. Read before any rename or refactor.

---

## 1. Storage Architecture

### How it works today

Files live in a **single Telegram channel** ("vault") as plaintext chunk documents. Each chunk is a separate Telegram document with a JSON caption (`xcloud:{...}`) carrying metadata (object ID, name, size, mime, parent, index, hash). The vault channel is a flat list of messages — there are no actual Telegram folders or sub-channels.

**Upload flow:**
1. File → `ChunkPlanner` splits into 64–256 MB chunks (based on media type)
2. Each chunk → temp file → `TelegramClient.sendFile()` to vault channel
3. Each chunk's `messageID` → saved as `ChunkRecord` in local SQLite
4. Object metadata → `ObjectRecord` in local SQLite (state: uploading → ready)
5. Object + all chunk captions → published as catalog checkpoint/delta in vault channel

**Download flow:**
1. Object's `ChunkRecord`s → sorted by index → each chunk's `messageID` → TDLib `downloadFile`
2. Chunks concatenated → local cache file (`~/Library/Application Support/xCloud/cache/<id>.<ext>`)
3. Cache hit check: file exists AND size == object.size (partial files don't count)

**Streaming flow (uncached files):**
1. `VideoStreamingEngine` loads layout (chunk offsets) → `VaultStreamServer` serves 1 MB slices via HTTP byte-range
2. mpv reads from `http://127.0.0.1:PORT/stream/<id>` — no disk download needed
3. Slices cached in-memory (`SliceCache`) for repeated reads

**Catalog sync (cross-device):**
- Local SQLite = source of truth
- Checkpoint message = full catalog JSON in one message (published every 24h or on 200+ changes)
- Delta message = only changed records (published on routine changes)
- Reconcile on launch: fetch newest checkpoint + newer deltas → LWW merge by `modifiedAt`
- Another device sees changes within ~4 seconds (debounced upload)

### Is the storage architecture good?

**Yes, it's surprisingly solid.** The design is clever and unconventional:

| Aspect | Assessment |
|--------|-----------|
| **Telegram as storage backend** | Works. No server costs, built-in encryption in transit, works on any device with Telegram. The 2 GB/file limit is irrelevant (128 MB chunks). Flood control is handled. |
| **Chunking scheme** | Well-tuned: 128 MB standard, 64 MB media, 256 MB archive. Per-object stored chunk size means resume never misaligns. |
| **Catalog sync** | Battle-tested pattern (same as Syncthing/CRDT). LWW merge is idempotent. Checkpoint + delta bounds restore cost. |
| **Byte-range streaming** | Elegant — mpv plays any container without downloading the whole file. 8-slice batching amortizes Telegram round trips. |
| **Plaintext storage** | Simple and correct after encryption was dropped. The `isPrivate` flag + vault PIN gate controls visibility; chunks are just bytes. |
| **Backup mirror** | Cheap reference forward (no re-upload). Covers vault deletion scenarios. |

**The one structural concern:** everything funnels through a single Telegram channel. This works for personal use (your test account has ~30 files) but could hit Telegram's message limits at scale (thousands of files = thousands of chunk messages + catalog messages). The catalog checkpoint/delta messages add to this. Not a problem today, but worth noting.

### Should files upload to root by default?

**No — and the app already handles this correctly.** The upload path takes `parentID` as a parameter, and the UI (drag-drop, FAB, context menu) passes the current folder's ID. Files only land at root if the user is viewing root when they upload. The `uniqueName` dedup prevents collisions.

The real UX question is whether the FAB / upload action should **prompt** the user to pick a destination folder when uploading from root (like iCloud Drive does). Currently it just uploads to the current location, which is the expected Finder-like behavior. This is fine.

---

## 2. Code Architecture

### Current structure

```
App/
  AppState.swift          (2292 lines — THE problem)
  xCloudApp.swift         (scene setup)
  TerminationHandler.swift (URL handling, window management)
  AppPaths.swift          (data folder paths)

Engine/
  UploadEngine.swift      (655 lines — upload + thumbnail + book cover)
  DownloadEngine.swift    (293 lines — download + cache)
  VideoStreamingEngine.swift (484 lines — byte-range streaming)
  VaultStreamServer.swift (HTTP server)
  ShareEngine.swift       (share link creation/import)
  AudioPlayerEngine.swift (mpv playback + system volume)
  BackupSync.swift        (backup channel mirroring)
  ThumbnailService.swift  (thumbnail generation + caching)
  FaceEngine.swift        (on-device people recognition)
  TransferCenter.swift    (transfer card state machine)
  ChunkPlanner.swift      (chunk size selection)
  ChunkCaption.swift      (JSON caption codec)
  ChannelAvatar.swift     (branded channel photos)
  VideoFrameExtractor.swift (FFmpeg frame extraction)

Storage/
  DatabaseManager.swift   (1073 lines — all DB operations)
  Models.swift            (368 lines — all GRDB models)
  CatalogSnapshot.swift   (454 lines — checkpoint/delta sync)
  VaultManager.swift      (vault channel setup)
  VaultRepair.swift       (channel scan + repair)

Telegram/
  TelegramClient.swift    (1493 lines — ALL TDLib operations)

Features/
  FileBrowserView.swift   (THE file grid)
  TheaterView.swift       (preview + audio player)
  RootView.swift          (main layout + sidebar)
  SidebarView.swift       (sidebar destinations)
  SettingsView.swift      (settings)
  ... (20+ view files)

Crypto/
  KeychainStore.swift     (keychain operations)
```

### The core problem: AppState is a God Object

`AppState` (2292 lines) is the single biggest architectural issue. It owns:

- **File browser state**: `files`, `currentFolderID`, `selectedFiles`, sorting, grid column count
- **Share state**: `incomingShares`, `outgoingShares`, `shareResultLink`, pending imports
- **Playback state**: `theaterFile`, `isTheaterFullScreen`, audio engine references
- **Transfer state**: (delegates to TransferCenter, but also has `uploadQueue`, `isUploading`)
- **Auth state**: `isAuthorized`, `hasTelegramCredentials`, bootstrap lifecycle
- **Vault state**: `isPrivateVaultUnlocked`, vault key, folder operations
- **UI state**: `selectedDestination`, `showSettings`, `showLogin`, `showOnboarding`
- **Undo/redo**: full undo stack for file operations
- **Thumbnail refresh**: `thumbnailVersion`, notification observers
- **Catalog sync**: snapshot upload, reconcile, delta publishing
- **Folder operations**: create, rename, move, delete, undo
- **Share operations**: create, cancel, import, archive

**Why this is a problem:**
1. Every `@Observable` property change triggers SwiftUI observation across ALL views that read AppState — even unrelated ones
2. Impossible to test individual features in isolation
3. Every new feature means adding more state + methods to the same 2292-line file
4. Race conditions between concurrent operations that all touch the same state

### Other architectural issues

**TelegramClient (1493 lines):** Mixes raw TDLib calls, channel management, share plumbing, file upload/download, backup mirroring, flood-wait handling — all in one place. Should be split into focused managers.

**DatabaseManager (1073 lines):** One actor handles objects, chunks, shares, transfers, migrations, backup, deduplication. Every feature's data access goes through the same file.

**Engines are static/enum singletons:** `UploadEngine`, `DownloadEngine`, `ShareEngine` are all `enum` with static methods — no dependency injection, no protocol abstraction, impossible to mock for testing.

**No protocol-based abstraction:** TelegramClient is directly referenced everywhere (`TelegramClient.shared`). No way to swap in a test doubles.

**Experimental code in `claude/` folder:** Demo views (`FABDemoView`, `LiquidFABStack`, etc.) that aren't part of the app. Should be cleaned up.

---

## 3. Recommended Improvements (Priority Order)

### Quick wins (do alongside rename)

1. **Delete `claude/` folder** — 5 minutes, instant cleanup
2. **Rename file: `xCloudApp.swift` → `CascadeApp.swift`** — part of rename
3. **Split migrations into `Migrations.swift`** — reduces DatabaseManager noise

### Medium effort (high impact)

4. **Split AppState into domain-specific ObservableObjects:**
   - `FileBrowserState` — files, folders, selection, sorting, grid
   - `ShareState` — incoming/outgoing shares, pending imports
   - `PlaybackState` — theater file, fullscreen, audio
   - `VaultState` — vault key, private vault unlock, folder ops
   - `SyncState` — catalog sync, snapshot upload, last sync date
   - `AuthState` — authorization, credentials, bootstrap
   - AppState becomes a thin coordinator owning these

5. **Extract Telegram channel management:**
   - `ChannelManager` — vault/share channel lifecycle, archive, photo
   - `MessageTransport` — send/receive/forward (thin TDLib wrapper)
   - Keep `TelegramClient` as the thin wrapper

6. **Extract DatabaseManager into repositories:**
   - `ObjectRepository` — CRUD for objects + chunks
   - `ShareRepository` — share records + channel state
   - `TransferRepository` — transfer history
   - `CatalogRepository` — snapshot/delta publishing
   - DatabaseManager becomes a thin connection holder

### Large effort (future)

7. **Protocol-based engine abstraction:**
   - `ShareProviding` protocol → `ShareEngine` conformance
   - `DownloadProviding` → `DownloadEngine`
   - Enables real unit testing with mock Telegram client

8. **Dependency injection container:**
   - Single `Container` or `Services` struct injected via environment
   - Replaces all `XXXEngine.shared` / `XXXClient.shared` references

---

## 4. What NOT to change

- **The storage architecture is good** — don't touch the chunking, catalog sync, or streaming pipeline
- **Telegram as a backend is fine** — it works, it's free, it's encrypted in transit
- **The GRDB model layer is solid** — defensive decoding, LWW merge, migration system
- **mpv as the sole media engine** — mandated, verified, works perfectly
- **The vault channel structure** — single channel with caption-based metadata is simple and correct
