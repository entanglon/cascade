# Cascade iOS — UI Fix Instructions for Antigravity

> **Date:** 2026-08-27
> **Status:** iOS app builds and installs but UI needs fixing to match Apple Files app
> **Reference Screenshots:** `/Users/zainulnazir/Projects/Cascade/iOS-Screenshots/` (14 PNGs: IMG_0501 through IMG_0514)

---

## 1. What Cascade Is

**Cascade** is a macOS/iOS app that turns a Telegram account into a private cloud drive:

- Files are chunked and uploaded to a private Telegram channel ("vault")
- Local SQLite catalog syncs between devices via Telegram
- **mpv is the ONLY media engine** — no AVFoundation/AVKit allowed
- TDLibKit powers Telegram auth + messaging
- Features: file browsing, video/audio playback, thumbnails, folder navigation, private vault (PIN), trash, favorites, archive, share links, transfers

---

## 2. Current iOS App State

- ✅ **Builds successfully** for iOS 18.0
- ✅ **Installs and runs** on iPhone XS Max (iOS 18.7.9)
- ✅ **Login flow works** (phone → 5-digit code → password → confirmation)
- ✅ **Post-auth setup works** (vault found, catalog restored, files loaded)
- ✅ **mpv player ported** (real OpenGL ES + EAGLContext rendering — but untested)
- ✅ **VaultStreamServer started** on iOS (byte-range HTTP streaming)
- ❌ **Thumbnails not loading** — files show generic folder/file icons
- ❌ **Files not opening** — tapping video files doesn't launch player
- ❌ **UI doesn't match Files app** — wrong icons, wrong layout, missing elements

---

## 3. What You Need to Fix

### Reference Screenshots
The `iOS-Screenshots/` folder contains 14 PNGs showing the Apple Files app. **Study these carefully** before making any changes:

- **IMG_0501.PNG**: Browse tab — Locations section with colored icons
- **IMG_0502.PNG**: Shared tab with search bar
- **IMG_0503.PNG**: Recents tab — 3-column grid with thumbnails, names, dates, sizes
- **IMG_0504.PNG**: Browse tab with three-dot menu (Scan Documents, Connect to Server, Edit)
- **IMG_0505.PNG**: Shared tab full menu (Select, Icons/List, Name, Kind, Date, Size, Tags, View Options)
- **IMG_0506.PNG**: Recents tab full menu
- **IMG_0507.PNG**: iCloud Drive folder view (blue folder icons)
- **IMG_0508.PNG**: On My iPhone folder view (files with thumbnails)
- **IMG_0509.PNG**: Recently Deleted view

### Files to Modify
All iOS files are in `/Users/zainulnazir/Projects/Cascade/Cascade iOS/`:

