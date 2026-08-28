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
- **Image preview** (`FilePreviewView`): Native Apple Files-style presentation on a pure black background with hidden navigation/status bars that toggle on tap without auto-hide timers.
- **Folder navigation** (`FileBrowserView`): `NavigationLink` triggers smooth folder navigation hierarchy without button capture interference.
- **Grid thumbnail presentation** (`FileGridItem`): Media thumbnails float centered inside an invisible 105pt container with `.aspectRatio(contentMode: .fit)`, continuous rounded corners, realistic drop shadows, and natural proportioned placeholder cards.

## Recent Changes

### Round 183: Upload Cloud Sync & iOS Pull-to-Refresh Cloud Reconcile
- Added `CatalogSnapshot.upload()` immediately upon completing uploads in `UploadEngine.swift`.
- Updated `Cascade iOS/AppState.swift` `loadAllFiles(reconcileCloud: true)` to invalidate scan cache and reconcile cloud catalog snapshots on pull-to-refresh.
- Removed duplicate "Browse Vault" link from `SettingsView`.

### Round 182: Aspect-Ratio Preserving Thumbnails & Files-Style Grid Presentation (`bd6a53c`)
- Switched `UploadEngine.generateThumbnails` and `ThumbnailService` from `ThumbnailCrop.subjectSquare` to `ThumbnailCrop.aspectFit`, preserving 16:9, 4:3, 9:16, etc.
- Updated `FileGridItem.thumbnailView` on iOS to render aspect-fit thumbnails floating inside invisible 105pt containers with natural proportioned fallback cards for video (16:9), photos (4:3), and documents (3:4).

### Round 181: Folder Navigation Gesture Fix (`8c8c6ff`)
- Made `onTap` optional in `FileRow` and `FileGridItem` so `NavigationLink` receives taps directly and pushes folder views smoothly.

### Round 180: Native Apple Files Image Viewer & Video Player Fix (`9824092`)
- Native Apple Files image viewer (pure black canvas, aspect-fit, hidden bars toggled on tap).
- Dismiss crash fix in `VideoPlaybackView` by routing dismiss through `appState.closeTheater()`.
- Cloud catalog name healing in `CatalogSnapshot.merge()` ensuring authentic filenames always override `File-` phantoms.

## Dual-Platform Verification
- `Cascade iOS` scheme (`sdk iphoneos`, Debug): **BUILD SUCCEEDED**
- `Cascade` macOS scheme (`platform=macOS`, Debug): **BUILD SUCCEEDED**
- Installed & running on physical iPhone XS Max (`8F28E614-EA35-5B10-8DC9-E390026D4599`).

