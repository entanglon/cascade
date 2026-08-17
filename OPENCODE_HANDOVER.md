# xCloud — Handover for opencode (2026-08-17)

> Read this first. This document is written for a fresh agent (opencode) to pick up
> the work without any prior conversation context. It explains the project, the
> exact state of the repo, the **v3 share upgrade** (the important work in flight),
> what is already built vs. pending, and every gotcha that has burned agents before.

---

## 0. TL;DR — the task opencode should carry on

The user is building **xCloud** (a macOS app that turns a Telegram account into a
private cloud drive) and had just designed — and approved — a major upgrade to the
**share-link system** (they call it the **v3 share upgrade**). The previous agent
session died mid-implementation after building only two of the pieces. **opencode's
job: continue and complete the v3 share upgrade.**

The approved design (user's words, 2026-08-17, summarized):
1. **Private share links**: sharing a new private link should invalidate all other
   private links, **OR** keep up to **5 private channels** so up to 5 private share
   links can be active at once. Channels must be **disposable and reusable** so
   Telegram doesn't block us.
2. **Rework the Shared page** to list **active shares / live links** (what the user
   is sharing right now, which links are active) **instead of imported files** —
   with **public/private indicators** or **separate public/private sections**
   (like Files/Folders on the All Files page).
3. **Cancel a share from the Shared page** (whether private or public) → the share
   link gets cancelled.
4. **Move shared imports from the Shared page to the Transfers page.**
5. **Fix the Transfers page**: proper thumbnails and better cards with all required
   details.
6. **Right-click "Cancel all shares"** (with a warning) → instantly deletes all of
   those files from the public/private share channels and invalidates the links.
7. **Save the channels' invite links in the DB** so that even if the user
   accidentally leaves a channel, the app can still use it.
8. **Channel recreation mechanism**: if the share channels get deleted, new ones are
   created automatically to keep the flow of shared files working.
9. **Grouped share** (already built — see below): sharing multiple selected files
   creates ONE group share under a single private link.

**State: ~40% done.** The grouped share (item 67 in the old handover) and the
"Shared page = imports only + Remove from Shared" (item 66) are built but **not
committed**. Everything else in the list above is **not built**. Note: item 66 went
the *opposite* direction of point 2 — it made the Shared page show only imports,
which the user then superseded with the v3 design (active shares + imports moved to
Transfers). **The v3 design is the authoritative spec.**

---

## 1. What the project is

**xCloud** — native macOS SwiftUI app (the "Freebuff desktop" project) that turns a
Telegram account into a private cloud drive:

- Files are chunked (128 MiB chunks) and uploaded to a private Telegram channel
  ("vault"). Chunks are **plaintext** since 2026-08-16 (per-file encryption was
  dropped by user decision; `isPrivate` is now just a PIN-gated visibility flag +
  `.bin` chunk naming; the vault key seal PIN/device still gates app access).
- `mpv` (bundled via LocalPackages/LocalMPVKit) plays any video/audio container
  through a local byte-range HTTP server (`Engine/VaultStreamServer.swift`) +
  libmpv render API.
- **mpv is the ONLY media engine. AVFoundation/AVKit are REMOVED from the codebase
  (user mandate, 2026-08-15). Never reintroduce `import AVFoundation`/`AVKit`** —
  not for playback, thumbnails, durations, or anything else. Video/audio previews
  come from Telegram's attached thumbnails; durations come from mpv during playback.
- TDLibKit powers Telegram auth + messaging. Local SQLite catalog
  (`Storage/DatabaseManager.swift`, GRDB) + snapshot/delta catalog sync between
  devices (the catalog lives in the vault channel as `xcloud:{"kind":"checkpoint"|"dbdelta"}` messages).
- Share links are **forward-based** (v2): the sender forwards the file's vault chunk
  messages into one reusable "xCloud Shares" channel (server-side copy, no
  re-upload); the link is an obfuscated `xcloud://share#<blob>` URL carrying
  channel + invite + expiry + forwarded message IDs.

Stack: Swift 6.3, SwiftUI + AppKit, macOS 26.5 deployment target. Logging via
`Logger(subsystem: "com.xcloud.app", ...)`.

---

## 2. Repo layout / the two-copy trap (READ BEFORE EDITING ANYTHING)

**There are TWO copies of the project on disk. This has caused a multi-hour
incident (2026-08-15) and repeatedly "lost" work.**

- **MAIN (authoritative, what the user's Xcode builds):** `~/Projects/xCloud`
  (DerivedData `~/Library/Developer/Xcode/DerivedData/xCloud-cdpcjcegyfsbheeztqhmjnnukgcv`).
- **WORKTREE (agent edit area):** `~/Projects/xCloud/.freebuff/worktrees/b32b5e13-4ff7-4e37-924e-76f15c4c2d98`.

**Rules:**
1. Edits land in the **worktree** (relative tool paths resolve there).
2. **After ANY edit, sync worktree → main** (NEVER main → worktree — that wipes edits):
   ```bash
   WT=~/Projects/xCloud/.freebuff/worktrees/b32b5e13-4ff7-4e37-924e-76f15c4c2d98
   MAIN=~/Projects/xCloud
   rsync -a --exclude '.git' --exclude '.freebuff' --exclude 'xcuserdata' \
         --exclude 'DerivedData' --exclude '*.dmg' --exclude '*.profraw' \
         --exclude '.swiftpm' --exclude 'node_modules' "$WT/" "$MAIN/"
   ```
3. **Build/test from MAIN** (that's the build the user actually runs). The worktree
   has its own DerivedData (`xCloud-wt`) only for agent-side typechecks.
4. Before building, verify main actually has your change: `grep '<marker>' ~/Projects/xCloud/<file>`.
5. When in doubt about which copy you're in: `pwd`. If you open the app for the user,
   open the MAIN build, and prefer letting the **user** launch the app to verify UI.

Both copies are currently **byte-identical** (verified 2026-08-17). The uncommitted
diff described in §3 exists in both.

---

## 3. Current repo state (verified 2026-08-17, builds + tests green)

- Branch: `main` at commit `5534317` "Fix share imports end-to-end: real server IDs,
  re-import dedup, Shared nav, and the VaultRepair phantom-object root cause"
  (commits `f28429f` → `5534317` cover items 49–65 of the old HANDOVER).
- **Uncommitted work (8 modified files)** — this is the group-share + Shared-page
  work (old HANDOVER items 66–67):
  - `Engine/ShareEngine.swift` — group shares: `share(objects:)` entry point,
    `ShareFile` struct, v2 links gain `f` = base64url JSON manifest
    `[{"n":name,"m":"id,id,…"}]`, `reusableGroupShareLink(for:)` for exact-set reuse,
    stale-link reuse guard (verifies forwarded messages still exist via
    `messagesByIds`; revokes + re-mints if deleted manually).
  - `App/AppState.swift` — `shareFiles(_:)` (group), `shareFile(_:)` wrapper,
    `removeFromShared(_:)`, `sharedObjectIDs` = incoming only, `shareResultFileCount`.
  - `Features/FileBrowserView.swift` — "Remove from Shared" context menu (Shared
    page, file stays in All Files), count-aware "Share N Items via Link…",
    `ShareLinkSheet` fileCount wording.
  - `Features/TheaterView.swift` — `.shared` case in `mediaBase` (incoming only).
  - `Storage/DatabaseManager.swift` — migration `v23-group-shares`: `shares.groupObjectIDs`.
  - `Storage/Models.swift` — `groupObjectIDs` on share records.
  - `xCloudTests/xCloudTests.swift` — group-share codec/round-trip/reject tests.
  - `HANDOVER.md` — the old handover, updated with items 66–67 (read it for history,
    but this file supersedes it for the go-forward plan).
- **A git stash exists in the shared store**: `batch2-mystery-changes-2026-08-17
  (preserved, not lost)` — contains 22 files of OLDER pre-commit versions (e.g. its
  `Telegram/TelegramClient.swift` lacks `chatExists`, matching the old base commit).
  **Do NOT restore it** — the committed main content is authoritative and restoring
  the stash would break the build. It was left as insurance; can be dropped.
- **Build:** green (Debug, main folder).
- **Tests:** 51 unit tests green (run with `-only-testing:xCloudTests`) + 4 UI tests.
- The `docs/` folder still has the old consult docs (`PLAYER.md`,
  `ANTIGRAVITY_PLAN.md`, `fullscreen-link-consult.md`, `thumbnail-capture-consult.md`)
  — mostly historical; the useful current reference is this file + HANDOVER.md.

---

## 4. Build / run / test commands

```bash
# Build (MAIN folder — the user's build):
cd ~/Projects/xCloud && xcodebuild -project xCloud.xcodeproj -scheme xCloud \
  -configuration Debug \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/xCloud-cdpcjcegyfsbheeztqhmjnnukgcv \
  build

# Unit tests:
cd ~/Projects/xCloud && xcodebuild -project xCloud.xcodeproj -scheme xCloud \
  -configuration Debug \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/xCloud-cdpcjcegyfsbheeztqhmjnnukgcv \
  test -only-testing:xCloudTests
```

- **Launching the app:** `open <MAIN>/.../Debug/xCloud.app`. Agent-launched app
  windows often come up invisible (ordered out; TCC/agent-context quirk) — **let the
  user launch/relaunch to verify UI**. If an agent-launched instance is left running,
  `pkill -f "xCloud.app"` before handing over.
- The app is **unsandboxed** (`ENABLE_APP_SANDBOX = NO`); its real DB is
  `~/Library/Application Support/xCloud/xcloud.sqlite`. Debug vs Release have
  different bundle ids (`com.nemesys.xcloud.xCloud` vs `.prod`) and different data
  folders (`xCloud` vs `xCloud-Prod`) — they never mix state.
- Debug hooks (in `AppState.bootstrap`): `--dump-channel`, `--dump-chat <id>`,
  `--import-share <link>`, `--create-share`, `--revoke-shares` (destructive),
  `--repair-catalog <ids>`, `--cache-video <id>`, `--stream-server`, `--video-thumb <id>`.
  **Gotcha:** most hooks run AFTER `completePostAuthSetup` (post-auth re-merges the
  channel state first) — only `--repair-catalog` runs pre-post-auth.
  After killing an app with pkill, remove `xcloud.sqlite-wal`/`-shm` before trusting
  sqlite3 reads.

---

## 5. The share system today (what exists, before v3)

All in `Engine/ShareEngine.swift` unless noted. **v2 = forward-based shares:**

- **Share creation:** `ShareEngine.share(objects:)` → forwards each file's vault
  chunk messages into the **reusable "xCloud Shares" channel** (created lazily,
  archived + muted, tracked in `share_state` table id=1), mints one one-use expiring
  invite (`createChatInviteLink`, memberLimit 1), one expiry (default 7 days), one
  link. Single file → normal link; 2+ files → group link (carries `f` manifest).
- **Link format (v2):** `xcloud://share?v=2&id=…&ch=…&inv=…&key=…&name=…&exp=…&m=<comma msgIDs>[&w=<wrappedKeyB64>][&f=<base64url JSON manifest for groups>]`.
  `m` = the forwarded message IDs in the share channel; `w` = object key re-wrapped
  (EMPTY for non-private — always empty now, encryption dropped); `f` = per-file
  manifest for group shares. Transported obfuscated as `xcloud://share#<blob>`.
  Legacy v1 links (disposable channels) still parse/import.
- **Reuse:** `reusableShareLink(for:)` returns the identical live link if the file
  already has an active share; group reuse via `reusableGroupShareLink(for:)`
  (exact same object set). Both verify liveness (`getChat` + `messagesByIds`); dead
  records are marked revoked and a fresh link is minted.
- **Self-open:** sharer opening their own link reveals the original file (v2 matched
  by channelID AND messageIDs).
- **Import (recipient):** `importLink` → joins channel with the one-use invite,
  `importForwarded`/`importLegacy` re-forward the chunk messages into the recipient's
  own vault, catalogs the file, writes an incoming ShareRecord, **leaves the share
  channel** on success (never on failure). Re-import of same `rootHash` → 
  `.alreadyImported` (reveal + flash existing copy). Name dedup: Finder-style
  "Name 2.ext" (`uniqueName`, case-insensitive).
- **Expiry/revocation:** expired/revoked v2 shares delete their messages
  individually; `retireShareChannelIfEmpty` deletes the channel when no active
  outgoing shares remain. `deleteForever` on a file revokes its shares + deletes the
  share-channel copies. `leaveChat` is used after imports.
- **DB:** `shares` table (id, objectID, groupObjectIDs, channelID, role, state,
  linkBlob, expiry, createdAt, messageIDs…), `share_state` (id=1: reusable channel),
  migrations v22 (`forward-shares`) + v23 (`group-shares`).
- **Shared page UI:** `Features/FileBrowserView.swift` destination `.shared` shows
  `sharedObjectIDs` (currently = **incoming only**, per item 66); "Remove from
  Shared" context menu deletes the incoming record only. Sidebar badge = incoming
  count. `Features/TheaterView.swift` `.shared` case mirrors the grid for preview
  arrows.

**Key files for the share system:**
- `Engine/ShareEngine.swift` — all share logic + link codec (`ShareLink`, `ShareFile`).
- `App/AppState.swift` — `shareFiles/shareFile/importShareLink/removeFromShared/loadShares`, `sharedObjectIDs`, `shareResultLink`, `shareResultFileCount`.
- `Storage/DatabaseManager.swift` — `shares`/`share_state` tables + v22/v23 migrations, share CRUD.
- `Storage/Models.swift` — `ShareRecord`, `ShareState`.
- `Telegram/TelegramClient.swift` — `createShareChannel`, `createInviteLink`, `joinChatByInviteLink`, `forwardMessages`, `leaveChat`, `messagesByIds`, `chatExists`, `isChatMember`, `resolveConfirmedMessageID`.
- `Features/FileBrowserView.swift` — Shared destination, context menus, `ShareLinkSheet`, `ShareProgressSheet`.
- `Features/TransfersView.swift` + `Engine/TransferCenter.swift` — the Transfers page (needs v3 polish: thumbnails, better cards).
- `Features/SidebarView.swift` — Shared badge.

---

## 6. THE V3 SHARE UPGRADE — the important work (opencode's task)

### 6.1 The user's approved spec (verbatim intent, from the 2026-08-17 conversation)

The user's full design message (edited for clarity, preserving every requirement):

> "Whenever a user shares a private link, all other private links should get
> invalidated, or even better we can use **5 different private channels** — in that
> way we can keep up to **5 private share links active at a time**. We can also make
> these channels **disposable and reusable** so that we don't get blocked by
> Telegram.
>
> Also we can tweak the **Shared page** a bit: **list shared files/links in the
> Shared page instead of imported files** — like this a user will get a clear
> picture of which files they are sharing actively, or which share links are
> currently active. And **if a user cancels a share (export) from the Shared page,
> whether private or public, the share link will get cancelled**.
>
> We can **differentiate public and private shares** with some kind of indicators,
> or keep private and public share sections **separated like Files and Folders on
> the All Files page**.
>
> And we can simply **move the shared imports from the Shared page to Transfers**
> instead. **Fix the Transfers page to also show proper thumbnails and better cards**
> with all the required details.
>
> We can also add an option in the **right-click menu to cancel all the shares**,
> with a warning of course, that will instantly delete all of those files from the
> public or private share channels and invalidate the share links.
>
> We will **save the invite links for these channels in our DB** so that even if we
> accidentally leave the channel, we can still use them, and we should create a
> **mechanism where if the channels are deleted, new channels are created** to
> ensure proper flow of shared files."

Then the follow-up approval: *"Yes definitely, you can go ahead. And also make sure a
user is able to share multiple files at the same time… it should be a **grouped
share**, so that a user can share multiple files in a single group through private
sharing."* → **grouped share is DONE** (§3, item 67).

### 6.2 Design decisions to make (be opinionated, propose, confirm)

The v3 spec leaves real design choices open. Recommended direction (aligns with
existing architecture — confirm with the user before heavy builds):

- **Public vs private link semantics:**
  - *Private links* (default): expire (keep 7-day default or a shorter picker),
    content visible only via the link, channel membership = one-use invite.
  - *Public links*: **never expire**, anyone with the link can import; the shared
    copy lives in a **separate persistent channel** so private-link invalidation
    never kills it. There is no anonymous-public concept in Telegram channels (a
    private channel is only reachable by invite) — "public" here means *link never
    expires / always importable*, not Telegram `public channel` (don't use
    `username`-based public channels unless the user asks; they'd be searchable).
  - Recommendation: two channel pools — one **public share channel** (persistent,
    never expired links) + one **private share channel pool** (up to 5 channels for
    private links, channels retired/recreated as needed). The existing
    `share_state`/`shares` schema can be extended (`share_state` rows per channel
    with `kind = public|private`, `inviteLink` saved, `inUse` count).
- **5-channel invalidation rule:** when all 5 private channels are in use and a new
  private share is created, either (a) invalidate the oldest/expired private share
  and reuse its channel, or (b) block with a clear error. Confirm which.
- **Shared page (v3):** show **outgoing active shares** (public + private sections
  with indicators; each row: file name(s)/thumb, link state, expiry, "Copy Link",
  "Cancel Share"). **Imports move to Transfers** (add an import record/card type to
  `transfers`). Keep "Remove from Shared" for the (now Transfers-located) imports or
  drop it.
- **Cancel all shares:** context menu on the Shared page + AppState batch op →
  revoke every active outgoing share, delete their channel messages, retire channels
  when empty, mark records revoked.
- **Saved invite links:** persist the generated invite link on the share record /
  channel row; `joinChatByInviteLink` fallback path when the app left the channel
  but the record is live (revive membership before import).
- **Channel recreation:** on share creation, if the recorded channel is gone
  (`chatExists` false) → create a replacement, save its id + invite, and continue.
- **Transfers page polish:** thumbnails on transfer cards + richer details — look at
  `Features/TransfersView.swift` + `Engine/TransferCenter.swift` (items already
  exist: `transferIcon`, cards, Clear Finished, pause/resume/cancel). Add real
  thumbnail URLs (reuse `ThumbnailService.thumbnailURL`) and an import card type.

### 6.3 Suggested implementation order

1. **Schema**: migration `v24-share-channels` (or extend `share_state`): `kind`,
   `inviteLink`, `poolIndex`; add `shares.linkKind`/`isPublic`. Unit tests for
   migration + model decoding.
2. **Channel pool**: refactor `reusableShareChannel()` → `shareChannel(kind:pool:)`
   managing up to 5 private + 1 public channels with saved invites + recreation.
3. **Public/private share()**: extend `share(objects:)`/link minting with a
   `public:` flag (expiry nil for public; group shares work for both).
4. **Shared page v3**: outgoing active-shares view (public/private sections,
   indicators, Copy Link, Cancel Share), moving imports to Transfers.
5. **Cancel all shares** (context menu + batch revoke) with confirmation.
6. **Transfers page**: import cards + thumbnails + better card layout.
7. Verify end-to-end with the user (self-open reveal, recipient import of public
   and private links, cancel flows).

### 6.4 Testing notes

- Keep the app-hosted unit test pattern: `shareRefusesPrivateAndFolderObjects`,
  `shareReusesLiveLinkInsteadOfMintingNewOne` skip the `chatExists` check under
  XCTest (the app-hosted suite boots the real app whose auto-login can flip
  `isAuthorized` mid-run).
- Add unit tests for: link codec with `public`/expiry variants, channel-pool
  allocation/reuse, saved-invite revival, cancel-all revocation, group+public combo.
- Real two-account E2E is still pending (the DMG login gate on this Mac had a
  hit-testing issue; the dev build's keychain already has the test session) — a
  second Telegram account is the only true recipient test.

---

## 7. Gotchas & environment notes (agents have burned hours on these)

- **Two copies — sync worktree → main after every edit; NEVER main → worktree.**
  Verify with grep in main before building. (§2)
- **AVFoundation/AVKit are banned** (user mandate). If a task "needs" AVFoundation
  (frame extraction, metadata, durations), the answer is a Telegram thumbnail, an
  mpv property, or dropping the feature. Video/audio thumbs come from Telegram's
  attached `-tg.jpg`; only photos are generated locally; video frames come from the
  bundled FFmpeg extractor (`Engine/VideoFrameExtractor.swift`, opens local files
  AND loopback stream URLs).
- **`modifiedAt` is the catalog's LWW merge clock** (`DatabaseManager.swift` ~line
  655): every mutation MUST go through `updateObject` (bumps `modifiedAt`) or the
  next snapshot merge silently reverts it ~4s later (the 2026-08-15 "photo moves
  back" bug).
- **Never let any routine auto-delete objects or Telegram messages as "repair"**
  (2026-08-15 catalog-collapse incident). `VaultRepair` is reconstruct-only.
  `deleteForever` must never delete a channel message still referenced by ANOTHER
  object's chunk.
- **Stale `lsregister` scheme registrations** caused "window vanished on link open"
  incidents. `xCloud.app` self-registers `xcloud://` at launch
  (`NSWorkspace.setDefaultApplication`); if the browser opens a logged-out app,
  check `lsregister -dump` for stray xCloud.app paths and unregister/delete them.
- **Full-screen link delivery:** never orderFront/activate a full-screen window
  (the OS switches Spaces itself); there's a `FullScreenReentryGuard` in
  `App/TerminationHandler.swift` — don't break it.
- **Media pages aggregate across the cloud** (Photos/Videos/Audio show every file of
  that type from ALL folders; only albums/playlists appear as collections). Do NOT
  add plain folder tiles there again (user explicitly rejected that).
- **Share import must `leaveChat`** after success (never on failure — retry needs
  membership for the one-use invite).
- **The batch2 stash** (§3) is older content — don't restore, don't rely on it.
- Debug/prod isolation: bundle-id-scoped keychain, data folders, URL-handoff
  notification names. Don't merge them.
- The `website/` folder is a separate astro project (dev server may be running;
  rsync excludes `node_modules` — if it ever gets wiped, `npm install` in `website/`).
- DerivedData hygiene: only the `xCloud-cdpcjcegyfsbheeztqhmjnnukgcv` folder for the
  user's build; never build with a custom `-derivedDataPath` into a new `xCloud`
  folder (stale-binary incidents).

---

## 8. History in one paragraph

2026-08-14: foundation (transfer history, liquid FAB, private vault). 2026-08-15:
HDR/EDR mpv color pipeline, adaptive cache, keyboard nav, face-aware thumbnails,
folder nav in preview, AVFoundation removal (mpv-only mandate), headless FFmpeg
video thumbnails, byte-range streaming server, transfer persistence. 2026-08-16:
backup mirror channel, forward-based v2 share links, production build isolation
(v1.1.x DMGs), fresh-install login fix, per-file encryption dropped (flag-only
private vault), streaming replay-buffering fix (TDLib ranged-download starvation),
player polish (F7/F8/F9, glass, share-in-player). 2026-08-17: share-import "Not
Found" fix (real server message IDs), re-import dedup + Finder-style name dedup,
VaultRepair phantom-object fix, Shared-page semantics + stale-link reuse guard,
**group shares** (v23 migration), then the **v3 share upgrade design** — where the
work stopped. Build + 51 unit tests green; items 66–67 uncommitted on main.
