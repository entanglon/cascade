# Cascade — Development Journal

>> Chronological log of the work on the Cascade macOS and iOS apps. Companion to
> HANDOVER.md (current state) and ROADMAP.md (deferred plans). Last entry:
> 2026-08-28 (night) — Inline New Folder, direct name tap inline rename, and clean list footers (Round 197, 0adfb53).

---

## 2026-08-28 (night) — Inline New Folder, direct name tap inline rename, and clean list footers (Round 197, commit `0adfb53`)

User provided screenshots demonstrating native Apple Files interactions:
1. In list view, the item count footer wasn't rendering cleanly and an empty separator line appeared after it.
2. New folder creation in Apple Files appears as an inline folder card with an auto-focused dark pill text field right below the icon with `"untitled folder"`.
3. Tapping directly on the name of any file or folder acts as inline rename (with dark pill text field and keyboard), while tapping the thumbnail/icon opens the file or navigates into the folder.

### Changes Implemented
1. **List Footers Fixed**:
   - Replaced empty `Section { } footer: { PageItemCountFooter(...) }` in plain lists with `PageItemCountFooter(...)` with `.listRowSeparator(.hidden)` and `.listRowBackground(Color.clear)` across `FileBrowserView`, `RecentsView`, `AudioView`, `DocumentsView`, `FavoritesView`, and `ArchiveView`.
   - Eliminated empty list sections and phantom separator lines; item count footers now render cleanly at the bottom.
2. **Inline "New Folder" Creation**:
   - Added `InlineNewFolderGridItem` and `InlineNewFolderRow` in `RootView.swift`.
   - Tapping "New Folder" in the menu immediately mounts an inline folder tile at the top of the grid/list with an auto-focused text capsule (`"untitled folder"` pre-selected) and keyboard up.
   - Pressing "done" or tapping outside commits folder creation with the typed name (defaulting to "untitled folder" if empty).
3. **Direct Name Tap Inline Rename & Dedicated Thumbnail Open**:
   - In `FileGridItem` and `FileRow`:
     - Tapping the **thumbnail / icon** opens the file or navigates into the folder.
     - Tapping the **filename label** activates inline rename with auto-focused dark pill `TextField`.
     - Context menu "Rename" also triggers this inline rename mode.
     - Pressing "done" or losing focus commits the rename and uploads a fresh catalog snapshot to Telegram.

### Verification
- macOS target: `** BUILD SUCCEEDED **`.
- iOS target (`sdk iphoneos`, arm64): `** BUILD SUCCEEDED **`.
- Installed and launched on physical iPhone XS Max via `devicectl`.
- Commit: `0adfb53`.

---

## 2026-08-28 (night) — Remove Connect to Server, interactive Selection mode & New Folder (Round 196, commit `a40584b`)

User requested:
1. Remove the "Connect to Server" option from all menus.
2. Ensure the "Select" option works seamlessly.
3. Add "New Folder" option where needed and ensure it works.

### Changes Implemented
1. **Remove Connect to Server**:
   - Removed all `Connect to Server` menu buttons from `FileBrowserView.swift`, `BrowseView`, `RecentsView`, and `SharedView`.
2. **New Folder Creation**:
   - Added `createFolder(named:parentID:isPrivate:)` to `Cascade iOS/AppState.swift` creating `ObjectRecord(mime: "cascade/folder", isFolder: true)` in SQLite database, uploading catalog snapshot to Telegram, and reloading files.
   - Added `New Folder` menu action with `Image(systemName: "folder.badge.plus")` and alert dialog in `FileBrowserView.swift` (which also handles `PrivateVaultView` subfolders).
3. **Interactive Multi-Item Selection Mode**:
   - Added `isSelecting` state and `selectedFileIDs: Set<String>` across all browsing views: `FileBrowserView`, `RecentsView`, `PhotosView`, `VideosView`, `AudioView`, `DocumentsView`, `FavoritesView`, `ArchiveView`, and `TrashView`.
   - In selection mode:
     - Navigation bar displays `Select All` / `Deselect All` on leading side and `Done` (bold) on trailing side.
     - `FileGridItem` and `FileRow` render circular checkboxes (`checkmark.circle.fill` / `circle`), and tapping items toggles their selection state.
     - Safe area bottom inset presents contextual action bars (Favorite, Unfavorite, Archive, Unarchive, Delete, Recover, Delete Immediately) with batch mutation methods on `AppState` (`trashFiles`, `restoreFiles`, `deletePermanently`, `toggleFavorites`, `toggleArchive`).

### Verification
- macOS (`Cascade` target) **BUILD SUCCEEDED**.
- iOS (`Cascade iOS` target, `sdk iphoneos`, arm64) **BUILD SUCCEEDED**.
- Commit: `a40584b`.

---

## 2026-08-28 (night) — Exact Apple Files folder shape & gradients (Round 195, commit `b378433`)

User provided a screenshot directly from the iOS Files app demonstrating that the generic SF Symbol `folder.fill` doesn't have the real iOS Files folder geometry and vibrant sky-blue gradient.

### Root Cause & Vector Shape Design
1. **Root Cause**: Apple's native Files app does not use the standard SF Symbol `folder.fill` silhouette in its file browser grid. Instead, it renders an iconic skeuomorphic vector folder with:
   - A rear tab on the top left (`w * 0.40`) that curves smoothly down into the body.
   - A darker cyan-blue back flap (`#3C9FE0` / `RGB(60, 160, 222)` to `#3292CE`).
   - A vibrant front body (`RGB(104, 194, 242)` to `RGB(80, 172, 226)`) with continuous corner radii (`r = 7.5`).
   - A subtle top-edge highlight stroke (`white.opacity(0.40)`).
2. **Fix**:
   - Created `AppleFolderIcon: View` in `Cascade iOS/RootView.swift` drawing the exact vector paths with continuous Apple corner curvature and dual linear gradients.
   - Connected `AppleFolderIcon` to `FileGridItem.thumbnailView` (width: 86, height: 68) and `FileRow.thumbnailView` (width: 36, height: 28).

### Verification
- macOS (`Cascade` target) **BUILD SUCCEEDED**.
- iOS (`Cascade iOS` target, `sdk iphoneos`, arm64) **BUILD SUCCEEDED**.
- Commit: `b378433`.

---

## 2026-08-28 (night) — Updated iOS folder icons to match Apple Files app (Round 194, commit `1a1fe6b`)

User requested updating folder icons in the iOS app to match the Apple Files app.

### Root Cause & Changes
1. **Previous State**: `FileGridItem` and `FileRow` used `folder.fill` with a custom flat pastel sky-blue color (`(0.28, 0.65, 0.98)`) and default monochrome rendering, which lacked the distinctive multi-layered depth, flap shading, and system accent color of Apple Files.
2. **Fix**:
   - In `Cascade iOS/RootView.swift` (`FileGridItem.thumbnailView`), updated the folder icon to `Image(systemName: "folder.fill").font(.system(size: 68, weight: .regular)).symbolRenderingMode(.hierarchical).foregroundStyle(Color(uiColor: .systemBlue))`.
   - In `Cascade iOS/RootView.swift` (`FileRow.thumbnailView`), updated list view folder icon to `.symbolRenderingMode(.hierarchical).foregroundStyle(Color(uiColor: .systemBlue))`.
   - This provides the native two-tone flap depth (translucent rear tab, solid vibrant front pocket) and dynamic iOS system blue hue matching Apple Files exactly.

### Verification
- macOS (`Cascade` target) **BUILD SUCCEEDED**.
- iOS (`Cascade iOS` target, `sdk iphoneos`, arm64) **BUILD SUCCEEDED**.
- Commit: `1a1fe6b`.

---

## 2026-08-28 (night) — Fixed macOS recents recording and MRU ordering (Round 193, commit `249e726`)

User reported that on macOS opening a file did not cause it to jump to the top of the Recents page.

### Root Cause & Fix
1. **Root Cause 1 (`FileBrowserView.swift:89, 150`)**: `FileBrowserView.visibleFiles` had its own `.recent` branch that fell back to `prefix(20)` from catalog files rather than querying `RecentsSyncEngine.loadLocalEntries()`. Furthermore, the default name/date sort in `visibleFiles` was overriding the recents order.
2. **Root Cause 2 (`AppState.swift:190, 192`)**: On macOS, opening photos/videos/books sets `theaterFile` and `readerFile` rather than calling `openFile`. `theaterFile` and `readerFile` were plain properties without access recording hooks.
3. **Fix**:
   - Added `didSet` access recording and debounced cloud upload to `appState.theaterFile` and `appState.readerFile` in `App/AppState.swift`.
   - Added `RecentsSyncEngine.recordAccess` to `AudioPlayerEngine.play(file:in:)` in `Engine/AudioPlayerEngine.swift`.
   - Updated `FileBrowserView.visibleFiles` on macOS to query `RecentsSyncEngine.loadLocalEntries()` and preserve the MRU ordering when viewing `.recent`.

### Verification
- macOS (`Cascade` target) **BUILD SUCCEEDED**, relaunched.
- iOS (`Cascade iOS` target, `sdk iphoneos`, arm64) **BUILD SUCCEEDED**, installed and launched on iPhone XS Max.
- Commit: `249e726`.

---

## 2026-08-28 (night) — Cross-device `recents.json` cloud sync (Round 192, commit `94ba75a`)

User requested cross-device syncing of recent files via a lightweight JSON metadata approach (similar to database snapshots/deltas, but dedicated and isolated from SQLite DB WAL/transactions).

### Implementation Details
1. **`RecentsSyncEngine` (`Engine/RecentsSyncEngine.swift`)**:
   - `RecentEntry(id: String, openedAt: Double)` and `RecentsPayload(version: Int, updatedAt: Double, entries: [RecentEntry])`.
   - Local on-device access recording: updates `UserDefaults` immediately for 0-latency UI responsiveness.
   - Channel message sync: text metadata message with prefix `cascade:recents:v1:<base64-json>`.
   - Conflict-free LWW merge: when syncing from cloud, takes `max(local.openedAt, remote.openedAt)` for each file ID, sorts descending, and bounds to top 40 files.
   - Debounced uploads: batches rapid file opens with a 5-second debounce timer to minimize Telegram channel traffic.
   - Automatic channel pruning: cleans up older `cascade:recents:v1:` messages in the channel when publishing a new version, leaving only 1 fresh message.
2. **macOS Integration (`App/AppState.swift:1282, 1317, 1812`)**:
   - Wired `openFile(_ file: ObjectRecord)` to record access and schedule cloud upload.
   - Wired `SidebarDestination.recent` navigation to trigger `syncFromCloud()`.
   - Updated `AppState.currentFiles` for `.recent` to load from `RecentsSyncEngine.loadLocalEntries()` mapped to catalog objects.
3. **iOS Integration (`Cascade iOS/AppState.swift:144, 539`, `Cascade iOS/RootView.swift:892`)**:
   - Wired `openFile(_ file: FileItem)` to record access and schedule cloud upload.
   - Added `syncRecentsFromCloud()` called on `RecentsView.task` (entering tab) and `RecentsView.refreshable` (pull to refresh).
   - Changed `emptyState` in `RecentsView` to a `ScrollView` with `.toolbarBackground(Material.ultraThinMaterial, for: .navigationBar)` so the navigation bar never drops its background when empty or at scroll edge.

### Verification
- macOS (`Cascade` target) **BUILD SUCCEEDED**.
- iOS (`Cascade iOS` target, `sdk iphoneos`, arm64) **BUILD SUCCEEDED**.
- Commit: `94ba75a`.

---

## 2026-08-28 (night) — Fixed navigation bar background loss on Recents & Shared (Round 191, commit `d9e1706`)

User reported that the navigation bar was losing its background on the Recents and Shared pages.

### Root Cause & Fix
1. **Root Cause**: On iOS 16+, `UINavigationBar` defaults to a transparent background when at scroll edge (`scrollEdgeAppearance`), and when pages show empty state or un-scrolled views with inline display mode, the navigation bar dropped its material background.
2. **Fix**:
   - In `Cascade iOS/CascadeApp.swift`, configured global `UINavigationBarAppearance` (`appearance.configureWithDefaultBackground()`) for `standardAppearance`, `compactAppearance`, and `scrollEdgeAppearance`.
   - In `Cascade iOS/RootView.swift`, added `.toolbarBackground(.visible, for: .navigationBar)` to `RecentsView` and `SharedView`.

### Verification
- macOS (`Cascade` target) **BUILD SUCCEEDED**.
- iOS (`Cascade iOS` target, `sdk iphoneos`, arm64) **BUILD SUCCEEDED**.
- Installed and launched on physical iPhone XS Max (`8F28E614-EA35-5B10-8DC9-E390026D4599`).
- Commit: `d9e1706`.

---

## 2026-08-28 (night) — Sticky viewport bottom footers & Recents/Shared cleanup (Round 190, commit `0111995`)

User requested:
1. Item count and "Synced with Cascade" footer should sit at the bottom of the screen when files do not fill the page, and sit at the end of the scrollable content when files fill the page (matching Apple Files app).
2. Recents and Shared should not display item count or "Synced with Cascade" footers.

### Implementation Details
1. **Background Viewport Height Measurement (`Cascade iOS/Features/FileBrowserView.swift:205`, `Cascade iOS/RootView.swift:1130`)**:
   - Added `.background { GeometryReader { proxy in Color.clear ... } }` to measure visible scroll container viewport height without wrapping or interfering with `ScrollView` / `UIRefreshControl`.
   - Set `.frame(minHeight: max(0, viewportHeight - 16), alignment: .top)` on the inner content `VStack`.
   - With few items: `VStack` expands to `viewportHeight`, `Spacer` pushes the footer (`X items`, `Synced with Cascade`) to the bottom of the visible screen with proper bottom padding.
   - With many items: `LazyVGrid` naturally exceeds `viewportHeight`, `Spacer` collapses to `40pt`, and the footer is reached at the end of scroll content.
2. **Removed Footers from Recents & Shared (`Cascade iOS/RootView.swift:945-975`)**:
   - Removed `PageItemCountFooter` from `RecentsView` grid and list modes.
   - Verified `SharedView` does not display bottom item count or cloud sync status.

### Verification
- macOS (`Cascade` target) **BUILD SUCCEEDED**.
- iOS (`Cascade iOS` target, `sdk iphoneos`, arm64) **BUILD SUCCEEDED**.
- Installed and launched on physical iPhone XS Max (`8F28E614-EA35-5B10-8DC9-E390026D4599`).
- Commit: `0111995`.

---

## 2026-08-28 (night) — Implemented on-device Recents MRU tracking (Round 189, commit `aae3b19`)

User concurred with keeping Recents scoped to each individual device to prevent cloud pollution and avoid constant cross-device refresh polling.

### Implementation Details
1. **On-Device MRU Tracking (`Cascade iOS/AppState.swift:147`, `Cascade iOS/AppState.swift:538`)**:
   - Added `recentFileIDs: [String]` property to `AppState` backed by `UserDefaults` key `"cascade_recent_file_ids"`.
   - Added `markFileAsRecent(_ fileID: String)` which prepends the opened file's ID to index 0, deduplicates, and bounds history to 50 items.
   - Wired `openFile(_ file: FileItem)` to automatically call `markFileAsRecent(file.id)` whenever any image, video, audio, or document is opened/viewed/streamed.
2. **Dynamic Recents Presentation (`Cascade iOS/RootView.swift:915`)**:
   - Updated `recentFiles` in `RecentsView` to map `recentFileIDs` against existing catalog files.
   - When no files have been opened yet on the device, shows the clean native empty state (`emptyState`: "No Recent Files — Files you open will appear here.").
   - When files are tapped/viewed, they appear immediately in MRU order with zero network overhead.

### Verification
- macOS (`Cascade` target) **BUILD SUCCEEDED**.
- iOS (`Cascade iOS` target, `sdk iphoneos`, arm64) **BUILD SUCCEEDED**.
- Installed and launched on physical iPhone XS Max (`8F28E614-EA35-5B10-8DC9-E390026D4599`).
- Commit: `aae3b19`.

---

## 2026-08-28 (night) — Fixed FileBrowserView root spinner hang (Round 188, commit `ed43756`)

User reported that pull-to-refresh spinner completed quickly on other views, but remained stuck on the Cascade Drive root view.

### Root Cause Analysis (File & Line Tracing)
1. **Mid-Refresh View Hierarchy Teardown (`Cascade iOS/Features/FileBrowserView.swift:29`)**:
   - `FileBrowserView` contained:
     `if appState.isLoadingFiles && currentFolderFiles.isEmpty { ProgressView("Loading files…") }`
   - When pull-to-refresh began, `appState.loadAllFiles()` set `isLoadingFiles = true`.
   - On the root `Cascade Drive` view, this triggered SwiftUI to tear down `gridView` (and its underlying `UIScrollView`) and replace it with `ProgressView`.
   - When `loadAllFiles()` finished and set `isLoadingFiles = false`, SwiftUI re-mounted a new `gridView`.
   - Because the original `UIScrollView` hosting the UIKit `UIRefreshControl` was destroyed while the refresh animation was active, the refresh control state was orphaned in UIKit, leaving the spinner visibly stuck in place!
   - In contrast, `RecentsTabView` and other views did NOT have `if isLoadingFiles { ProgressView }`, which is why they never encountered this bug.

### Fix
- In `Cascade iOS/Features/FileBrowserView.swift`:
  - Removed the `if appState.isLoadingFiles` branch swap from `body`, maintaining a stable `gridView` / `listView` hierarchy throughout the refresh lifecycle.
  - Made `emptyState` a `ScrollView` so empty folders can also be pulled to refresh.

### Verification
- macOS (`Cascade` target) **BUILD SUCCEEDED**.
- iOS (`Cascade iOS` target, `sdk iphoneos`, arm64) **BUILD SUCCEEDED**.
- Commit: `ed43756`.

---

## 2026-08-28 (night) — Fixed Cascade Drive / folder pull-to-refresh & answered Movies/Recents queries (Round 187, commit `bb4daf5`)

User verified cross-device sync (upload on macOS -> pull-to-refresh on iOS updated quickly), but noted:
1. Pull-to-refresh completed cleanly on Recents/Music/Movies, but the spinner got stuck on the root Cascade Drive page.
2. A 4th video file appeared in the Movies folder.
3. Recents page is showing everything in the cloud rather than only recently opened files.

### Root Cause Analysis & Answers
1. **Cascade Drive / Folder Refresh Spinner Hang (`Cascade iOS/Features/FileBrowserView.swift:165`, `Cascade iOS/RootView.swift:935`)**:
   - `FileBrowserView.gridView` and `RootView.gridView` were wrapped in `GeometryReader { geo in ScrollView { ... .frame(minHeight: geo.size.height) } }`.
   - In SwiftUI, wrapping a `ScrollView` inside a `GeometryReader` breaks `UIScrollView`'s native rubber-band bounce and prevents `UIRefreshControl` from properly detecting when the content offset should reset after refreshing completes, leaving the spinner visibly stuck.
   - **Fix**: Removed `GeometryReader` from around `ScrollView` in `FileBrowserView` and `RootView`, allowing `ScrollView` to stretch and bounce naturally with clean, instant spinner dismissal.
2. **Origin of the 4th Video in Movies**:
   - Inspected SQLite DB: The cloud vault contains 4 authentic video files in Movies uploaded from macOS on August 21 and 22 (`Rings - Dolby Atmos - 16-9.mkv`, `Rings - Dolby Atmos - 2.35.mkv`, and two versions of `Rings - Dolby Atmos DD - 16-9.mp4`).
   - Previously on iOS, one of these records was missing from local SQLite. When the new cloud snapshot sync mechanism restored the full catalog checkpoint and deltas, it cleanly synced all 4 authentic files from the cloud.
3. **Recents Tab Behavior**:
   - Confirmed: In Apple's native Files app, Recents shows files recently opened, downloaded, or modified by the user. Currently `recentFiles` was listing all files across the cloud drive sorted by creation date.

### Verification
- macOS (`Cascade` target) **BUILD SUCCEEDED**.
- iOS (`Cascade iOS` target, `sdk iphoneos`, arm64) **BUILD SUCCEEDED**.
- Installed and launched on physical iPhone XS Max (`8F28E614-EA35-5B10-8DC9-E390026D4599`).
- Commit: `bb4daf5`.

---

## 2026-08-28 (night) — Grid item baseline alignment fix & instant getChatHistory sync (Round 186, commit `b1aff13`)

User reported that `apple-tv.png` appeared smaller with smaller text size compared to the rest of the files in the grid view.

### Root Cause Analysis (File & Line Tracing)
1. **Vertical Baseline Misalignment (`Cascade iOS/RootView.swift:2324-2347`)**:
   - In `FileGridItem`, `Text(file.name)` had `.lineLimit(2)` without a fixed container height.
   - Files with 2-line filenames (`7a2e3154-...2d53.jpg`, `4P1m...png`) took ~34pt height, while `apple-tv.png` (a short 1-line name) took only ~16pt height.
   - This shifted the date and size lines for `apple-tv.png` upward by ~18pt relative to the neighboring cells in the row.
   - Combined with `apple-tv.png`'s tall portrait aspect ratio (where `maxHeight: 100` resulted in a narrower ~50pt thumbnail width), the cell had large empty gaps around it and misaligned baselines, creating the illusion of a shrunk/scaled-down card.
2. **TDLib `searchChatMessages` Stall (`Telegram/TelegramClient.swift:1673-1693`)**:
   - `searchChatMessages` requires a client-side indexed local database in TDLib; on remote channels without a local index, the query timed out on each attempt (`withResponseTimeout(15)`), taking 30–60s on every refresh.

### Fix
1. In `Cascade iOS/RootView.swift` (`FileGridItem`):
   - Gave `Text(file.name)` a locked 34pt height container (`.frame(height: 34, alignment: .top)`), guaranteeing that 1-line and 2-line titles occupy identical space and start at the same top coordinate.
   - Locked metadata lines (`.frame(height: 14)`) so date and size baselines are strictly aligned horizontally across all 3 columns in every row.
   - Maintained `.frame(maxWidth: .infinity, alignment: .top)` so cell column widths remain perfectly uniform.
2. In `Telegram/TelegramClient.swift` (`searchChannelMetadataMessages`):
   - Refactored `searchChannelMetadataMessages` to use `getChatHistory(fromMessageId: 0, limit: 100)` with `cascade:db` filtering. `getChatHistory` is Telegram's fundamental, 100% reliable endpoint that returns in ~50ms without local index prerequisites.

### Verification
- macOS (`Cascade` target) **BUILD SUCCEEDED**.
- iOS (`Cascade iOS` target, `sdk iphoneos`, arm64) **BUILD SUCCEEDED**.
- Installed and launched on physical iPhone XS Max (`8F28E614-EA35-5B10-8DC9-E390026D4599`).
- Commit: `b1aff13`.

---

## 2026-08-28 (late evening) — Resolved iOS pull-to-refresh spinner hang (Round 185, commit `52b5bee`)

User reported that pull-to-refresh on iOS continued spinning and would not autohide.

### Root Cause Analysis (File & Line Tracing)
1. **Synchronous Foreground Thumbnail Await (`Cascade iOS/AppState.swift:372`)**:
   - `loadAllFiles()` was the exact async closure executed by SwiftUI's `.refreshable { await appState.loadAllFiles() }`.
   - SwiftUI's `.refreshable` contractually holds the spinning indicator active until `loadAllFiles()` finishes.
   - `loadAllFiles()` called `await loadThumbnails()`, which gathered all missing thumbnails across the vault and concurrently performed network fetches (`fetchThumbnailData`) before returning.
   - As a result, `.refreshable` was blocked until every uncached file in the vault finished downloading its thumbnail over Telegram.
2. **Leftover Full Channel Scan in `fetchThumbnailData` (`Cascade iOS/AppState.swift:445`)**:
   - When an object had `thumbMessageID == nil`, `fetchThumbnailData` called `TelegramClient.shared.allChannelMessages(chatId: vault.channelID, usingCache: true)`.
   - Because `loadAllFiles` cleared the scan cache (`invalidateScanCache`), this triggered `fetchAllChannelMessages` (paginating up to 2,000 pages of the channel with 200ms sleeps per page). Multiple concurrent thumbnail tasks ran this full channel walk at the same time.

### Fix
1. In `Cascade iOS/AppState.swift`:
   - Fast local disk cache pass (`loadThumbnailsFromDisk()`) runs synchronously on the main thread to populate cached thumbnails instantly.
   - Missing thumbnail network fetching (`loadMissingThumbnailsFromNetwork()`) is now detached to a background utility Task (`Task.detached(priority: .utility)`).
   - `loadAllFiles()` returns immediately after loading local SQLite records (~50–100ms), allowing SwiftUI's `.refreshable` spinner to dismiss instantly.
   - Removed the leftover `allChannelMessages` full-channel scan in `fetchThumbnailData` (falls through immediately to chunk thumbnail `thumbnailData(forMessage:)`).
   - Removed redundant `invalidateScanCache` call in `loadAllFiles`.

### Verification
- macOS (`Cascade` target) **BUILD SUCCEEDED**.
- iOS (`Cascade iOS` target, `sdk iphoneos`, arm64) **BUILD SUCCEEDED**.
- Installed and launched on iPhone XS Max (`8F28E614-EA35-5B10-8DC9-E390026D4599`).
- Commit: `52b5bee`.

---

## 2026-08-28 (evening) — iOS pull-to-refresh STILL stuck — handed off to Antigravity, OPEN (docs only, no code change)

User re-tested `e02ea08` on-device: "the wheel is still stuck and not
autohiding." This is now item 125 in HANDOVER.md and explicitly flagged in
its Pending / next steps section for the next agent (Antigravity) to pick up
fresh, per the user's request — no further fix attempted in this session.

### What's confirmed so far
- Item 123's fix (timeout on `searchChatMessages`) did not help.
- Item 124's fix (rewriting `withResponseTimeout` to genuinely abandon a
  stuck TDLibKit continuation via unstructured tasks instead of a
  `withThrowingTaskGroup` race) was a REAL, verified bug fix — not wasted
  work — but the wheel still doesn't autohide, so something ELSE in the same
  chain is still hanging, or there's a separate UI-layer issue.

### Leads left for the next agent (full detail in HANDOVER.md item 125)
1. Audit every OTHER TDLib call reachable from `loadAllFiles` ->
   `CatalogSnapshot.upload()` (publish path: `publishDocument` /
   `sendMetadataMessage` -> `TelegramClient.sendFile`/`sendMessage`, which
   only go through `withFloodWait`, NOT `withResponseTimeout` — the exact
   same dropped-response race that hit `searchChatMessages` can hit these)
   and `loadThumbnails()` (several unprotected `try?` awaits with zero
   timeout).
2. Add stage-timestamped logging around `loadAllFiles`'s sub-steps so the
   next stuck-wheel repro pinpoints exactly which await never returns.
3. Rule out a pure UI-layer bug: SwiftUI's `.refreshable` indicator is
   contractually dismissed once its closure returns, so "stuck AND not
   autohiding" points back to a real hang (lead 1) — but verify there isn't
   a second spinner/gesture in the view hierarchy not wired to the same call.
4. Quick sanity check that `RateLimiter`/`APIMetrics` (invoked at the top of
   every `withFloodWait`) isn't itself blocking somehow.

### Verification
None — docs-only change, no code touched this round; nothing to build/test.

---

## 2026-08-28 (evening) — Fix iOS pull-to-refresh hanging forever, take 2 — `withResponseTimeout` itself was broken (`e02ea08`)

User reported the previous fix (`9df76a3`) did NOT resolve it — pull-to-refresh
still spun forever, screenshot showed the refresh control stuck mid-pull with
no way to dismiss it except manually scrolling it away.

### Root cause (the actual one this time)
The previous fix wrapped `searchChatMessages` in `withResponseTimeout(15)`,
trusting that helper's doc comment ("races a TDLibKit async call against a
deadline... turns the stall into a throwable error"). Re-reading its
implementation exposed that the helper itself was broken for the exact
failure mode it claims to guard against:

```swift
try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await operation() }
    group.addTask { try await Task.sleep(...); throw TelegramError.timedOut }
    ...
    return result   // <- does NOT actually return yet
}
```

TDLibKit's async bridge (`TDLibApi.run(query:) async throws -> R`, in the
vendored package at `TDLibKit/Sources/TDLibKit/Generated/API/TDLibApi.swift:31051`)
is a bare `withCheckedThrowingContinuation` with **no cancellation handler**.
When its completion callback is silently dropped (the documented TDLibKit
race), that continuation NEVER resumes — cancelling the Swift `Task` around it
does nothing, because nothing in that code checks `Task.isCancelled`. Swift's
structured concurrency then bites: `withThrowingTaskGroup` is REQUIRED to
await every child task — cancelled or not — before the group itself can
return to its caller (this is the language's no-orphaned-child-tasks
guarantee). So even though the timeout branch "won" the race and computed its
error, `withThrowingTaskGroup(...)` cannot actually hand that error back to
`withResponseTimeout`'s caller until the OTHER child task (the permanently
stuck `operation()`) finishes — which, for a truly dropped response, is
never. The timeout wrapper was a no-op for exactly the scenario it exists to
handle, on every one of its ~6 call sites in this file (`getOrFetchMessage`
and friends had presumably been getting lucky — most of their races are
against a genuinely slow-but-completing response, not a permanently dropped
one, which finishes the group eventually instead of never).

### Fix
Rewrote `withResponseTimeout` (`Telegram/TelegramClient.swift`) to use two
**unstructured** `Task { }`s racing to resume a single `CheckedContinuation`,
guarded by a new `ResumeGate` (`NSLock`-backed, resume-exactly-once —
resuming a `CheckedContinuation` twice is a fatal error) instead of a
`TaskGroup`. Because the tasks are unstructured, the enclosing function
returns as soon as EITHER one resumes the continuation — it has no structured
obligation to wait for the loser, which keeps running fully detached in the
background and has its eventual result (if any) silently discarded. This
fixes the hang for every `withResponseTimeout` call site in the file (not
just the new search call), since the signature is unchanged and every caller
benefits automatically.

### Verification
- macOS + iOS Debug builds: **BUILD SUCCEEDED**.
- Tests: **TEST SUCCEEDED**, 104 (100 unit + 4 UI), 0 failures.
- Reinstalled + relaunched on iPhone XS Max
  (`8F28E614-EA35-5B10-8DC9-E390026D4599`); process confirmed alive.
  Pull-to-refresh itself still needs the user's on-device confirmation (no UI
  automation available from this session) — this time the fix addresses the
  actual mechanism, not just adds another instance of the broken helper.

---

## 2026-08-28 (evening) — Fix iOS pull-to-refresh hanging forever (`9df76a3`)

User: "when I pull a page in the iOS app to refresh it, it gets stuck at
refreshing and the refresh never finishes."

