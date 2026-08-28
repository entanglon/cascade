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

### Round 205: Fix Folder Tap Opening & MKV Video Playback Renderbuffer Sizing (`7e09cfc`)
- **Folder Tap Fix**: Removed inner nested `Button` elements inside `FileGridItem.gridContent` that were swallowing touch events meant for the outer `NavigationLink`. Now tapping anywhere on a folder card immediately opens the folder.
- **MKV / Video Playback Fix**: Implemented `layoutSubviews()`, `didMoveToWindow()`, and `updateRenderbufferSize()` in `MPVPlayerView.swift` to properly resize the `CAEAGLLayer` OpenGL ES renderbuffer upon view sizing, eliminating the blank video screen issue. Configured post-init mpv properties (`hwdec = auto`, `profile = fast`, `video-sync = audio`, `keep-open = yes`).

### Round 204: Share Link Importing, Deep Link cascade:// Scheme, & In-App "Add from Share Link" Sheet (`1ed7c52`)
- Registered `cascade://` URL scheme in `project.pbxproj` and wired deep link handling in `CascadeApp.swift`.
- Added `ImportShareLinkSheet` with clipboard auto-detection, paste button, password support, and "Import to Drive" action.
- Added "Add from Share Link..." into `...` menus in `SharedView` and `FileBrowserView`, plus quick buttons in the Shared banner and empty state.

### Round 203: Functional Shared Page (Public/Private Shares, Copy Link, Revoke) & Native Apple Files Context Menu (`ab1df9e`)
- Overhauled `SharedView` with Public and Private share sections, status badges, countdowns, search, icons/list view modes, sorting, and pull-to-refresh.
- Added `ShareGridCard` and `ShareListRow` with `Copy Link`, `Share Link...` (`UIActivityViewController`), and `Revoke Share` context menu actions.
- Implemented native Apple Files context menu on `FileGridItem` and `FileRow`: top horizontal `ControlGroup` (`Copy`, `Move`, `Share`) and vertical list (`Quick Look`, `Get Info`, `Rename`, `Archive`, `Duplicate`, `New Folder with Item`, `Favorite`, `Delete`).
- Added `ShareFileSheet` and `MoveDestinationPickerSheet`.

### Round 202: Consolidated Upload Files Nested Menu with Choose Files, Photo Library, & Take Photo or Video (`6569f15`)
- Consolidated upload actions under a single "Upload Files" menu item that opens a submenu matching native Apple Files: Choose Files (`folder`), Photo Library (`photo.on.rectangle`), and Take Photo or Video (`camera`).
- Implemented `CameraMediaPicker` with photo/video camera capture.

### Round 201: Apple Files Selection Circles, Hidden Back Button, Batch Uploads, & Direct Sharing (`dff03e7`)
- Fixed grid selection indicators to match native Apple Files: bottom-centered translucent circular rings when unselected, blue checkmarks when selected.
- Hid back arrow during selection mode, with "Select All" leading, dynamic count title, and "Done" trailing.
- Added location-aware batch uploading honoring current subfolder `parentID` and wired `.onOpenURL` for direct file sharing from other apps.

### Round 200: Apple Files Grid Spacing (3.5 Rows) & Folder Creation Smooth Transition (`507f354`)
- Updated `LazyVGrid` row spacing to `28pt` and thumbnail height to `94pt` matching native Apple Files ~3.5 rows per screen ratio.
- Fixed folder creation lag by removing `withAnimation` collision on creation and deferring keyboard focus.

## Dual-Platform Verification
- `Cascade iOS` scheme (`sdk iphoneos`, Debug): **BUILD SUCCEEDED**
- `Cascade` macOS scheme (`platform=macOS`, Debug): **BUILD SUCCEEDED**
- Installed & running on physical iPhone XS Max (`8F28E614-EA35-5B10-8DC9-E390026D4599`).

