# Cascade Porting Rules (macOS → Android)

Source of truth for behaviors the Android port must match. Every rule cites
the Mac implementation. When Mac and Android disagree, **Mac wins** — fix
Android, then add the case here so the next port decision is a lookup.

## R1 — Upload name collision: silent paren rename, per folder
`Engine/UploadEngine.swift:117-135`. Uploading `icon.png` into a folder
that already holds a non-trashed `icon.png` does NOT prompt, replace, or
fail — the new file is silently renamed `icon (1).png`, then
`icon (2).png`, … (first free `i`, starting at 1).

- Scope: same `parentID` only (`nil` = root). Sibling folders with the
  same name do not collide.
- Trashed items do not count (`!$0.trashed`; tombstoned rows are trashed).
- Comparison is **case-sensitive** (plain `Set<String>.contains`).
- Extension split at the last dot: `archive.tar.gz` → `archive.tar (1).gz`;
  extension-less names → `Folder (1)`.
- Folders colliding with the name get the same treatment (no `isFolder`
  filter in the taken set).
- Applies to fresh uploads only; resumed uploads keep their name.

## R2 — Canonical unique name: Finder-style `Name 2.ext`, per folder
`Engine/ShareEngine.swift:1610-1620` (`uniqueName`) scoped by
`Storage/DatabaseManager.swift:1165-1174` (`uniqueObjectName`). Used by
**rename** (`AppState.swift:2817`), **move** (`:2336`, `:2391`),
**share-import confirm** (`:1387`, `:1415`), **Duplicate seed** (`:2272`),
**folder import** (`:1237`), playlists (`:2133`).

- Free → unchanged; else `Name 2.ext`, `Name 3.ext`, … (starts at **2**,
  space — not parens, not starting at 1).
- Comparison is **case-insensitive** (`lowercased()`).
- Scope: same `parentID`, non-trashed, excluding the object itself
  (`excluding:`) for rename so case-only renames keep working.
- Batch moves pass `reserved:` names so two moved files can't claim the
  same name.
- There is deliberately NO database-level `UNIQUE(parentID, name)`
  constraint (`DatabaseManager.swift:79-90`) — uniqueness is app-level.

## R3 — Import dedupe is by content hash, not by name
`Engine/ShareEngine.swift:1220-1226`, `:1589-1593`.

- Re-importing a file whose `rootHash` (plaintext SHA-256 of the file)
  matches a non-trashed object **reveals the existing copy** — no second
  forward, no duplicate, no rename (`.alreadyImported` → jump + highlight,
  no modal).
- Opening your OWN share link reveals the original (matched by
  `channelID` **and** `messageIDs` — ids alone collide across chats).
- Name is never a dedupe key. A confirmed import whose name collides gets
  R2 (`Report.pdf` → `Report 2.pdf`), root-scoped.
- Folders / hashless objects never dedupe (`rootHash == nil` skips).
- Trashed copy + reimport = fresh import (trashed rows ignored).
- Uploads do NOT dedupe by content (same bytes upload twice = two
  objects); review UI is `Engine/DuplicateFinder.swift` (group by
  `rootHash`).

## R4 — Duplicate naming: `X Copy`, then R2
`App/AppState.swift:2259-2273`. Duplicating `Report.pdf` in place yields
`Report Copy.pdf`; a further collision yields `Report Copy 2.pdf` (R2).

- Last-dot split: `archive.tar.gz` → `archive.tar Copy.gz`.
- Folders: shallow copy (children stay), seed `<name> Copy`, then R2
  (`Photos` → `Photos Copy` → `Photos Copy 2`).
- Files clone chunk records with fresh ids sharing `messageID`
  (server-side, no re-upload).
- No `Copy (n)` paren pattern exists anywhere on Mac.

## R5 — New folder does NOT unique
`App/AppState.swift:2059`, `:2212`. Creating "New Folder" twice saves the
name verbatim both times. (Exception: folder *import* uniques via R2.)

## R7 — Chunk messages come in three content types; readers must speak all
`Telegram/TelegramClient.swift:1440-1490` (`sendFile`), `:718-745`
(`MediaKind`, `primaryFile`). Single-chunk, non-private videos go out as
real Telegram video messages (`inputMessageVideo`, `supportsStreaming:
true`); everything else — multi-chunk video, private video, photos, docs —
goes out as plain documents (`inputMessageDocument`,
`disableContentTypeDetection: true`, so TDLib never re-types .mp3→audio
or images→photos). Readers must therefore extract the stored file per
type, exactly like Mac `primaryFile`: document → `document.document`,
video → `video.video`, photo → widest of `photo.sizes`, audio →
`audio.audio` (defensive; TDLib auto-conversion makes these appear).
Android violated this by reading only `messageDocument` — Mac-shared
videos failed with "no document". Thumbnails likewise: `messageVideo`
carries `video.thumbnail`.

## R6 — Thumbnails ride on chunk messages (vault ≠ photo messages)
`Engine/UploadEngine.swift` (`generateThumbnails` + `thumbnailPath` on
every chunk): the vault stores chunks as plain documents and Telegram
auto-generates previews only for real photo messages, so every uploader
must attach a locally generated JPEG to every chunk. Android parity:
`ThumbGen` + `inputThumbnail` (TDLib field name is `thumbnail`, and
TDLib `Document` names its file field `document` — see HANDOVER §155).
