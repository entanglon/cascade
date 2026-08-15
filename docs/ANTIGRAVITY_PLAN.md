# ANTIGRAVITY PLAN — xCloud fixes (handoff 2026-08-15)

You are picking this up fresh. Read **HANDOVER.md** items 30–33 first for full incident
context. This file lists the open issues the user wants fixed, with concrete pointers.
The project root is `~/Projects/xCloud` (Xcode builds from this folder). There is also a
Freebuff git worktree at `~/Projects/xCloud/.freebuff/worktrees/b32b5e13-*` — keep source
files byte-identical in BOTH copies when you edit (the user's Xcode builds from the main
folder; agent builds used the worktree).

## Environment gotchas (learned the hard way — respect these)

1. **The app is UNSANDBOXED** (`ENABLE_APP_SANDBOX = NO` in project.pbxproj). Its real DB
   is `~/Library/Application Support/xCloud/xcloud.sqlite`. The container DB at
   `~/Library/Containers/com.nemesys.xCloud.xCloud/Data/Library/Application Support/xCloud/xcloud.sqlite`
   is STALE (14 objects, mtime 12:21) — never read by the current build. Ignore it.
2. **Background processes die between terminal commands** in this environment. To run the
   app with captured stdout you must launch, wait, and kill inside ONE command:
   `"$APP/Contents/MacOS/xCloud" > /tmp/log.txt 2>&1 & PID=$!; sleep N; grep ...; kill $PID`.
   TDLib auth + post-auth catalog scan takes 60–130s before the app's `print()` lines
   (`xCloud post-auth: ...`, `repair scan changed=...`) appear. Agent-launched app windows
   come up ordered-out on this Mac (user may need to click the Dock icon) — use
   `open "$APP"` for the user's normal launches, `open` loses stdout though.
3. **Single-instance guard**: only one xCloud may run. Always `pkill -9 -f
   "xCloud.app/Contents/MacOS"` before launching, and before touching the DB file.
4. **Never** import AVFoundation/AVKit (user mandate; see HANDOVER). mpv is the only media
   engine.
5. **Backups live in** `~/Projects/Backups/`: `xCloud-source-backup-2026-08-15.zip`
   (source + website, refreshed 18:31, 220 MB), `xCloud-appdata-backup-2026-08-15.zip`,
   `xCloud-recovered-db-2026-08-15.sqlite`, `cache-recovery/` (1.2 GB of cached file bytes
   used for the recovery). The newest published catalog checkpoint on the Telegram channel
   is cached locally at
   `~/Library/Caches/xCloud/tdlib-files/documents/snapshot-53D9276F-2298-4AB6-897B-2DBBC1FE4F75.json`
   (18 files + 3 folders, 26 chunks).

---

## TASK 1 — Remove the 3 "ghost" catalog rows so the app shows exactly what's in the cloud