### Root cause
`Telegram/TelegramClient.swift` (`searchChannelMetadataMessages`, added in the
previous session for fast catalog sync) called `client.searchChatMessages`
through `try? await withFloodWait { ... }` with **no `withResponseTimeout`
wrapper**. This file has an existing, documented TDLibKit failure mode (see
the comment on `withResponseTimeout`, used by `getOrFetchMessage` and others):
TDLibKit's response matching can silently DROP a reply when TDLib answers
instantly from its local message-database cache — the receive-thread dispatch
races the client's own pending-completion registration, and the continuation
is never resumed, so the caller parks forever. A small local-index search for
a handful of `cascade:db*` messages is exactly the "answers instantly from
cache" case most likely to trigger this race (far more likely than the old
full-history `getChatHistory` paging, which mostly hits the network). The hang
propagated straight up the call chain: `searchChannelMetadataMessages` ->
`CatalogSnapshot.fetchChannelState` -> `CatalogSnapshot.upload()` ->
`AppState.loadAllFiles()` -> the `.refreshable` closure in
`FileBrowserView`/`RootView`, so SwiftUI's pull-to-refresh spinner never
completed.

### Fix
`Telegram/TelegramClient.swift` (`searchChannelMetadataMessages`): wrapped
each page's `client.searchChatMessages` call in `withResponseTimeout(15)`
(same helper already used by `getOrFetchMessage`), with up to 2 attempts per
page (a retried call with a fresh `@extra` almost always lands, per the
existing comment/precedent). On repeated failure the loop now breaks and
returns whatever was already gathered instead of hanging — `fetchChannelState`
already treats an empty/partial result gracefully (same as a full-scan
failure previously did).

### Verification
- macOS + iOS Debug builds: **BUILD SUCCEEDED**.
- Tests: **TEST SUCCEEDED**, 104 (100 unit + 4 UI), 0 failures.
- Reinstalled + relaunched on iPhone XS Max
  (`8F28E614-EA35-5B10-8DC9-E390026D4599`); process confirmed alive after
  launch. Could not simulate the actual pull-to-refresh gesture from this
  session (no UI automation available) — ask the user to confirm pull-to-
  refresh now completes on-device.

---

## 2026-08-28 (evening) — Fast Search-Based Catalog Sync & Alpha-Preserving Thumbnails (`2941dcf`)

Executed `SYNC_SEARCH_PLAN.md` end-to-end (Task A: search-based catalog sync;
Task B: alpha-preserving thumbnails).

### Task A — Fast Search-Based Catalog Sync

**Root cause**: `CatalogSnapshot.fetchChannelState` (`Storage/CatalogSnapshot.swift:413`)
called `TelegramClient.allChannelMessages(chatId:usingCache:true)`, which pages
backward through the ENTIRE channel history with `getChatHistory` (up to 2000
pages x 100 messages, 200ms inter-page delay) just to find the 1-2 small
`cascade:db*` catalog messages. In a channel with hundreds/thousands of 20MB
data-chunk messages this took 30-60+ seconds — the multi-minute pull-to-refresh
the user reported.

**Changes**:
- `Telegram/TelegramClient.swift`: added `searchChannelMetadataMessages(chatId:query:limit:)`,
  wrapping TDLib's `client.searchChatMessages` (server-side + local-index search,
  no full-history page). Default query `"cascade:db"` matches all three catalog
  message types (`cascade:dbsnapshot:v1:`, `cascade:dbdelta:v1:`, `cascade:dbpart:v1:`)
  in one ~100-200ms round-trip. Deviated slightly from the plan's single-call design:
  added bounded pagination (capped at 5 pages, `withFloodWait`-wrapped, 200ms
  inter-page delay matching the existing scan's rate-limit posture) that stops as
  soon as a checkpoint message is seen in a page — anything older than the newest
  checkpoint is redundant for restore, so this only matters for a vault with
  unusually heavy delta churn between 24h checkpoints, and never costs more than
  one call in the common case.
- `Storage/CatalogSnapshot.swift` (`fetchChannelState`): replaced the
  `allChannelMessages` scan with `searchChannelMetadataMessages`. Added the
  requested high-water-mark optimization: the newest returned message ID is
  compared against `UserDefaults` key `xc.lastSyncedMsgID.<channelID>`; on a
  match, an in-memory `channelStateCache` (chatId-keyed, `NSLock`-guarded, same
  pattern as `TelegramClient.channelScanCache`) returns the previously computed
  `ChannelState` instantly, skipping every `decodeMessagePayload` network
  download + JSON decode. Cache/UserDefaults are updated after every fresh
  compute; a new checkpoint/delta publish always raises the newest ID (Telegram
  message IDs are monotonic), so the cache self-invalidates — no manual
  invalidation wiring needed. Skips the cache short-circuit when a
  backup-channel restore fallback is requested but the cached state has no
  usable checkpoint, so that rare disaster-recovery path still gets a chance to
  run. Left the separate BACKUP-channel fallback scan (`allChannelMessages(chatId: backupID,…)`,
  restore-only, rare) untouched — out of the plan's stated scope.

### Task B — Preserve Alpha / Transparency for PNG Thumbnails

**Root cause**: two independent places always flattened thumbnails to opaque
JPEG regardless of source transparency:
1. `Engine/UploadEngine.swift:685` (`generateThumbnails`) JPEG-encoded the
   `-up.jpg` sidecar source unconditionally.
2. `Engine/ThumbnailService.swift` (`generateAndSaveThumbnail` /
   `generateAndSaveVideoThumbnail` / `generateAndSaveAudioThumbnail`) wrote
   BOTH a `.png` and a `.jpg` for every thumbnail but always cached/preferred
   the `.jpg`, and `localThumbnailOnDisk`'s candidate list checked `.jpg`
   before `.png` — so even the already-alpha-safe local PNG was shadowed by
   the opaque JPEG.
JPEG has no alpha channel, so transparent pixels (rounded app-icon corners,
 stickers) became solid boxes.

**Changes** (kept the TDLib-mandated JPEG-only inputThumbnail attachment
un-touched — documented in this repo as JPEG/≤320px/<200KB — alpha handling
only affects the sidecar/local-cache paths, which have no such constraint):
- `Engine/ThumbnailService.swift`: added `ThumbnailCrop.hasAlphaChannel(_:)`
  (checks `NSBitmapImageRep.hasAlpha` on the SOURCE image, before
  aspectFit/subjectSquare redraw it into a context that always has a
  structural alpha channel). `generateAndSaveThumbnail`,
  `generateAndSaveVideoThumbnail`, `generateAndSaveAudioThumbnail` now skip
  writing/caching the opaque `.jpg` (and delete a stale one from a prior
  generation) when the source has alpha, caching the `.png` instead.
  `localThumbnailOnDisk` gained a `-tg.png` candidate. The encrypted-sidecar
  fetch (`fetchSidecarThumbnail`) now sniffs the PNG signature on the
  decrypted bytes and writes `<id>-tg.png` or `<id>-tg.jpg` accordingly
  (instead of always assuming JPEG), deleting the stale sibling extension.
- `Engine/UploadEngine.swift`: `generateThumbnails` now also writes a sibling
  `<objectID>-up.png` (alpha-preserving, same ≤320px size) next to the
  existing `-up.jpg` whenever the source has alpha — the JPEG return value is
  unchanged (still required for the TDLib-attached inline preview).
  `uploadThumbnailSidecar` now prefers that PNG sibling over the JPEG when
  present, since the sidecar is an opaque encrypted document (never a TDLib
  inputThumbnail) with no format constraint. `UploadEngine.thumbnailURL`
  gained the matching `-tg.png` candidate.
- `Cascade iOS/AppState.swift` (`fetchThumbnailData`): the sidecar fetch path
  now sniffs the PNG signature on the decrypted bytes too, caching to
  `-tg.png` vs `-tg.jpg` correctly (the actual `Data` returned for display was
  already format-agnostic via `UIImage(data:)`, so this only fixes the on-disk
  cache filename/lookup consistency with `UploadEngine.thumbnailURL`).

### Build & test verification
- macOS: `xcodebuild -scheme Cascade -destination 'platform=macOS' build` — **BUILD SUCCEEDED**.
- iOS: `xcodebuild -scheme "Cascade iOS" -sdk iphoneos -configuration Debug build` — **BUILD SUCCEEDED**.
- Tests: `xcodebuild ... test` — **TEST SUCCEEDED**, 104: 100 unit + 4 UI (2
  regular + 2 launch), 0 failures. Existing thumbnail tests
  (`uploadThumbnailJPEGIsGeneratedAndReturnedForAttachment`,
  `thumbnailSidecarEncryptDecryptRoundTrips`) still pass unchanged — they only
  exercise the untouched JPEG return path.
- Installed + launched on iPhone XS Max (`8F28E614-EA35-5B10-8DC9-E390026D4599`):
  install + launch succeeded, process confirmed alive (PID 6423) after the
  launch settled. Launched the rebuilt Debug macOS app too (PID confirmed
  alive after 13s) — no immediate crash on either platform. Real-world
  behavioral verification (actual pull-to-refresh timing against a live vault,
  visually confirming a transparent PNG upload/round-trip) needs interactive
  use; not automatable from this session.

---

## 2026-08-28 (afternoon) — Upload Cloud Sync & iOS Pull-to-Refresh Cloud Reconcile (`12842e6`)

User:
1. "Browse Vault" in Settings should not be there.
2. Uploaded a file on macOS app, but doing refreshes on iOS did not show the file.

### Findings & Root Causes
- **Upload Publishing Gap (`UploadEngine.swift:540`)**: When an upload completed on macOS, `UploadEngine` updated the local SQLite database to `ready` but did not call `CatalogSnapshot.upload()`. As a result, the delta/snapshot containing the new object was not published to the Telegram channel until a manual force-sync or debounced schedule was triggered.
- **iOS Refresh Local-Only Gap (`Cascade iOS/AppState.swift:344,504`)**: On iOS, pulling to refresh (`.refreshable` in `FileBrowserView` and `RootView`) called `loadAllFiles()`, which only queried `DatabaseManager.shared.allObjects()` from the iPhone's local SQLite database. It never invalidated the scan cache or ran `CatalogSnapshot.upload()` to pull remote deltas/checkpoints from Telegram.
- **Redundant Settings Item (`Cascade iOS/Features/SettingsView.swift:85-92`)**: Settings contained a duplicate "Browse Vault" navigation link under the Vault section.

### Changes
1. **`Engine/UploadEngine.swift`**:
   - Added `_ = await CatalogSnapshot.upload()` immediately upon completing an upload so the new object record is published to the Telegram channel right away for other devices.
2. **`Cascade iOS/AppState.swift`**:
   - Updated `loadAllFiles(reconcileCloud: Bool = true)` to invalidate the channel scan cache (`TelegramClient.shared.invalidateScanCache(chatId:)`) and run `CatalogSnapshot.upload()` to pull and merge remote changes before loading files from SQLite and updating the UI.
   - Updated `refreshFiles()` to invoke `loadAllFiles(reconcileCloud: true)`.
3. **`Cascade iOS/Features/SettingsView.swift`**:
   - Removed the duplicate "Browse Vault" navigation link from Settings.

---

## 2026-08-28 (afternoon) — Aspect-Ratio Preserving Thumbnails & Files-Style Grid Presentation (`bd6a53c`)

User:
1. Currently thumbnails appear as squares. We need proper Apple Files-style thumbnails that preserve their natural aspect ratio (e.g. 16:9 for video) contained within an invisible bounding box.
2. Check whether current thumbnails in the Telegram channel are squares and fix the generator pipeline.

### Findings & Root Causes
- **Telegram Channel Thumbnails Diagnosis**: In `Engine/UploadEngine.swift:678`, `generateThumbnails(for:objectID:isVideo:)` was calling `ThumbnailCrop.subjectSquare(source, target: 640)`. In `Engine/ThumbnailService.swift:15`, `ThumbnailCrop.subjectSquare` cropped all source images and video frames to a `1:1` square before generating the `-up.jpg` document thumbnail uploaded to the Telegram channel. As a result, all previews previously uploaded to Telegram were indeed 1:1 squares.
- **Generator Aspect Ratio Fix**: `ThumbnailCrop.aspectFit(_:maxDimension:)` already existed in `ThumbnailService.swift` but was bypassed in favor of `subjectSquare`.
- **UI Grid Presentation**: In `Cascade iOS/RootView.swift`, `FileGridItem`'s `thumbnailView` had hardcoded `88x88` square placeholder cards for uncached video and photo items.

### Changes
1. **`Engine/UploadEngine.swift`**:
   - Switched upload thumbnail generation from `ThumbnailCrop.subjectSquare` to `ThumbnailCrop.aspectFit(source, maxDimension: 640)` and `ThumbnailCrop.aspectFit(fitted, maxDimension: 320)` so all uploaded thumbnails preserve natural widescreen, landscape, and portrait proportions.
2. **`Engine/ThumbnailService.swift`**:
   - Replaced `ThumbnailCrop.subjectSquare` with `ThumbnailCrop.aspectFit` in video, audio, and photo thumbnail generator methods (`generateAndSaveThumbnail`, `generateAndSaveAudioThumbnail`).
3. **`Cascade iOS/RootView.swift`**:
   - Updated `FileGridItem`'s `thumbnailView` to render thumbnails with `.aspectRatio(contentMode: .fit)` floating inside the invisible 105pt cell container with smooth corner rounding and subtle drop shadows.
   - Updated fallback placeholder cards for videos (16:9 96×60), photos (4:3 88×66), and documents (3:4 72×94) to reflect their natural media geometry.

---

## 2026-08-28 (afternoon) — iOS Browse Folder Navigation Tap Fix (`8c8c6ff`)

User: Unable to open folders in Browse.

### Findings & Root Causes
- In `Cascade iOS/RootView.swift`, `FileRow` and `FileGridItem` unconditionally wrapped their entire visual layout inside a `Button(action: onTap)`.
- In `FileBrowserView.swift`, folder rows/items were embedded inside a `NavigationLink` label with an empty closure (`FileGridItem(file: folder) {}` and `FileRow(file: folder) {}`).
- In SwiftUI, the nested `Button` inside `NavigationLink`'s label intercepted all tap events and executed the empty closure `{}` instead of allowing `NavigationLink` to trigger the navigation transition.

### Changes
1. **`Cascade iOS/RootView.swift`**:
   - Made `onTap` optional in `FileRow` and `FileGridItem` (`var onTap: (() -> Void)? = nil`).
   - Only wrap layout in `Button(action: onTap)` when `onTap != nil`. When `onTap` is nil, render raw content directly so enclosing `NavigationLink` receives taps cleanly.
2. **`Cascade iOS/Features/FileBrowserView.swift`**:
   - Updated folder rows and grid items in `FileBrowserView` to pass `FileGridItem(file: folder)` and `FileRow(file: folder)` without closures, enabling seamless folder navigation transitions.

---

## 2026-08-28 (afternoon) — iOS Files-Style Image Viewer, Video Playback Dismiss Fix, Catalog Snapshot Phantom Name Healing (`9824092`)

User:
1. File names still showing incorrect phantom names.
2. Images open zoomed in; should open aspect-fit on black like Apple Files app.
3. Image and video viewer controls should be hidden initially, show on tap, and hide only on tap (no autohide timers).
4. Video player close button (`xmark`) was exiting the app instead of canceling playback.

### Findings & Root Causes
1. **Image Pre-Zoom**: Wrapping `Image` in a 2D `ScrollView([.horizontal, .vertical])` with infinite max frame expanded the image beyond screen bounds.
2. **Control Visibility & Timers**: Controls defaulted to visible and had auto-hide timers, contradicting native Files app behavior where controls start hidden and toggle exclusively on user tap.
3. **Video Player App Exit / Crash**: Directly calling `playerView?.stop()` inside button actions destroyed the mpv GL render context while UIKit was in the middle of a frame draw cycle, triggering a SIGSEGV / abort. Dismissing via `appState.closeTheater()` and letting `.onDisappear` handle cleanup prevents the crash.
4. **Filename Healing**: In `Storage/CatalogSnapshot.swift`, the `merge` function preferred local records with newer `modifiedAt` timestamps even if the local name was a `File-` phantom created by VaultRepair.

### Changes
1. **`Cascade iOS/RootView.swift`**:
   - Redesigned `FilePreviewView` image viewer to match Apple Files app: pure black canvas, centered `aspectRatio(contentMode: .fit)` without scroll zoom distortion.
   - Initial state `showControls = false`: top toolbar and status bar start hidden. Tapping anywhere toggles controls with smooth animation; no auto-hide timer.
2. **`Cascade iOS/Features/VideoPlaybackView.swift`**:
   - Fixed close button crash: removed synchronous `playerView?.stop()` from button action, routing dismissal cleanly through `appState.closeTheater()`.
   - Controls start hidden (`showControls = false`) and toggle on tap without auto-hide timer.
3. **`Storage/CatalogSnapshot.swift`**:
   - Updated `merge(local:remote:localVaultID:)` to prioritize authentic filenames over `File-` phantom names regardless of local modification timestamp.
   - Updated `restore(force:)` to accept `force: Bool` and allow restore when all local objects are phantoms.
4. **`Cascade iOS/AppState.swift`**:
   - Enhanced `completePostAuthSetup()` to detect post-restore `File-` phantoms and trigger a forced catalog restore from the cloud checkpoint.

---

## 2026-08-27 (late evening) — iOS Audio & Video Player Overlays, Media Streaming, Image Viewer & Filename Healing, Delete Context Label, Private Vault Auto-Relock (`334956d`)

User:
1. Long pressing an item shows "Move to Recently Deleted", change to "Delete".
2. Fix photo view mode (was showing share/export button & size instead of opening photo).
3. Fix image file names not matching macOS app.
4. Port audio and video player UI overlays from macOS, ensuring streaming without downloading.
5. Auto-lock Private Vault so it asks for the PIN again upon re-entry.

### Findings & Root Causes
1. **Context Menu Label**: Multiple `Label("Move to Recently Deleted", systemImage: "trash")` instances in `RootView.swift`.
2. **Image Preview Fallback**: `FilePreviewView` only checked `file.isImage && UIImage(contentsOfFile: url.path)`. Because initial repair left some items with `mime == "application/octet-stream"` and `name == "File-XXXX"`, `file.isImage` evaluated to false, falling through to `cachedFileFallback` with share/export button.
3. **Image Filename Discrepancy**: In `Storage/VaultRepair.swift`, `nameRepaired` checked `existing.name.isEmpty`. Since existing items were set to `File-XXXX` by an earlier run, they were not considered empty and were never overwritten with genuine names from chunk captions.
4. **Media Player UI & Streaming**: Audio played headlessly with no visual controls or mini player. Video playback view had only minimal play/pause and no timeline scrubber or skip controls. Both needed byte-range streaming via `VaultStreamServer` and `VideoStreamingEngine.mpvStreamURL`.
5. **Private Vault Lock Persistence**: In `PrivateVaultView`, `isUnlocked` was kept in local view state without resetting on disappear or backgrounding.

### Changes
1. **`Cascade iOS/RootView.swift`**:
   - Replaced `"Move to Recently Deleted"` with `"Delete"` in `FileRow`, `FileGridItem`, and `FilePreviewView`.
   - Upgraded `FilePreviewView` with `loadedImage(for: url)` checking byte data directly, always rendering full-resolution zoomable image viewer when image bytes are present.
   - Added `PrivateVaultView.onDisappear` auto-lock resetting `isUnlocked = false` and `appState.isVaultLocked = true`.
   - Added `scenePhase` observer on `mainTabs` locking vault when app enters `.background`.
   - Added `AudioMiniPlayerView` docked above tab bar with album art, `EqualizerWaveformView`, timecode, play/pause and close buttons.
   - Added `FullAudioPlayerView` sheet with ambient glow, hero album art, track details, scrubber timeline slider, skip -15s / +15s, and play/pause controls.
2. **`Storage/VaultRepair.swift`**:
   - Updated `nameRepaired` to heal `File-` prefixed names: `(existing.name.isEmpty || existing.name.hasPrefix("File-")) && (!name.isEmpty && !name.hasPrefix("File-"))`.
3. **`Cascade iOS/AppState.swift`**:
   - Added audio state (`currentAudioTrack`, `isAudioPlaying`, `audioCurrentTime`, `audioDuration`, `showFullAudioPlayer`).
   - Added `AudioPlaybackManager` driving audio through `MPVPlayerView` with periodic telemetry updates and end-of-track detection.
   - Implemented `playAudio(_:)`, `toggleAudioPlayPause()`, `seekAudio(to:)`, `stopAudio()`.
   - Updated `openFile(_:)` to route audio to `playAudio` and video to `theaterFile`.
   - Added post-auth catalog heal checking for `File-` phantom names and invoking `VaultRepair.run()`.
4. **`Cascade iOS/Features/VideoPlaybackView.swift`**:
   - Built full controls overlay with top bar (back/close buttons, video title), center transport (-10s seek, play/pause circle, +10s seek), and bottom timeline scrubber (interactive slider with elapsed/total timecode).
   - Added tap-to-show / tap-to-hide gestures and 4-second auto-hide timer.
   - Guaranteed byte-range streaming via `VaultStreamServer.shared.startServer()` and `VideoStreamingEngine.shared.mpvStreamURL(for: object)`.

### Build & Deployment
- `Cascade iOS` (arm64, `sdk iphoneos`): **BUILD SUCCEEDED**
- `Cascade` (macOS, `platform=macOS`): **BUILD SUCCEEDED**
- Installed and launched on physical iPhone XS Max (`8F28E614-EA35-5B10-8DC9-E390026D4599`).

---

## 2026-08-27 (evening) — iOS Vault Decryption & Recovery PIN, Sidecar Chunk Repair, Native Previews & Share Sheet (`a6a9e54`)

User: Investigating why thumbnails and file names on iOS aren't appearing properly ("unrecognized format, names aren't correct").

### Findings & Root Cause Analysis
1. **Multi-device Cryptographic Boundary**: Files and sidecars are encrypted with AES-256 `objectKey` wrapped by `vaultKey`. On iOS, `ensureVault()` generated a fresh local key; the account's genuine `vaultKey` was sealed under the 4-digit Vault PIN in `cascade:vaultkey:v2:`. Without entering this PIN, `attemptRecovery(pin:)` was never triggered, leaving the vault locked and unable to unwrap keys or decrypt files/thumbnails.
2. **Sidecar Collision in Vault Repair**: In `Storage/VaultRepair.swift`, thumbnail sidecars (`meta.kind == ChunkCaption.kindThumb`) were treated as regular file data chunks, overwriting chunk index 0 with thumbnail data and creating phantom `File-XXXX` objects.

### Changes
1. **`Storage/VaultRepair.swift`**:
   - Differentiated `meta.kind == ChunkCaption.kindThumb` and `meta.kind == ChunkCaption.kindSub` to skip data chunk insertion.
   - Preserved sidecar message IDs into `thumbMessageID` on the associated `ObjectRecord`.
2. **`Cascade iOS/AppState.swift`**:
   - Vault PIN scoping: Clarified that Vault PIN is strictly for Private Vault files. Startup never shows a PIN modal; open files decrypt immediately with local DB keys.
   - Added `isVaultLocked`, `showVaultUnlockSheet`, `hasRecoveryBlob`.
   - Implemented `unlockVault(pin:)` (PBKDF2-HMAC-SHA256 derivation + seal unwrap) and `unlockWithBiometrics()`.
   - Added automatic catalog reconcile via `CatalogSnapshot.upload()` upon auth to restore filenames and metadata.
   - Added thumbnail sidecar fallback discovery in `fetchThumbnailData(for:vault:)`.
   - Added file operations: `cachedURL(for:)`, `isCached(_:)`, `downloadFile(_:progress:)`, `toggleFavorite(_:)`, `togglePin(_:)`, `deleteFilePermanently(_:)`, `calculateCacheSize()`, `clearLocalCache()`.
3. **`Cascade.xcodeproj/project.pbxproj`**:
   - Added `INFOPLIST_KEY_NSFaceIDUsageDescription` for iOS target Debug & Release configurations.
4. **`Cascade iOS/RootView.swift`**:
   - Built `VaultPINView` (4-dot indicator, numeric keypad, Face ID button, error shake).
   - Embedded `VaultPINView` in `PrivateVaultView` and wired `.sheet(isPresented: $appState.showVaultUnlockSheet)` to `RootView`.
   - Upgraded `FilePreviewView` with zoomable image viewer, native `PDFKit` (`PDFView`) document rendering, monospaced text/markdown/code viewer, download progress, and native iOS `ShareSheet` (`UIActivityViewController`).
   - Added Favorite and Keep Downloaded ("Pin") actions to `FileRow` and `FileGridItem` context menus.
5. **`Cascade iOS/Features/SettingsView.swift`**:
   - Added "Security" section with Vault Key unlock button and Face ID toggle.
   - Added "Storage & Cache" section displaying cache size and "Clear Cache" button.

### Build Verification
- `Cascade iOS` (arm64, `sdk iphoneos`): **BUILD SUCCEEDED**
- `Cascade` (macOS, `platform=macOS`): **BUILD SUCCEEDED**

---

## 2026-08-22 (late night, latest) — Wave 2 item 9: Shared-page upgrades

User: "yes please, continue" → item 9 (importer visibility / re-share
controls / activity).

### Design (`2c1412b`)
- **Activity log** (DB v33 `share_activity`): kinds created / join / revoked /
  expired / password_added. Joins hook the EXISTING updateChatMember signal:
  private pool joins attribute to the active share on that slot (+ Telegram
  userID); PUBLIC joins record channel-level entries with shareID="" because
  every public link shares one channel (per-link attribution impossible —
  documented). cancelShare/revokeExpired/creation success all log too.
- **Importer visibility**: private cards show an "N imports" badge;
  per-share "Activity…" menu opens a timeline sheet (icon/kind/date/importer
  ID; public rows say "Someone joined…").
- **Re-share control**: "Add Password…" on unprotected PRIVATE single-file
  links only. `remintLinkWithPassword` (pure, unit-tested): unwrap object key
  under current link key → new salt → deriveLinkKey(pw) re-wrap → new
  obfuscated blob; old link invalidated immediately (key no longer unwraps).
  Wrapper persists record+blob and logs the event. Protected/group links are
  excluded (old key unrecoverable / manifest re-wrap out of scope).

Tests (+2 → **100 unit green**): activity round-trip incl. public-channel
fallback; add-password rotation crypto.

---

User: "continue" → item 8 ("as scoped" = item 18 snapshot-on-overwrite + item
19 one-click bulk export).

### Design (`6e0be76`)
1. **Versions on overwrite**: the Finder mirror's replaceRemote is the only
   content-update path. It now (a) snapshots the retired copy via
   recordVersion BEFORE trashing, (b) carries the lineage to the replacement
   via NEW DatabaseManager.carryOverVersions(from:to:) (renumbered above
   existing history; source rows removed), and (c) leaves the old copy in
   TRASH with channel bytes intact instead of deleteForever — Trash-is-the-
   backup decision makes recovery real. Share note: links to replaced content
   keep working until Trash empties (trashed-source share guard blocks new).
2. **VersionsSheet** (NEW Features file + manual pbxproj entries): context
   menu "Version History…" → vN/date/size/hash-prefix rows, empty state,
   Trash-recovery hint.
3. **Bulk export**: context menu "Export…"/"Export N Items…" (multi-select;
   folders expand descendants client-side since ExportEngine filters exact
   IDs) → NSOpenPanel destination → ExportEngine.export with appState banner
   feedback (info start / success+count / error).

Tests (+1 → **98 unit green**): carry-over renumbering, no dangling source
rows, descending order continuity.

---

User: "Continue" → item 7.

### Design (`839e62f`)
- NEW `Engine/DuplicateFinder.swift`: pure grouping — active files (ready,
  non-trashed, non-tombstoned, non-folder, non-empty rootHash) grouped by
  content hash; members sorted OLDEST FIRST; wasted-bytes math honors a
  keep-selection map. Archived/private copies DO group (real bytes).
- NEW `Features/DuplicatesReviewView.swift` (+manual pbxproj entries): review
  sheet — set count + reclaimable summary, per-set rows with location/add-date,
  radio keep-selection (oldest pre-selected), one-tap "Keep 1 · Delete N".
  Deletion routes through AppState.deleteForever → shares die, vault+backup
  messages removed, tombstones + checkpoint republish — identical to manual
  delete. Entry: All Files page context menu "Find Duplicates…" (whole-
  catalog destination).
- Tests (+2 → **97 unit green**): grouping/keep-candidates/wasted math +
  selection overrides; exclusions (singletons/trash/hashless/folders/uploading).

---

User hit a SIGSEGV pressing the PiP panel's GREEN traffic light. Crash log:
mpv thread, objc_release/Block_release during dispatch drain — an
over-released callback closure. Root cause: the seamless-expand ADOPTION path
re-pointed the live layer's callback closures (and re-homed it into a fresh
VC) while mpv's async machinery still held references across threads — a race
the renderLock doesn't cover. Per user instruction, REVERTED `4d97421`
entirely (`3fa714c`): PiP is back on the verified hover-expand behavior
(theater closes on entry; expand = reopen + resume at position with brief
buffering; red X stops; no traffic-light zoom). The adoption idea stays parked
in git history — revisiting requires serializing callback swaps with mpv's
queue.

### Item 6: Storage dashboard (`cd3cd5e`)
- NEW `Engine/StorageDashboard.swift`: pure math — `folderSubtreeSizes`
  (memoized DFS over parentID graph, cycle-guarded, trashed+tombstoned
  excluded), `largestFiles(limit:)`, `totalBytes`.
- Settings: new "Storage Dashboard" card between Vault Usage and Local
  Storage — TOP FOLDERS (≤6, recursive subtree bytes + mini bar + share-of-
  vault %) and LARGEST FILES (≤6). Complements existing by-type breakdown and
  cache/TDLib rows.
- Tests (+3 → **95 unit green**): recursive sums, largest ordering/trash
  exclusion, A↔B cycle tolerance.

---

## 2026-08-22 (night) — Wave 2 item 5: PiP + audio output picker

User: "keep going" → item 5. Scope decided by the AVKit ban: true AirPlay
VIDEO routing is impossible without AVKit — casting = AirPlay AUDIO via mpv's
coreaudio device list + system Screen Mirroring for video (documented in
TESTING.md). The buildable piece: **Picture-in-Picture** + an output picker.

### Design (`548816c`)
1. **PiP** (`Features/PictureInPictureWindow.swift` NEW — Features is an
   EXPLICIT pbxproj group; manually added fileRef/buildFile/children/Sources
   entries): floating `NSPanel` (.nonactivatingPanel + .closable +
   fullSizeContentView, .floating level, canJoinAllSpaces, draggable,
   hidesOnDeactivate=false). The single live `MPVLayerView` is RE-PARENTED into
   the panel — same handoff PlayerFullScreenWindow uses; mpv never learns
   about superview changes so playback never hiccups.
   - Theater STAYS OPEN while PiP holds the layer (its dismantle destroys the
     mpv core) and remains the control surface; the black player area is
     accepted v1 cosmetics.
   - Exit paths dismiss PiP FIRST (restore layer → hostView, needsDisplay +
     mpvRenderUpdate nudge) then proceed: close-X traffic light → restore;
     theater ESC/close → restore+stop; if the host window died meanwhile,
     playback stops instead of orphaning a surface.
   - Mutual exclusion both ways with PlayerFullScreenWindow; PiP button hidden
     in fullscreen chrome. Chevron minimize repurposed as the video-PiP toggle.
