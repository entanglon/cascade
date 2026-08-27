# iOS Port — Current State Handover (2026-08-27)

> **Read this file FIRST** when starting a new agent session on the Cascade iOS port.
> It captures the exact state of the iOS app as of the last working session.

## Critical Rules

1. **AVFoundation and AVKit are STRICTLY PROHIBITED.** mpv is the only media engine.
2. **Do NOT modify** `Cascade iOS/Features/MPVPlayerView.swift` or `Cascade iOS/Features/VideoPlaybackView.swift`.
3. **Both iOS and macOS targets must build cleanly** with 0 errors after every change.
4. **Navigation bar titles must use `.inline` mode** (not `.large`). The app mimics Apple Files which uses inline titles.
5. **Debug builds only** unless the user explicitly approves Release.

## Build & Deploy Commands

```sh
# iOS build (signed for physical device)
xcodebuild -project /Users/zainulnazir/Projects/Cascade/Cascade.xcodeproj \
  -scheme "Cascade iOS" -sdk iphoneos -configuration Debug build

# macOS build (verify no regressions)
xcodebuild -project /Users/zainulnazir/Projects/Cascade/Cascade.xcodeproj \
  -scheme Cascade -destination 'platform=macOS' build

# Install to iPhone XS Max
devicectl device install app --device 8F28E614-EA35-5B10-8DC9-E390026D4599 \
  /Users/zainulnazir/Library/Developer/Xcode/DerivedData/Cascade-ezedzhfojrwwyhefeufajkbrtlll/Build/Products/Debug-iphoneos/Cascade.app

# Launch on iPhone
devicectl device process launch --device 8F28E614-EA35-5B10-8DC9-E390026D4599 com.cascade.app.ios
```

**Device:** iPhone XS Max, UDID `8F28E614-EA35-5B10-8DC9-E390026D4599`, Bundle ID `com.cascade.app.ios`

**Note:** If `devicectl` fails with error 10003, the device screen is locked — user must unlock first.

## Project Architecture

```
/Users/zainulnazir/Projects/Cascade/
├── App/                         # macOS-only: AppState.swift (126KB), CascadeApp.swift, AppPaths.swift
├── Cascade/                     # macOS Assets
├── Cascade iOS/                 # iOS Target (MAIN WORKING AREA)
│   ├── AppState.swift           # iOS @Observable state, FileItem model, thumbnail loading
│   ├── CascadeApp.swift         # iOS @main entry point
│   ├── RootView.swift           # Complete iOS navigation UI (~78KB, ~2240 lines)
│   └── Features/
│       ├── FileBrowserView.swift # Folder browser with Grid/List modes
│       ├── MPVPlayerView.swift   # ⚠️ DO NOT MODIFY — libmpv UIKit bridge
│       ├── SettingsView.swift    # iOS settings
│       └── VideoPlaybackView.swift # ⚠️ DO NOT MODIFY — video playback
├── Crypto/                      # SHARED: AES-GCM encryption (CryptoEngine, KeychainStore)
├── Engine/                      # SHARED: Core engines
│   ├── ThumbnailService.swift   # macOS-only (#if os(macOS)) — face/saliency cropping
│   ├── UploadEngine.swift       # Shared paths; generateThumbnails is macOS-only
│   ├── DownloadEngine.swift     # File download + caching
│   ├── VaultStreamServer.swift  # Localhost byte-range HTTP streaming server
│   ├── VideoStreamingEngine.swift
│   ├── AudioPlayerEngine.swift
│   └── ...
├── Storage/                     # SHARED: GRDB database, models, vault management
│   ├── DatabaseManager.swift
│   ├── Models.swift             # ObjectRecord, ChunkRecord, VaultRecord, AppPaths, PlatformImage
│   ├── VaultManager.swift
│   ├── CatalogSnapshot.swift
│   └── VaultRepair.swift
├── Telegram/                    # SHARED: TDLibKit wrapper
│   └── TelegramClient.swift     # Actor wrapping TDLib — auth, file upload/download, thumbnails
└── Features/                    # macOS-only views (FileBrowserView 160KB, etc.)
```

## iOS Thumbnail System (Just Fixed)