**Why (user: "the database is still not updated, the app isn't showing actually what's in
the cloud")**: the 2026-08-15 wipe deleted 30 chunk documents from the Telegram channel.
15 of 17 files were recovered by re-uploading from cache; the recovery catalog keeps 3
objects that have ZERO chunks and no bytes anywhere (permanently lost). The app lists them
as normal `ready` files, so the UI shows 18 files while the cloud actually holds 15.

**Ghost rows** (in `objects`, all `isFolder=0`, all `state='ready'`, no rows in `chunks`):

| id | name |
|----|------|
| `C8F5AC50-A2C9-4FAE-AEC9-5DAB1AB6C0AE` | House.of.the.Dragon.S01E01.1080p.BluRay.x265-RARBG[eztv.re].mp4 |
| `332D38BD-61C7-4522-BD44-94FFC2650F7C` | The Exorcist theme (HD).wav |
| `33D2C3AE-8653-4E9C-92CD-F76BD3AD7966` | The Exorcist.ogg |

**Do**:
1. `pkill -9 -f "xCloud.app/Contents/MacOS"` (app must not be running).
2. Delete those 3 rows: `DELETE FROM objects WHERE id IN (...)` — the `chunks` FK is
   `ON DELETE CASCADE` (there are no chunk rows anyway).
3. Relaunch the app (user launches via `open`). On every login the app calls
   `forcePublishSnapshot()` (App/AppState.swift) and REPLACES the channel checkpoint with
   the local catalog — so the cleaned 15-file catalog gets published automatically.
4. Verify: DB shows 15 files + 3 folders; newest `snapshot-*.json` in
   `~/Library/Caches/xCloud/tdlib-files/documents/` contains 18 objects, 15 files, 24
   chunks; `--dump-channel` hook shows only real chunk documents.

**Do NOT**:
- Don't "fix" `VaultRepair` — it was already fixed to be reconstruct-only (never deletes).
- Don't expect the ghosts to come back: nothing in the channel references them anymore.

---

## TASK 2 — Transfers page: download cards + Uploads/Downloads separation

**Why (user request)**: "there doesn't seem to be any download history in the app.
Shouldn't we add downloads to the transfer as well? The cards for downloads should also
appear in the transfer page. We can separate the uploads and downloads exactly like we do
folders and files on the all files page."

**Current state (verified)**:
- `Engine/TransferCenter.swift` already models BOTH directions: `Item.Direction { case
  upload, download }`, persists finished history to the DB (`upsertTransfer` /
  `deleteTransfers`, restored by `restoreHistory()`), and `resume()`/`cancel()`/`discard()`
  already handle downloads.
- `Engine/DownloadEngine.swift` ALREADY posts downloads to TransferCenter:
  line 81 `await TransferCenter.shared.begin(...)` (with a `quiet` flag — quiet downloads
  get NO card), line 91 `update(...)`, line 203 `finish(... success: true)`, line 231
  `finish(... false)`, line 238 `registerCancel(...)`.
- `Features/TransfersView.swift` renders ALL `center.items` (no direction filter) as
  `TransferGridCard`/`TransferRow`; empty-state text already says "uploads or downloads".
- `Features/FileBrowserView.swift` has the Folders/Files split pattern the user wants
  mirrored (folder section vs file section on the All Files page).

**Gaps to close**:
1. **UI separation**: add an Uploads / Downloads segmented control at the top of
   `TransfersView` (mirror the Folders/Files split in FileBrowserView). Filter
   `center.items` by `direction`. Decide: show both sections stacked (like Folders then
   Files) or a segmented picker — the user said "exactly like folders and files", which is
   the stacked-sections pattern, but a segmented control is a reasonable read; pick one
   and keep it simple.
2. **Why does the user see "no download history"?** Investigate:
   - Where downloads are started with `quiet: true` (thumbnail warm-up, cache management,
     preview prefetch) — those intentionally get no cards. User-initiated downloads
     (playing/downloading a file) should be non-quiet. Check the call sites.
   - Confirm `finish()` persists history rows for downloads the same way it does for
     uploads (look at `finish` + `persist` in TransferCenter).
   - Check `restoreHistory()` doesn't drop `direction == "download"` rows (it reads
     `record.direction == "download" ? .download : .upload` — looks fine, but verify the
     DB rows are actually written).
3. **Verification**: unit tests in xCloudTests cover TransferCenter; add/extend a test
   that a completed download persists a history row and restoreHistory brings it back with
   `direction == .download`. Manual: play/stream a file, open Transfers, see a download
   card complete; relaunch app, card still there under Downloads.

---

## TASK 3 — "Files play from cache, not streamed" — clarify, don't "fix"

**Why (user observation)**: the recovery re-uploaded 15 files from the app cache; the user
concluded files play from cache instead of streaming.

**Truth (documented in HANDOVER)**: this is by design, not a bug. Files are
downloaded/cached when played or explicitly downloaded; cached files play from local disk
(offline-first). NEVER-cached files (e.g. House of the Dragon before the wipe) stream via
the loopback byte-range server (`Engine/VaultStreamServer.swift`, `http://127.0.0.1:PORT/stream/<id>`)
without downloading the whole file. The 15 cached files had been downloaded during earlier
sessions, so their bytes were available for recovery — that's exactly why recovery was
possible.

**Action**: verify streaming still works with a file that is NOT cached (re-upload
something or use a fresh upload, then play it before it finishes caching; or delete a
cached copy and play — the stream server must serve exact 206 byte ranges). Log line
`vcodec/acodec` telemetry lives in `/tmp/xcloud-mpv-telemetry.log` (mpv path) — confirm
the stream URL was used. Do not change the cache/stream architecture.

---

## Suggested execution order

1. Task 1 (2 minutes — pure data cleanup) → relaunch → user sees 15 files, cloud-accurate.
2. Task 2 (the real feature work) — do the UI split + download-history gap, build, test.
3. Task 3 (verification only).
4. Sync all edited files to BOTH copies, run `xcodebuild test`, refresh the backup zip
   (`cd ~/Projects && zip -r -y ~/Projects/Backups/xCloud-source-backup-2026-08-15.zip
   xCloud -x "xCloud/.git/*" -x "xCloud/.freebuff/*" -x "xCloud/build/*"`), update
   HANDOVER.md (add an item under section 4) + this file's "Status" below.

## Status

- [ ] TASK 1 — ghost rows removed, catalog == cloud (15 files + 3 folders)
- [ ] TASK 2 — Transfers shows download cards; Uploads/Downloads separation shipped
- [ ] TASK 3 — streaming verified end-to-end