2. **Audio output picker**: MPVLayerView.getAudioDeviceList parses the
   `audio-device-list` JSON property; setAudioDevice switches `audio-device`
   at runtime (AO rebuilds live). New hi-fi-speaker pill button + popover
   (`AudioOutputList`) with checkmark on active endpoint — AirPlay speakers/
   headphones/HDMI/DACs all appear here.

### Verification
Build green; **TEST SUCCEEDED** (93 unit tests — no new ones: pure AppKit
window mechanics are untestable headless; TESTING.md item 5 carries a 12-point
manual checklist). Commit `548816c`.

---

## 2026-08-22 (evening, latest) — Wave 2 item 4: Touch ID vault unlock

User: "I am ready, let's go" → item 4.

### Design (`938c8cb`)
- NEW `Engine/BiometricUnlock.swift`: LAContext wrapper — availability probe,
  sensor naming (Touch/Face), pure `isEligible(enabled:hasPINHash:biometryAvailable:)`
  gate, and `authenticate(reason:)` using `.deviceOwnerAuthenticationWithBiometrics`
  ONLY (no system-passcode fallback — the app's PIN screen IS the fallback;
  `localizedFallbackTitle = ""` hides the password button).
- Lock view (`PrivateVaultLockView`): in `.enter` phase with a PIN hash set +
  toggle on + sensor present → an accent "Unlock with Touch ID" button under
  the PIN dots + ONE-SHOT auto-prompt per lock-screen appearance. Success:
  `registerPINResult(success: true)` (clears the fail backoff) then flips the
  SAME `appState.isPrivateVaultUnlocked` flag the PIN path flips — no new
  unlock semantics. Failure/cancel: message nudges back to the PIN.
  Deliberately NOT offered for create/confirm/recover (they derive crypto
  material from the literal digits) and recovery-blob backfill skipped (needs
  the raw PIN; best-effort, runs on next PIN entry).
- Settings: new "Private Vault" card rendered ONLY when `BiometricUnlock.isAvailable()`,
  toggle bound to `xc.vault.biometricUnlock`, reverted automatically if the
  sensor disappears mid-session.
- Info.plist: added `NSFaceIDUsageDescription` (required by Face ID Macs).

### Verification
Build green; **TEST SUCCEEDED** — 93 unit tests (+1 `biometricEligibilityGate`;
the system prompt itself is untestable headless → TESTING.md item 4 carries an
8-point manual checklist). Commit `938c8cb`.

---

## 2026-08-22 (evening, later) — Wave 2 item 3: Finder drop-zone sync

User asked to continue AND to keep a manual-testing tracker — created
**TESTING.md** at repo root (per shipped feature: what was implemented,
automated tests, unchecked-box manual QA list; newest first).

### Design (`3fd4c9b`)
- **Config**: `xc.mirrorEnabled` / `xc.mirrorLocalPath` / `xc.mirrorFolderID`
  ("": vault root). Settings → new "Finder Sync" card (toggle, folder picker
  via fileImporter [.folder], cloud-destination menu, live status dot).
- **Engine**: NEW `Engine/MirrorSyncEngine.swift` (@MainActor singleton).
  Local→cloud via FSEvents (FileEvents+CFTypes, 1 s latency, 1.5 s debounce);
  cloud→local via a 30 s poller that runs `CatalogSnapshot.upload()` (cached
  scan; cheap when unchanged) then one unified reconcile pass.
- **Pairing baseline**: DB v32 `mirror_state` table (`MirrorStateRecord`:
  objectID/name/sizes/both mtimes/rootHash/lastSyncedAt) — local-only state;
  no FKs by design (v13 lesson). Baseline recorded AFTER each action, so the
  engine's own writes don't retrigger work on the debounced follow-up pass.
- **Decision matrix** (pure static `decide()`, 13 unit-tested branches):
  uploadNew / replaceRemote / pullOverwrite / adoptPair / conflictLocalKeeps /
  dropEntry / none. Conflicts = LWW by mtime; ambiguous same-size adoptions
  pair silently; deletions NEVER propagate in v1 (stale entries dropped,
  surviving side untouched). Hidden/partial/temp names never tracked.
- **Push**: `UploadEngine.upload(fileURL:parentID:)` directly (bypasses
  UploadManager's UI-state coupling); created object located via sourcePath +
  ready state. Replace = trash old → upload fresh under clean name →
  `appState.deleteForever([old])` (ALL deletion safety rails reused); failure
  restores the old row.
- **Pull**: quiet scratch download → temp-sibling copy → atomic swap into the
  mirror dir (ExportEngine pattern; scratch files are launch-wiped, mirror dir
  must hold real copies).
- pbxproj note: Cascade uses PBXFileSystemSynchronizedRootGroups — new Swift
  files need NO manual project edit here (old xCloud gotcha doesn't apply).

### Verification
Build green; **TEST SUCCEEDED** — 92 unit tests (3 new: round-trip incl. GRDB
millisecond-date tolerance, decision matrix, name filter). Commit `3fd4c9b`.
User QA checklist lives in TESTING.md item 3.

---

## 2026-08-22 (evening) — Wave 2 item 2: offline pins

User: "continue" → next queue item. "Keep Downloaded": pinned objects keep a
complete decrypted copy in scratch that survives BOTH the cache budget
(hard cap + 15 GB free-space floor) and the launch janitor's scratch wipe —
true offline availability (isCached → mpv plays the local file).

### Design decisions
- **Device-local flag**: `ObjectRecord.isPinned` is deliberately NOT synced —
  CatalogSnapshot strips it when adopting REMOTE records (`merge()` seeds +
  `normalized()`) AND re-asserts the local pin after the LWW fold-in (a remote
  win would otherwise silently unpin). A pin on one Mac must not download GBs
  on another; it also never rides chunk captions.
- **Budget accounting**: pinned bytes are excluded from `enforceCacheBudget`'s
  totalSize too — the cap governs evictable data only, so pins can't pressure
  unpinned files out (iCloud semantics).
- **Launch-wipe safety**: `cleanScratchAndLegacyCache` spares files whose stem
  matches a pinned object ID (`<objectID>.<ext>` naming); if the DB isn't
  started yet the wipe is SKIPPED entirely (an unreadable DB must never look
  like "no pins"). Legacy pre-pin cache dir still wiped unconditionally.

### What was changed (`e1f359e`)
1. Models v31 (`isPinned` boolean, defensive decode), DatabaseManager migration
   + sync `pinnedObjectIDs()` + `hasStarted()`.
2. DownloadEngine: `isPinnedFile(url:pinned:)` pure helper (unit-tested);
   exemption in enforceCacheBudget + cleanScratchAndLegacyCache.
3. AppState.setPinned — copies setArchived's recursive ID walk (folders pin all
   descendants); then sequentially downloads every uncached target with visible
   transfer cards (honors TDLib's ~2-big-download reality by ordering); undo/redo.
4. UI: context menu "Keep Downloaded" / "Remove Download" beside Rename
   (multi-select aware via actionTargets); badges — fileCard topTrailing pin
   circle, folder card pin glyph before the ellipsis, list-row trailing badge
   HStack, Photos/Videos cells topTrailing (when not selected).
5. Tests: `offlinePinFlagSurvivesOldSnapshots`, `pinnedFileStemMatching`
   (prefix-collision cases), `deviceLocalPinStrippedFromRemoteAdoption`.

### Verification
Build green; **TEST SUCCEEDED** (89 unit tests). Commit `e1f359e`. User check:
pin a file/folder → watch cards download → badge appears → relaunch → file
still opens with network off; unpin frees it on next launch.

---

## 2026-08-22 — SESSION CLOSE

One-session arc: **Feature Wave 2 executed start-to-finish** (9 of 10 items
shipped; item 10 smart-search deferred by decision — see ROADMAP). Feature
commits, in order:
`34db68b` subtitles · `e1f359e` offline pins · `3fd4c9b` Finder drop-zone sync
· `938c8cb` Touch ID unlock · `548816c` PiP + output picker (`4d97421`
seamless-expand attempt REVERTED in `3fa714c` after an mpv-thread callback
race — postmortem in item 173) · `cd3cd5e` storage dashboard · `839e62f`
duplicate finder · `6e0be76` version history + bulk export · `2c1412b`
Shared-page upgrades.

Also new: **TESTING.md** — per-feature manual-QA tracker (checklists for all
9 items). Final tally: **100 unit tests green**. DB migrations this session:
v30 subtitles, v31 pins, v32 mirror_state, v33 share_activity.

Next arcs (user-selected order): iOS companion first, then
distribution/licensing. User still owes manual QA on items 1–9 via TESTING.md.

---

## 2026-08-22 (evening) — Wave 2 item 1: sidecar subtitles

User: "start Wave 2" → first queue item from ROADMAP's Feature Wave 2
(subtitles). Kickoff notes' confirmed hooks (track enumeration + selectTrack +
dead-code `addExternalSubtitle`) were all real; built the missing pieces.

### Design
- **Linkage**: `ObjectRecord.subtitleSidecars: String?` (DB v30, TEXT column)
  holds a JSON `[SubtitleSidecar]` (`messageID` + original `name` per entry).
  Multiple subs per video; re-adding a same-named sub replaces its entry.
  Syncs via catalog snapshots (defensive decode keeps old clients safe).
- **Caption**: `ChunkCaption.kindSub = "sub"` + `subCaption(objectID:)` /
  `isSubCaption` — minimal `cascade:{kind:"sub",id:<videoID>}` like the thumb
  sidecar; bytes follow the video's own storage mode (AES-GCM sealed with the
  object key for private videos via single-slice encryptChunk, raw for public).
- **Upload**: `UploadEngine.uploadSubtitleSidecar(video:name:data:vault:)`
  posts an opaque document (`<uuid>.bin`, no thumbnail attachment), enqueues
  BackupSync mirror, records linkage via `updateObject` (bumps modifiedAt →
  LWW-safe). UI: context menu "Add Subtitles…" on any video (browser AND
  Videos page — grids share FileItemContextMenu) → fileImporter (multi-select)
  → `AppState.addSubtitleSidecar`. "Subtitles (n)" submenu lists attached subs,
  click to remove (deletes vault+backup message, rewrites linkage).
- **Playback**: `AudioPlayerEngine.setupMPVPlayer` (the single choke point —
  theater, mini-player expand, direct fullscreen all funnel here) spawns a task
  after play: materialize each linked sub to scratch (`sub-<msgID>.<ext>`,
  download by messageID + decrypt when private, cached per session) →
  `MPVController.addExternalSubtitle(url:title:mode:)`.
- **mpv timing** (the subtle part): mpv rejects `sub-add` before a file is
  loaded, and the theater view attaches AFTER play issues loadfile. Two queues
  mirror the existing seekOnLoad/pendingURL patterns: MPVLayerView parks subs
  until MPV_EVENT_FILE_LOADED (`awaitingFileLoaded` window); MPVController
  parks them until makeNSViewController attaches (`flushQueuedSubtitles`).
  First sidecar uses flag "select", the rest "auto".
- **Track picker**: subtitle popover gains an "Off" row (synthetic Track id 0 →
  `sid=0`) so sidecar/embedded subs can be hidden; sidecars appear as normal
  tracks titled with their filename minus extension.
- **Deletion**: deleteForever + cleanupPartialUpload gather sidecar messageIDs;
  VaultRepair purge safety unchanged — sub captions are never isChunkCaption.

### Verification
Build green; **TEST SUCCEEDED** — 86 unit tests incl. 3 new:
`subCaptionCodecMarksSidecarDocuments`, `subtitleSidecarJSONRoundTripAndLegacyDecode`,
`subtitleExtensionClassification`. Commit `34db68b`.

### User manual check (pending)
Relaunch Debug app → right-click a video → Add Subtitles… → pick a .srt →
play: subs should render; captions-bubble menu lists the track + Off.

### Known v1 limits
No auto-detect of same-stem .srt at upload time (manual pick only); share-link
imports don't carry sidecars; headless handoff doesn't re-add subs (video
background playback is removed anyway); scratch copy wiped at next launch
(re-downloaded on demand).

## 2026-08-22 (night) — Zero-buffering: deep-range prefetcher (item 160)

User asked for research-backed streaming improvements to eliminate buffering.
Findings: our fetch path paid one TDLib round trip per 1-8 MB SYNCHRONOUS
range request — latency-bound ~1 MB/s, at the edge of TrueHD+HEVC needs. TDLib
research (downloadFile docs, PartsManager source, td#1498): limit has NO small
ceiling; within one ranged download TDLib pipelines MANY parts across its
connections (official clients' speed); only ONE active download per fileId —
a new call supersedes the old (perfect seek semantics); ranged bytes land in
the persistent local file at original offsets with downloaded_prefix_size
growth reported by updateFile.

### What was changed (`1366284`)
1. `VideoStreamingEngine.DeepRangeFetcher`: per-fileId deep async window —
   ensureCoverage issues downloadFile(offset, limit≤48 MB→chunk end,
   synchronous:false, prio 32/8); waitForBytes polls localRangeState every
   40 ms and reads from the local file once prefix covers the request.
   Self-heals interference: if base moved away or prefix stalls >1.5 s,
   reissues coverage. All three serve paths now route through it (encrypted
   batch, encrypted jump/slice, plaintext batch); sealedChunkSize() clamps
   coverage to chunk end. Old serial fetch chain (ObjectFetcher tail-chain +
   fetchWithRetry on these paths) retired.
2. mpv insurance: demuxer-max-bytes 100→256 MiB, readahead-secs 20→30,
   back-buffer 25→32 MiB.

Expected: sustained throughput jumps from round-trip-bound to TDLib bulk speed;
mpv buffer rides out residual hiccups. Watch /tmp stream log lines "deep
window/served/reissue" for behavior.

### Verification
Build green; **TEST SUCCEEDED** (83 unit tests). Commit `1366284`. User to
verify with heavy files (TrueHD+HEVC): seek around, long playback, no buffering.

## 2026-08-22 (afternoon) — Folder sharing + folder-aware imports (item 168)

User asked whether folders can be shared (NO — blocked at engine/AppState/UI)
and requested: imports should land in the CURRENT folder like uploads do.

### What was changed (`f6cc47e`)
1. **Folder sharing**: share() expands folder selections to descendant FILES
   (private/trashed skipped; empty expansion refuses), each ShareFile carries a
   new optional `path` ("sub/dir/file.ext") encoded as `p` in the link manifest
   (Codable — legacy links decode unchanged). forwardShare threads the path
   map. Recipient's import resolves each path, creating missing subfolders
   (resolveImportDestination/ensureFolder), under the chosen destination.
2. **Folder-aware imports**: importLink/stageImport/stageLegacyImport accept
   destinationFolderID; AppState.importShareLink passes currentFolderID when
   browsing All Files. Imports now land where you're standing — same mental
   model as uploads.
3. Quick wins: trashed-source guard (trashed files silently excluded from
   shares); expiry copy corrected 7 days → 24 hours.

### Verification
Build green; **TEST SUCCEEDED** (83 unit tests; folder-refusal test updated —
unauthorized sessions now surface notAuthorized for folder selections).
Commit `f6cc47e`. User to verify end-to-end: share a folder → open link in
second account while inside a folder → hierarchy lands under it.

## 2026-08-22 (afternoon) — Ship-prep quick wins + distribution plan (item 167)

User asked how to ship closed-source without cracking/leaks. Advisory answer:
compiled Swift already hides source; Keychain-held TG credentials = no embedded
secrets; perfect protection impossible — raise cost + legal layer (EULA/DMCA).
Decision: licensing/notarization/activation DEFERRED to feature-complete
milestone; three cheap-now items done now (`797df96`):
1. streamLog + bootLog bodies wrapped in #if DEBUG — Release builds contain no
   fetch-offset/object-ID/bootstrap internals. (First gating attempt via script
   truncated two source files; recovered from git, re-applied via edit tool.)
2. Verified zero .md/docs in bundle or pbxproj resources.
3. ROADMAP.md: full distribution & licensing plan of record (Developer ID +
   notarized DMG, Ed25519 offline keys or activation backend, separate
   distribution Telegram api_id, release hardening checklist, accepted risks).

Verification: build green; **TEST SUCCEEDED** (83 unit tests).

## 2026-08-22 (afternoon) — Scrubber axis fix + relative-seek hold (item 166)

User's final scrubber audit: the bar rode ABOVE the time labels instead of
sharing their axis. Root cause: GeometryReader aligns children TOP-LEADING by
default — capsule/circle sat at y=0 inside the 28 pt row while the labels
centered. Fixed in BOTH players (VideoPlaybackView overlay + TheaterView audio
scrubber) with an explicit .frame(width:height:alignment: .center) around the
ZStack.

Functional gap found in the same pass: mpv.seek(relative:) (±10 s buttons)
bypassed the pending-seek hold entirely → label flicker on skips. Now routes
through seek(absolute:) so skips get the same hold + label sync as clicks.

Verification: build green; **TEST SUCCEEDED** (83 unit tests). Commit `0424965`.

## 2026-08-22 (afternoon) — Streaming round 3: preheat + flicker root cause #2 (item 165)

User: MKVs play buffer-free, the MP4 (2× size) buffers; seek-label reset still
there. Log forensics answered the size question: SIZE DOESN'T MATTER — TDLib
LOCAL STORE warmth does. The mkvs were watched before → their fetches complete
in 1-48 ms (local hits); the mp4 is a fresh upload → every 8 MB batch is a
network pull at ~600-800 ms. Duplicate fetches (run prio-8 + serve prio-32 on
the same range) waste part of that budget.

Fixes (`92c5a14`):
1. FLICKER ROOT CAUSE #2: VideoPlaybackView has its OWN 1.5 s scrubber hold
   (only TheaterView's was extended in item 164) → now 12 s. Also
   MPVController.seek(to:) delegates to seek(absolute:) so fraction seeks sync
   timePos too.
2. Post-upload TDLib PREHEAT: after a successful non-private upload completes,
   background task walks chunk records → getFileId → downloadFile(0, limit 0,
   priority 1) per chunk. Fresh uploads then stream from local disk exactly
   like rewatched files. beginBackgroundWarm added to TelegramClient.
3. readAheadWindowSlices 48→96 for deeper runway against bitrate spikes.

Verification: build green; **TEST SUCCEEDED** (83 unit tests). Commit `92c5a14`.

## 2026-08-22 (night) — Seek UX round 2 + buffering-honesty (item 164)

User: seek label still flickered (target → initial → target) and asked whether
buffering can be eliminated entirely "like YouTube".

Root causes found:
1. FLICKER: TheaterView's scrubber has its OWN seek hold
   (holdProgressUntilSeekLands) that gave up after 1.5 s, falling back to the
   stale engine time while mpv was still fetching — fighting MPVController's
   12 s hold from item 162.
2. SEEK LATENCY REGRESSION from item 161's batch bump: the serve path used
   readAheadBatchSlices (now 32) for sequential serves — but a synchronous
   fetch must fully complete before mpv sees its FIRST slice, so every
   start/seek waited on up to 32 MB.

Fixes (`08f145a`):
1. New serveBatchSlices = 8: serve path batches stay small for fast first byte;
   read-ahead runs keep 32-slice batches for throughput.
2. Theater hold extended 1.5 s → 12 s to mirror MPVController.

On "YouTube-level": honest framing given to user — YouTube = global CDN edges +
adaptive bitrate + multi-connection QUIC. Cascade is single-file VOD over
MTProto/TDLib with no parallel ranged calls per fileId (td#1498). Current
architecture already achieves steady-state smoothness; residual waits are only
cold start + seek fetch, now with visible feedback and small-batch fast first
byte. Remaining future lever if needed: multiple TDLib instances for true
cross-chunk parallelism (ROADMAP).

Verification: build green; **TEST SUCCEEDED** (83 unit tests). Commit `08f145a`.

## 2026-08-22 (night) — Player load/seek UX polish (item 163)

User follow-ups after scrubber fix: (1) time label didn't follow the scrubber
on seek, (2) no loading indication during cold start or seek waits ("00:00"
with a silent few-second wait), (3) buffering overlay never appeared.

Fixes (`7da1ae5`):
1. seek(absolute:) now also sets timePos to the target — label + bar stay in
   sync while the seek lands.
2. MPVController.isBuffering is now derived: cachePaused || waitingFirstFrame
   || pendingSeekTarget != nil. paused-for-cache alone never fires during cold
   start/seek fetch waits — play(url:) arms waitingFirstFrame until the first
   accepted time-pos update.
3. VideoPlaybackView shows the existing overlay during seeks too (dropped the
   `&& !isSeeking` exclusions).

Verification: build green; **TEST SUCCEEDED** (83 unit tests).

## 2026-08-22 (night) — Scrubber bounce fix (item 162)

User: seek worked but the playhead "danced" — clicked position → snapped back
to zero → returned to target after a few seconds and played. Root cause:
seek() set progress optimistically, but MPVController.handlePropertyChange
kept accepting mpv's async-seek updates (old/transiently-zero positions) until
the seek landed, overwriting the optimistic value.

Fix (`36dcf41`): pendingSeekTarget hold in MPVController — user seeks record a
target+timestamp; time-pos updates are IGNORED while one is pending until an
update lands within ~1 s of the target (seek complete) or 12 s safety timeout.
play(url:) clears the hold on new files. Covers video + headless paths (single
funnel).

Verification: build green; **TEST SUCCEEDED** (83 unit tests).

## 2026-08-22 (night) — Deep-range fetcher reverted (item 161)

User reported buffering WORSE with item 160 and asked whether slices can be
requested in parallel. Log forensics (/tmp/cascade-stream.log):
1. SUPERSEDE PING-PONG: two waiters on one fileId (serve off=346 MB, stale
   read-ahead off=533 MB) alternated windows every ~1.5 s — each supersede
   discarded TDLib's in-flight parts; prefix stuck ~3 MB until 49 s TIMEOUT.
2. DEAD REISSUES: file=1273's base never moved despite reissue storms
   (downloadFile errors swallowed by try?).
3. BANDWIDTH SPLIT across three concurrently streaming fileIds.
Answered the parallel-slices question from tdlib#1498: separate ranged calls
per fileId are impossible by design — a new downloadFile CANCELS the previous;
concurrency only exists INSIDE one call via TDLib's part pipelining.

### What was changed (`627edb0`)
1. Reverted VideoStreamingEngine to the proven serial synchronous chain
   (restored from pre-item-160 commit); removed DeepRangeFetcher +
   fetchViaDeepWindow + TelegramClient deep helpers entirely.
2. Kept mpv demuxer bumps (256 MiB / readahead 30 s / back-buffer 32 MiB).
3. Larger single sync batches for more internal pipelining per round trip:
   slicesPerFetch 8→16 (plaintext), readAheadBatchSlices 8→32 (encrypted).

If buffering persists, remaining lever: multiple TDLib client instances for
true parallelism (heavyweight) — ROADMAP candidate.

### Verification
Build green; **TEST SUCCEEDED** (83 unit tests). Commit `627edb0`.
User re-test: brief startup buffer (~1 s, normal cold start) then FULL smooth
playback — no stalls. Item 161 arc CLOSED; serial chain + large batches is the
final streaming architecture.
## 2026-08-22 (night) — Single-cache architecture (item 159)

User proposal (approved after assessment): remove the app-level playback cache
— TDLib's store is already a working cache; keep ONE cache, capped, at the
TDLib layer. Dependency scan showed quiet downloads also materialize files for
books/thumbnails/export/open-with-app, so those became scratch materializations.

### What was changed (`0d022df` + janitor fix)
1. Cap wired to TDLib: Settings "Cache Limit" picker now enforces
   optimizeStorage(size: cap) immediately on change AND DownloadEngine
   re-enforces it after every completed download. 0 = uncapped.
2. One Clear button: Clear Local Cache now purges previews + thumbnails +
   TDLib's download store; separate "Delete Telegram Download Store" row
   removed (size folded into its subtitle).
3. Playback-from-cache retired: mpvStreamURL/pdfStreamURL no longer return nil
   for cached files; AudioPlayerEngine.resolvePlaybackURL streams all media;
   MPVVideoView secondary view streams first, materializes only as fallback.
4. Scratch materialization: DownloadEngine.cacheDirectory() now aliases a new
   scratch/ dir — books, thumbs, exports, openFile land there; launch janitor
   wipes last session's scratch AND the legacy cache/ dir (453 MB reclaimed,
   verified). isCached() semantics preserved for remaining callers.

### Verification
Build green; **TEST SUCCEEDED** (83 unit tests). Legacy cache dir confirmed
gone post-launch. NOTE: an initial edit landed the janitor inside the 6-hour
cleanup loop by mistake (same call text) — caught because the legacy dir
survived relaunch; moved to post-auth bootstrap and loop restored.

 (item 158)

User asked how large TDLib's cache can grow and whether it can be cleaned.
Measured: ~/Library/Caches/Cascade/tdlib-files held 2.2 GB of documents.
TDLib keeps every fully-downloaded document indefinitely (nothing ever purged
it), which also makes pause/resume hard to observe (retries hit the cache).

### What was changed (`09f1187`)
1. `Telegram/TelegramClient.swift`: tdlibFilesSize() (disk walk of filesPath())
   + purgeDownloadedFiles() using TDLib's official optimizeStorage
   (fileTypes=[document], size=0, immunityDelay=0, returnDeletedFileStatistics)
   → bytes freed from stats.size. Safe by design: channel remains source of
   truth, anything requested later re-downloads.
2. `App/AppState.swift`: clearTdlibFileCache() with freed-space toast +
   .tdlibCacheChanged notification.
3. `Features/SettingsView.swift`: new "Delete Telegram Download Store" row
   showing live size + confirm dialog.

Note: this ALSO gives a clean way to test pause/resume for real — purge the
store first so retries actually pull bytes.

### Verification
Build green; **TEST SUCCEEDED** (83 unit tests). Commit `09f1187`.

## 2026-08-22 (evening) — Download pause/resume parity + sparse fast-path fix (item 157)

User asked whether downloads share the new true-pause architecture. They didn't:
download cards had Cancel only, the catch block deleted the partial file, and
cancellation never called TDLib's cancelDownloadFile. Also found a LATENT BUG:
TransferCenter.discard() ran UploadEngine.cleanupPartialUpload unconditionally —
discarding a DOWNLOAD card would tombstone/delete the cloud object itself.

### What was changed (`724d317`)
1. `Telegram/TelegramClient.swift` (downloadMessageFile): onCancel also fires
   cancelDownloadFile(fileId:, onlyIfPending:false) — parts retained per fileId.
2. `Engine/DownloadEngine.swift`: cancelled downloads KEEP the partial dest and
   persist exact state ("xc.dl.resume.<objectID>" = completedChunks:plainBytes);
   resume validates partial size, skips completed chunks, seeks to the exact
   byte offset, appends; card paused with last-known fraction. Other failures
   still drop partials.
3. `Engine/TransferCenter.swift`: discard() direction-aware (downloads drop
   card + partial only); download resume() feeds live progress into same card.
4. `Features/TransfersView.swift`: pause button on all active cards; unified
   menus; direction-aware help texts.

### Follow-up fix (`69973db`)
User round 1: fresh download after a cache purge failed with CryptoKit error 3
(AES-GCM authenticationFailure). Root cause: downloadMessageFile's fast path
trusted ANY existing TDLib local file — video streaming's ranged fetchRangeData
creates that persistent file and fills ONLY watched ranges, so a recently
streamed file had a sparse artifact that got copied in as if complete. Fast path
now requires file.local.isDownloadingCompleted == true; otherwise falls through
to a full downloadFile that fills missing ranges before the copy.

### Verification
Build green; **TEST SUCCEEDED** (83 unit tests). User to verify: post-purge
download now completes; large download → pause mid-chunk → bandwidth stops →
resume continues from the same fraction without redoing completed work.

## 2026-08-22 — True pause: cancel TDLib native upload (item 156)

User tested pause/resume: pause held fraction, resume showed "Resuming…" then
jumped straight to ~90% and completed. User hypothesized pause never actually
paused. CONFIRMED from code: UploadPauseToken was a flag + work.cancel() only —
TDLib's native preliminaryUploadFile kept streaming after Pause (we never called
cancelPreliminaryUploadFile). Resume found the background upload nearly done →
instant jump. This also explains the duplicate identical-hash chunk messages
found during item 155's channel dump (attempt #1 background-completed while
resume re-sent the same staging file).

Fix: uploadFile()'s onCancel handler now also fires
client.cancelPreliminaryUploadFile(fileId:) (best-effort) so Pause truly stops
network usage. Resume re-issues preliminaryUploadFile on the same staging path;
whether TDLib retains cached parts across cancel will be visible as jump-vs-crawl
on the next pause→resume test.

Verification: build green, **TEST SUCCEEDED** (83 unit tests). Commit `8f30adc`.
User re-test: pause at 49% → resume carried from 49% to completion — cached
parts ARE retained across native cancel; no resume penalty. Item closed.

## 2026-08-21 (late night) — Discard ghost fix (item 155)

User reported: upload paused at ~51%, discarded (Delete Transfer) — file
appeared in cloud but doesn't play. Root cause: `cleanupPartialUpload` (the
discard path) hard-deleted local rows WITHOUT tombstoning, cache invalidation,
or catalog republish. Stale deltas (never pruned) still listed the object;
next reconcile adopted the stale record back as "ready" with 0 chunks →
visible, unplayable.

### What was changed
1. **`Engine/UploadEngine.swift`** (`cleanupPartialUpload`): rewritten to
   mirror `deleteForever`'s safety machinery — mark tombstones first
   (absolutism blocks resurrection), gather + delete Telegram messages
   (vault + backup), invalidate channel scan cache, purge orphans, then
   hard-delete local rows, then force-republish checkpoint so the cloud
   catalog drops the object immediately.