### How it works now:
1. **FileItem.==** compares both `id` AND `thumbnailData` presence, so SwiftUI properly re-renders cells when thumbnails arrive.
2. **`thumbnailVersion` counter** on `AppState` increments when thumbnails are ready.
3. **`.xcThumbnailReady` notification observer** in `AppState.observeThumbnailNotifications()` bumps `thumbnailVersion`.
4. **Per-cell lazy `.task(id:)`** on both `FileRow` and `FileGridItem` — each cell lazily fetches its own thumbnail when it appears (disk cache first, then Telegram).
5. **Bulk `loadThumbnails()`** runs at startup for fast initial load from disk cache + background Telegram fetches.
6. **`fetchSingleThumbnail(for:)`** on `AppState` — on-demand single-file thumbnail loader used by per-cell tasks.

### Thumbnail sources (priority order):
1. Local disk cache: `<AppSupport>/Cascade/thumbs/<id>.jpg`, `.png`, or `-tg.jpg`
2. Encrypted sidecar from Telegram: `ObjectRecord.thumbMessageID` → download + AES-GCM decrypt
3. Attached thumbnail from chunk messages: `TelegramClient.thumbnailData(forMessage:chatId:)`

### What's NOT ported to iOS yet:
- `ThumbnailService` (macOS-only) — Vision face/saliency cropping, local thumbnail generation from cached files
- `VideoFrameExtractor` (macOS-only) — FFmpeg video frame extraction for thumbnails
- `UploadEngine.generateThumbnails` / `subjectThumbnail` — iOS returns nil (no thumbnail generation during iOS uploads)

## UI State (Apple Files-like)

- **Tab bar:** Recents | Shared | Browse
- **Browse page:** Locations (Cascade Drive), Categories (Photos, Videos, Audio, Documents), Tags, utility sections (Private Vault, Favorites, Transfers, Archive, Recently Deleted)
- **All pages use `.navigationBarTitleDisplayMode(.inline)`** — NOT `.large`
- **All pages have `.searchable()` with always-visible search bar**
- **All empty page background icons use `.foregroundStyle(.blue)`**
- **Item count footer** (`PageItemCountFooter`) shows at the bottom of content pages
- **Three-dot menu** in toolbar uses unfilled `ellipsis.circle` (not filled)
- **Trash section** is labeled "Recently Deleted" (not "Trash")
- **Loading screen** shows SVG cascade icon + spinner (no text)
- **App opens directly to Cascade Drive page** (not Browse)

## Files Changed in This Session

### `Storage/VaultRepair.swift`
- Differentiated `kindThumb` and `kindSub` captions to prevent data chunk 0 corruption and phantom `File-XXXX` generation.
- Correctly parsed and persisted `thumbMessageID` for encrypted thumbnail sidecars.

### `Cascade iOS/AppState.swift`
- Added Vault PIN recovery & biometric unlock (`unlockVault(pin:)`, `unlockWithBiometrics()`).
- Added vault lock state tracking (`isVaultLocked`, `showVaultUnlockSheet`, `hasRecoveryBlob`).
- Cloud catalog reconcile (`CatalogSnapshot.upload()`) on startup restores true filenames, extensions, and metadata.
- Added fallback thumbnail sidecar discovery in `fetchThumbnailData(for:vault:)`.
- Added `cachedURL(for:)`, `isCached(_:)`, `downloadFile(_:progress:)`, `toggleFavorite(_:)`, `togglePin(_:)`, `deleteFilePermanently(_:)`.
- Added `calculateCacheSize()` and `clearLocalCache()`.

### `Cascade iOS/RootView.swift`
- Added `VaultPINView` (4-digit PIN pad with Face ID / Touch ID integration and error shake).
- Embedded `VaultPINView` in `PrivateVaultView` and wired `.sheet(isPresented: $appState.showVaultUnlockSheet)` to `RootView`.
- Upgraded `FilePreviewView`:
  - Full-resolution pinch-to-zoom image viewer.
  - Native `PDFKit` (`PDFView`) document rendering.
  - Monospaced text/markdown/code viewer.
  - On-demand download with progress indicator.
  - Native iOS Share Sheet (`UIActivityViewController`).
- Added Favorite and Keep Downloaded ("Pin") actions to `FileRow` and `FileGridItem` context menus.

### `Cascade iOS/Features/SettingsView.swift`
- Added "Security" section: Vault status, PIN unlock button, and Face ID toggle.
- Added "Storage & Cache" section: Cache size display and "Clear Cache" button.

### `Cascade.xcodeproj/project.pbxproj`
- Added `INFOPLIST_KEY_NSFaceIDUsageDescription` to `Cascade iOS` Debug and Release configurations.

## Dual-Platform Verification
- `Cascade iOS` scheme (`sdk iphoneos`, Debug): **BUILD SUCCEEDED**
- `Cascade` macOS scheme (`platform=macOS`, Debug): **BUILD SUCCEEDED**

