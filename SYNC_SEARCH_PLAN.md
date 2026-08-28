# Fast Search-Based Catalog Sync & Transparent Thumbnail Plan

> **Instructions for Zed Code / Next Agent**:
> 1. Read `AGENTS.md` first before making any changes.
> 2. Document every finding, change, build result, and commit in **`JOURNAL.md`** (chronological top entry) AND **`HANDOVER.md`** (current state reference) in the same session.
> 3. Verify **both macOS and iOS builds** (`xcodebuild ... -scheme Cascade` and `xcodebuild ... -scheme "Cascade iOS" -sdk iphoneos`).
> 4. Keep git commits atomic per task. Never leave the working tree dirty.

---

## 1. Context & Motivation

### Problem 1: Slow Multi-Minute Pull-to-Refresh on iOS
- **Root Cause**: `CatalogSnapshot.fetchChannelState` currently calls `TelegramClient.shared.allChannelMessages(chatId:)`, which paginates backwards through the entire channel history with `getChatHistory` (2,000 max pages, 200ms delay per page).
- In a channel with hundreds or thousands of 20MB data chunk messages, downloading and iterating through the entire message history to find 1 or 2 small database snapshot/delta messages takes 30–60 seconds.

### Problem 2: Thumbnails with Rounded Corners / Alpha Show White Halos
- **Root Cause**: In `Engine/UploadEngine.swift:683`, all thumbnails are encoded as JPEG (`ThumbnailCrop.jpegData(from: ..., quality: 0.85)`).
- JPEG has no alpha (transparency) channel. Transparent PNGs (app icons, stickers, designs with rounded transparent corners) have their transparent pixels converted into opaque white backgrounds.

---

## 2. Proposed Architecture & Tasks

### Task A: Server-Side Telegram Search for Snapshots & Deltas

Instead of downloading thousands of data chunk messages to find the deltas, use Telegram's native server-side search API (`searchChatMessages`):

1. **Add `searchChannelMetadataMessages` in `Telegram/TelegramClient.swift`**:
   - Wrap TDLib's `client.searchChatMessages`:
   ```swift
   func searchChannelMetadataMessages(chatId: Int64, query: String = "cascade:db", limit: Int = 100) async throws -> [Message] {
       guard let client else { throw TelegramError.notInitialized }
       let result: FoundChatMessages = try await withFloodWait(function: "searchChatMessages") {
           try await withCheckedThrowingContinuation { continuation in
               do {
                   try client.searchChatMessages(
                       chatId: chatId,
                       filter: nil,
                       fromMessageId: 0,
                       limit: limit,
                       offset: 0,
                       query: query,
                       senderId: nil,
                       topicId: nil
                   ) { res in
                       switch res {
                       case .success(let found): continuation.resume(returning: found)
                       case .failure(let err): continuation.resume(throwing: err)
                       }
                   }
               } catch {
                   continuation.resume(throwing: error)
               }
           }
       }
       return result.messages ?? []
   }
   ```

2. **Update `Storage/CatalogSnapshot.swift` `fetchChannelState`**:
   - Replace `allChannelMessages(chatId: chatId, usingCache: true)` with `searchChannelMetadataMessages(chatId: chatId, query: "cascade:db", limit: 100)`.
   - The query directly returns only `cascade:dbsnapshot:v1:`, `cascade:dbdelta:v1:`, and `cascade:dbpart:v1:` messages from Telegram's server in a single fast network call (~100–200ms).
   - Stop paging as soon as the newest checkpoint is found.

3. **High-Water Mark Optimization (`lastSeenMessageID`)**:
   - Persist the newest processed message ID in `UserDefaults` (`xc.lastSyncedMsgID.<channelID>`).
   - If the newest message ID returned from `searchChatMessages` matches our local `lastSeenMessageID`, skip decoding and return immediately (0ms).

---

### Task B: Preserve Alpha Transparency for PNG Thumbnails

1. **Update `Engine/UploadEngine.swift`**:
   - Check if source image has alpha or is PNG/WebP.
   - When generating the thumbnail sidecar, keep PNG encoding (`.png`) for images with alpha channels instead of forcing lossy/opaque JPEG.
   - Encrypted sidecar documents (`thumbMessageID`) can store PNG data directly, allowing iOS and macOS to display transparent corners and transparent backgrounds without white boxes.

---

## 3. Step-by-Step Implementation Checklist for Zed Code

- [ ] **Step 1**: Implement `searchChannelMetadataMessages` in `Telegram/TelegramClient.swift`.
- [ ] **Step 2**: Refactor `Storage/CatalogSnapshot.swift:413` (`fetchChannelState`) to use `searchChannelMetadataMessages`.
- [ ] **Step 3**: Fix PNG alpha preservation in `Engine/UploadEngine.swift` and `Engine/ThumbnailService.swift`.
- [ ] **Step 4**: Verify both build schemes:
  ```sh
  # macOS
  xcodebuild -project /Users/zainulnazir/Projects/Cascade/Cascade.xcodeproj -scheme Cascade -destination 'platform=macOS' build
  
  # iOS
  xcodebuild -project /Users/zainulnazir/Projects/Cascade/Cascade.xcodeproj -scheme "Cascade iOS" -sdk iphoneos -configuration Debug build
  ```
- [ ] **Step 5**: Deploy and test on iPhone XS Max (`8F28E614-EA35-5B10-8DC9-E390026D4599`).
- [ ] **Step 6**: Update `JOURNAL.md` and `HANDOVER.md` with detailed entries, commit on `main`, and record commit hashes.

---

## 4. Continuity & Recovery for Future Sessions

If Zed Code stops or disconnects mid-way:
1. Check `git status` and `git log -5 --oneline`.
2. Inspect the latest entry in `JOURNAL.md` to see what was finished and what was in progress.
3. Resume directly from the next unchecked step in the checklist above.