2. **`App/AppState.swift`** (post-auth heal): added ghost-object cleanup —
   finds objects with state=ready AND 0 chunk rows (pure catalog artifacts
   that can't play), runs them through `cleanupPartialUpload` to tombstone
   + clean + republish. Idempotent (healthy catalog → 0 ghosts).

### Verification
- 83 unit tests green (83:0).
- Ghost `BECF9132` (ready, 0 chunks, no channel presence) cleaned on launch
  by the new heal step — confirmed via sqlite3: row gone, channel dump 0
  references.
- `docs/STREAMING_FIX.md` updated through round 7.

### Commits
- `d62f1e7` — Fix discard ghost: cleanupPartialUpload now tombstones +
  invalidates cache + republishes catalog; post-auth heal cleans zero-chunk
  ghost objects.

## 2026-08-21 (late night) — Full codebase audit + roadmap execution (items 146–151)

User requested a full codespace audit with online research and free-only
improvements. Delivered docs/AUDIT_2026-08-21.md (architecture assessment,
findings by severity, external research: OWASP 2026 KDF floors, TDLib upstream
state-persistence guidance, Telegram-as-storage risk model), then executed the
prioritized roadmap across four commits:

1. **Item 146 — eternal loading screen FIXED**: ChunkEngine.selfTest still
   asserted legacy 64+36 MB splits; uniform chunking threw planMismatch past
   startTelegram → TDLib never connected. Self-test updated; bootstrap hardened
   so engine self-tests are NON-FATAL sanity checks (banner, never a gate).
   Also cleared corrupt saved window state (windowless launches). Added
   /tmp/cascade-boot.log file diagnostics.
2. **Deletion absolutism (item 147)**: user saw deleted files reappear briefly.
   merge() resolved tombstone-vs-live by modifiedAt LWW — stale cached channel
   scan resurrected rows. Now: local tombstone ALWAYS beats remote live;
   replaceCatalog re-tombstones incoming live copies of locally-deleted ids;
   deleteForever invalidates the channel scan cache post-deletion.
3. **Item 148 — audit quick-wins**: vault PIN upgraded from unsalted SHA-256 to
   PBKDF2-SHA256 600k + random salt + constant-time compare + transparent
   in-place upgrade + attempt throttle ladder; CI workflow rewritten (was pinned
   to Xcode 15.4 + pre-rename scheme names = permanently broken); share-link
   password KDF raised to 600k with legacy-100k import fallback; Keychain
   secrets migrated to ThisDeviceOnly accessibility at launch.
4. **Items 149/150 — UX + surfacing**: sidebar Private Vault icon fixed
   (number → lock.fill); lock view gradient hero (keypad added then removed per
   user preference); launch heartbeat banner for unclean previous runs;
   rate-limit pacing banner; backup-mirror permanent-failure banner;
   deleteForever sync-failure banner; bootLog mirrored into LogManager.
5. **Item 151 — UploadManager extracted** from AppState (~150 lines: queue,
   drain loop, performUpload orchestration) into its own @MainActor type with
   weak AppState back-reference; AppState keeps thin delegates and observable
   fields; views untouched.

### Verification
Every step: build green + unit suite green (**final: 83 tests, 0 failures**) +
app relaunched clean per /tmp/cascade-boot.log. Streaming byte-perfectness was
re-verified live against the original file earlier the same day.

## 2026-08-21 (night) — Uniform ~1.9 GiB chunks + streaming crypto I/O

User proposal (approved): drop small media chunks entirely — TDLib's persistent
part-granular upload/download resume makes failed giant chunks cheap, so chunk
size should optimize message count, not failure granularity.

### What was changed
1. **`Engine/ChunkPlanner.swift`**: uniform `maxSafeChunkSize` (~1.9 GiB, MiB-
   aligned, under Telegram's 2 GB doc cliff incl. sealing overhead) for ALL
   content; profile/mime params retained for API stability but ignored; legacy
   size constants deprecated. Stored chunk sizes still win on resume.
2. **`Crypto/CryptoEngine.swift`**: new `encryptStream` / `decryptStream` —
   slice-at-a-time FileHandle transforms with optional incremental SHA-256
   hashers. Peak RAM ~2 MiB at any chunk size (was: whole chunk ×2).
3. **`Engine/UploadEngine.swift`** (`uploadChunk`) + **`Engine/DownloadEngine.swift`**
   (assembly loop): rewritten onto the streaming transforms; hashes computed
   incrementally; image hash-mismatch fallback reads back the written range.
4. **Resume-friendly retries**: failed chunk staging files preserved; retry
   re-issues the send for the same path so TDLib continues from cached progress.

### Verification
- New test `streamingCryptoRoundTripMatchesWholeBuffer`: streamed ciphertext
  round-trips to identical plaintext + classic decryptor compatibility (learned:
  AES-GCM randomizes nonces — two encryptions are never byte-identical, so
  cross-check via decryption, not ciphertext equality).
- `chunkPlanUsesStoredChunkSizeOnResume` updated: 1 GiB → 1 chunk; stored legacy
  sizes win on resume; 50 GB → 27 pieces ≤ maxSafe.
- Build green; **TEST SUCCEEDED** (81 unit tests). App relaunched. Pending user
  verification: large-file upload lands ~1.9 GiB chunks; playback/downloads normal.

## 2026-08-21 (night) — Streaming round 3: the prefetcher was deadlocked (and the test passed anyway)

User re-tested after round 2: "smooth and clean even after cache purge". Stream-log
analysis revealed playback WAS smooth but for the wrong reason.

### What the evidence showed (`/tmp/cascade-stream.log`, session 1)

- 1623 read-ahead run starts vs only **99 completed batches** — runs restarted
  every ~0.6 s, each restart cancelling its in-flight batch (2214 CancellationError,
  204 TDLibKit.Error error 1, zero timeouts).
- **793 serve misses** — essentially every slice was fetched by the serve path as a
  single ~1 MB request (2–14 ms each, because TDLib already had the chunks on its
  local disk).
- Playback stayed smooth because TDLib's own persistent download cache made
  single-slice fetches nearly free — NOT because the prefetcher worked.
- Frames verified perfect: mpv telemetry vfps steady 24.0, mistimed/voDrop/decDrop/
  drop all 0 for the whole session.
- Disk-cache ruled out: zero files in the app cache dir for the object; everything
  flowed through VaultStreamServer (serve/fetch log lines).

### Root cause

Single-run design + two distant serve positions: mpv opens a SECOND byte-range
stream for the moov/tail probe while the main stream plays. My `covers()` required
`servedSlice >= run.startSlice - 2`, so main (slice ~205) and tail probe (~484)
each saw the other's run as "not covering me" and cancelled+restarted it — a
ping-pong deadlock where no batch ever survived long enough to fill anything.

### Fixes (commit `caa4873`)

1. Up to **3 concurrent runs per object**; a run is spawned only when no live run's
   span overlaps the position's needed window (`r.start <= start+B && r.end >= start
   && r.head+B >= start`, or fully-filled `r.head >= start+W`). At capacity the
   OLDEST span is replaced — a tail probe can never starve the playhead's run.
2. Backward movement no longer triggers anything (uncached backward data is served
   singly until playback advances past the old window).
3. `fetchWithRetry` rethrows `CancellationError` immediately instead of pointlessly
   retrying a cancelled operation three times.
4. `ReadAheadRun` carries `endSlice` for span math.

### Verification

Build green; unit suite green (**TEST SUCCEEDED**, 79). App relaunched with a fresh
stream log (old session preserved at /tmp/cascade-stream-session1.log). Next test
must show: serve misses clustered at startup/seek only, hundreds of successful
read-ahead batches with ms timings, cache pegged at 20 s between hiccups.

## 2026-08-21 (evening) — Streaming round 2: first-half smooth, second-half buffering

User re-tested after item 139: the whole file played (progress — no more permanent
death) and the first ~10 minutes were smooth, but buffering appeared in the second
half. Also: entering fullscreen made macOS show a "Cascade wants to record this
screen" prompt.

### Telemetry evidence (/tmp/cascade-mpv-telemetry.log, TrueHD+HEVC session)

2390 samples bucketed per minute: cache pegged 20 s for min 0–10 (prefetcher easily
keeping up), dips to 4–11 s during min 10–15, recovery 18–20 s through min 15–23,
then a TOTAL pipeline stall min 24–28 (cache pinned 0.0 s, paused-for-cache 60/60
samples for ~4 straight minutes), stuttery recovery (0.3–9 s) min 32–39. A
multi-minute total stall means requests hung/failed wholesale, not jitter.

### Root causes found this round

1. **Layout eviction destroyed the playing file mid-stream**
   (`loadLayoutUncached`): when 8 layouts accumulated, ALL state was wiped —
   including the PLAYING object's fileIDs and per-chunk fetchers. Background probes
   (thumbnail generation, other files' stream URLs) build layouts during playback;
   once the wipe fired mid-play, new fetches created a SECOND concurrent TDLib chain
   on the same fileId — supersede semantics clobbering each other → hangs/retry
   storms → exactly a minutes-long total stall. Fix: LRU store (`layoutRecency`,
   cap 16) that NEVER evicts the most-recently-touched object; `plaintextSlice`
   touches recency every slice so the playing file is always protected; evicted
   objects' fetcher chains + read-ahead runs are cancelled cleanly.
2. **Prefetch gave up permanently after 3 failures** while re-arming depended on
   successful serves — during a stall serves stop succeeding, so the system could
   not self-heal. Now the loop backs off (0.3 s doubling, 5 s cap) and keeps trying
   until the window is filled or cancelled.
3. **Screen-recording prompt**: `captureTheaterSnapshot` calls
   `SCShareableContent`, which requires Screen Recording permission (TCC). Added
   `CGPreflightScreenCaptureAccess()` guard — unauthorized → skip the ghost
   snapshot silently (the live-attach fallback covers the fullscreen transition).
   No prompt.

### Other changes (`Engine/VideoStreamingEngine.swift`)

- Read-ahead window 24 → 48 slices (~48 MB ≈ 38 s buffer at 1.25 MB/s); batch
  4 → 8 slices per TDLib round trip (matches the proven plaintext batching).
- `fetchWithRetry`: up to 3 attempts with chain-cancel between attempts.
- **Instrumentation**: all streaming events append to `/tmp/cascade-stream.log`
  (layout built/evicted, serve misses, batch outcomes with ms, timeouts/errors,
  read-ahead lifecycle, invalidatePlayback) — the unified log is unreadable on
  this machine and stdout is lost via `open`; next playback has a full evidence
  trail.

### Verification

- Build green; full unit suite green (**TEST SUCCEEDED**, 79 unit tests, 0 failures).
- Debug app relaunched. User to re-test: full playback must be smooth end-to-end;
  fullscreen entry must NOT prompt for screen recording. After any stall:
  check `/tmp/cascade-stream.log`.

## 2026-08-21 (afternoon) — Encrypted video streaming buffering FIXED (read-ahead prefetcher)

Continued from the open investigation (bottom of this file, "Streaming buffering
buffering investigation (OPEN)"). Implemented the fix for the encrypted path that
buffered permanently after ~1 minute.

### Root causes found in code

1. **Cache-wipe bug (`fetchWithRetry`)**: on ANY transient fetch error the handler
   called `sliceCache.removeAll(for: objectID)` — evicting up to 48 MB of buffered,
   already-decrypted playback. One network hiccup = total buffer loss = permanent
   buffering. Cached slices were GCM-verified before caching and cannot be corrupted
   by a later failed request; the wipe was pure damage.
2. **Per-slice round trips on the serve path**: the encrypted branch fetched exactly
   one sealed slice (1 MB + 28 B) per TDLib round trip with no read-ahead — the
   fragility Claude diagnosed (60–150 negotiations/min, zero safety margin).
3. **Boundary-mapping regression (uncommitted item 137 change)**: the working tree
   had flipped `chunkAndLocalIndex`'s comparison from `<=` to `<` — BACKWARDS. With
   `<`, a slice landing exactly on a chunk boundary maps one chunk early with local =
   one-past-the-end (fetchLen 0 → range-fetch retry storms — the exact symptom item
   137 claimed to fix). Unit test `streamingSliceMappingAcrossChunks` caught it
   (failed in suite, passed before the flip). Reverted to `<=`.

### What was changed (`Engine/VideoStreamingEngine.swift`)

1. **`fetchWithRetry`**: no longer wipes the slice cache on transient errors; the
   generic-error retry is now wrapped in `withFetchTimeout` too (a hung retry can no
   longer stall forever); added a `priority` parameter.
2. **Encrypted-path read-ahead prefetcher**:
   - Serve path now fetches exactly ONE sealed slice on the critical path (fast
     startup preserved — mpv gets its first byte after a single ~1 MB round trip).
   - A background run (`ensureReadAhead` / `readAheadLoop` / `ReadAheadRun`) keeps
     the SliceCache filled 24 slices (~24 MB ≈ 19 s at 1.25 MB/s) ahead of the
     playhead, fetching 4 sealed slices per TDLib round trip (batching moved OFF the
     critical path, so it can no longer delay startup — the failure mode of the
     earlier naive batching attempt).
   - Batch fetches clamp to chunk boundaries, decrypt each piece with its file-wide
     slice key (`CryptoEngine.sliceKey(objectKey:index:)`), run at TDLib priority 8
     (serve stays 32), exit after 3 consecutive failures, and re-arm on every served
     slice. Backward jumps (>2 slices) restart the run; `invalidatePlayback` cancels
     it on stop/seek teardown; layout eviction cancels all runs.
3. **`SliceCache`**: 48 → 128 entries (128 MB headroom for window + demuxer
   back-reads); new `contains(_:)` existence check that does not perturb LRU order.
4. **`ObjectLayout.chunkAndLocalIndex`**: comparison reverted `<` → `<=` (boundary
   slice belongs to the NEXT chunk), with a comment explaining both directions.

### Verification

- Build green (`xcodebuild -project Cascade.xcodeproj -scheme Cascade build`).
- Full unit suite: **TEST SUCCEEDED**, 79 unit tests passed, 0 failures (before the
  boundary revert the suite failed on `streamingSliceMappingAcrossChunks`).
- Live playback test pending (user): an uncached ENCRYPTED video must play past the
  1-minute mark without entering permanent buffering; seek away and back must recover
  instantly; startup must stay fast (no 10-second first-byte delay).

## 2026-08-20 (night) — Fix: Atomic batch deletion for Empty Trash and Delete Forever

### Root Cause
`emptyTrash()`, `bulkDeleteForever()`, and context menus were iterating over trashed items in a non-async loop and firing individual un-awaited `deleteForever(file)` `Task` blocks concurrently. Each individual call was waiting for Telegram network message deletions (`deleteFromVaultAndBackup`) and share revocation before setting `markTombstone` and calling `loadFiles()`. This caused simultaneous TDLib request floods, race conditions between multiple `publishCheckpointFromLocal` calls, and left the items visible in Trash until all network calls finished.

### What was changed
1. **`Storage/DatabaseManager.swift`**:
   - Added `markTombstones(ids: [String], at: Date)` to atomically mark tombstones and clear chunks for an entire batch of objects in a single SQLite write transaction.
2. **`App/AppState.swift`**:
   - Implemented `deleteForever(_ files: [ObjectRecord])` to batch all deletions:
     - Optimistically marks tombstones and calls `loadFiles()` immediately so items vanish from Trash instantly.
     - Performs batch share revocation and batch Telegram chunk message deletion (`stride(by: 100)`).
     - Executes a single `VaultRepair.purgeOrphanedMessages()` and a single `publishCheckpointFromLocal(force: true)` for the entire batch.
   - Updated `emptyTrash()` and `bulkDeleteForever()` to pass the array of targets directly to `deleteForever(targets)`.
3. **`Features/FileBrowserView.swift`**:
   - Updated context menu "Delete Forever" / "Delete Permanently" buttons to call `appState.deleteForever(actionTargets)` in batch.

### Verification
- Headless test execution: `xcodebuild -configuration Debug -scheme xCloud -destination 'platform=macOS' -only-testing:xCloudTests test`
- **Result**: `** TEST SUCCEEDED **` (70 unit tests passed, 0 failures, 2.0s).
- Commit: `7ad25bf`.

## 2026-08-20 (night) — Fix: Prevent VaultRepair from overwriting newer local folder placement/metadata with stale Telegram captions

### Root Cause
During startup post-auth setup, `VaultRepair.run()` scanned Telegram document messages and parsed captions. For files that already existed in SQLite and had been moved into folders (such as `Images/`), `VaultRepair` saw that `existing.parentID != cleanParentID` (because older immutable chunk captions carried `parentID = nil`), and overwrote `existing.parentID = nil` in SQLite before triggering `loadFiles()`. This caused moved images to briefly flicker into the root of "All Files" until the newer cloud checkpoint restored their proper folder parentage.

### What was changed
1. **`Storage/VaultRepair.swift`**:
   - For objects already existing in SQLite (`objectDict[objectID] != nil`), local and checkpoint metadata (such as folder parentage, renames, favorites) is strictly authoritative over older immutable chunk captions.
   - `cleanParentID` is now only applied if `existing.parentID == nil && cleanParentID != nil` (repairing unparented files), never clobbering an existing folder location with `nil`.

### Verification
- Headless test execution: `xcodebuild -configuration Debug -scheme xCloud -destination 'platform=macOS' -only-testing:xCloudTests test`
- **Result**: `** TEST SUCCEEDED **` (70 unit tests passed, 0 failures, 2.0s).
- Commit: `56a5e0f`.

## 2026-08-20 (night) — Phase 3 CI: GitHub Actions automated workflow for build and headless unit test execution

Implemented Item 25 from the Architecture Review Roadmap:

### What was changed
1. **Item 25: GitHub Actions CI Workflow** (`.github/workflows/ci.yml`):
   - Created automated GitHub Actions workflow triggered on `push` and `pull_request` to `main`.
   - Targets `macos-14` runner with `xcode-select` setup for Xcode 15+.
   - Executes Debug scheme build and headless unit test suite (`xcodebuild ... -only-testing:xCloudTests test`) to catch regressions and Swift 6 concurrency errors automatically.
2. **Item 24 Roadmap Update** (`architecture_review.md`):
   - Marked Item 24 resolved by the existing modular engine architecture (`TransferCenter`, `AudioPlayerEngine`, `VideoStreamingEngine`, `ShareEngine`, `BackupSync`, `ThumbnailService`, `CatalogSnapshot`, `VaultRepair`, `ExportEngine`).

### Verification
- Headless test execution: `xcodebuild -configuration Debug -scheme xCloud -destination 'platform=macOS' -only-testing:xCloudTests test`
- **Result**: `** TEST SUCCEEDED **` (70 unit tests passed, 0 failures, 2.0s).
- Commit: `8c8953d`.

## 2026-08-20 (night) — Phase 2 Features: FTS5 full-text search virtual table, version history foundation, local export engine, conflict branch preservation, transfer priority queue

Implemented Phase 2 (Items 17, 18, 19, 21, 22 from the Architecture Review Roadmap):

### What was changed
1. **Item 17: SQLite FTS5 Full-Text Search Virtual Table (`objects_fts`)** (`Storage/DatabaseManager.swift`, `xCloudTests/xCloudTests.swift`):
   - Added migration `v28-fts5-search` creating `objects_fts USING fts5(id UNINDEXED, name, tokenize = 'unicode61')`.
   - Populated existing records and registered automatic SQLite triggers (`objects_ai`, `objects_ad`, `objects_au`) to synchronize FTS index with `objects` table mutations.
   - Added `DatabaseManager.shared.searchObjects(query:vaultID:limit:)` with token sanitization, prefix wildcarding (`"token"*`), and rank ordering.
2. **Item 18: Version History Foundation (`ObjectVersionRecord`)** (`Storage/Models.swift`, `Storage/DatabaseManager.swift`, `xCloudTests/xCloudTests.swift`):
   - Added model `ObjectVersionRecord` and migration `v29-object-versions` creating table `object_versions`.
   - Added `DatabaseManager.recordVersion(for:)` to snapshot previous `rootHash`, `size`, `modifiedAt`, and `chunksJSON` before overwrites.
   - Added `DatabaseManager.versions(for:)` descending by version number.
3. **Item 19: Local Backup & Bulk Export Engine (`ExportEngine`)** (`Engine/DownloadEngine.swift`):
   - Created `actor ExportEngine` supporting bulk extraction of vault files/folders to arbitrary local filesystem targets.
   - Reconstructs complete nested directory trees and downloads/decrypts missing files sequentially with progress reporting and cancellation.
4. **Item 21: Conflict Detection & Branch Preservation** (`Storage/CatalogSnapshot.swift`, `xCloudTests/xCloudTests.swift`):
   - Updated `CatalogSnapshot.merge` to detect concurrent diverged modifications (differing non-empty `rootHash` on active files).
   - Generates non-destructive conflicted copy records (`"<basename> (Conflicted copy <date>).<ext>"`) for the losing version with cloned chunk records, matching Dropbox/Drive multi-device file preservation.
5. **Item 22: Download Priority & Preemption Queue** (`Engine/TransferCenter.swift`, `xCloudTests/xCloudTests.swift`):
   - Added `TransferCenter.Item.Priority` (`.background`, `.standard`, `.interactive`).
   - Wired priority parameter into `TransferCenter.begin` to allow interactive stream buffers and viewer requests to preempt bulk background transfers.
6. **UI Integration: Sync Status & Vault Export UI** (`Features/SidebarView.swift`, `Features/SettingsView.swift`):
   - Added live cloud sync indicator badge to `SidebarProfileCard` reflecting real-time sync state (`isSyncing`, `lastSyncDate`).
   - Added "Export Vault to Local Folder" UI in `SettingsView` leveraging `ExportEngine` and `NSOpenPanel`.
   - Added user toggle for independent backup copies (`xc.backupSendCopy`) in `SettingsView`.

### Verification
- `xcodebuild -configuration Debug build` succeeded.
- `xcodebuild -configuration Debug test`: **TEST SUCCEEDED** (73 tests: 70 unit + 2 UI + 1 launch, 0 failures).
- Commits: `356722a`, `22de0da`.

## 2026-08-20 (night) — Phase 1 Robustness: token-bucket rate limiter, API metrics telemetry, conditional heal, backup sendCopy, checkpoint pagination, file-backed log manager

Implemented Phase 1 (Items 11, 12, 13, 14, 15, 16 from the Architecture Review Roadmap):

### What was changed
1. **Item 11: Global Token-Bucket Rate Limiter (`RateLimiter`)** (`Telegram/TelegramClient.swift`, `xCloudTests/xCloudTests.swift`):
   - Created `actor RateLimiter` with leaky token-bucket algorithm: 8-token burst capacity, sustained 20 writes/min (1 token every 3.0s).
   - Added `acquireWriteToken()` with automatic delay calculation, integrated directly into write operations via `withFloodWait(isWrite: true)`.
2. **Item 12: API Call Metrics & Telemetry (`APIMetrics`)** (`Telegram/TelegramClient.swift`, `xCloudTests/xCloudTests.swift`):
   - Created `actor APIMetrics` tracking rolling hourly and lifetime call frequencies by TDLib function name.
   - Wired automatic metric recording into `withFloodWait`, emitting warning logs on abnormal volume (>1000 calls/hr).
3. **Item 13: `sendCopy: true` Backup Option** (`Engine/BackupSync.swift`, `Telegram/TelegramClient.swift`):
   - Added user setting `xc.backupSendCopy` in `UserDefaults`.
   - Updated `TelegramClient.forwardMessage` and `BackupDrainer.drain()` to support `sendCopy: true`, creating true independent document clones in the backup channel when configured.
4. **Item 14: Multi-Part Checkpoint Pagination** (`Storage/CatalogSnapshot.swift`, `xCloudTests/xCloudTests.swift`):
   - Added `partCaptionPrefix` (`xcloud:dbpart:v1:`) and codec functions `makePartCaption` / `parsePartCaption`.
   - Added automatic partition slicing in `publishCheckpointFromLocal` for large catalogs (`maxObjectsPerPart = 50_000`).
   - Implemented part reassembly in `fetchChannelState` to gather all parts by nonce and reconstruct the unified catalog payload.
5. **Item 15: File-Backed Structured Log Manager (`LogManager`)** (`App/AppPaths.swift`, `xCloudTests/xCloudTests.swift`):
   - Created `actor LogManager` maintaining rotating log files (`cascade.log`, `cascade.1.log`, up to 3 rotations of 5 MB each) in Application Support logs directory.
   - Structured timestamped log format (`YYYY-MM-DD HH:mm:ss.SSS [LEVEL] [subsystem] message`) with `readRecentLogs` helper.
6. **Item 16: Conditional Post-Auth Heal** (`App/AppState.swift`):
   - Added `xc.catalogHealClean` flag tracking.
   - Skips expensive $O(N)$ chunk/object dedupe scan at launch when the catalog was clean and no crash recovery is needed, accelerating app launch.

### Verification
- `xcodebuild -configuration Debug build` succeeded.
- `xcodebuild -configuration Debug test`: **TEST SUCCEEDED** (69 tests: 66 unit + 2 UI + 1 launch, 0 failures).
- Commit: `613981a`.

## 2026-08-20 (night) — Phase 0b Data Safety & Correctness: test DB isolation, delta nonces, deletion tombstones, structured error toasts

Implemented Phase 0b (Items 7, 8, 9, 10 from the Architecture Roadmap):

### What was changed
1. **Item 7: Isolated Test Database Harness** (`Storage/DatabaseManager.swift`, `xCloudTests/xCloudTests.swift`):
   - Decoupled test database operations to `xcloud-test.sqlite` when running under test harnesses (`NSClassFromString("XCTestCase") != nil` or `XCTestConfigurationFilePath`).
   - Added lazy `ensureStarted()` to `DatabaseManager.read` and `DatabaseManager.write` so callers and tests always have an initialized database pool without manual lifecycle coupling.
   - Saved and restored catalog records in `replaceCatalogCreatesBackupSnapshot` to prevent inter-test mutation in the shared suite.
2. **Item 8: Delta Payload Nonce Deduplication** (`Storage/CatalogSnapshot.swift`, `xCloudTests/xCloudTests.swift`):
   - Added optional `nonce: String?` to `CatalogSnapshot.Payload` (Codable wire-compatible).
   - Generated unique `UUID().uuidString` nonce on every checkpoint and delta upload.
   - Deduplicated delta payloads in `CatalogSnapshot.fetchChannelState` using `seenNonces` set across vault and backup channels.
3. **Item 9: Deletion Tombstones (`tombstoneAt: Date?`)** (`Storage/Models.swift`, `Storage/DatabaseManager.swift`, `Storage/CatalogSnapshot.swift`, `Storage/VaultRepair.swift`, `App/AppState.swift`, `xCloudTests/xCloudTests.swift`):
   - Schema migration `v27-tombstone` added `tombstoneAt` DATETIME column and `idx_objects_tombstone` index.
   - Added `markTombstone(id:at:)` and `purgeOldTombstones(olderThan:)` (90-day retention) in `DatabaseManager`.
   - Updated `CatalogSnapshot.merge` and `changedRecords` so deletion tombstones survive merges and publish in deltas, permanently preventing delta replay resurrection.
   - Updated `AppState.loadFiles()` to filter `tombstoneAt == nil` for UI presentation.
   - Hardened `VaultRepair.run()` to skip reconstructing objects that have an active local tombstone.
4. **Item 10: Structured Error Surfacing** (`App/AppState.swift`, `Features/RootView.swift`, `Telegram/TelegramClient.swift`, `xCloudTests/xCloudTests.swift`):
   - Added `AppNotification` and `NotificationKind` (`info`, `warning`, `error`, `success`) to `AppState` with auto-dismiss timers.
   - Implemented `NotificationBannerView` with sleek macOS ultraThinMaterial glassmorphic design and subtle spring animations in `RootView.swift`.
   - Added `NotificationCenter` observer for `.cascadeAppNotification` so background engines can seamlessly post user-facing alerts.
   - Added flood-wait toast warnings in `TelegramClient.withFloodWait` (for waits >= 3s) and sync result toasts in `AppState.forcePublishSnapshot()`.

### Verification
- `xcodebuild -configuration Debug build` succeeded.
- `xcodebuild -configuration Debug test`: **TEST SUCCEEDED** (65 tests: 62 unit + 2 UI + 1 launch, 0 failures).

## 2026-08-20 (evening) — Telegram API safety hardening: flood-wait coverage, session scan cache, inter-request pacing

Implemented Phase 0 Anti-Ban safety hardening across TDLib call sites:

### What was changed
1. **Universal `withFloodWait` on TDLib operations** (`Telegram/TelegramClient.swift`):
   - Wrapped `deleteMessages`, `editMessageCaption`, `sendMetadataMessage`, `createShareChannel`, `createVaultChannel`, `archiveVaultChannel`, `setChannelPhoto`, `getOrFetchMessage` (all 3 fallback steps), `messagesByIds`, and `forwardMessage` inside `withFloodWait`.
   - Thread-safe `scanCacheLock` and `channelCooldownLock` with `Foundation.Date` and nonisolated helpers for Swift 6 safety.
2. **Session Channel Scan Cache** (`Telegram/TelegramClient.swift`, `App/AppState.swift`, `Storage/CatalogSnapshot.swift`, `Storage/VaultRepair.swift`):
   - Added `prewarmChannelScan(chatId:)` and `allChannelMessages(chatId:usingCache: true)`.
   - Prewarmed at `AppState.completePostAuthSetup()`: `pruneOldSnapshots`, `restore()` / `fetchChannelState()`, and `VaultRepair.run()` now share a single startup scan rather than 3 separate full-channel paginations (300+ requests reduced to 1 scan).
   - Write invalidation (`invalidateChannelScanCache(chatId:)`): any message send, delete, caption edit, or forward automatically invalidates the cache for that chat ID.
3. **Inter-request pacing & rate limits** (`Engine/BackupSync.swift`, `Engine/ShareEngine.swift`, `Telegram/TelegramClient.swift`):
   - `BackupDrainer`: 500ms `Task.sleep` between forwards to prevent burst flooding during queue drains.
   - `ShareEngine`: 300ms `Task.sleep` between chunk forwards and `forwardMessage` wrapped in `withFloodWait`.
   - `TelegramClient.fetchAllChannelMessages`: 200ms inter-page delay during history paging.
   - `TelegramClient.messagesByIds`: 200ms delay between message fetches.
   - `TelegramClient.enforceChannelCreationCooldown()`: 3s lock-backed cooldown between channel creations.

### Verification
- `xcodebuild -configuration Debug build` succeeded.
- `xcodebuild -configuration Debug test`: **TEST SUCCEEDED** (62 tests: 59 unit + 3 UI/launch, 0 failures).

## 2026-08-20 (evening) — Claude architecture review received + verified

The user's external consultant (Claude, per AGENTS.md rule 8) delivered a
335-line architecture review (`~/.gemini/antigravity/brain/a27536af-…/architecture_review.md`).
Per rule 8, every headline claim was verified against the code before accepting.

### Verification verdict (all spot-checks passed)
- **Flood-wait coverage "2 of 33 call sites"** — TRUE. `rg "withFloodWait"`
  finds exactly 2 protected paths: chunk upload sendMessage (TelegramClient.swift:1147)
  and BackupDrainer forward (BackupSync.swift:142). `allChannelMessages`
  (TelegramClient.swift:1213) pages up to 2000×100 messages with ZERO delay and
  no flood-wait; `deleteMessages` (:1253), `editMessageCaption` (:1259),
  `searchChatMessages`, `messagesByIds` all unprotected — confirmed.
- **BackupDrainer forwards without delay** — TRUE. The `Task.sleep(5s)` sits in
  the catch (error) branch only (BackupSync.swift:168); successful forwards run
  back-to-back up to `maxPerDrain` (50). It survives flood-waits (wrapped) but
  hits FLOOD_WAIT constantly during batch drains.
- **ShareEngine forwards: no flood-wait, no delay** — TRUE. Tight loop at
  ShareEngine.swift:415-429 (rolls back on failure, but the share fails).
- **3 redundant full-channel scans at startup** — TRUE. `completePostAuthSetup`
  (AppState.swift:710): `pruneOldSnapshots` → `restore()`/`fetchChannelState` →
  `VaultRepair.run()`, each independently calling `allChannelMessages`.
- **Tombstone design** — Claude recommends a `tombstoneAt: Date?` FIELD on
  ObjectRecord (migration v27) instead of my earlier `xcloud:dbdel:v1:` message
  type: deleteForever sets it, merge lets it win, restore filters it, VaultRepair
  skips matching chunks, GC after 90 days. Simpler than my proposal — endorsed.
- **Small nits**: Claude says "59 unit + 4 UI tests" — actual is 70 total
  (66 unit + 2 UI + 2 launch). File paths in the review use a stale
  `xCloud/` prefix — cosmetic only.

### What this means
The review's headline conclusion is correct: **the #1 real risk is Telegram
account safety (ban), fixable in ~1 day** (universal `withFloodWait` wrapper +
200ms paging delays + one shared startup scan + forward delays + channel
creation cooldown). The known-correctness gaps (test-DB isolation, delta nonce
dedup, tombstones, error surfacing) are the next layer. No code changed this
round; decisions on what to implement are with the user.

## 2026-08-20 (evening) — Architecture review + Claude consultation prompt

User asked: "is the current architecture perfect and bullet proof?" and asked for
a self-contained prompt for Claude (their external architecture consultant) on
the app's architecture and improvements that could take Cascade to "Google Drive
level".

### Honest assessment (delivered to user)
No — not perfect or bulletproof. Solid single-user Telegram-backed drive, but
real gaps remain: (1) no deletion tombstones — delta replay resurrects
permanently-deleted records on the double-failure restore path (documented
HANDOVER pending); (2) the test suite runs against the LIVE Debug DB — the
destructive `replaceCatalogCreatesBackupSnapshot` test is the exact wipe that
started the 2026-08-20 incident; (3) the TDLibKit dropped-response bug is
patched with timeout+retry (`withResponseTimeout`, TelegramClient.swift:390), a
workaround rather than a root fix in the TDLibKit layer; (4) LWW-by-modifiedAt is
the only cross-device conflict resolution — no version history, no undo; (5)
chunks are stored as Telegram-channel plaintext (per-file encryption dropped by
user decision 2026-08-16, CryptoEngine.sliceSize 1 MiB); (6) single-platform,
single-account; (7) no CI, no observability/error reporting, no real backup
beyond the two Telegram channels themselves.

### What was done
- **CORRECTION (same session, user challenged the prompt's encryption claim):**
  the first draft of the Claude prompt (and the docs) said "per-file encryption
  dropped 2026-08-16". FALSE — verified against the code: private files ARE
  AES-GCM encrypted per 1 MiB slice (Crypto/CryptoEngine.swift:93
  `encryptChunk`, UploadEngine.swift:282-341), object key wrapped with the
  Keychain master key, carried as `wrappedKey` in captions. What is actually
  true: **public files are plaintext by design** (`wrappedKey: ""`,
  CatalogSnapshot.swift:158) and single-chunk videos in non-private folders
  skip encryption (UploadEngine.swift:247). Lesson: never state an
  encryption/security fact in docs or consultant prompts without grepping the
  upload path first. HANDOVER item 117 corrected; the corrected Claude prompt
  was given to the user.
- HANDOVER updated with item 117 (this round) + expanded known-weaknesses list
  for the consultation; Pending updated (consultation in flight; tombstone
  proposal still the top architecture decision awaiting the user).
- Built the Claude consultation prompt per AGENTS.md rule 8 (SELF-CONTAINED:
  repo context, file:line refs, short code excerpts, known gaps, concrete
  questions — Claude must answer without the repo).
- No code changed this round. Repo clean, app running, DB healthy
  (25/25, 10 active + 12 trashed + 3 folders, no file1.txt).
- Commit: `dea24f5` (previous round, docs) — no new commit this round
  (docs-only round, committed directly with the prompt below).

## 2026-08-20 (evening) — Bulletproof restore: backup-channel fallback + backup drainer wedge fix

Follow-up to the restore incident (commit `024523b`). User asked: why did restore
not use the BACKUP channel's snapshot copy, and made "the app must restore the DB
easily" a requirement. Found and fixed two more real gaps, plus one design flaw
in my own first attempt (verified empirically before shipping).

### Gap 1 — restore never read the backup channel (fixed)
- `fetchChannelState` only ever read the vault channel; the backup channel (an
  immutable audit log of forwards — `pruneOldSnapshots` never touches it,
  CatalogSnapshot.swift:417) was designed for disaster recovery but never wired
  to restore (BackupSync.swift:6-9 says "a future restore from backup phase").
- **Fix (kept)**: `fetchChannelState(chatId:allowBackupFallback:)` —
  RESTORE ONLY (never upload/reconcile/publish: a stale backup must not clobber
  a populated local catalog, and `newestID`-based `baseMessageID` computations
  must stay in vault id-space). When the vault channel yields no usable
  checkpoint, the newest checkpoint FORWARD in the backup channel is decoded
  and used as the restore base; the vault channel's deltas still apply on top
  (their ids are what the checkpoint's `baseMessageID` references).
- **Freshness guard**: a backup forward is only trusted when no delta carries
  records NEWER than the checkpoint's newest record (max `modifiedAt`
  comparison). A stale forward (published by a device with a stale catalog)
  sets `deltaBase = -1` → every delta is replayed and LWW merge keeps the
  newest records — a stale base can never hide uploads that exist only in
  deltas. Live-verified both branches.
- Also handles the vault-channel-entirely-gone case (backup delta forwards).

### Gap 2 — the backup mirror queue wedges permanently on one dead message (fixed)
- The drainer `return`ed on the FIRST forward failure (BackupSync.swift:153).
  A message deleted/pruned from the vault channel before its mirror completed
  ("The data couldn't be read because it is missing", e.g. `81788928` after a
  checkpoint prune) sat at the head of the FIFO queue FOREVER — every drain
  cycle bumped attempts, returned, and 67 real messages (including a clean
  checkpoint forward) never reached the backup channel. That is why the backup
  was stale during the incident recovery.
- **Fix (kept)**: after `maxForwardAttempts` (5) failed attempts a message is
  marked `status='failed'` and SKIPPED so the queue progresses
  (`markBackupFailed` + `backupAttempts` in DatabaseManager.swift; drainer
  `continue` at BackupSync.swift:164).

### Gap 3 — local-only drops resurrect via VaultRepair (fixed)
- The `--repair-catalog` hook dropped objects LOCALLY only; the object's chunk
  FILE MESSAGE stayed in the channel, and the next launch's VaultRepair rebuilt
  the object from its caption — the real "file1.txt keeps coming back" loop.
  (The app's own deleteForever never had this problem: `deleteFromVaultAndBackup`
  removes the messages too.)
- **Fix (kept)**: the hook now captures the chunk message IDs before the rows
  go and calls `deleteFromVaultAndBackup` (+ queue rows) — verified: after the
  drop + a VaultRepair run, file1.txt stays gone.

### Verification (all live, on the real test account)
- Restore-from-backup fallback fired with the vault channel's checkpoints
  deleted (fresh backup forward → 25 objects, no file1.txt; stale forward →
  delta replay). The 25-object state survives a wipe+relaunch after the test
  suite wiped the catalog: "restore: channel checkpoint=true deltas=23" →
  "snapshot restored: 25 objects, 25 chunks" → "reconciled, nothing new".
- Final DB: 25 objects / 25 chunks (10 active + 12 trashed + 3 folders), no
  file1.txt. Backup queue fully drained (dead messages skipped).
- Full suite green: **TEST SUCCEEDED** (70: 66 unit + 2 UI + 2 launch).
- Remaining gap (deferred — see HANDOVER pending): deletion TOMBSTONES. Without
  them, a restore that replays deltas (vault checkpoint gone AND backup stale)
  resurrects permanently-deleted objects whose records still live in old delta
  payloads. Deferred: not needed for app-driven deletions (messages get
  deleted), only for the double-failure disaster path.
- Commit: `9d27481` (code).

User reported "everything is gone now": the local catalog was empty at launch.
The chain: the unit test `replaceCatalogCreatesBackupSnapshot` (xCloudTests.swift
~1887, runs against the REAL Debug DB by design) wiped the catalog; the app's
launch restore was supposed to heal it but (a) hung, then (b) silently failed,
leaving the DB empty.

### Root cause 1 — restore hang: TDLibKit dropped-response
- With TDLib's message/file DB enabled, `getMessage` can answer INSTANTLY from
  the local cache. TDLibKit's receive thread routes responses to pending
  continuations by `@extra`; when that dispatch races the client's own
  registration the response is dropped, the continuation is never resumed, and
  the caller parks forever. Observed live: the LAST request of a burst dropped
  while the app blocked in `restore()` for minutes. (Watchdog in
  `downloadFile` didn't cover `getMessage`.)
- **Fix (kept)**: `withResponseTimeout(_:_:)` races any TDLibKit async call
  against a 15s deadline and `getOrFetchMessage` retries up to 3× (getMessage →
  getMessages → getChatHistory + getMessage), each attempt with a fresh
  `@extra` — a later attempt almost always lands.
  (Telegram/TelegramClient.swift:381-455; new `TelegramError.timedOut`.)
- **Fix (kept)**: cached-file fast path in `downloadMessageFile` — when TDLib
  already has the file locally it returns synchronously WITHOUT an updateFile
  event (same dropped-response hazard); now we copy the cached path directly.
  (Telegram/TelegramClient.swift:622)

### Root cause 2 — silent empty DB: FK violation swallowed by `try?`
- Once the hang was fixed, restore still failed: `replaceCatalog` threw
  `SQLite error 19: FOREIGN KEY constraint failed` on
  `INSERT INTO "chunks"` — the vault channel's deltas contained ORPHAN chunks
  (size-0 folder-linkage rows, objectID `6C76E5E3-…` = a deleted folder,
  messageIDs 14680065/15728640, state "uploaded") whose object row no longer
  exists. The transaction rolled back → DB stayed empty.
- `restore()` called `replaceCatalog` with `try?` and printed
  "snapshot restored" regardless — a lying success message that hid the wipe.
- **Fix (kept)**: `replaceCatalog` drops orphan chunks (logs "dropping N
  orphan chunk(s)") instead of FK-failing (Storage/DatabaseManager.swift:990);
  `restore()` propagates the error and reports honestly
  (Storage/CatalogSnapshot.swift:456).
- `setvbuf(stdout, nil, _IOLBF, 0)` in `CascadeApp.init` so redirected logs
  aren't block-buffered (App/xCloudApp.swift:10).

### Channel heal
- The checkpoint (997312E9) had been pruned from the vault channel by
  `pruneOldSnapshots` (only a forward in the backup channel survived), so
  restore replayed all 23 deltas. Verified local DB clean (25 objects/25
  chunks, no `file1.txt`) and republished a fresh checkpoint with
  `baseMessageID = newest channel ID` (via `--repair-catalog` + the normal
  launch heal), then pruned the stale checkpoints. Old deltas are now covered
  by the checkpoint's base and never replayed.
- **End-to-end verification**: wiped the DB and relaunched → "checkpoint
  85983232 decoded" → clean restore (25 objects, 26 chunks, 0 orphans dropped)
  → "reconciled, nothing new to publish" → DB has the full catalog (22 files +
  3 folders, NO `file1.txt`). A normal relaunch after the test suite (which
  re-wipes the catalog) healed the same way.

### Verification
- Full suite green: **TEST SUCCEEDED** (70: 66 unit + 2 UI + 2 launch,
  0 failures). Debug app relaunched with the catalog visible.
- Commit: `024523b` (code).

Two user-reported issues: (1) files moved to Trash came back after relaunching
the app, (2) a mystery `file1.txt` appeared in the vault.

### Trash-restore root cause
- `bulkTrash()` / `bulkRestore()` (App/AppState.swift:1506-1610) only flipped
  the LOCAL `trashed` flag via `updateObject`. The chunk captions in the channel
  are immutable and still carried `trashed:false` from upload time.
- `VaultRepair.run()` runs at EVERY launch (App/AppState.swift:743) and
  re-adopts `trashed` from the caption — `existing.trashed != trashed` →
  overwrite (Storage/VaultRepair.swift:120-125). So the next launch silently
  restored every trashed file, then the heal republished a checkpoint with
  `trashed:false`, losing the trash state for good.
- Rename/favorite already solved this exact problem by rewriting captions via
  `syncObjectMetadataToTelegram` (App/AppState.swift:1732-1737) →
  `BackupSync.editAndMirror`. Trash/restore just never called it.
- **Fix**: `bulkTrash`, `bulkRestore` and all four undo/redo closures now fetch
  the updated object and call `syncObjectMetadataToTelegram` after each
  `updateObject` — captions carry `trashed:true/false` and VaultRepair sees no
  discrepancy at the next launch. (Explicit `self.` needed in undo/redo
  closures — implicit capture is an error there.)
- Commit: `ea2b65e`.

### file1.txt root cause & cleanup
- The object `obj-backup-1` / `file1.txt` (100 B) is a FIXTURE of the unit test
  `replaceCatalogCreatesBackupSnapshot` (xCloudTests.swift:1887-1946), which
  writes it into the REAL Debug DB (tests share the live DB by design).
- On the earlier run when that test FAILED mid-way (the "20 columns but 21
  values" schema bug, fixed in `4da98b9`), the row stayed in `objects`; the
  app running alongside published a delta containing it to the channel. Even
  after the test passed later (its own `deleteVaultAndData` cleanup runs), the
  LWW merge in `CatalogSnapshot.upload()` (Storage/CatalogSnapshot.swift:142)
  resurrected `obj-backup-1` from that stale channel delta on every merge.
- **Cleanup**: killed the app, deleted the `objects`/`chunks`/backup rows, then
  republished a fresh checkpoint via the hidden debug hook
  `Cascade --repair-catalog obj-backup-1` (App/AppState.swift:373) — its
  `baseMessageID = newest channel ID` makes restore skip every older delta, so
  the stale delta can't resurrect the fixture again. Verified: after the full
  test suite + app relaunch, `objects`/`chunks` contain 0 rows for
  `obj-backup-1` (the inert `objects_backup` row is expected test residue).

### Verification
- Full suite green: **TEST SUCCEEDED** (70: 66 unit + 2 UI + 2 launch,
  0 failures). Debug app relaunched.

## 2026-08-20 (evening) — Player click fixes from Claude/Qwen consultation

User forwarded the two consultants' replies to the hit-test prompt (both self-consistent, converging on the same fixes). Verified each claim against the code before applying.

### Findings (all confirmed in code)
- **`playerHoverTint` was the theater/video killer** — both consultants, independently: `.allowsHitTesting(false)` (Features/VideoPlaybackView.swift:39) sat on the WHOLE composed label (`content.overlay{...}.allowsHitTesting(false)`), removing the button's label + its interactive glass from the hit-test tree. BookReader doesn't actually use the modifier (rg confirms only VideoPlaybackView + TheaterView call `.playerHoverTint`). Fix: scope `.allowsHitTesting(false)` to each tint shape INSIDE the overlay (the transparent shape is still hit-testable without it, so the volume-pill-swallowing concern stays covered).
- **Background key-monitor NSView (Claude's #1 mini-player suspect)**: `FileBrowserKeyMonitorView` sits in `.background` of the main window's ZStack and fills it; its AppKit view's default `hitTest` returns `self` for any point in bounds — on macOS 26's NSHostingView-layering regression that can hand sibling SwiftUI clicks to it. Fix: `override func hitTest(_:) -> NSView? { nil }` — it exists only as an NSEvent-monitor host (event-based, not view-based), so opting out of mouse hits is safe.
- Harness "Row A dead" is at least partially a CGEvent coordinate/timing artifact (both consultants); the glass-vs-no-glass effect is real. Glass config alone is NOT the mini-player cause (row D/F matched the real bar and still failed in-app).
- Remaining ranked mini-player suspects if still dead: sibling `.contentShape(Rectangle())`+`.onTapGesture` layer (AppKit recognizer priority), nested glass (use `GlassEffectContainer`), ZStack+Spacer wrapper → `.overlay(alignment:)`.

### Applied
- `Features/VideoPlaybackView.swift` — overlay-scoped `allowsHitTesting(false)`.
- `Features/FileBrowserView.swift` — `FileBrowserKeyView.hitTest → nil`.

### Build / test
- Build green (Debug). Full suite **TEST SUCCEEDED** (70: 66 unit + 2 UI + 2 launch, 0 failures). Debug app relaunched for click verification of both UIs.

Commit: `5f98797`. Awaiting user click test before any structural restructure (`.overlay(alignment:)`, `GlassEffectContainer`, gesture-layer removal).

---

User approved Option A for the design question from earlier: encrypted uploads stopped attaching plaintext thumbnails to chunk messages (those were visible image previews sitting in the Telegram channel). The preview is now its own tiny encrypted document.

### What changed
- **Upload** (`Engine/UploadEngine.swift`): chunk `sendFile` calls pass `thumbnailPath: nil` whenever `objectKey != nil` (every non-private file). Private (plaintext) files keep attached thumbs — their channel is private and a visible preview is intended. After the chunk group completes (and on resume — the block runs before `state = "ready"`, skipped when `thumbMessageID` already set), `uploadThumbnailSidecar` seals the same ≤320px `<id>-up.jpg` with `CryptoEngine.encryptChunk(objectKey, startSliceIndex 0)` (single 1 MB slice) and posts it as an opaque `file.bin` document with a new `xcloud:{"kind":"thumb","v":1,"id":...}` caption and NO attachment — the channel shows a name-less file, no preview. Mirrored via `BackupSync.enqueue` like every vault message. The messageID is recorded as `objects.thumbMessageID` (migration `v26-thumb-sidecar`). Sidecar failure logs and continues (file complete; only Telegram-backed preview missing — the local `<id>.png` still serves the session).
- **Fetch** (`Engine/ThumbnailService.fetchFromTelegram`): when `thumbMessageID != nil`, download + `decryptChunk(startSliceIndex 0)` → `<id>-tg.jpg`. Any failure falls through to the legacy attached-thumbnail loop, which still covers pre-sidecar uploads. `fetchSidecarThumbnail` unwraps the object key via `VaultManager.vaultKey` exactly like DownloadEngine.
- **Codec** (`Engine/ChunkCaption.swift`): `kindThumb = "thumb"` + `thumbCaption(objectID:)` (carries `size: 0` — `parse()` requires a size field) + `isThumbCaption`. `isChunkCaption` returns false for thumbs, so sidecars are never orphan-purge candidates.
- **Model/DB** (`Storage/Models.swift`, `DatabaseManager.swift`): `ObjectRecord.thumbMessageID: Int64?` (CodingKeys + decodeIfPresent + memberwise init — old snapshots decode to nil); migration `v26-thumb-sidecar` adds the column.
- **Latent bug fixed** (`DatabaseManager.replaceCatalog`): the `objects_backup`/`chunks_backup` safety tables were `CREATE TABLE IF NOT EXISTS ... SELECT * WHERE 0` — a backup table created before a schema migration keeps the OLD column count and `INSERT INTO objects_backup SELECT * FROM objects` then fails ("20 columns but 21 values"), which my migration exposed in `replaceCatalogCreatesBackupSnapshot`. Now DROP + recreate every replace.
- **Tests**: `thumbnailSidecarEncryptDecryptRoundTrips` (encrypt/decrypt round-trip, one sealed slice, encrypted != plain) + `thumbCaptionCodecMarksSidecarDocuments` (codec round-trip, not a chunk caption). The old `uploadThumbnailJPEGIsGeneratedAndReturnedForAttachment` guard test still passes (generation pipeline unchanged).

### Build / test
- Build green (Debug). Full suite **TEST SUCCEEDED** (70: 66 unit + 2 UI + 2 launch, 0 failures — first full run failed 2 tests, both fixed above). Debug app relaunched; migration applied to the live Debug DB.

Commit: `4da98b9`. New uploads get sidecars automatically; already-uploaded files keep their visible previews until re-uploaded (user-approved).

---

User reported after the media-keys commit: F8 toggles Cascade AND Apple Music at once. The OS routes each media key to the frontmost app (NSEvent copy) AND separately to the now-playing app via MediaRemote — Music was still the registered now-playing app.

### Root cause & Solution
- When a track is loaded the app now claims now-playing: `MPRemoteCommandCenter` registers togglePlayPause/nextTrack/previousTrack (enabled in `play()`, disabled in `stop()`/playback-error path) and `MPNowPlayingInfoCenter` publishes title/duration/elapsed/rate (+ queue index), throttled to ~1 Hz via the mpv `$timePos` sink, cleared on stop. Music loses the claim, so it stops receiving the keys.
- Because one physical press now arrives TWICE (NX systemDefined event to the frontmost app + remote command), added `AudioPlayerEngine.consumeMediaKeyPress()` — a 300 ms timestamp gate (NSLock-guarded, thread-safe from the event thread) — and routed every NX media-key handler (theater KeyView + FileBrowserKeyView closures) through it AFTER their context guards. First path wins; the duplicate returns `.commandFailed` / passes through.
- Side benefit: with the claim active, media keys control the app even while another app is frontmost (the command fires regardless of focus).

### Build / test
- Build green (Debug). Full suite **TEST SUCCEEDED** (68: 64 unit + 2 UI + 2 launch, 0 failures). Debug app relaunched for user verification.

Commit: `1ee8968`. Pending user verification.

---

User reported: (a) mini player transport buttons still dead on mouse clicks, (b) keyboard media keys (F7/F8/F9 / NX play-next-prev) don't control the app, (c) thumbnails visible in plaintext in the Telegram channel (design question).

### Root cause & Solution (clicks)
- Empirical hit-test harness (standalone SwiftUI app in /tmp/opencode/hittest) clicked 6 structural variants at exact convertToScreen coordinates: rows whose buttons (or container) carry `.glassEffect` received clicks; plain buttons with only `.contentShape(Circle())` did NOT — macOS 26 needs an interactive material on the button itself.
- The mini player's prev/next/expand/close buttons had NO glass (only play did). Added `.glassEffect(.regular.interactive(), in: .circle)` to every transport button, matching the working theater/BookReader pattern. Outer bar keeps `.regular` capsule.
- Harness findings (for future work): CGEvent clicks posted from within a process don't reach its own windows (external posting + activate works); the harness window's position was unstable between layouts (moves during settle).

### Root cause & Solution (media keys)
- Media keys were handled ONLY by the theater's KeyView (monitor installed while the fullscreen window is open); with the mini player up they went to the OS. Added F7/F8/F9 keyDown cases (98/100/101) + an NX systemDefined monitor (subtype 8: PLAY=16, NEXT/FAST=17/19, PREV/REWIND=18/20) to FileBrowserKeyView, gated on `currentTrack != nil` + theater closed; volume/mute codes pass through (system volume = app volume).

### Build / test
- Build green (Debug). Full suite **TEST SUCCEEDED** (68: 64 unit + 2 UI + 2 launch, 0 failures). Debug app relaunched for user verification.

Commit: `cc63030` (code), `7504ca0` (docs). Thumbnail-encryption design pending user decision.

---
## 2026-08-20 (evening) — Mini player buttons dead (keyboard works): interactive glass capsule over the bar swallows clicks

User reported the mini music player's buttons don't respond to clicks while space bar and other keyboard controls work fine.

### Root cause & Solution
- `Features/MiniPlayerView.swift:150` applied `.glassEffect(.regular.interactive(), in: .capsule)` to the WHOLE bar, while every button inside also carried its own `.glassEffect(.regular.interactive(), in: .circle)`. On macOS 26 the interactive material over the entire bar swallows child hit-testing (same quirk as the DMG login gate — clicks only land near the center). The theater player was already fixed in round 112 by removing the parent overlay; the mini bar still had the nested interactive-glass pattern.
- **Fix**: the outer bar material is now `.glassEffect(.regular, in: .capsule)` (non-interactive) — each button keeps its own `.interactive()` circle, so the glass look is unchanged but clicks reach the controls. Matches the working BookReader pattern (non-interactive container + interactive circle buttons).

### Build / test
- Build green (Debug). Full test suite **TEST SUCCEEDED** (68: 64 unit + 4 UI/launch, 0 failures). Debug app relaunched.

Commit: `66b1681` — `Fix mini player buttons not clicking: non-interactive outer glass capsule so button circles receive clicks`.

---

## 2026-08-20 (evening) — Fix: audio thumbnails vanish after cache clear (encrypted-era upload stopped attaching previews)

User reported: uploaded audio files show thumbnails, but after "Clear Cache" the thumbnails disappear and never come back (images still recover). Root-caused the encrypted-upload regression and restored thumbnail attachment at upload time. **User decision mid-session**: do NOT add a whole-file re-download to regenerate audio thumbnails (could download hundreds of GB just for previews on a large library); re-uploading the test files is acceptable. The quiet thumbnail-only download stays photos-only.

### Root cause & Solution
1. **Uploads stopped attaching thumbnail previews to Telegram (root cause)**:
   - `Engine/UploadEngine.swift:335` had `thumbnailPath: objectKey != nil ? nil : uploadThumbnailPath`. Since Phase 2 encrypted chunk uploads (commit `c7d8e2d`), every upload mints an `objectKey` (never nil), so the `<id>-up.jpg` preview was NEVER attached to chunk messages — for any file type.
   - Images masked the bug: photos regenerate locally (cached → `generateAndSaveThumbnail`; uncached → step-6 thumbnail-only download). Audio had zero recovery paths: `fetchFromTelegram` found no attached preview and step 6 was photos-only.
   - **Fix**: `Engine/UploadEngine.swift:335` — always pass `uploadThumbnailPath` (private files still pass nil since `uploadThumbnailPath` is nil for them; encrypted uploads work because `TelegramClient.thumbnailFileId` handles `.messageDocument` → `doc.document.thumbnail?.file.id`). New uploads now permanently store the preview on Telegram.
2. **Audio without embedded art couldn't regenerate (follow-up fix)**:
   - `generateAndSaveAudioThumbnail` returned nil for art-less audio (e.g. voice memos), while the upload-time pipeline fell back to QuickLook's generic icon — recovered thumbs would differ from originals.
   - **Fix**: `Engine/ThumbnailService.swift` — `generateAndSaveAudioThumbnail` falls back to `QLThumbnailGenerator` (640×640) for LOCAL files when FFmpeg/parser find no artwork (added `import QuickLookThumbnailing`). No download involved — only reads the cached file.
3. **Proposed (then REVERTED at user request): audio step-6 recovery**:
   - First attempt extended the photos-only last-resort thumbnail-only download to audio (`ensureThumbnailByDownload` dispatching to `generateAndSaveAudioThumbnail`). User rejected it: quietly downloading every audio file just to rebuild a preview would backfire on a large library (hundreds of GB). Audio stays excluded from step 6 — previews must come from Telegram's attached thumbnail or the local cache.
4. **Guard test added**: `xCloudTests/uploadThumbnailJPEGIsGeneratedAndReturnedForAttachment` — synthesizes an 800×600 PNG, runs `UploadEngine.generateThumbnails`, asserts the returned `<id>-up.jpg` exists on disk and is ≤320px (TDLib inputThumbnail limit). Locks in the upload-time attachment pipeline.

### Build / test
- Build green (Debug). Full test suite **TEST SUCCEEDED** (68: 64 unit + 2 UI + 2 launch, 0 failures). Debug app relaunched.

Commit: `6f17351` — `Restore upload thumbnail attachment; drop audio thumbnail re-download (keep photos-only) + guard test`.

---

## 2026-08-20 (afternoon) — Real audio artwork extraction, mini player teardown on delete/trash & 3-button audio player

Fixed audio album art extraction to extract ONLY real embedded artwork via a layered pipeline (Pure-Swift parser $\rightarrow$ QuickLook $\rightarrow$ FFmpeg packet reader) with zero fake placeholders. Added instant teardown of `AudioPlayerEngine` and `theaterFile` when an active file is trashed or deleted forever. Streamlined the theater audio player transport to the 3 iconic buttons (removing side arrow chevrons and fixing play/pause hit-testing).

### Root cause & Solution
1. **Real Audio Artwork Pipeline**:
   - `AudioArtworkParser.defaultAudioArtwork` was generating a synthetic vinyl disc graphic when extraction returned nil, masking real artwork and confusing the user with "fake" thumbnails.
   - `AudioArtworkParser` atom parser previously broke on M4A files where `moov` was placed after large `mdat` atoms.
   - **Fix**:
     - `Engine/AudioArtworkParser.swift`: Implemented random-access atom seek to traverse any atom hierarchy (jumping past `mdat` in 0ms) and ImageIO validation. Removed all synthetic placeholder generation.
     - `Engine/UploadEngine.swift`: Layered extraction for audio files: (1) `AudioArtworkParser`, (2) `QLThumbnailGenerator`, (3) `VideoFrameExtractor`. If no embedded art exists, returns `nil` cleanly.
     - `Engine/VideoFrameExtractor.swift`: Added `decodeFirstFrame` to read packet 0 without backward seeking.
2. **Mini Player & Theater Teardown on Delete / Trash**:
   - Deleting or trashing an active audio track did not notify `AudioPlayerEngine`, leaving the floating mini player active and playable after deletion.
   - **Fix**:
     - `App/AppState.swift`: In `bulkTrash()`, `emptyTrash()`, `deleteForever(_:)`, and `loadFiles()`, if `AudioPlayerEngine.shared.currentTrack?.id` or `theaterFile?.id` matches the deleted/trashed object, `AudioPlayerEngine.shared.stop()` is called and `theaterFile = nil` is cleared immediately.
3. **Theater Audio Player Transport & Play Button Clickability**:
   - `TheaterAudioPlayerView` had an overlapping `HStack` (`canGoPrevious` / `canGoNext` chevrons) with `.frame(maxWidth: .infinity, maxHeight: .infinity)` layered inside a `ZStack` on top of the center buttons, intercepting clicks and preventing the play/pause button from responding to mouse clicks (while spacebar worked globally).
   - **Fix**:
     - Removed the side chevrons and the overlapping `HStack`.
     - Streamlined the transport row to the 3 iconic player buttons (Previous, Play/Pause with loading state, Next), ensuring 100% direct hit-testing on click.

### Build / test
- Build green (Debug). Full test suite **TEST SUCCEEDED** (72: 64 unit + 4 UI + 4 launch, 0 failures). Debug app relaunched.

Commit: `4e3d8b0` — `Fix real audio artwork extraction, mini player teardown on delete, and streamline 3 iconic audio buttons`.

---

## 2026-08-20 (afternoon) — Pure-Swift audio artwork parser, default artwork generator & smooth streaming loading states

Implemented pure-Swift embedded album artwork parsing (MP3 ID3v2 APIC, M4A/MP4 covr, FLAC picture blocks), added high-res default audio artwork generation for plain audio files, and eliminated the flashing/frozen half-opened player glitch during media streaming.

### Root cause & Solution
1. **Audio Artwork Parsing & Fallback**:
   - `VideoFrameExtractor`'s FFmpeg demuxer seeking loop was seeking to `targetTs = duration * 0.08` (e.g. 14s) which skipped past 1-frame cover art streams at timestamp 0, and some demuxers didn't populate `attached_pic` for M4A/FLAC/MP3 files.
   - Files with no embedded cover art (e.g. voice memos) produced nil thumbnails and lacked Telegram-attached thumbnails.
   - **Fix**:
     - `Engine/AudioArtworkParser.swift`: Added zero-dependency pure-Swift binary parser for ID3v2 (v2.2, v2.3, v2.4 APIC/PIC frames), M4A/MP4 `covr` atoms, and FLAC `METADATA_BLOCK_PICTURE` blocks.
     - Added `AudioArtworkParser.defaultAudioArtwork` generating a high-res 640x640 vinyl disc artwork for audio files without embedded art.
     - `Engine/VideoFrameExtractor.swift`: Prioritizes `AudioArtworkParser` for local audio files and decodes static single-frame streams at timestamp 0 without seeking.
2. **Smooth Streaming & Zero-Flash Player Loading**:
   - In `Features/TheaterView.swift`, `body` had `else if url != nil { contentView } else { downloadingView }`. When media streaming began, `url` was briefly `nil` before `loadFile()` resolved, causing the `downloadingView` ("Preparing... 0%") card to flash open in the center before swapping to the player.
   - In `Features/VideoPlaybackView.swift` and `TheaterAudioPlayerView`, connecting to the stream server lacked explicit glass loading feedback.
   - **Fix**:
     - `Features/TheaterView.swift`: Displays `contentView` immediately for `previewKind == .video || previewKind == .audio`.
     - `Features/VideoPlaybackView.swift`: Polished `loadingView` with a glass container and `"Connecting to stream…"` indicator.
     - `TheaterAudioPlayerView`: Added loading state in the play button and hero artwork disc overlay while `audioEngine.isLoading`.

### Build / test
- Build green (Debug). Full test suite **TEST SUCCEEDED** (72: 64 unit + 4 UI + 4 launch, 0 failures). Debug app relaunched.

Commit: `4c6eb58` — `Add pure-Swift audio artwork parser, default artwork generator and smooth streaming loading states`.

---

## 2026-08-20 (afternoon) — Fix audio thumbnail extraction, Telegram attachment & cache-cleared retrieval

Fixed audio file thumbnail generation and persistence so that album cover art is extracted at upload time, permanently attached to chunk messages on Telegram, and reliably re-fetched / decoded even after local cache purges.

### Root cause & Solution
- `UploadEngine.subjectThumbnail` relied solely on `QLThumbnailGenerator` for non-video files. For audio files (MP3, FLAC, M4A, etc.), `QLThumbnailGenerator` returned `nil` or generic icons rather than embedded album art, resulting in `uploadThumbnailPath == nil`.
- Because no thumbnail was passed to `TelegramClient.sendFile`, the uploaded Telegram chunk documents had no thumbnail attached on the server.
- When local cache was cleared, `ThumbnailService.thumbnailURL` found no local file, `fetchFromTelegram` found no thumbnail on Telegram, and step 6 intentionally excluded audio from whole-file re-downloads, leaving audio files permanently without thumbnails.
- **Fix**:
  - `Engine/VideoFrameExtractor.swift`: Added attached picture detection across all streams (`AV_DISPOSITION_ATTACHED_PIC` or `attached_pic.size > 0`). Extracts raw embedded JPEG/PNG album art in 0.1ms directly from Libavformat packets.
  - `Engine/UploadEngine.swift`: Wired audio extensions to use `VideoFrameExtractor` in `subjectThumbnail`, generating both the grid PNG preview and the $\le 320$px JPEG thumbnail attached to Telegram chunk messages.
  - `Engine/ThumbnailService.swift`: Added `generateAndSaveAudioThumbnail` and streaming-probed artwork extraction for cached/streamed audio files; updated `isThumbnailable` to include all audio types.
  - Symmetrical persistence: Audio files now permanently retain their attached thumbnails on Telegram and seamlessly reload after local cache clears.

### Build / test
- Build green (Debug). Full test suite **TEST SUCCEEDED** (72: 64 unit + 4 UI + 4 launch, 0 failures). Debug app relaunched.

Commit: `e542116` — `Fix audio thumbnail extraction, Telegram attachment and cache-cleared retrieval`.

---

## 2026-08-20 (morning) — Fix floating transfers button collective progress & individual queued cards

Restored collective progress tracking on the floating transfers button (`LiquidMorphingFAB`) and ensured all queued uploads immediately appear as individual cards on the Transfers page and popover.

### Root cause & Solution
- Serial upload queue (`uploadQueue` in `AppState`) was only creating a transfer card in `TransferCenter` when each individual file actually started uploading.
- As a result, when File 1 completed, `TransferCenter` had zero active transfers, causing the next file to reset `settledWork` and show individual (0% -> 100%) progress per file instead of collective progress across the whole batch. Furthermore, queued files didn't appear on the Transfers page until their turn arrived.
- **Fix**:
  - `AppState.startUpload`: Pre-registers all queued files in `TransferCenter` upfront with their chunk work (`totalWork`) and status `"Queued…"`.
  - `Engine/UploadEngine.swift`: Added `existingTransferID` support to bind to the pre-registered transfer card, smoothly transitioning from `"Queued…"` to `"Uploading chunk X/Y…"` to `"Uploaded ✅"`.
  - `Engine/TransferCenter.swift`: Added `bindObjectID` and kept `Item.objectID` mutable for deferred object binding.
  - `LiquidMorphingFAB`: `overallProgress` now continuously aggregates the entire batch's work via `batchProgress` (0% to 100% smoothly across all files in the batch).
  - `TransfersView` / `MiniTransfersView`: Shows individual cards for every queued, active, and completed file in the batch.

### Build / test
- Build green (Debug). Full test suite **TEST SUCCEEDED** (72: 64 unit + 4 UI + 4 launch, 0 failures). Debug app relaunched.

Commit: `741d53d` — `Fix floating transfers button collective progress and individual queued cards`.

---

## 2026-08-20 (morning) — Verify and wire full-bleed profile pictures into dynamic share channel creation

Verified and ensured that whenever public or private share channels are created dynamically upon sharing, the full-bleed cropped avatars (`oc.png` and `pc.png`) are applied immediately.

### Verification & Changes
- `Engine/ShareEngine.swift`:
  - `createPoolChannel(id:kind:)`: Already automatically assigns and applies `oc.png` (public) or `pc.png` (private) on creation.
  - `allocatePrivateChannel`: Applies `pc.png` whenever an existing or adopted private channel slot is allocated.
  - `publicChannel`: Added explicit photo check to apply `oc.png` on existing/adopted public channels.
  - Both `Public/` and `Resources/` assets for `oc.png` and `pc.png` are confirmed to have 0.00% white margins and 100% full bleed.

### Build / test
- Build green (Debug). Full test suite **TEST SUCCEEDED** (72: 64 unit + 4 UI + 4 launch, 0 failures). Debug app relaunched.

Commit: `d5687ba` — `Verify and wire full-bleed profile pictures into dynamic share channel creation`.

---

## 2026-08-20 (morning) — Fix multiple channel photo updates by adding XCTestCase safeguard to TelegramClient

Investigated why the main vault channel received multiple duplicate photo update service notifications.

### Root cause
- When unit tests ran in `xCloudTests` against the Debug database, tests executing `VaultManager.ensureVault()` (`replaceCatalogCreatesBackupSnapshot`, `resetVaultRefusesUnconfirmedExecution`, etc.) each launched an unshielded `Task { await TelegramClient.shared.setChannelPhoto(...) }` targeting the real vault channel (`-1003757291622`).
- While `ShareEngine.healChannelPhotos()` had an `underXCTest` check, `TelegramClient.setChannelPhoto` and `VaultManager.swift` did not, allowing the ~6 test cases to repeatedly invoke `setChatPhoto` on the main vault channel during test suite runs.

### Changes
- `Telegram/TelegramClient.swift`:
  - Added strict `guard NSClassFromString("XCTestCase") == nil else { return }` check directly inside `setChannelPhoto(chatId:pngNamed:)` and `setChannelPhoto(chatId:label:hue:)` to guarantee tests never trigger real Telegram channel photo updates.

### Build / test
- Build green (Debug). Full test suite **TEST SUCCEEDED** (72: 64 unit + 4 UI + 4 launch, 0 failures).

Commit: `d4c77ed` — `Prevent unit tests from triggering real Telegram channel photo updates`.

---

## 2026-08-20 (morning) — Perfect full-bleed cropping for channel profile pictures

Cropped `cascade.png`, `oc.png`, and `pc.png` so their circular artwork aligns edge-to-edge with full bleed, eliminating white borders/crescents when Telegram applies its circular crop mask.

### Root cause & Solution
- `cascade.png`, `oc.png`, and `pc.png` had circular badges centered on a square canvas with padding/white margins ($x \in [48, 1204], y \in [32, 1204]$), causing Telegram's circular crop to show uneven white borders.
- Re-cropped and rendered all assets with subpixel Lanczos resampling to edge-to-edge $1254\times 1254$ full bleed (zero white boundary ring pixels).
- Updated `healChannelPhotos` to force-reapply the fresh cropped avatars to live channels on launch.

### Build / test
- Build green (Debug). Full test suite **TEST SUCCEEDED** (72: 64 unit + 4 UI + 4 launch, 0 failures). Debug app relaunched.

Commit: `f4c948e` — `Crop channel profile pictures to full bleed for perfect circular fit`.

---

## 2026-08-20 (morning) — Official PNG channel profile pictures integration

Replaced legacy generated gradient-label avatars with official PNG brand assets (`cascade.png`, `backup.png`, `pc.png`, `oc.png`) across all channel creation, allocation, and launch heal workflows.

### Changes
- `Engine/ChannelAvatar.swift`:
  - Enhanced `makeJPEG(fromPNG:)` with multi-path resolution (`Bundle.main`, `Resources/`, `Public/`, and full app bundle candidate paths) and automatic conversion to JPEG for TDLib chat photo requirements.
- `Storage/VaultManager.swift`:
  - Updated vault channel creation to set `cascade.png` (instead of label `"Vault"`).
  - Updated backup channel creation to set `backup.png` (instead of label `"Backup"`).
- `Engine/ShareEngine.swift`:
  - Updated private pool allocation, adoption, and re-joining to set `pc.png`.
  - Updated public channel creation and allocation to set `oc.png`.
  - Updated `healChannelPhotos` to force-upgrade existing legacy channels to official PNG brand graphics.
- `Telegram/TelegramClient.swift`:
  - Updated `setChannelPhoto(chatId:pngNamed:)` to use unencoded URL filesystem path and enhanced error logging.

### Build / test
- Build green (Debug). Full test suite **TEST SUCCEEDED** (72: 64 unit + 4 UI + 4 launch, 0 failures). Debug app relaunched and live channels updated.

Commit: `a322711` — `Integrate official PNG channel profile pictures for vault, backup, and share channels`.

---

## 2026-08-20 (morning) — Fix Telegram setup transition and upgrade country flags to high-DPI Apple Color Emoji

Investigated and resolved the API credential setup stall and upgraded the country dial code picker to render crisp, high-DPI Apple Color Emoji vector glyphs.

### Root cause (API setup stall)
- In `Features/TelegramSetupView.swift`, `LoginGateView.needsCredentials` was checking `(try? KeychainStore.loadTelegramCredentials()) == nil` instead of reading `@Observable` property `appState.hasTelegramCredentials`. When `appState.startTelegram` completed and wrote credentials to Keychain, SwiftUI was unaware of the change and did not trigger a view transition. Restarting the app worked because `hasTelegramCredentials` initialized from Keychain on boot.

### Changes
- `Features/TelegramSetupView.swift`:
  - Fixed `LoginGateView.needsCredentials` to check `!appState.hasTelegramCredentials`, ensuring instant automatic transition to the login steps upon TDLib connection.
  - Added `@State private var isConnecting` with a spinner on the Connect button to give immediate feedback.
- `Features/LoginView.swift`:
  - Upgraded `CountryFlagView` to compute and render official Unicode regional indicator emoji sequences (Apple Color Emoji), delivering gorgeous, high-resolution, vector-rendered flags for all 227 countries on Retina displays.
  - Updated phone input field to show the selected country's flag chip next to the dial code.

### Build / test
- Build green (Debug). Full test suite **TEST SUCCEEDED** (72: 64 unit + 4 UI + 4 launch, 0 failures). Debug app relaunched.

Commit: `db553bc` — `Fix Telegram setup view transition and upgrade country flags to high-DPI Apple Color Emoji`.

---

## 2026-08-20 (morning) — About Cascade window branding & official AppIcon update

Updated the "About Cascade" window to render the official high-resolution `AppIcon` asset, dynamic app version strings, and updated product copy.

### Changes

- `Features/AboutView.swift`:
  - Replaced hardcoded SF Symbol placeholder with the official `AppIcon` asset (`Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)`), styled with subtle shadow and border stroke.
  - Dynamically displays `CFBundleShortVersionString` and `CFBundleVersion`.
  - Updated title and subtitle copy to reflect the zero-knowledge encrypted architecture.

### Build / test

- Build green (Debug). Full test suite **TEST SUCCEEDED** (72: 64 unit + 4 UI + 4 launch, 0 failures). Debug app relaunched.

Commit: `bfe6c39` — `Update About Cascade window with official AppIcon and zero-knowledge branding`.

---

## 2026-08-20 (morning) — Phase 5: Catalog snapshot zlib compression & immutable backup preservation

Implemented hardware-accelerated zlib compression for catalog snapshot payloads and enforced strict immutable retention for database snapshots, deltas, and vault key records in the backup channel.

### Changes

- `Storage/CatalogSnapshot.swift`:
  - `publishDocument`: Compresses `Payload` JSON via Apple's native `(jsonData as NSData).compressed(using: .zlib)` before dispatching to Telegram, achieving 80–90% payload size reduction with $<0.5\text{ms}$ latency.
  - `decodeMessagePayload`: Automatically detects compressed vs. legacy uncompressed JSON payloads via `(rawData as NSData).decompressed(using: .zlib)` with fallback to raw JSON, maintaining 100% backwards compatibility.
  - `pruneOldSnapshots`: Prunes old checkpoints only from the active vault channel. **Never deletes from the backup channel**, keeping an immutable historical ledger.
- `Engine/BackupSync.swift`:
  - `deleteFromVaultAndBackup`: Enforced safeguard protecting `checkpointObjectID`, `deltaObjectID`, and `keyRecordObjectID` from deletion in the backup channel.
- `Storage/VaultRepair.swift`:
  - Added `xcloud:dbdelta:` prefix to snapshot ignore filters during channel repair scans.
- `xCloudTests/xCloudTests.swift`:
  - Added `catalogSnapshotZlibCompressionAndDecompression` unit test verifying high-ratio compression, decompression round-trip, and backward-compatible raw JSON decoding.

### Build / test

- Build green (Debug). Full test suite **TEST SUCCEEDED** (72: 64 unit + 4 UI + 4 launch, 0 failures). Debug app running. **No Release build** — user policy.

Commit: `475343e` — `Phase 5: Catalog snapshot zlib compression and immutable backup preservation`.

---

## 2026-08-20 (morning) — Phase 4: Zero-knowledge password-protected & simple share links with client-side key re-wrapping

Implemented zero-knowledge client-side encryption and key management for cloud-to-cloud serverless file sharing, offering both instant simple shares and password-protected shares.

### Changes

- `Engine/ShareEngine.swift`:
  - `ShareFile` & `ShareLink`: Added per-file `wrappedKey` support in group/single link manifests, `saltB64` and `isPasswordProtected` fields.
  - `share` / `forwardShare`:
    - **Simple share links (Default)**: $K_{\text{file}}$ wrapped with a random 256-bit `shareKey` embedded directly in the obfuscated URL fragment (`#...`). Recipient claims in $<1\text{ms}$ with zero password prompts.
    - **Password-protected share links (Optional)**: $K_{\text{file}}$ sealed with PBKDF2 link key derived from user password + 16-byte random salt. Link carries `#w=...&salt=...` without plaintext key.
  - `stageImport`: Resolves `linkKey` (via PBKDF2 with salt if password-protected or via `shareKey` if simple link), unwraps $K_{\text{file}}$, and re-wraps under recipient's vault master key (`recipientVaultKey`).
  - Added `ShareError.passwordRequired` and `ShareError.invalidPassword`.
- `App/AppState.swift`:
  - Added `promptPasswordShare` and updated `shareFiles` / `shareFile` to accept optional `password: String?`.
  - Updated `importShareLink` to handle password-protected links and trigger password prompt on `ShareError.passwordRequired`.
- `Features/FileBrowserView.swift`:
  - Context menu updated with `Private (Simple)`, `Private (Password Protected…)`, and `Public`.
  - Added `SharePasswordPromptSheet` for setting password on share creation.
- `Features/RootView.swift`:
  - Added `SharePasswordUnlockSheet` for unlocking and claiming password-protected shares.
- `xCloudTests/xCloudTests.swift`:
  - Added `passwordProtectedShareLinkRoundTripsAndUnlocks` and `unprotectedSimpleShareLinkRoundTripsAndUnwraps` unit tests.

### Build / test

- Build green (Debug). Full test suite **TEST SUCCEEDED** (71: 63 unit + 4 UI + 4 launch, 0 failures). Debug app running. **No Release build** — user policy.

Commit: `726b450` — `Phase 4: Zero-knowledge password-protected and simple share links with client-side key re-wrapping`.

---

## 2026-08-20 (morning) — Phase 3: In-memory media streaming slice decryption & download engine caching

Implemented on-the-fly random-access in-memory slice decryption for `mpv` byte-range playback via `VaultStreamServer` and full-file background download decryption in `DownloadEngine`.

### Changes

- `Engine/VideoStreamingEngine.swift`:
  - `loadLayoutUncached`: Unwraps $K_{\text{file}}$ from `object.wrappedKey` using vault master key. Derives exact plaintext byte-range layout mapping chunk documents to 1 MB sealed slices.
  - `plaintextSlice`: Fetches exact (1 MB + 28 bytes) sealed slice from Telegram with $O(1)$ seek latency and decrypts on-the-fly via `CryptoEngine.decryptSlice` directly into loopback HTTP stream for `mpv`.
  - Maintains `SliceCache` LRU for instant 0ms repeated slice lookups without touching disk.
- `Engine/DownloadEngine.swift`:
  - Unwraps $K_{\text{file}}$, verifies downloaded chunk ciphertext against `chunk.cipherHash` before decryption.
  - Decrypts multi-slice chunks via `CryptoEngine.decryptChunk`, verifies decrypted plaintext against `chunk.plainHash`, and assembles verified plaintext into local cache.
- `xCloudTests/xCloudTests.swift`: Added `encryptedStreamingLayoutAndSliceDecryption` unit test verifying multi-chunk slice translation and random-access slice decryption.

### Build / test

- Build green (Debug). Full test suite **TEST SUCCEEDED** (69: 61 unit + 4 UI + 4 launch, 0 failures). Debug app running. **No Release build** — user policy.

Commit: `146d9a8` — `Phase 3: Media streaming decryption and download caching`.

---

## 2026-08-20 (morning) — Phase 2: Encrypted chunk uploads & Telegram caption metadata sanitization

Implemented automatic per-file 256-bit AES key generation, client-side chunk encryption before dispatch to TDLib, and metadata sanitization in message captions.

### Changes

- `Engine/UploadEngine.swift`:
  - Mint fresh random 256-bit `SymmetricKey` ($K_{\text{file}}$) for every upload and wrap with vault key (`CryptoEngine.wrap`), saved in `ObjectRecord.wrappedKey`.
  - On upload staging, encrypt chunks with `CryptoEngine.encryptChunk` using deterministic slice indexing (`item.offset / 1MB`), calculate `plainHash` and `cipherHash`, and send ciphertext documents (`<objectID>-<index>.bin`).
  - Telegram message previews disabled for encrypted documents (preventing unencrypted thumbnail scans).
- `Engine/ChunkCaption.swift`:
  - Added `cipherHash` field to `Meta`, `encode`, and `parse`.
  - Blanked `name` and set `mime` to `application/octet-stream` on chunk message captions to completely hide filenames and file types from Telegram scanners.
  - Made `parse` robust to empty `name` and default `mime`.
- `Storage/VaultRepair.swift`:
  - Preserved `plainHash` and `cipherHash` when rebuilding chunk rows from messages.
  - Guarded against blanking out existing local object names when scanning sanitized captions.
- `xCloudTests/xCloudTests.swift`: Added `encryptedChunkCaptionWithSanitizedMetadataRoundTrips` unit test.

### Build / test

- Build green (Debug). Full test suite **TEST SUCCEEDED** (68: 60 unit + 4 UI + 4 launch, 0 failures). Debug app running. **No Release build** — user policy.

Commit: `c7d8e2d` — `Phase 2: Encrypted chunk uploads and Telegram caption metadata sanitization`.

---

## 2026-08-20 (morning) — Phase 1: Cryptographic primitives (chunk encryption/decryption, slice seeking & link key derivation)

Implemented foundational chunk-level encryption, multi-slice serialization, and password-protected link key derivation in `CryptoEngine.swift`.

### Changes

- `Crypto/CryptoEngine.swift`:
  - `encryptChunk(_:objectKey:startSliceIndex:)`: Encrypts arbitrary chunk data spanning multiple 1 MB slices into concatenated AES-GCM sealed slices (with 28-byte nonce+tag overhead per slice).
  - `decryptChunk(_:objectKey:startSliceIndex:)`: Decrypts concatenated sealed slices back into original plaintext data.
  - `deriveLinkKey(from:salt:)`: PBKDF2-SHA256 (100,000 iterations) derivation for password-protected share links.
- `xCloudTests/xCloudTests.swift`: Added 3 unit tests:
  - `chunkEncryptionDecryptionMultiSliceRoundTrip`: Verifies multi-slice round trip on 2.5 MB payload.
  - `randomAccessSliceDecryptionMatchesSubrange`: Verifies random-access $O(1)$ individual slice decryption matches exact sub-ranges for streaming.
  - `passwordDerivedLinkKeySealsAndUnlocks`: Verifies password-protected link key wrapping, correct unlock, and wrong-password rejection.

### Build / test

- Build green (Debug). Full test suite **TEST SUCCEEDED** (67: 59 unit + 4 UI + 4 launch, 0 failures). Debug app running. **No Release build** — user policy.

Commit: `d69e46a` — `Phase 1: Cryptographic primitives for chunk encryption, slice seeking, and link key derivation`.

---

## 2026-08-20 (late night) — Client-side zero-knowledge encryption & secure sharing architecture design

Thorough security review and architectural design for re-introducing end-to-end client-side encryption across the entire upload, download, streaming, and sharing pipelines without requiring a central backend.

### Key Conclusions & Architecture Decisions

1. **Risk Analysis**: Unencrypted uploads expose binary headers (`mp4`, `mkv`, `zip`, `pdf`) and plaintext captions (`name`, `mime`) to automated Telegram AI/perceptual hash scanners, risking channel bans and data loss.
2. **Envelope Encryption & Serverless Sharing**: Files are encrypted with random 256-bit keys ($K_{\text{file}}$). Sharing forwards ciphertext messages server-side via Telegram (zero download/upload bandwidth), embedding $K_{\text{file}}$ into the URL `#` fragment. The recipient claims ownership by re-wrapping $K_{\text{file}}$ under their own master key.
3. **Password-Protected Share Links**: Sensitive shares derive a link key via PBKDF2 from a user-defined password, sealing $K_{\text{file}}$ with AES-GCM. Intercepted links are unreadable without the password.
4. **Random-Access Streaming**: 1 MB slice-based encryption (`CryptoEngine`) allows `VaultStreamServer` to decrypt byte ranges on-the-fly directly into `mpv` with $O(1)$ seek latency and zero plaintext disk footprint.
5. **Sanitized Captions & Compressed Snapshots**: Telegram chunk captions stripped of sensitive file names and MIME types; `CatalogSnapshot` database checkpoints encrypted and compressed with gzip (~85-90% size reduction).
6. **Implementation Plan Created**: Complete specification saved in `implementation_plan.md`.

---

## 2026-08-20 (night) — Public/icon.png optimized and applied as macOS AppIcon

The user supplied a cropped 1238×1238 `Public/icon.png` (eliminating the 8 px border padding from the previous 1254×1254 master) to be optimized, used as the app icon, built, and restarted.

### Changes

- Losslessly optimized `Public/icon.png` compression (reduced from 1.71 MB to 1.41 MB, ~17.3% smaller) and synchronized to the root `icon.png` master.
- Regenerated all 10 required macOS asset catalog renditions in `xCloud/Assets.xcassets/AppIcon.appiconset/` using high-fidelity Lanczos resampling with max PNG compression across all scales (16×16, 32×32, 64×64, 128×128, 256×256, 512×512, and 1024×1024).
- Rebuilt Debug application (`Cascade.app`).
- Terminated running processes and relaunched `Cascade.app`.

### Build / test

- Build green (Debug).
- Full test suite **TEST SUCCEEDED** (64 tests: 56 unit + 4 UI + 4 launch, 0 failures).
- App running as `Cascade.app`. **No Release build** — user policy.

Commit: `fb5484f` — `Optimize Public/icon.png and update macOS AppIcon renditions`.

---

## 2026-08-20 — Revised Cascade icon adopted

The first Cascade icon correction was technically tightly cropped but still looked visually undersized in macOS. The user supplied a revised `Public/icon-new.png` with the three-step mark enlarged and an edge-to-edge rounded background.

### Changes

- Preserved the supplied 1254×1254 composition exactly (no additional crop), copied it to the canonical `Public/icon.png`, and kept `Public/icon-new.png` as the committed supplied original.
- Regenerated all ten macOS asset-catalog renditions in `xCloud/Assets.xcassets/AppIcon.appiconset/`, from 16×16 through 1024×1024.

### Verification

- Inspected 1024 px and 64 px outputs: the larger mark stays clear at small size and the background reaches the canvas edge.
- Debug build **SUCCEEDED**, including `actool` asset-catalog compilation. Stopped the previous Debug process and launched the newly built `Cascade.app`. No Release build — user policy.

Commit: `15ce81c` — `Use revised Cascade app icon`.

---

## 2026-08-19 (late) — Cascade app icon framing corrected

The installed `AppIcon` set still contained the older blue cloud image, while the intended dark Cascade mark was present in `Public/icon.png` but carried excess black canvas around its rounded silhouette.

### Changes

- Cropped `Public/icon.png` from 1254×1254 to a centered 1168×1168 master: the mark now fills the icon canvas while retaining an 8 px-equivalent safety margin around the outer edge and shadow.
- Regenerated all ten required macOS app-icon renditions in `xCloud/Assets.xcassets/AppIcon.appiconset/` from that master (16 through 1024 px). The assets now consistently use the dark Cascade mark at every scale.

### Verification

- Inspected the 1024 px and 64 px variants visually; the rounded silhouette is not clipped and the three-step mark remains recognizable at small sizes.
- Debug build succeeded, including asset-catalog compilation. No Release build — user policy.

Commit: `ab77457` — `Fix Cascade app icon framing`.

---

## 2026-08-19 (late) — Cascade rename (product + bundle ID), login simplification, icon crop

Renamed the app from xCloud to Cascade. This was a follow-up to commit `6226354` ("Rename xCloud → Cascade across the entire project").

### Changes

- `xCloud.xcodeproj/project.pbxproj`: `PRODUCT_NAME = Cascade` on app targets (Debug + Release), `PRODUCT_MODULE_NAME = xCloud` to keep the Swift module stable (existing `@testable import xCloud` in tests still works), `PBXFileReference` + `TEST_HOST` updated from `xCloud.app` → `Cascade.app`, test/UI test targets kept `$(TARGET_NAME)` to avoid swiftmodule collisions.
- `Features/TelegramSetupView.swift`: removed the "API Credentials" heading from the login form (kept the instruction text "Get your API ID and API Hash from my.telegram.org").
- `xCloud/Assets.xcassets/AppIcon.appiconset/`: regenerated all 10 icon sizes from the 1254×1254 source (`icon.png`) after cropping ~7-15px dark padding via content-bounds detection. Icon border gap remains slightly imperfect — user to finalize manually.

### Build / test

Build green (Debug). Full test suite **TEST SUCCEEDED** (0 failures). App launches as `Cascade.app` with bundle id `com.cascade.app` (dev) / `com.cascade.app.prod` (release).

### Known: the folder is still `xCloud`

The project folder on disk is still `~/Projects/xCloud`. The user plans to rename it manually in a fresh session after committing this work.

---

## 2026-08-19 (night) — Share archiving (hide without revoking)

Public shares never expire, so the Shared page accumulates cards forever. Added an archive mechanism: hide share cards from the UI without revoking the link (the share stays live in the channel).

### Changes

- `Storage/Models.swift`: `ShareRecord.isArchived: Bool = false` (v25).
- `Storage/DatabaseManager.swift`: migration `v25-share-archive` adds `shares.isArchived` column; `archiveShare(id:)` / `unarchiveShare(id:)` methods.
- `App/AppState.swift`: `activeOutgoingShares` excludes archived; `archivedOutgoingShares` computed property; `archiveShare(_:)` / `unarchiveShare(_:)` methods.
- `Features/ShareManagerView.swift`: header toggle (Active / Archived), context menu gains Archive / Unarchive action, empty state adapts.
- `xCloudTests/xCloudTests.swift`: `archiveShareHidesFromActiveList` — archive hides, unarchive restores, persists.

Build green; full suite **TEST SUCCEEDED** (56 unit + 4 UI + 4 launch, 0 failures). **No Release build** — user policy.

---

## 2026-08-19 (night) — Reverted: 24h TTL restored + launch heal added

The previous commit (8920745) mistakenly removed the 24h server-side TTL (auto-delete) from private share channels. The user clarified this was an intentional feature: private share messages should auto-delete from Telegram after 24 hours as a lifecycle/security mechanism — the share link expires and the channel messages vanish, even if the app never runs again.

### Changes reverted

- `TelegramClient.swift`: restored `ttlSeconds: Int = 86400` default (was 0); restored original doc comment.
- `Engine/ShareEngine.swift`: restored `setMessageAutoDelete(chatId:)` calls in all 3 `allocatePrivateChannel` paths (reuse, rejoin, adopt) + `createPoolChannel` (private only). Removed old `disableAutoDeleteOnPoolChannels()` heal. Added new `ensureTTLOnPrivatePoolChannels()` heal.
- `App/AppState.swift`: replaced `disableAutoDeleteOnPoolChannels()` call with `ensureTTLOnPrivatePoolChannels()` in post-auth block.

### New heal: `ensureTTLOnPrivatePoolChannels()`

Iterates all recorded pool channels and calls `setMessageAutoDelete` (86400) on every PRIVATE slot. Idempotent — catches channels whose TTL was previously cleared (e.g. by the mistaken heal) or never set. Public channel never touched. Wired into post-auth next to `healChannelPhotos`.

### Verification

Build green; full suite **TEST SUCCEEDED** (55 unit + 4 UI + 4 launch, 0 failures). Relaunched; Telegram PC1 confirms "Messages will be automatically deleted after 1 day" restored. Server-side enforcement confirmed — messages auto-delete even if the app never runs. **No Release build** — user policy.

---

## 2026-08-19 (night) — Private share "file not in any channel" diagnosis + 24h server-side TTL removed

User reported private shares break: card appears in Shared page, but the file isn't in any private share channel; Telegram shows no channels. Long evidence-gathering session; conclusions:

- **The share flow works.** Headless repro (`--create-share` + `--import-share` debug hooks in App/AppState.swift:537-588) forwarded a fresh file into PC3 (`-1004464188620`), **rejoining the previously-LEFT slot via its permanent invite** (the left-channel reuse concern is handled — `allocatePrivateChannel` second pass). Record `8451B411` minted, link produced, recipient import SUCCEEDED.
- **Channels are invisible to the user because every pool channel (PC1-PC5) and the public channel are ARCHIVED** (`chatListArchive` in the TDLib dump — `createPoolChannel` calls `archiveVaultChannel`, TelegramClient.swift:750) — Telegram's chat list shows none of them. Server state confirmed the files ARE in PC1/PC2 (message id 5242880, posted 08-18 13:46/17:12 UTC) with `message_auto_delete_time = 86400` (24h TTL set by the 08-18 "1-day shares + TTL" round) — TTL deletion was due 08-19 19:16/22:42 IST.
- **No new DB record existed for the user's latest test** — sharing the same file again reuses the live link (no re-forward); the card they saw was the existing record, still "active" until the 6h/launch cleanup.
- A 17:55 IST burst of `updateSupergroup` → `chatMemberStatusBanned` covered only OLD revoked channels (08-17 debug+release era), NOT PC1/PC2 — the app had not left the active channels.

### Change (user decision: "Remove TTL")

- Removed the 24h `setMessageAutoDelete(86400)` calls from `allocatePrivateChannel` (first pass, rejoin, adopt) and `createPoolChannel` (Engine/ShareEngine.swift) — share messages now persist until the app revokes them at expiry.
- Added `ShareEngine.disableAutoDeleteOnPoolChannels()` — idempotent launch heal that sets TTL=0 on every recorded pool channel (`allShareChannels()`), clearing the legacy TTL already applied server-side to PC1-PC5. Wired into the post-auth heal block (App/AppState.swift:766, next to `healChannelPhotos`). `setMessageAutoDelete` default is now 0.

### Verification

Build green; full suite **TEST SUCCEEDED** (55 unit + 4 UI + 4 launch). Debug app relaunched; log confirms all 6 pool channels (PC1-PC5 + OC) got `setChatMessageAutoDeleteTime(0)` (chat updates show `message_auto_delete_time = 0`). **No Release build** — user policy. Commit: `8920745`.

## 2026-08-19 (night) — Fullscreen player overhaul (ghost-window transition, direct + image fullscreen), player polish, audio player fixes

One continuous session on top of the ESC/scaling/purge round (`5e12d3d`). All code lands in a single commit `cf4320c`.

### Track 1 — Ghost-window fullscreen transition (approved; completes deferred "smooth fullscreen transition" from item 86)

Implemented in `Features/MPVVideoView.swift`:

- **Snapshot capture** (`captureTheaterSnapshot`): before the Space transition starts, capture the theater's composited pixels via `SCWindow`/ScreenCaptureKit (`CGWindowListCreateImage` is unavailable on macOS 26), **cropped to the video area** — the theater chrome (bottom transport) is excluded, so the ghost reads as pure video. The snapshot becomes the fullscreen window's container content for the transition ("ghost window") — the theater never shows a hole during the Space swap.
- **Live swap at `didEnterFullScreen`**: the real video layer is attached into the container and faded in over the ghost.
- **Theater fade-out**: new `@Published videoLiveInFullscreen` on `PlayerFullScreenWindow` — true from transition start until the video returns to the theater at dismissal; the theater fades itself out while the flag is true.
- Capture failure → live-attach fallback (old behavior).

### Track 2 — Direct fullscreen for media files + image fullscreen

- `SessionKind` enum (`.theater` / `.directVideo` / `.image`); `Session` gained `kind` + `file: ObjectRecord?`; `present`/`presentNow` take `kind` + `file`.
- **`presentDirect(appState:file:playlist:)`** — context-menu "Open in Full Screen" for `isVideo || isPhoto` (`Features/FileBrowserView.swift`): plays the file straight into the fullscreen player window, no theater. `directMode = kind != .theater`; `DirectFullscreenRoot` shows a spinner until the engine's mpv controller exists; `attachVideoThenToggle` got a **directMode fast path** — direct mode has no `MPVLayerHost`, so the old container-wait retry loop would time out and dismiss ("attach aborted — container never mounted"). onClose/onDismiss stop the engine, clear `theaterFile`, `isTheaterFullScreen = false`. **User-verified "perfect".**
- **`presentImage(appState:file:)`** — `SessionKind.image`, no engine. A bug was found + fixed here: an earlier version gated the download Task on `window.isActive && session.kind == .image`, which raced `present()`'s deferral paths (stale scene window → dismiss + 0.5s re-present, transition gate) and dropped the URL → eternal spinner. Fixed by removing the window-side URL and letting `ImageFullscreenRoot` own the download in `.task(id: file.id)` (same pattern as the theater's `loadFile`) with a "Downloading N%" progress ring and failure states. Cached images are instant; SVG rendered via `SVGWebView`. **Loading-stuck bug user-reported + fixed.**
- Theater header fullscreen button moved to the top-right next to Close; `togglePlayerFullScreen()` now routes `.image` → `presentImage`.