1. **`RootView.swift`** — Main UI with tabs, navigation, all views
2. **`AppState.swift`** — State management, file operations
3. **`Features/FileBrowserView.swift`** — File browser with grid/list views
4. **`Features/MPVPlayerView.swift`** — Video player (already ported, don't touch)
5. **`Features/VideoPlaybackView.swift`** — Video playback wrapper
6. **`Features/SettingsView.swift`** — Settings view

### Specific UI Issues to Fix

#### Issue 1: Tab Bar Order
**Current:** Recents → Shared → Browse
**Should be:** Recents (left) → Shared (center) → Browse (right)
**Where:** `RootView.swift` TabView section

#### Issue 2: Browse Tab Layout
**Current:** Just a list of navigation links
**Should be:** Match Files app exactly:
- Large "Browse" title
- Search bar with microphone icon
- **Locations section** with colored icons:
  - ☁️ Cascade Drive (blue)
  - 🔒 Private Vault (red)
  - ⭐ Favorites (yellow)
  - ⇅ Transfers (blue)
  - 📦 Archive (gray)
  - 🗑️ Trash (red)
- **Media section** with colored icons:
  - 🟢 Photos (green)
  - 🟣 Videos (purple)
  - 🟠 Audio (orange)
  - 🔵 Documents (blue)

#### Issue 3: Recents Tab
**Current:** Empty state only
**Should be:** 3-column grid of recent files with:
- Actual thumbnails (not generic icons)
- File name (truncated with ellipsis)
- Date (formatted like "21/08/26")
- Size (like "193 KB", "2.1 MB")
- Footer: "30 items" + "Synced with Cascade"

#### Issue 4: Search Bar Missing
**Current:** Only on some pages
**Should be:** On EVERY page (Recents, Shared, Browse, Photos, Videos, Audio, Documents)

#### Issue 5: Three-Dot Menu Missing
**Current:** Only on Browse and Recents
**Should be:** On EVERY page (Shared too)

#### Issue 6: File Icons
**Current:** Shows generic colored squares with SF Symbols
**Should be:** 
- Folders: Blue folder icon (like Files app)
- Images: Actual thumbnail from Telegram
- Videos: Actual thumbnail from Telegram
- Audio: Music note icon (gray/white)
- Documents: Document icon with appropriate type

#### Issue 7: Context Menus
**Current:** Basic (Open, Rename, Get Info, Move to Trash)
**Should be:** Match Files app:
- Open
- Rename
- Get Info
- Move to Trash
- (For folders) Open in New Tab

---

## 4. What NOT to Touch

- **`Features/MPVPlayerView.swift`** — Already ported with real mpv + OpenGL ES. Don't modify.
- **`Features/VideoPlaybackView.swift`** — Already wired to stream server. Don't modify.
- **Login flow** — Already works correctly.
- **Post-auth setup** — Already works correctly.

---

## 5. Build Commands

```bash
# Build iOS app
xcodebuild -project /Users/zainulnazir/Projects/Cascade/Cascade.xcodeproj \
  -scheme "Cascade iOS" -sdk iphoneos -configuration Debug build

# Install on device (device must be unlocked)
xcrun devicectl device install app --device 8F28E614-EA35-5B10-8DC9-E390026D4599 \
  ~/Library/Developer/Xcode/DerivedData/Cascade-ezedzhfojrwwyhefeufajkbrtlll/Build/Products/Debug-iphoneos/Cascade.app

# Launch on device
xcrun devicectl device process launch --device 8F28E614-EA35-5B10-8DC9-E390026D4599 com.cascade.app.ios

# Verify macOS still builds (don't break it!)
xcodebuild -project /Users/zainulnazir/Projects/Cascade/Cascade.xcodeproj \
  -scheme Cascade -destination 'platform=macOS' build
```

---

## 6. Key Constraints

1. **AVFoundation/AVKit are BANNED** — mpv is the only media engine
2. **iOS deployment target:** 18.0
3. **Bundle ID:** com.cascade.app.ios
4. **Signing:** Apple Development (haditbutt7@gmail.com, XCF4BNLDB4)
5. **Device:** iPhone XS Max (iOS 18.7.9, device ID 8F28E614-EA35-5B10-8DC9-E390026D4599)
6. **All iOS files use `#if os(iOS)` guards** — macOS code is separate
7. **FileItem struct** has these properties: id, name, isFolder, size, mime, isPrivate, createdAt, parentID, thumbnailData, isFavorite, isArchived
8. **AppState** has: allFiles, files, currentFolderID, loadAllFiles(), loadThumbnails(), openFile(), trashFile(), renameFile(), navigateToFolder()

---

## 7. Testing Checklist

After fixing the UI, verify:
- [ ] Tab bar order matches Files app (Recents → Shared → Browse)
- [ ] Browse tab shows Locations and Media sections with correct icons
- [ ] Recents tab shows files in 3-column grid
- [ ] Search bar appears on all pages
- [ ] Three-dot menu appears on all pages
- [ ] Context menus work (Open, Rename, Get Info, Move to Trash)
- [ ] Navigation works (folders open, back button works)
- [ ] macOS still builds without errors

---

## 8. Success Criteria

The iOS app should **look exactly like the Apple Files app** based on the screenshots. The goal is pixel-perfect UI match, not just "similar".