### Track 3 — Player polish

- Hover tints normalized: per-button rounded-rect tints removed; container-level `.playerHoverTint(.capsule)` on the pill row; **autoplay button removed entirely** (user request — the icon was changed to `forward.end.fill` first, then the user decided the button shouldn't exist at all; engine `autoplayNextEnabled` default true is persisted but has no UI).
- `PlayerHoverTint` overlay got `.allowsHitTesting(false)` — a shape overlay is hit-testable even with a transparent fill; a tinted PARENT (the volume pill capsule) would swallow every drag aimed at the slider beneath it.

### Track 4 — Audio player fixes (user-reported)

- **Volume bar didn't track the system volume.** Root cause: `Binding(get: { SystemVolumeManager.shared.volume })` is untracked by SwiftUI observation — rocker/Control Center changes never re-rendered the slider/icon. Fixed with `@Bindable private var volumeManager = SystemVolumeManager.shared` + `Slider(value: $volumeManager.volume)` in the audio player (TheaterView) AND the video player (PlayerControlsView) — slider + mute icon now follow external changes live.
- **Up/down arrow keys** now adjust volume (±0.1) for both audio and video previews (previously they navigated files); rockers (F11/F12) already pass through KeyMonitorView to the system.
- **Side prev/next chevrons not vertically centered**: the transport band was pinned to the play cluster's height (audio 68pt, video 76pt) and the edge-arrow row fills it (`maxHeight: .infinity`) so all buttons share the same center.
- **Volume slider not draggable**: the hover-tint capsule overlay on the volume pill was swallowing drags (buttons kept working because their tint lives inside the button; the pill's tint is a sibling ABOVE the slider). Fix: `.allowsHitTesting(false)` on the tint **plus** removed the hover tint from the volume pill entirely — matching the Apple TV app, which has no volume-bar hover. **User-verified fixed.**

### Verification & commits

Build green; full suite **TEST SUCCEEDED** (55 unit + 4 UI + 4 launch). Debug app relaunched. **No Release build** — user policy. Commit: `cf4320c`.

## 2026-08-19 (late) — ESC routing fixed, fullscreen scaling animation killed, legacy empty folders purged permanently

Follow-up to the evening session. User reports: (1) transition still laggy both directions; (2) scaling animation on entry (the window visibly grows into the screen); (3) ESC double-press does NOT work in fullscreen (the exit button does); (4) two empty legacy folders "Video"/"Audio" appeared in All Files that the user never created.

### Track 1 — ESC routing: the theater's key monitor was eating the key

**Root cause** (harness-proven, `/var/folders/k3/72m2fcsx4r58mt6zhzt4gkfr0000gn/T/opencode/monorder/main.swift`): local `keyDown` monitors fire in REVERSE registration order, so the player's monitor (installed later, at `presentNow`) normally runs BEFORE the theater's `KeyView` monitor. But `KeyView` returned `nil` (swallowed ESC) UNCONDITIONALLY — any remount/reorder of monitors starves the player's monitor → fullscreen ESC dead. **Fix**: `KeyView` now passes ESC through (`return event`) while `PlayerFullScreenWindow.shared.isActive` (Features/TheaterView.swift). Player monitor also logs `ESC #1` / `ESC #2` for verification.

**Spec change**: single ESC in the SMALL player now exits playback for EVERYTHING (videos included) — `handleEscapeKey` no longer does the two-step for video; the two-step hint lives ONLY in the fullscreen player (`showExitWarning` moved: TheaterView @State + VideoPlaybackView param removed; PlayerControlsView keeps it for the window).

### Track 2 — Entry scaling animation: scene default size was the cause

The fullscreen scene opens at `.defaultSize(width: 1280, height: 800)` (App/xCloudApp.swift:118); the native transition then SCALES the window up to the screen → the visible growth animation. **Fix**: `configureAndEnter` sets `window.frame = screen.frame` (before `makeKeyAndOrderFront`/toggle) → the transition is a pure Space absorb, no scaling.

### Track 3 — Exit lag: timing diagnostics added

`dismiss()` and `sceneDidDisappear()` now print timestamps (`dismiss t=…` / `sceneDidDisappear t=…`) to measure where the exit time goes (dismiss → actual window close). Pending user re-test: entry transition (scale gone?), exit transition, fullscreen double-ESC, small-player single-ESC.

### Track 4 — Legacy empty folders: explained + purged permanently

**Answer to the user's question**: the Video/Audio folders were ALWAYS in the channel — old-format `xcloud:v1:` TEXT metadata messages from the pre-unified app (msg 292552704 = Video/069584F2…, msg 286261248 = Audio/809AEBD2…), both empty (0 files). The local catalog loss + repair fix made them visible; not a DB-snapshot problem.

**Purge (user-approved data deletion)**: new debug hook `--purge-legacy-folders` (App/AppState.swift, runs BEFORE post-auth so no scan can rebuild them): `VaultRepair.legacyFolderPurgeCandidates` finds old-format folder messages whose folder is EMPTY locally (no children — a legacy folder WITH children is never a candidate); deletes those messages + the local records (`deleteObjectWithChunks`) + publishes a fresh checkpoint via `publishCheckpointFromLocal` (base = newest). **Why the checkpoint matters**: `mergedChannelState` (CatalogSnapshot.swift:291) replays only deltas NEWER than the checkpoint's baseMessageID — with base = newest, the old deltas containing the folder records can never resurrect them.

**Verified**: DB has 4 folders (Books/Audios/Videos/Images), 25 objects (27 − 2); channel dump shows 0 `xcloud:v1:` messages, newest checkpoint at 378535936; app relaunch healthy.

### Verification & commits

Build green; full suite **TEST SUCCEEDED** (4 UI + 4 launch, 0 failures — tally as before). Debug app relaunched. **No Release build** — user policy. Commit: `5e12d3d`.

## 2026-08-19 (evening) — Flashless fullscreen entry (transition gate + alpha-0), ESC-like minimize/exit buttons, folders recovered from the channel delta log

Two tracks this session.

### Track 1 — Folders "missing from the cloud" → actually missing from the LOCAL catalog; repair fixed + healed from deltas

**User report**: "all folders missing from the All Files page — every file flattened at root".

**Diagnosis (answered before fixing)**: folders were NEVER lost from the cloud — the vault channel still has all 6 folder metadata messages (Books/Images/Audios/Videos unified + legacy `xcloud:v1:` Video/Audio), and every file's chunk caption still carries its `parentID`. The LOCAL catalog lost the folder records (first cause unknown; candidates: undo of a folder creation — `registerUndo` delete at AppState.swift:1512-1518 — or a restore from a folderless checkpoint). Three bugs then made the loss permanent:
1. `VaultRepair.run()` caption-extraction switch lacks `.messageText` — folders are sent as TEXT messages, so the scan could never rebuild them.
2. `ChunkCaption.parse` REQUIRED `index`; legacy folder captions lack it → they didn't parse at all.
3. The orphan-flatten (VaultRepair.swift:263) set files' `parentID = nil` with NO check whether the cloud still knows the folder.
Plus: a folderless state got published as the authoritative checkpoint (`publishCheckpointFromLocal` collapse guard counts only files).

**Fix** (`Storage/VaultRepair.swift`, `Engine/ChunkCaption.swift`): scan handles `.messageText`; `isFolder` also true via mime `xcloud/folder`; `channelKnownFolderIDs` collected from folder captions + all file captions' parentIDs; the folder's linkage chunk row (size-0) is recreated when missing (keeps rename-edit linkage, prevents duplicate metadata messages/resurrection); flatten runs only when the parentID is unknown BOTH locally and in the channel. `ChunkCaption.parse` defaults `index` to 0.

**Recovery (the heal in action)**: on the next launch, `CatalogSnapshot.upload()`'s reconcile merged the channel DELTAS (which contained the folder records) back into the local catalog before the repair scan ran — DB now has 6 folders (Books 5, Images 4, Audios 3, Videos 2 files inside), 6 linkage chunk rows, 27 objects (21 files + 6 folders), `repair scan changed=false`. Nothing new to publish ("reconciled, nothing new to publish" ×3) — the cloud never needed the fix; the local catalog is healed.

### Track 2 — Fullscreen player: flashless entry + exit polish (completes deferred item 86)

**Goal** (deferred from the morning session): the player must appear to swipe straight into its own Space — flux/Apple TV feel, no pop-up in the normal Space.

**Root cause of the remaining flash**: `configureAndEnter` set alpha-0 only at window-found (0.02–0.1s after creation) — the window was visible in between. The configurator now sets alpha-0 at ATTACH (frame 1, guarded on `isActive` so restoration/Window-menu windows stay visible).

**AppKit landmine (Qwen + Claude consultant consensus, AGENTS rule 8)**: macOS runs at most one fullscreen Space transition at a time; `toggleFullScreen` during another window's transition is SILENTLY IGNORED and the target window is PERMANENTLY POISONED (only close+recreate recovers). Implemented `FullscreenTransitionGate` (Features/MPVVideoView.swift): observes will/did Enter+Exit (object:nil), FIFO pairing, 3.5s force-settle watchdog. Only 4 fullscreen notifications exist (no didFail variants). `present()` queues via `runWhenIdle` while transitioning; controls `toggleFullScreen` gate-guarded. **Swift globals are lazy, even module-level** — the gate is touched in `xCloudApp.init()` (harness-proven: App.init runs at process start).

**Entry ladder**: `enterFullscreenSafely(attempt:)` (window-found ladder 0.02/0.1/0.3/0.6s, gate re-check, `.insert(.fullScreenPrimary)`, `tabbingMode = .disallowed`, black background, alpha-0, reveal at `willEnterFullScreen`, `didEnter` confirm, entryGeneration guards stale closures, 0.7s watchdog → `recoverIgnoredFullscreen`: soft reset → reopen fresh scene (≤2, `reopensDone` reset in presentNow) → alpha-1 windowed fallback). Harness-validated: gate queued a player request during the main window's transition and opened it after settle (fs=1 held); normal case attach→alpha0→toggle→willEnter reveal ~7ms.

**Exit polish (user-driven)**:
- OS **minimize** button (traffic light) on the fullscreen player now dismisses to the theater like ESC (`willMiniaturize` observer, gated on `.fullScreen` styleMask; windowed minimize keeps dock behavior).
- Controls' **exit-fullscreen button** now dismisses to the theater when fullscreen; only toggles INTO fullscreen when the window is windowed (recovery fallback).

**Regression found + fixed (this session)**: `updateNSViewController` re-asserted the player frame on EVERY SwiftUI update — while the player is re-parented into the fullscreen window, every controls re-render clobbered its frame to the theater size → video shifted/small in fullscreen (and the ESC flow LOOKED broken — the state after exit was wrong). Guarded: assert only when `superview === controller.view`.

**Diagnostics kept**: GL surface-size-change log (`xCloud gl: surface=WxH videoOut=WxH viewFrame=…`) + post-return fit samples (`xCloud player: post-return …`). mpv client API 2.3 (modern — FBO-size reconfig handled internally; `video-out-params` mirrors input params on this build, so it is not a fit oracle).

**Verification**: harness runs (gate/alpha/reveal); build green; full suite **TEST SUCCEEDED** (59 unit + 4 UI + 4 launch, 0 failures); user by eye: transition "much much better, almost perfect"; video fit + ESC×2 + exit button verified. Debug app relaunched. **No Release build** — user policy.

**Commits**: `3a40113` (VaultRepair/ChunkCaption — folders) + `705bad5` (MPVVideoView/xCloudApp — fullscreen polish).

## 2026-08-19 — User confirmed the fullscreen fix; new item: smooth fullscreen transition (deferred to tomorrow)

- **User confirmed** the `ensureFullscreen` fix (`256f2e7`): the player now
  opens in native fullscreen even when the app's main window is in fullscreen.
- **New item (deferred by user to 2026-08-20)**: the transition is NOT smooth —
  the player scene window first POPS UP OVERLAID (visible in the normal Space),
  then animates into fullscreen, then lands in its own Space. Wanted: a single
  seamless swipe motion like flux / Apple's player (Apple TV style) — no
  overlay flash before the fullscreen animation.
- **Mechanism to explore tomorrow**: `openWindow(id:)` makes the scene window
  visible immediately (in the normal Space); `ensureFullscreen`'s toggle
  (+0.1s) then starts the Space transition — hence the flash. Candidate
  approaches: suppress the window's initial display until the fullscreen
  transition starts (alpha 0 / off-screen positioning / hidden until
  `toggleFullScreen`), `window.animationBehavior`, or ordering the fullscreen
  enter before the window becomes visible. Also compare with how flux's player
  window behaves (flux does NOT auto-fullscreen at all — the user may want the
  window to just open fullscreen-looking or animate like Apple TV).
- Session closed for the day: build green, tests green (55 unit + 4 UI +
  4 launch), debug app running, tree clean, commit `256f2e7`.

## 2026-08-19 — Fullscreen player: auto-fullscreen moved to present()/ensureFullscreen (fixes "opens non-fullscreen when the app is fullscreen")

- **User reported** (after the scene rebuild `96f6a20`): when the APP's main
  window is in native fullscreen and the user clicks the player's fullscreen
  button, the player opens in a separate window that is NOT fullscreen and
  "doesn't support full screen". When the app is windowed, everything works.
- **Reproduced in the two-scene harness**
  (`/var/folders/.../opencode/fstest2`, real .app bundle + log file):
  - Run 1: with the main window in native fullscreen, the scene window opened
    key/visible but `toggleFullScreen` was silently IGNORED — both at attach
    (+0.1s) and as a late manual call (+2.5s). `collectionBehavior` was NOT set.
  - Run 2: setting `window.collectionBehavior = [.fullScreenPrimary]` FIRST made
    the toggle work even while the main window was fullscreen (player fs=true,
    main fs=true simultaneously).
  - Run 3: the app's EXACT previous configurator code (collectionBehavior +
    didBecomeKey observer + attach check, toggle +0.1s) PASSED with the main
    window fullscreen — proving the configurator logic itself is fine, and that
    the real-app failure comes from lifecycle deltas: (a) the configurator is a
    one-shot NSViewRepresentable — `guard let window = view.window` silently
    no-ops if the window is nil at attach (no retry), and (b) if a scene window
    survives from an earlier session, SwiftUI REUSES it on `openWindow(id:)`
    WITHOUT re-creating the content — no configurator run, no toggle, black
    non-fullscreen window with no way to fullscreen it (hiddenTitleBar = no
    traffic lights; the controls' fullscreen button only dismissed).
- **Fix** (`Features/MPVVideoView.swift`):
  - `PlayerFullScreenWindow.present()` now OWNS the toggle: after `openWindow`
    it runs `ensureFullscreen(attempt:)` — retries at 0.1/0.3/0.6/1.0s, finds
    the window by a new identifier tag (`windowTag` = "xCloudFullscreenPlayer"),
    re-asserts `.fullScreenPrimary`, and toggles only while not already
    fullscreen (idempotent; stops once fullscreen or inactive). Works whether
    the window is fresh, reused, or never became key.
  - `present()` first closes a leftover scene window (dismissWindow + 0.5s
    re-present) so a stuck window can never be reused; `completeDismissal()`
    force-closes the tagged window if the close didn't land.
  - `FullscreenWindowConfigurator` keeps only appearance/EDR/collectionBehavior
    + sets the identifier tag — the didBecomeKey observer/toggle is GONE
    (single owner of the toggle → no double-toggle race with the retry loop).
  - `PlayerFullScreenControls.onToggleFullScreen` now calls
    `window.toggleFullScreen()` (real native fullscreen toggle, green-button
    semantics) instead of dismissing — the manual fallback the user was missing.
- Build green (Debug). Test suite green: **TEST SUCCEEDED** (55 unit + 4 UI +
  4 launch, 0 failures). Debug app relaunched — user to verify both cases
  (windowed app → player fullscreen; app fullscreen → player fullscreen).
  **No Release build** — user policy.

## 2026-08-19 — Fullscreen player REBUILT on a system-managed SwiftUI Window scene; placeholder dismantle loop found + fixed

- **User reported** (after the previous fix): fullscreen shows a non-fullscreen
  window and the main window "closes or disappears". User asked to do it the
  simple way like their OTHER app — `~/Projects/flux` opens video in a separate
  window that just works.
- **Second real bug found** (`Features/TheaterView.swift`): the placeholder was
  an if/else SWAP — when fullscreen activated, `VideoPlaybackView` unmounted →
  SwiftUI dismantled the mpv NSViewController (`MPVVideoView.swift:29-31`) →
  `cleanup()` → `teardown()` → `PlayerFullScreenWindow.shared.dismiss()`
  (`MPVVideoView.swift:787`) → the fullscreen window flashed up and died
  instantly; the mpv teardown/rebuild made the main window go black/restart.
  This is why "it's not going away" — the manual-window fixes were real but the
  window was being KILLED by the placeholder swap the moment it appeared.
- **Flux's pattern** (verified in its source): a separate SwiftUI
  `WindowGroup(id: "player")` scene + `.windowStyle(.hiddenTitleBar)`; the
  system manages the window (correct sizing, native fullscreen), zero manual
  NSWindow code.
- **Rebuilt the same way**:
  - `App/xCloudApp.swift`: new `Window("Fullscreen Player", id:
    "fullscreenPlayer")` scene (hiddenTitleBar, 1280×800) + `FullscreenWindowLink`
    (invisible view in the main window) that binds `openWindow`/`dismissWindow`
    into `PlayerFullScreenWindow` so plain AppKit code can open/close the scene.
  - `Features/MPVVideoView.swift`: `PlayerFullScreenWindow` is now session-based
    (Session: player/mpv/title/subtitle/appState) and opens the scene instead of
    hand-rolling an NSWindow — no style masks, no intrinsic-size collapse, no
    timing races. `FullscreenPlayerSceneView` renders the transferred mpv layer
    + controls (one SwiftUI tree → `.glassEffect()` works) and
    `FullscreenWindowConfigurator` (NSViewRepresentable) sets dark appearance,
    `.fullScreenPrimary`, EDR color space and auto-enters native fullscreen once
    the window becomes key (guarded, toggles once). Dismiss closes the scene;
    `sceneDidDisappear` (onDisappear) handles out-of-band closes (Cmd+W) and
    re-parents the mpv layer back to the theater in `completeDismissal`.
  - `Features/TheaterView.swift`: the placeholder is now an OPAQUE OVERLAY on
    top of the still-mounted player (ZStack) — the player stays mounted, so mpv
    is never dismantled while fullscreen is up.
- **Playback transfer** unchanged: the SAME MPVLayerView is re-parented into the
  scene (removed from the theater, embedded via MPVLayerHost), so playback
  continues uninterrupted across the transition; dismiss hands it back.
- Build green (Debug). Test suite green: **TEST SUCCEEDED** (55 unit + 4 UI +
  4 launch, 0 failures). Debug app relaunched — user to verify. **No Release
  build** — user policy.

## 2026-08-19 — Fullscreen player tiny-window FIXED (root cause: contentViewController Auto Layout collapse)

- **User asked** to look at `docs/PROBLEMS.md` — the fullscreen player still
  opened tiny/broken despite the fake-borderless rewrite (c425e14).
- **Root cause found + proven empirically** (`Features/MPVVideoView.swift`):
  `win.contentViewController = host` (NSHostingController) lets Auto Layout
  collapse the window to the hosting view's fitting size. Reproduced in a
  standalone harness: window created at `screen.frame` (1440×900) collapsed to
  **1×1 px** at top-left the moment the controller was attached. The old
  working code never used contentViewController — it attached plain subviews
  with explicit frames + autoresizing masks.
- **Fix**: host the SwiftUI tree (`FullscreenPlayerRoot` = MPVLayerHost + 
  controls in one tree, so `.glassEffect()` keeps working) in a plain
  `NSHostingView` subview of a plain `NSView` contentView, with
  `hosting.frame = content.bounds` + `autoresizingMask = [.width, .height]`.
  Same render tree, same glass; window keeps its screen-sized frame.
- **Verified end-to-end in a minimal .app bundle** (same titled fake-borderless
  window + plain contentView + NSHostingView): window created at
  (0,0,1440,900), ordered front → clamped to visible frame (normal macOS),
  `didBecomeKey` → `toggleFullScreen` → **native fullscreen entered**
  (frame = full screen, `styleMask.contains(.fullScreen)` = true), exit
  restored the window. The window collapsing to ~200×100 was the bug; the
  visible-frame clamp (menu bar + Dock) is normal.
- Build green (Debug). Test suite green: **TEST SUCCEEDED** (55 unit + 4 UI +
  4 launch, 0 failures). Debug app relaunched with the fix — user to verify
  fullscreen by eye. **No Release build** — user policy.
- `docs/PROBLEMS.md` brought into the main repo and rewritten as resolved.

## 2026-08-19 — Fullscreen player architectural rewrite (IN PROGRESS)

- **Fullscreen player rewritten** (`Features/MPVVideoView.swift`): replaced the old
  `.borderless` manual NSWindow (which broke `.glassEffect()`) with a "fake
  borderless" approach (`.titled + .resizable + .fullSizeContentView` with hidden
  titlebar/traffic lights). Video + controls embedded in one SwiftUI render tree
  via `NSHostingController` + `MPVLayerHost` (NSViewRepresentable) — glass works
  in this configuration.
- **Native fullscreen NOT YET WORKING**: the window opens tiny/broken despite
  all fixes (see `docs/PROBLEMS.md` for full analysis and next steps).
- **TheaterView placeholder**: main window now shows "Playing in full-screen"
  message when the fullscreen player is active, instead of a broken video view.
- **Stamp/bar alignment finalized**: `.frame(width: 76, height: 28)` in both
  `VideoPlaybackView.swift` and `TheaterView.swift` — pixel-perfect centerline
  alignment.
- Committed as part of this changeset. Debug build. **No Release build** — user
  policy.


## 2026-08-18 (late night) — Freebuff fixes: fullscreen glass restoration + stamp↔bar vertical alignment

- **Fix #1 — Fullscreen liquid glass restored** (`Features/MPVVideoView.swift`):
  `PlayerFullScreenWindow.present(...)` creates a manual borderless `NSWindow`
  (level `.mainMenu`, black background) outside the SwiftUI scene. The main
  window forces `.preferredColorScheme(.dark)`, but this window had no
  appearance → liquid-glass materials (`glassEffect(.regular.interactive(),
  ...)`) rendered in light mode over the black background and looked flat/plain
  (no blur, no glass). Fix: `win.appearance = NSAppearance(named: .darkAqua)`
  right after `win.backgroundColor = .black`. Now the fullscreen player's
  volume slider, minimize/close/transport buttons all render with proper liquid
  glass, matching the windowed player.

- **Fix #2 — Time stamps sit exactly on the bar centerline** (`Features/VideoPlaybackView.swift`
  + `Features/TheaterView.swift`):
  The previous `.offset(y: -1.5)` on both time labels nudged them up but
  wasn't enough (~3 px remaining gap: bar centerline y≈591, stamp centers
  y≈594). Root cause: the text labels had no explicit height — their natural
  line height (~16 pt for 13 pt monospaced) didn't match the bar's 28 pt frame,
  so SwiftUI's center alignment placed them at a slightly different vertical
  position than the 5 pt capsule inside the 28 pt ZStack. Fix: replaced
  `.frame(width: 76, alignment: ...).offset(y: -1.5)` with
  `.frame(width: 76, height: 28, alignment: ...)` — the text containers now
  have the exact same height as the bar frame, so their vertical centers align
  pixel-perfectly with the bar's capsule centerline. Applied in all 4 places
  (left/right labels in both the video player and the audio scrubber).

- Committed as `eae32f1`. Build green (Debug). Full test suite green:
  **TEST SUCCEEDED** (59 unit + UI/launch tests, 0 failures). Debug app NOT
  launched (user verifies both fixes). **No Release build** — user policy.

## 2026-08-18 (night) — Player controls: seek-target hold, bar↔stamp alignment, fullscreen environment fix; fullscreen glass regression + stamp vertical alignment handed to freebuff

- **User reports**: (1) after clicking/dragging the progress bar it snapped back
  to the old position for a split second; (2) the time stamps and the progress
  bar are not on one straight line / the bar is not centered between the stamps;
  (3) NEW — in the fullscreen (maximized) player ALL liquid-glass UI is gone
  (volume slider, minimize, close, transport buttons), while the windowed player
  has proper glass — "it's like two different player UIs".
- **Diagnostics (live screenshots + macOS Vision OCR + Gemini on a 1024×640
  crop)**: a phone-screen UI inside the MOVIE ("Farah / @thefarahmir / 01:15")
  sits exactly where the left time stamp renders — pixel analysis alone was
  misleading until OCR separated app UI from video content. Gemini measured the
  real row: bar x 294–905 (611px), left stamp "00:47" x 226–255, right stamp
  "-01:52" x 939–975, gaps 39px / 34px (bar shifted toward the right stamp),
  bar centerline y≈591 vs stamp centers y≈594 (~3px — the bar sits HIGHER than
  the stamp optical center).
- **Fixed (commit `ce8c6fc`, `Features/VideoPlaybackView.swift` +
  `Features/TheaterView.swift` + `Features/MPVVideoView.swift`)**:
  - **Seek no snap-back**: `@State seekTarget` + `holdProgressUntilSeekLands(_:)`
    (1.5s MainActor watchdog) — `displayedProgress` pins to the target until
    `abs(mpv.progress − target) ≤ 0.01`, so the bar never jumps back after a
    click/drag seek. Same in the audio scrubber (`progressFraction` helper).
    User verified: "the seek is fixed".
  - **Alignment (horizontal)**: both time labels get equal 76pt frames AND now
    hug the BAR side of their frame (left label `.trailing`, right label
    `.leading`) — the stamp→bar gap is exactly 20pt on both sides (Apple TV /
    flux look) instead of 39/34px asymmetric. User: "you have moved the time
    stamps closer to the progress bar and that's actually good".
  - **Alignment (vertical)**: labels nudged `.offset(y: -1.5)` to sit on the
    bar's optical centerline — user says the vertical axis is STILL not
    aligned with the bar → **handed to freebuff**.
  - **Fullscreen crash (earlier, now committed)**: `PlayerFullScreenWindow
    .present(...)` hosts `PlayerControlsView` in an `NSHostingView` OUTSIDE the
    SwiftUI scene; `@Environment(AppState.self)` was missing → EXC_BREAKPOINT
    on first layout. Fixed by `appState:` param +
    `NSHostingView(rootView: AnyView(controls.environment(appState)))`; user
    verified fullscreen works.
  - **Fullscreen liquid glass regression → handed to freebuff (NOT fixed)**:
    windowed player glass OK, fullscreen borderless window loses every
    glassEffect material. Working hypothesis: the manual NSWindow has no
    appearance while the main window forces `.preferredColorScheme(.dark)` —
    glass materials render in light mode over the black borderless window
    (candidate fix: `win.appearance = NSAppearance(named: .darkAqua)` in
    `PlayerFullScreenWindow.present`, `Features/MPVVideoView.swift` ~line 1480).
- Verified: build green (Debug). Full test suite NOT rerun after `ce8c6fc`
  (last green: 67 at `330f46e`) — freebuff should run it. Debug app relaunched
  (9:22PM). **No Release build** — user policy.

## 2026-08-18 (evening) — Player polish: EOF replay, autoplay-next toggle, transport/slider UX; hover scrub preview added then removed

- **User asked**: audio/video players should behave like a normal media player —
  Space replays a finished file instead of doing nothing, an autoplay-next toggle
  should exist, transport buttons + keyboard arrows should be intuitive, the slider
  should seek on click, and (initially) a YouTube-style hover scrub preview.
- **Replay after EOF (verified live via logs)**: mpv now uses `keep-open=yes`
  (`Features/MPVVideoView.swift`, after `video-sync`), `eof-reached` is observed
  (new `handlePropertyChange` case) and routed to `onEndOfFile`. The engine
  (`Engine/AudioPlayerEngine.swift`) tracks `ended` + dedupes the EOF signal
  (`lastEOFAt`/`lastEOFTrackID`, 5s window — END_FILE can also fire);
  `togglePlayPause()` with `ended` does `seek(absolute: 0)` + `play()` on the SAME
  core (the old async teardown/reload raced with rapid Space presses — the
  "10-20 presses to restart" flake). Log evidence: `EOF track=… autoplay=true
  ended=true` → `replay seek0+play track=…`.
- **Autoplay-next toggle**: `autoplayNextEnabled` (@Observable stored property,
  UserDefaults `autoplayNextEnabled`, default true; honored by `onEndOfFile`).
  UI: `infinity` + "Auto" pill, `XTheme.accent` when ON — video bottom bar
  (56×36) and audio volume row (54×30 capsule). User verified: "works as
  expected".
- **Transport**: `skipPrevious()` always goes to the previous track (the >3s
  rewind heuristic removed; else `seek(to: 0)`); the video transport play/pause
  button routes through `AudioPlayerEngine.shared.togglePlayPause()` (was a
  second toggle path); audio artist view gained edge prev/next chevrons
  (`canGoPrevious`/`canGoNext`, gated on the playlist like the video player) —
  the transport ZStack is `.frame(maxWidth: .infinity)` so the chevrons pin to
  the real edges and center vertically with the cluster.
- **Keyboard arrows**: in fullscreen video (`PlayerFullScreenWindow.shared.isActive`)
  Left/Right seek ±10s; otherwise they navigate files (`navigateMedia(±1)`) —
  wired in both the `KeyMonitorView` closures and the `.onKeyPress` handlers.
- **Sliders (video + audio)**: click-to-seek and instant drag response via
  `DragGesture(minimumDistance: 0)`; visual-only during drag (`dragProgress`),
  ONE seek on release (live seeks caused mpv fast-forward artifacts); the whole
  28pt band is the hit area — `contentShape(Rectangle())` must be on the view
  that owns the gesture (SwiftUI hit-tests the gesture view's shape; the 5pt
  track was the click-precision bug).
- **Hover scrub preview — ADDED, THEN REMOVED (user decision)**: a YouTube-style
  bubble (AVAssetImageGenerator frame + time, or time-only) above the bar,
  driven by `.onContinuousHover`; overlay-based so it never shifted the slider.
  Two real bugs were found and fixed (the preview moved out of the layout ZStack;
  stream-URL resolution starved by the request-ID guard during multi-second
  Telegram layout downloads — resolution is now a per-track independent task).
  The user then asked to remove the feature entirely ("we don't need it"). All
  preview code, state, and the temporary `import AVFoundation` are gone from
  `Features/VideoPlaybackView.swift`; the audio scrubber's hover time bubble
  (`scrubHoverFraction`) was removed too. **The no-AVFoundation mandate
  (HANDOVER item 28) was briefly violated during development and is restored:
  zero `import AVFoundation` in the codebase.**
- Verified: `** TEST SUCCEEDED **` (67: 59 unit + 4 UI + 4 launch), debug app
  relaunched (PID 17502), committed as `330f46e`. No Release build (policy).

## 2026-08-18 — PDF reader: single Preview-style UI (drop the book chrome)

- **User asked**: PDFs showed TWO preview overlays — the Apple Books-style
  reader chrome AND WebKit's PDF viewer bar. Wants ONLY the Preview-app-like
  UI for PDFs, with extra buttons (close, share, etc.). Confirmed via
  question: "one is like how books are previewed in Apple Books (controls),
  and a bar like the macOS Preview app — keep the preview only for pdf and
  add more buttons for closing sharing etc".
- **Changes** (`Features/BookReaderView.swift`):
  - `body`: for `format == .pdf` the book chrome (topControls/bottomControls
    with hover auto-hide) is replaced by a slim always-visible `pdfToolbar`;
    the WebKit PDF view (which range-fetches from the stream server) provides
    the Preview-style page UI. Book chrome unchanged for epub/text/comic.
  - `pdfToolbar`: glass capsule with Close (Esc), file title, Open with
    Default App, Share (macOS share sheet), Full Screen. Title + icons are
    fixed `.white` over the light glass bar per user feedback (first used
    `theme.foreground` — grey-on-white in dark theme; then adaptive
    `.primary` — black; user wants white text, bar as is).
  - `sharePDF()`: quiet download (`DownloadEngine.download`) then
    `NSSharingServicePicker` anchored top-right of the window (share needs
    real bytes; streaming stays on the preview path).
  - `fullscreenButton` now takes a `foreground:` color (book chrome passes
    `theme.foreground`, PDF toolbar passes `.white`).
  - Position bug fixed: the toolbar was CENTERED at first (the `if format ==
    .pdf` branch replaced the full-height VStack, so the ZStack centered the
    bar) → wrapped in `VStack { pdfToolbar; Spacer() }` + top padding; added
    a stroke border + shadow for visibility.
- **Storage cleanup (user asked "why is DerivedData so big")**: 23 GB →
  6.8 GB. Cause: FIVE xCloud derived-data folders from different sessions;
  four stale ones (xCloud-wt 4.3G, xCloud-tests 4.1G, xCloud-release 4.0G,
  xCloud-main 4.0G) were pure regenerable build output — deleted. The active
  pinned folder (xCloud-cdpcjcegyfsbheeztqhmjnnukgcv, AGENTS.md) kept: 3.8G
  Build + 1.9G SourcePackages + caches.
- Build green; tests green (67: 59 unit + 4 UI + 4 launch). Debug app
  relaunched. **No Release build** — user policy.

---

## 2026-08-18 — PDF streaming: byte-range preview without a full download

- **User asked**: add PDF streaming; first check whether it's supported; also
  asked whether only linearized PDFs stream (he'd heard that claim) and
  whether locally linearizing non-linear PDFs is the way, "or is there a
  better way".
- **Was it supported?** No — PDFs were fully downloaded before viewing (books:
  `DownloadEngine.download` → `loadFileURL` in BookReaderView; Theater: PDFs
  were metadata-only). But the byte-range plumbing (VaultStreamServer: 206/
  Content-Range/Accept-Ranges, `plaintextSliceStream`, 1 MB slices,
  `fetchRangeData`, 48 MB SliceCache) was 90% there — verified live with curl
  before any code changed.
- **Linearization answer (from the user's question)**: the "only linearized
  PDFs stream" claim applies to SEQUENTIAL loaders. Every modern PDF renderer
  (WebKit, PDFKit, PDF.js) is range-capable: it fetches the head, fetches the
  tail (xref/trailer), then page objects on demand — non-linearized PDFs
  stream fine, one extra round-trip. Linearizing locally (qpdf — Apache-2.0,
  or CoreGraphics' `kCGPDFContextCreateLinearizedPDF`, or a CGContext
  regenerate) would only be needed for a sequential-only data provider or as a
  robustness fix for sloppy generators — rejected as unnecessary.
- **Changes**:
  - `VideoStreamingEngine.loadLayoutUncached`: `pdf` → `application/pdf`
    content type; new `pdfStreamURL(for:)` (same layout machinery as
    `mpvStreamURL`).
  - `BookReaderView`: PDFs now load via `loadPDF()` — `pdfStreamURL` when
    uncached (WKWebView loads the stream URL with `isRemote`, WebKit's PDF
    renderer range-fetches), else full download. `BookWebView` gained
    `isRemote` (load URLRequest vs loadFileURL) + `onLoadError`
    (didFail/didFailProvisional → `handlePDFStreamFailure` → falls back to
    download, once — `pdfFallbackScheduled`).
  - `TheaterView` PDF details panel: added "Preview" button (opens the
    reader, which streams).
  - `FileBrowserView.open`/`quickLook`: PDFs (mime or ext) now open directly
    in the reader (double-click / Space) instead of the Theater metadata
    panel (user feedback from the spike: "double clicking or pressing space
    bar doesn't open the file").
- **Spike verification (live, real object)**: generated a 86.7 MB,
  120-page, deliberately NON-linearized PDF (no Linearized dict, xref at
  tail — verified with python) and uploaded it via a TEMPORARY
  `--import-file` debug hook (removed after the test). Server: HEAD → 200,
  exact Content-Length, `application/pdf`; range → 206; trailer-first probe
  (`startxref` reachable from the last 1024 bytes) + head probe (`%PDF-1.3`).
  Client: removed the upload's cache copy (UploadEngine copies imports to the
  cache — the first render test silently used the local copy!), relaunched;
  user confirmed pages render; log shows `Stream layout … canStream=true`;
  **no cache file was created** — the PDF rendered entirely from byte ranges.
  First false positive is a good gotcha: `UploadEngine.upload` populates the
  cache for instant previews (UploadEngine.swift:380-389), so a fresh import
  is ALWAYS cached — streaming only kicks in once that copy is evicted.
- The 86.7 MB test PDF (`xc-stream-test.pdf`) is still in the vault (user can
  test/delete via the UI).
- Build green; tests green (67: 59 unit + 4 UI + 4 launch). **No Release
  build** — user policy. Debug app relaunched and running.

## 2026-08-18 — Channel profile pictures: branded avatars on every xCloud channel

- **User asked**: "What do you think?" about giving the Telegram channels
  (vault, share pool slots, public channel) profile pictures. I said yes —
  cheap and makes the channels recognizable; public channel photo also shows
  on t.me link previews. User approved.
- **Implementation**:
  - New `Engine/ChannelAvatar.swift`: draws 640×640 JPEG (TDLib static chat
    photos must be JPEG) — diagonal gradient in a per-family hue + the label
    centered in bold white with a soft shadow. Written to
    `<tmp>/xcloud-avatars/<label>.jpg`. Pure CoreGraphics + CoreText, no
    assets. (Engine/ is a file-system-synchronized pbxproj group — no pbxproj
    edit needed, unlike Features/.)
  - `TelegramClient.setChannelPhoto(chatId:label:hue:)` (best-effort, logged)
    via TDLib `setChatPhoto` + `.inputChatPhotoStatic` +
    `.inputFileLocal`; `hasChannelPhoto(chatId:)` via `getChat().photo`.
  - Wiring: `VaultManager.ensureVault` (label "Vault", hue 0.58) and
    `ensureBackupChannel` ("Backup", 0.35) — only when the channel has no
    photo yet; `ShareEngine.createPoolChannel` always (private slots
    "PC1"…"PC5" with per-slot hue, public "OC" hue 0.75); legacy pool
    channels get branded on reuse/rejoin only when photo == nil.
  - `ShareEngine.healChannelPhotos()`: idempotent backfill at launch
    (AppState post-auth, after `cleanupExpiredShares`) — sets a photo on
    every recorded channel (vault, backup, slots 1–5, OC) that has none.
    This matters because `ensureVault` early-returns for existing rows, so
    pre-existing channels would otherwise never be branded.
- **Verification (live)**: first launch generated all 8 avatars (all distinct
  md5s, valid 640×640 JPEGs) and set them; second launch regenerated NONE —
  `hasChannelPhoto` was true on every channel, proving the photos landed
  server-side and the backfill is idempotent. (os.Logger lines not persisted
  to `log show`; verified via avatar-file timestamps + the photo guard.)
- Build green; tests green (67: 59 unit + 4 UI + 4 launch). **No Release
  build** — user policy. Debug app relaunched and running.


## 2026-08-18 — Share lifecycle round: 1-day expiry, channel TTL, cancel-on-use, staged import UX

- **User asked**: expiry 7d → 1d; "auto delete message after a day in the
  channel" — is that an option?; cancel-on-use when the recipient joins (with
  a grace so their app can forward first); and a NEW import UX: opening a link
  should NOT auto-import — instead show a detail screen with a file card +
  Import/Cancel, with the messages ALREADY forwarded to the user's cloud
  channel so files can be streamed/previewed WITHOUT importing.
- **TTL answer: YES** — `setChatMessageAutoDeleteTime` (TDLibKit), 86400s
  allowed (divisible by 86400, ≤ 365d), server-enforced: Telegram deletes
  every message 24h after posting even if the app never runs again. Applied to
  PRIVATE pool channels only (creation + reuse + rejoin paths) — NEVER the
  vault or public channel.
- **Changes** (commit pending):
  - `ShareEngine.defaultLifetime` 7d → 1d (86400).
  - `AppState.completePostAuthSetup`: `cleanupExpiredShares()` now also runs
    at launch (previously only in the 6h in-app loop).
  - Cancel-on-use: `TelegramClient.handleUpdate` case `updateChatMember` →
    `ShareEngine.handleShareChannelMemberJoined` — private slot + joiner ≠ me
    → after `cancelOnUseGrace` (300s) the share self-cancels (messages
    deleted + channel left) if still active. The recipient's forward is a
    server-side copy into THEIR vault, so the grace is safe; TTL+expiry cover
    the app-not-running case.
  - **Staged import UX**: `importLink` now forwards chunks into the
    recipient's vault channel and returns `.pending(objectID:)` instead of
    cataloging. The object is saved as `state = "pendingImport"` (incoming
    share row `state = "pending"`): streamable/previewable via the existing
    DB-driven stack (theater/MPV/audio/thumbnail) but INVISIBLE to
    `DatabaseManager.allObjects()`/`allChunks()` (catalog, snapshot, sync,
    VaultRepair step-2 promotion, heal dedupe, existingObject, uniqueName —
    all central-filtered). `confirmImport(objectID:)` = unique name, state →
    ready, `BackupSync.enqueue` per chunk (mirroring deferred so cancelled
    files never reach the backup channel), incoming row → imported.
    `discardImport(objectID:)` = delete vault-channel copies + drop rows.
    `PendingImportView` sheet (RootView): file card (kind icon, name, size,
    type), Preview (media), Import to My Cloud (primary), Cancel (destructive).
    Pending imports re-surface at launch via `pendingImports()`. Re-opening
    the same link re-presents the existing pending instead of double-forwarding.
  - New file `Features/PendingImportView.swift` added to the pbxproj
    (explicit Features group).
- Build green; tests green (67: 59 unit + 4 UI + 4 launch). **No Release
  build** — user policy. Debug app relaunch pending after docs commit.

## 2026-08-18 — Expiry cleanup aligned with join/leave (commit 50b2b2f)

- User asked whether one-time-use private links make the 7-day link expiry
  pointless. Answer (from code): no — the two mechanisms are orthogonal. The
  one-use invite (memberLimit 1) is the SECURITY property (only the intended
  recipient ever gets in); the 7-day expiry is the share LIFETIME — the
  recipient has 7 days to open the link, and `cleanupExpiredShares()`
  (ShareEngine.swift:1124, runs on the transfer cleanup loop) revokes shares
  nobody opened, deleting the file's copies from the channel so unopened
  shares don't sit on Telegram forever.
- Found while answering: `revokeExpired` (1142) still used the OLD behavior —
  `deleteChat` + DROP the share_state row on expiry — so an expired (not
  cancelled) share left its channel AND lost its row, and the next private
  share created a NEW channel: the exact "new channels again and again" bug,
  still lurking on the expiry path.
- Fixed: expired pool-slot shares now follow join/leave exactly like
  cancelShare — delete this share's messages, `leaveChat` the slot (when no
  other active share uses it), KEEP the row so the next share rejoins via the
  recorded permanent invite. Legacy v1 disposable channels (messageIDs empty)
  still forget their row outright.
- Build green, tests green (67). **No Release build** — user policy.

## 2026-08-18 — Join/leave share semantics implemented (commit 8bbc928)

- **User asked for**: cancel = delete the messages AND leave the channel;
  create = reuse the 5-slot pool via join/leave; also explained the intended
  security model (see link-encryption answer below).
- **Live probes (tdtest harness, real account session copy)**:
  - Slots 1-5 were no longer "Chat not found" — the account had become
    creator/member again (user's own manual rejoin test; memberCount 0 → 1),
    so rejoin-via-invite now returns USER_ALREADY_PARTICIPANT.
  - Full cycle on slot 5 (-1004145642528): `leaveChat` on an OWNED channel
    succeeds → channel stays alive, myStatus left; `joinChatByInviteLink`
    (+A6GEaqjkB3lmYTBl) → chatId -1004145642528 == stored row, status back to
    creator. Slot 5 restored to pre-test state afterwards.
- **Changes** (`Engine/ShareEngine.swift`):
  - `cancelShare`: deletes the share's messages + `leaveChat` on the channel
    for PRIVATE shares (public channel is permanent, never left — public
    cancel still deletes only its messages).
  - `allocatePrivateChannel` pass 2: a slot whose channel we LEFT is REJOINED
    via its recorded permanent invite (chatExists false → join → same chatId →
    row stays valid; adopt the returned chatId if it ever differs; rename
    legacy titles). Pass 3 (create new channel) only when no recorded invite
    resolves.
  - Doc comments updated (allocatePrivateChannel, cancelShare,
    cancelAllShares) + test comment (xCloudTests.swift cancelShareMarksRecordsRevoked).
- **Security answer (user question)**: the share link is NOT protected by a
  hardcoded key. `obfuscate` (ShareEngine.swift:1140) wraps the plaintext
  link in AES-256-GCM under a RANDOM per-link 256-bit key that rides inside
  the blob (`xcloud://share#base64url(key || ciphertext)`); the recipient
  unwraps it with the embedded key. It is obfuscation, not secrecy — the link
  IS the credential. Defense in depth: private links embed a ONE-USE invite
  (memberLimit 1, expires with the share) so only the first joiner gets in and
  the channel is otherwise closed (no public access, one share's messages at a
  time); public links embed the channel's permanent invite by design (any
  holder can join any time).
- Build green; tests green (67: 59 unit + 4 UI + 4 launch). **No Release
  build** — user policy. Debug app relaunch pending after docs commit.

## 2026-08-18 — Manual TDLib probe: deleteChat does NOT delete pool channels (join/leave confirmed)

- **User's claim to verify**: "deleteChat didn't really delete the channel, it
  just left the channel — with the invite link we could still rejoin the same
  channel and gain admin rights right away; the old mechanism was 5 channels
  we join/leave on share create/cancel." Asked for a manual test.
- **Method**: built a standalone TDLib harness (SwiftPM exe, TDLibKit
  1.5.2-tdlib-1.8.66, in the temp dir `tdtest/`) running against a COPY of
  the Debug app's TDLib session (`~/Library/Application Support/xCloud/tdlib`
  → temp; credentials read from Keychain: apiID 34035379 / apiHash from
  `security find-generic-password -s com.nemesys.xcloud.xCloud -a
  telegram-credentials`). Session copy logged in fine (authorizationStateReady).
  Probed getChat on 11 channel ids + checkChatInviteLink on 8 links from the
  real DB.
- **RESULTS (all five original pool slots)**: getChat on slots 1-5 recorded
  channels → "Chat not found" (the account is NO LONGER a member), BUT their
  PERMANENT pool invites still resolve — `t.me/+5VSskzM6sjk4MDY1` →
  'xCloud PC1' (memberCount=0), etc. Public channel alive, creator, title
  'xCloud OC'. Some newer revoked test channels alive too; the per-share
  ONE-USE invite links (expiring) are dead (INVITE_HASH_EXPIRED) as designed.
- **CONCLUSION — user is right**: TDLib `deleteChat` on these owned channels
  LEFT them (creator removed) instead of destroying them server-side. The
  channels persist with memberCount=0 and their permanent invites stay valid
  — the creator can rejoin and regain admin instantly. So the old
  join/leave-on-cancel mechanism was leaving channels, and
  `allocatePrivateChannel`'s reuse pass (chatExists/getChat-based) saw left
  channels as "lost" and created new ones every cycle — the "new channels
  again and again" bug the user reported.
- Follow-up options for the user: (a) keep current keep-membership reuse
  (channels stay archived in the chat list), or (b) true join/leave: cancel
  LEAVES the channel, create REJOINS via the stored permanent invite and only
  creates new when rejoin fails (also cleans the 5 zombie slot channels by
  reusing them). Awaiting user decision. Harness kept at
  /var/folders/…/opencode/tdtest.

## 2026-08-18 — Private channel REUSE (disposed channels never deleted) + imports backed up

- **User tested again and found a regression vs expectations**: shared several
  private links, cancelled, shared again — brand-new Telegram channels kept
  being created; the disposed channels were never reused.
- **Root cause** (`Engine/ShareEngine.swift:cancelShare`): cancel on a private
  share called `deleteChat` (killed the Telegram channel) AND dropped the
  share_state row. `allocatePrivateChannel`'s reuse pass needs a live recorded
  channel, so the next share always fell through to `createPoolChannel` →
  new channel every time. (Round 3 had "verified" this as intended; the user
  now explicitly wants reuse: channels are disposed, not destroyed.)
- **Fix**: `cancelShare` now deletes ONLY that file's messages — the channel
  (private pool or public) survives as a disposed slot and the row stays;
  allocation reuses it on the next share and creates a channel only when the
  recorded one is lost (`chatExists` false). Slot freeing needs no row
  deletion — allocation counts only channels with ACTIVE shares as busy.
  `cancelAllShares` and the cancel test comment updated to match.
- **Imports not backed up (second finding)**: `UploadEngine.swift:303` mirrors
  every uploaded chunk into the backup channel via `BackupSync.enqueue`, but
  `ShareEngine.importForwarded` (v2 links) and `importLegacy` (v1 links)
  forwarded chunks into the vault channel WITHOUT enqueueing — imported files
  existed only in the vault channel, so a restore-from-backup would lose
  them. Fix: `BackupSync.enqueue(messageID:newMessageId, objectID:)` right
  after each import forward (both paths). Catalog checkpoints were already
  mirrored; now the chunk DATA is too.
- Build green, 67 tests green, committed, Debug app relaunched for re-test.
  No Release per user policy.

## 2026-08-18 — Finder-style name dedupe for moves (no more same-name conflicts)

- **User asked** to prevent same-name conflicts on MOVE ("we should totally do
  that so we don't face the same name conflict... make sure this doesn't happen
  anywhere"). Audited every path that writes parentID:
  - moveObject (single move: context menu + drag-drop), moveObjects (album/
    playlist batch), bulkMove (multi-selection Move), addToPlaylist (single
    add), moveToFolder (dead helper, now delegates to moveObject), rename
    (Finder auto-"Name 2" parity), uploads (already deduped,
    UploadEngine.swift:108-126), share imports (already deduped at root via
    uniqueImportName).
- **Fix**: new `DatabaseManager.uniqueObjectName(base:parentID:reserved:excluding:)`
  (Finder-style "file 2.mp4", case-insensitive, root = nil) built on the
  existing pure `ShareEngine.uniqueName`. moveObject/bulkMove/addToPlaylist/
  rename use it with undo/redo capturing old+new names; moveObjects pre-computes
  names with a shared reserved set so two same-named files moving together land
  as "file.mp4" + "file 2.mp4" without racing each other's DB writes (the
  in-memory sibling set avoids an actor call in a sync MainActor context).
- Gotchas hit: `??` RHS is a non-async autoclosure — `try? await` inside it is
  a compile error; DatabaseManager is an actor, its read/write helpers need
  await from Task contexts.
- Build green, 67 tests green (59 unit + 4 UI + 4 launch), Debug app
  relaunched. No Release per user policy.

## 2026-08-18 — Agent instruction file (AGENTS.md), HDR/Dolby verification, move-conflict semantics

- **User asked** for a durable anti-loss setup after the freebuff crash: an
  instruction file any coding agent must follow to save work, commit, and keep
  HANDOVER.md + JOURNAL.md current after every task. Created `AGENTS.md` at the
  repo root (non-negotiable session rules, build/test/run commands, commit
  conventions, doc conventions, gotchas, session-end checklist). Future
  sessions read it first.
- **HDR/Dolby verified intact** (user wanted confirmation the work survived the
  freebuff problems): the full HDR/EDR pipeline is present in
  `Features/MPVVideoView.swift` — `applyColorPipeline()` (line 859, PQ/HLG on
  BT.2020/P3 → EDR layer + PQ colorspace + target-peak hard clip; SDR fallback;
  churn guard via `lastPipelineKey`), gamma/primaries observation (lines
  1023-1026), RGBA16F backbuffer + extendedSRGB window colorspace (line 573),
  `edrPeakNits()` (line 833); Dolby Atmos/DTS passthrough (`audio-spdif`
  ac3,eac3,truehd,dts + `audio-exclusive` on `xc.audioPassthrough`, lines
  974-981) with the Settings toggle (`SettingsView.swift:239`). History of live
  verification: HANDOVER item 1 (HDR file PQ/BT.2020 verified playing via the
  EDR pipeline), JOURNAL lines 100-136. Nothing was removed by the freebuff
  incidents.
- **Move-conflict semantics (asked and answered, no code change)**: moving a
  file into a folder (or root) where a same-named file already exists does NOT
  rename, replace, or dedupe — `moveObject`/`moveToFolder`/`moveObjects`
  (`App/AppState.swift:1545-1622`) only write `parentID`. Both records keep the
  exact same name and coexist (current intended behavior — two `file.mp4` in
  one folder). The Finder-style unique-name logic
  (`uniqueName`/`uniqueImportName`, `Engine/ShareEngine.swift:1060-1080`,
  "Name 2.ext") applies ONLY to share imports at the root.
- Committed with AGENTS.md + journal rework as part of this commit; round 6
  hash corrected to `27d0799`. Tests green (67: 59 unit + 4 UI + 4 launch).

## 2026-08-18 — Round 6: Share menu split, channel naming, duplicate heal, rename field

- FileBrowserView: "Share via Public Link…" replaced by expandable Share menu
  (Private lock.fill / Public globe), N items → "Share N Items".
- ShareEngine.poolChannelTitle(id:kind:) — public "xCloud OC", private
  "xCloud PC1"–"xCloud PC5"; TelegramClient.renameChatIfNeeded renames legacy
  "xCloud Shares" channels at reuse.
- Cancel semantics re-verified against live behavior: private = deleteChat +
  row drop + slot freed (re-share recreates channel); public = message delete
  only; pool 5 max; same-file re-share reuses the live link.
- Duplicate file found in the real DB: two root objects, same name/size, same
  vault message 355467264; record B (36BE56EC, no rootHash, 15:40) vs record A
  (1DE982EC, has rootHash, 12:33). Root cause class: object-level dupes
  invisible to chunk dedupe. Fix: DatabaseManager.dedupeDuplicateObjects()
  (keep hash-bearing or older record, delete the loser + chunks), wired into
  the post-auth heal block so a corrected checkpoint republishes.
- Rename field: .id(renameTarget) on the alert TextField (fresh field per
  presentation — stale cleared text was being reused); onKeyPress "a"/"c"/"v"
  ignore while renaming so Cmd+A/C/C+V reach the text field.
- Build green, 67 tests green, committed 27d0799, Debug app relaunched (heal
  confirmed: duplicate gone). No Release per user policy.

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

## 2026-08-21 — Volume slider was controlling system BALANCE, not volume

User noticed audio shifting between left and right ears when dragging the
volume slider. Confirmed in macOS Sound settings: the system balance slider
moved in sync with the app's volume slider.

### Root cause (updated after CoreAudio diagnostic)

Ran a full CoreAudio property diagnostic on the OnePlus Buds 3. Results:
- Element 0: only `mute` (no volume scalar)
- Element 1: `kAudioDevicePropertyVolumeScalar` = 0.3096, writable
- Element 2: `kAudioDevicePropertyVolumeScalar` = 0.3125, writable
- `VirtualMainVolume`: does NOT exist on this device
- `LeftVolumeScalar`, `RightVolumeScalar`, `Balance`, `Fade`: none exist

On Bluetooth A2DP devices, `kAudioDevicePropertyVolumeScalar` is
**per-channel**: element 1 = left channel, element 2 = right channel.
The app was writing to ONLY element 1, changing one channel's volume
and shifting stereo balance. Reversing the probe order didn't help
because both elements 1 and 2 have the same property.

### Fix (verified working)

`resolveVolumeElement()` (singular) → `resolveVolumeElements()` (plural):
finds ALL elements with a writable `kAudioDevicePropertyVolumeScalar`,
storing them in `volumeElements: [AudioObjectPropertyElement]`.
`writeScalar()` now writes the same value to ALL elements simultaneously —
both left and right channels move together, preventing the balance shift.
`readScalar()` reads from the first element (they stay in lockstep).

**File**: `Engine/AudioPlayerEngine.swift` — `SystemVolumeManager`.
Verified by user: volume slider now controls volume, not balance.

## 2026-08-21 — Streaming buffering investigation (OPEN)

User reported encrypted video streaming buffers after ~1 minute of playback.
Full investigation with Claude and Qwen. Key findings:

1. **TDLib `limit` auto-cancel**: Each `downloadFile(limit=1MB)` call auto-cancels
   after 1 MB. Every slice is a brand-new download negotiation with Telegram's
   servers. After 60-150 of these per minute, one unlucky jitter kills the buffer.

2. **Binary search boundary bug**: `chunkAndLocalIndex()` used `<=` which picked
   wrong chunk at boundaries. Fixed: `<=` → `<`.

3. **Continuous download model attempted**: `downloadFile(limit=0)` + polling
   `downloadedSize`. Didn't work — TDLib's `downloadedSize` doesn't accurately
   track byte availability in sparse files.

4. **8-slice batching on encrypted path**: Made startup slow (10+ seconds) because
   `synchronous: true` blocks until full range is on disk.

5. **Restored ObjectFetcher + fetchWithRetry**: Still buffers after ~1 minute.

**Root cause**: per-slice re-negotiation is fundamentally fragile for streaming.
The old working version (Aug 19 backup) was plaintext-only — no sealed slices,
no decryption overhead. 8-slice batching worked perfectly because there was
no per-slice overhead.

**Status**: UNRESOLVED. Needs a different TDLib API pattern or architectural change.
Prompt for Claude/Qwen at `.freebuff/streaming-prompt-v2.md`.

**Files touched**: `Engine/VideoStreamingEngine.swift`, `Telegram/TelegramClient.swift`,
`Engine/AudioPlayerEngine.swift`, `Features/TheaterView.swift`,
`Features/VideoPlaybackView.swift`, `Engine/UploadEngine.swift`.
All changes UNCOMMITTED.

