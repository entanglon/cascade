# xCloud — Feature Roadmap

> Brainstormed 2026-08-09. The app's identity: **Finder-quality macOS experience on top of
> Telegram's "unlimited" storage**. The features below are chosen to reinforce the three axes
> where the genre is weakest and where we can win: **speed, trust, and macOS-native feel**.

## Strategic context

- The core concept (Telegram as storage backend) is **not unique** — Unlim Cloud, TeleCloud,
  GigaDrive, and several OSS projects all do it. Our differentiator is **execution/craft**:
  chunked uploads with real resume, a real filesystem layer (folders/albums/playlists/vault),
  Finder-level UX (marquee select, multi-drag, Quick Look, undo/redo), and product polish.
- Competitive risks: Telegram ToS discourages general file-storage use; bulk usage can hit
  rate limits (FLOOD_WAIT) or daily message caps (~9 messages per 1 GB file at 128 MB chunks).
- Open-source question (deferred): concept is unproven for donations; modest fame possible
  via Show HN / r/MacOSApps / Product Hunt. If we go that route: security-audit the
  keychain/encryption path first, strip personal data, add README/screenshots, then release.
  Alternative: keep core closed, open a lite read-only version, or add a paid premium tier.

---

## Tier 1 — the big strategic wins

### 1. Parallel chunk uploads — ✅ *implemented 2026-08-10*
Up to 3 chunks of one file upload concurrently (`UploadEngine.maxConcurrentChunkUploads`).
Each chunk is an independent Telegram document, so TDLib pipelines them; per-chunk rows keep
pause/resume identical (pause cancels every in-flight send — none post a message — and
resume re-uploads only missing chunks). Each chunk opens its own file handle to avoid seek
races; `ParallelUploadProgress` aggregates per-chunk fractions for smooth card progress.
Honest caveat: parallelism never exceeds the ISP's raw cap — it wins when per-connection/
per-session throttling or latency is the real bottleneck. A "max concurrent transfers" knob
(parallel files) is a possible follow-up.

### 2. Folder watch / auto-sync
**Why:** turns the app from "a manual uploader" into "a real backup tool" (Dropbox-style,
but free and unlimited) — a category Unlim doesn't play in.
**How:** `FSEventStream` on a user-picked local folder (e.g. a "Sync" folder or Camera roll);
new/changed files auto-upload through the existing upload engine. Needs: folder-picker UI,
debouncing, rename/move handling, delete-propagation decision (trash vs. ignore).

### 3. Vault recovery key
**Why:** the existential trust risk of this app — everything is encrypted and keys live in the
macOS keychain. If the keychain entry is lost (reinstall, keychain reset, corrupted vault),
the user's files are **gone forever** (Telegram only holds ciphertext). A recovery key is the
single most trust-building feature we can add and directly answers "can I trust this app?".
**How:** exportable/importable encrypted recovery key with a paper-key flow (wallet-style
seed phrase); re-derives the vault key from the phrase + a KDF. Must be carefully designed
so the recovery phrase alone (or with minimal entropy) can't be brute-forced.

---

### 4. `yt-dlp` Link Saver ("Save to Cloud from URL") — *discussed 2026-08-10, deferred*
**Honest assessment:** architecturally one of the *easiest* features — the upload side (chunking,
encryption, Telegram, resume, transfer cards) is done; yt-dlp's only job is "produce a local
file", then it's just `UploadEngine.upload(fileURL:)`. But it's operationally the *riskiest*
feature, ~70/30 easy/hard:

- **Packaging (the #1 risk):** yt-dlp's official releases are Python zipapps needing `python3`
  (not guaranteed on a fresh Mac without CLT). Options: frozen/PyInstaller binary (unofficial,
  third-party trust issue for an app that uploads the output), user-installed (kills UX),
  or zipapp + auto-python. Research the cleanest macOS story before writing code.
- **ffmpeg dependency:** most YouTube media are separate DASH video/audio streams; without
  ffmpeg to merge, downloads produce silent video or audio-only files. That's a second binary
  and a silent-failure mode if unhandled.
- **YouTube fights back:** "Sign in to confirm you're not a bot" walls and rate limits make the
  marquee site the flakiest; Twitter/X, Vimeo, SoundCloud, and the other 1,000+ sites are
  generally cooperative.
- **Long downloads:** a 4K movie is 5–20 GB → long download + long upload + 40–160 Telegram
  messages (daily cap!). Needs temp-space cleanup on cancel/failure and pause = kill/resume
  process (`yt-dlp -c`) wired through the transfer cards.

**Recommended v1 scope (audio-first):** "Save audio (mp3/m4a) from link" via `yt-dlp -x` —
one stream, no ffmpeg merge, small files, reliable on YouTube *and* everything else. Then
video with a quality picker + honest errors ("YouTube is blocking this right now"), and a
Settings pane for the yt-dlp/ffmpeg binaries with a one-click install. Ship behind a
"may be flaky" note.

### 5. Encrypted Notes (Google Keep-style) — ✅ *implemented 2026-08-10*
A "Notes" sidebar destination with Keep-style color cards, pinning, tags, markdown preview,
trash lifecycle (inline with Trash page), keyboard shortcuts, multi-select drag, and a
SwiftUI `TextEditor`-based editor (rich NSTextView experiment was abandoned — input was
unreliable in a sheet; see git history for the research). Notes are currently **local-only**
(DB table + RTF column; not yet synced to Telegram).

---

## Tier 2 — competitive polish

### 6. Menu bar presence + background transfers
Transfers continue when the window closes; menu bar icon shows collective progress (the
liquid FAB condensed to a small dot). Clicking opens the main window / mini transfer list.
Every serious macOS cloud app has this; its absence reads as "not production software".

### 7. Duplicate detection
Hash a file before upload; if identical content already exists, link to it instead of burning
a daily-message slot and channel space. Saves the user's quota and keeps the channel clean.
Pairs well with the existing VaultRepair orphan/duplicate purge.

### 8. Smart folders / saved searches
"Recently Added", "Large Files", "Videos over 1 GB", "Favorites in Photos" — saved-search
predicates like macOS smart folders. Cheap to build on the existing sort/filter machinery.

### 9. Storage analytics
A "Storage" screen: usage per file type and per folder, top-10 files, daily message usage with
a warning before approaching flood limits. All the data already exists; this is presentation.

---

## Tier 3 — ambitious / fun

### 10. Finder integration
Right-click any file in Finder → "Upload to xCloud" via a Share / Finder-Sync extension.
High fame-per-effort for the OSS story.

### 11. Offline pinning
Mark files "available offline" and pre-download into the LRU cache (Google-Drive-pin style)
so they open instantly with no network.

### 12. Share links via a small bot
A Telegram bot that hands out expiring download links for individual files. Turns a private
vault into a sharing tool; strong "why this is different" story.
*Superseded by the Vault bot plan (2026-08-16) — see the bot section at the bottom.*

### 13. S3-Compatible Local Gateway
Run a lightweight embedded S3 server (`http://127.0.0.1:9000`) so tools like rclone, Cyberduck,
Restic, or custom apps can use xCloud as an S3 cloud storage backend.

---

## Other ideas on the table (from earlier discussions)

- **Multi-account support** — multiple Telegram accounts/vaults with switching in the sidebar.
- **Premium tier** — larger chunks, parallel uploads, multi-account, with a simple license
  check; likely earns far more than open-source donations.
- **Open-source prep** — security review of keychain/encryption, strip personal/session data,
  README + screenshots + LICENSE + CONTRIBUTING, then Show HN / r/MacOSApps / Product Hunt.
- **Transfer queue management** — reorder, pause-all, retry-all, transfer history archive.
- **Full-text search** in documents (index text of PDFs/docs for search).
- **EXIF / map view** for photos with GPS.
- **End-to-end encryption marketing** — "your files, your keys" positioning page.

---

## Recommended order (updated 2026-08-10 — notes + parallel uploads done)

1. **Folder auto-sync** — continuous background backup; category shift.
2. **Vault recovery key** — maximum trust & seed-phrase recovery.
3. **`yt-dlp` Link Saver** — audio-first v1 as scoped above; do the packaging research first.
4. **Note sync to Telegram** — encrypt + upload note payloads so notes survive reinstalls.
5. **Max concurrent transfers** — the simpler "parallel files" win across the queue.

---

## Decisions & deferred plans — 2026-08-14

### Finder integration: File Provider, iCloud/Drive-style — DECIDED, DEFERRED

User explicitly rejected both alternatives after discussion:
- ❌ **WebDAV over the existing stream server** ("this dav method isn't good") — old network-drive feel, not what Drive/iCloud are.
- ❌ **Local sync folder (Mega/Dropbox-classic model)** — real local copies, no eviction, plaintext on disk.
- ✅ **File Provider extension** — "we gotta do it exactly like cloud and google drive": on-demand materialization, automatic eviction, cloud badges, Open/Save dialogs. This is what iCloud/Drive/Dropbox actually run.

**Project state that makes this viable:** macOS 26.5 deployment target, signing team `A6388Z7T5U`, bundle `com.nemesys.xcloud.xCloud`. No entitlements files exist yet (app is non-sandboxed) — extension work starts from zero.

**Build plan (each milestone working/verifiable):**
1. **Skeleton** — extension target, File Provider + App Group entitlements, shared container; vault shows as a browsable folder in Finder.
2. **Materialization** — double-click downloads from Telegram, opens; eviction + badges follow.
3. **Writing** — drag-in upload, new folder, rename, move, delete (existing upload engine).
4. **Live sync** — in-app changes push to Finder via `signalEnumerator`; two-way.
5. **Polish** — Open/Save dialogs, working set, conflict handling, badges everywhere.

**Three hard problems to solve (recorded design notes):**
1. *Signing/entitlements* — new Xcode target + App Group capability on the team (non-App-Store OK with Developer ID).
2. *Catalog mirror* — extension keeps its own SQLite item DB (required by File Provider); app mirrors catalog changes into the shared container and signals; extension imports; extension reports uploads/deletes back.
3. *Keys in the sandbox* — extension can't touch the app's keychain/DB; share wrapped vault key via shared container + shared Keychain group so the extension decrypts chunks itself (reuse existing decrypt-streaming pipeline).

### Auto backup & restore — DEFERRED ON MAC (user decision 2026-08-14)

"Leave the auto backup aside for now. I think we won't need it on a mac, right?" — agreed: with File Provider the Mac gets on-demand materialization (files land locally when used) and the existing evictable stream cache; the local copy *is* the Mac-side redundancy. The catalog-sync / chunk-repair / restore machinery remains **valuable for the future mobile client** (see below) but is not being built now.

### Mobile support — FUTURE GOAL (recurring user intent)

Everything is being built with a future iOS/Android client in mind: the stack is Telegram-native (TDLib + crypto), so a mobile app is "sign in + enter vault PIN + scan vault channel (VaultRepair) → cloud reassembles." The PIN-recovery mechanism already enables cross-device restore with no new server infrastructure. When mobile arrives: reuse the restore path, and revisit auto-backup (catalog sync + health checks) for phones.

### Storage analytics — PARTIALLY DONE (2026-08-14)

Roadmap item #9 ("Storage screen"): the **Settings → Vault Usage** card now shows an Apple-style stacked storage bar (Images/Videos/Audio/Documents/Other with sizes + percentages, live from the catalog). Remaining: per-folder usage, top-10 files, daily message usage / flood-limit warnings.

### Private vault stealth — DEFERRED (brainstorm 2026-08-14, user decided not needed now)

Goal: hide the vault's *presence* and make locking frictionless. Current state: 4-digit PIN lock screen exists; the sidebar always advertises "Private Vault"; locking is only via the page context menu. Honest boundary: hiding the UI is anti-discovery for casual observers, NOT anti-forensics — the PIN stays the real gate.

**Tier 1 — shortcuts + auto-lock (recommended first):**
- `⌘L` lock vault instantly (set locked + navigate away to All Files); `⌘⇧U` jump to vault + focus PIN field.
- Auto-lock: idle timer (1/5/15/never, settable), on app deactivate (`didResignActive`), on screen sleep.
- Panic shortcut: lock + switch to All Files + clear selection (one keystroke = zero trace).

**Tier 2 — actual hiding:**
- **Stealth Mode toggle (Settings):** sidebar row disappears entirely; access via keyboard-only (`⌥⌘V` shows vault + lock screen).
- **Disguise:** user-renameable vault label (e.g. "Archive") + plain folder icon (drop the `number` icon giveaway).

**Tier 3 — ambitious (parked for now):**
- Touch ID unlock via LocalAuthentication (fallback to PIN) — best unlock UX win, small code.
- Decoy vault on wrong PIN (plausible empty folder) — real deniability but a security-design decision; easy to get wrong; parked.

### Edit files with system apps — DEFERRED (brainstorm 2026-08-14, user decided not needed now)

Open a cloud file in the default macOS app, edit, and save back to the vault (Drive-style in-place editing). Feasible: the basic loop (stage copy → open externally → watch for changes → re-upload) is buildable with existing machinery in ~a day.

**Design sketch:**
- "Edit" action (or pencil icon) → copy object bytes into a stable **staging dir** (separate from the evictable LRU cache so mid-edit eviction can't lose changes) → `NSWorkspace.open` → watch the staging dir (FSEvents, atomic-save aware) → debounced upload on save.
- Upload path needs a new **"update object contents"** flow: delete the object's old chunk messages in the vault channel, post new chunks, update the catalog row (size/hash/modifiedAt) + metadata caption + publish snapshot. (Telegram documents are immutable — content changes always mean new chunk messages.)
- "Create with system tools": trivially builds on the same loop (stage a blank file of a chosen type, open, upload on first save).

**Honest gotchas to design around:**
- **Quota per save:** every save re-uploads the whole file (1 GB ≈ 8 messages). Debounce saves; for large files consider an explicit "Save to Cloud" mode or a per-edit threshold.
- Atomic saves (TextEdit/Pages replace the file): watch the directory + filename, not the inode.
- Conflict: last-write-wins v1 (warn if the remote changed mid-edit).
- Staging copy lifecycle: keep until editor closes or app quits; never let the evictable cache own it.

### Backup / restore channel — PLANNED for implementation (design decided 2026-08-16)

A second private Telegram channel ("xCloud Backup", archived + muted) receiving a
**forward** (`forwardMessages`, `sendCopy: false` = zero-cost reference, bytes and
`xcloud:v1:` captions preserved → encryption intact) of every message the app posts
to the vault channel (chunk messages, object metadata captions, vault key blob,
checkpoint/delta catalog messages). If the main vault channel is deleted or the app
malfunctions and wipes it, the backup channel still holds everything.

**Decided scope (user decisions 2026-08-16):**
- **No trash/retention channel and no tombstones** — Trash is already the backup;
  deleting from Trash = permanent. Delete-forever removes the object's messages from
  the BACKUP channel too (via a main→backup message-ID mapping recorded at forward
  time), so nothing lingers after permanent deletion.
- Mirroring is a background queue (`backup_msgs` table) drained by a forwarder actor
  at ~1 msg/sec — flood control is the only constraint (no daily caps exist; the
  "1,000 forwards/day" figure is a myth — see limits research below).
- Whole-channel "restore from backup" (rebuild catalog + chunk records from the
  backup channel) is a later phase; the mirror must simply be complete and current.

**Real Telegram limits that DO matter to xCloud (tginfo.me, 2026-08-16):**
- File size: 2 GB free / 4 GB Premium per file — irrelevant to 128 MiB chunks.
- Captions: 1,024 chars free / 4,096 Premium — xCloud captions must stay under 1,024.
- Send rate: ~1 msg/sec per chat (flood control; TDLib `withFloodWait` already handled).
- Non-Premium upload speed throttle: server-side, after an undocumented monthly data
  threshold (FLOOD_PREMIUM_WAIT / -429) — throttles speed, not volume.
- Channel/supergroup membership: 500 free / 1,000 Premium — v2 shares reuse ONE
  channel with per-share expiring invites (superseded the "temp channel per share"
  model 2026-08-16 — see forward-based shares); watch the reusable channel if many
  shares accumulate (per-file deletion on expiry/revoke).
- Channel/group creation: 50/day — bounds mass share-link creation.
- Downloads: ~5 parallel small (<20 MB) / ~2 parallel big — honor in DownloadEngine.
- File name: 60 chars (trimmed). No daily upload/forward quotas exist, so no
  in-app "daily limit" warnings are warranted (user decision 2026-08-16).

---

## Vault bot — PLANNED (design discussion 2026-08-16)

A Telegram bot added to the vault channel as admin. Two horizons decided:

**Near-term — individual self-hosted bot (ships separately for users who can run it):**
The desktop app adds the bot to the user's vault channel automatically during
onboarding (`addChatMember` with admin rights — the user never configures anything).
The bot runs 24/7 on the user's own server as a TDLib bot session
(`checkAuthenticationBotToken` — same stack, no new infra). Capabilities:

- **Forward-to-upload** — forward any file to the bot from any device → bot
  reference-forwards it into the vault channel (zero re-upload, any size up to
  Telegram's 2 GB/4 GB cap; the 50 MB Bot API upload limit never applies to
  reference forwards or user-side uploads), posts the catalog delta, mirrors to
  the backup channel. Works with the desktop app closed.
- **Always-on backup drainer** — the `backup_msgs` mirror queue keeps draining
  while the app is offline.
- **Disaster recovery** — as backup-channel admin, re-forward everything into a
  fresh vault channel if the vault is lost.
- **Integrity checks** — vault↔backup message-count cross-check, catalog↔chunk
  verification, stale snapshot pruning, checkpoint republishing.
- **Commands** — `/list`, `/search`, `/stats`, `/status`; quick downloads by
  `file_id` (server-side reference, no size cap).
- **Notifications** — DMs on drain failures, uploads, tamper detection.

**Future — shared multi-tenant bot + Telegram Mini App (product vision):**
One hosted bot (bot operator reads all vault channels — a deliberate trust
statement) + a Mini App giving a full web client inside Telegram (browse/search/
download/request-upload on any device). Constraints researched 2026-08-16:
- Bot API has **no history access** — catalog restore, integrity, file listings
  need TDLib, not a worker. A Cloudflare Worker can only be a *reaction layer*
  (handle forwards, post deltas); the *brain layer* must be a TDLib daemon.
- Bot API downloads cap at **20 MB** (2 GB with a self-hosted Local Bot API Server) —
  serving 128 MiB chunks needs TDLib or the local server.
- **~30 msg/sec global cap per bot token** — scaling = more bots, sharded by user.

**Share serving via bot — nuance (corrects the "bot just forwards" assumption):**
Shares do NOT forward from the vault — `ShareEngine.share()` re-encrypts a fresh
copy (new object key wrapped by the share key) into a disposable channel so the
vault channel is never touched and the link dies with the channel. A bot cannot
re-encrypt without the vault master key, and re-encryption means real bandwidth
through the bot (the ONE operation that isn't reference-only). Options: (a) the
self-hosted bot holds the master key and serves full share creation server-side,
or (b) share creation stays app-side and the bot only handles expiry cleanup/
revocation — (b) is the safe default for now.



## Streaming architecture candidate: TDLib whole-chunk fill + sparse-file reads (Qwen, 2026-08-21)

Prototype before adopting: replace per-range `downloadFile` batching entirely with
one low-priority `downloadFile(fileId, limit: 0)` per relevant chunk, then serve
slices by reading TDLib's growing local sparse file directly; gate on
`getFileDownloadedPrefixSize` / `updateFile` progress events instead of polling
`downloadedSize` (item 55's failed attempt used the wrong signal). Would delete the
ObjectFetcher chains, batch planning, and read-ahead run pool. Validate first:
updateFile event reliability for ranged downloads, priority coexistence with
foreground grabs, memory behavior of full-chunk downloads across many chunks.
Current implementation stays until a cold-cache prototype beats it on stall count.

## Argon2id password KDF upgrade (parked 2026-08-21, audit item 10)

Replace PBKDF2-HMAC-SHA256 (600k) with Argon2id (OWASP 2026 default:
m=19456 KiB, t=2, p=1) for password-derived keys — vault recovery key and
password-protected share links. Benefit: memory-hardness makes GPU offline
brute-force of a exfiltrated key record + salt orders of magnitude slower.

Adoption notes (from docs/AUDIT_2026-08-21.md):
- CommonCrypto has no Argon2id — requires a vetted third-party Swift package
  or vendored C reference implementation (supply-chain weight is the reason
  this is parked).
- Dual-path verification required: existing PBKDF2-derived records (vault key
  seal v2, password links minted at 600k) must keep verifying; migrate to
  Argon2id on next successful unlock/re-mint. Legacy-100k link fallback stays.
- Threat model fit: only matters when an attacker has BOTH the channel's
  sealed key record AND offline time. Item 148 (PIN PBKDF2 + throttle) closed
  the more accessible door.
Trigger to revisit: user request, or any incident suggesting channel-data
exfiltration attempts.

## Distribution & licensing plan (feature-complete milestone — decided 2026-08-22, item 167)

Ship closed-source. Compiled Swift already hides source; no vendor secrets are
embedded (Telegram api_id/api_hash are user-entered, stored in Keychain).
Deferred until feature-complete: license module, notarization, activation.

Plan of record:
1. Channel: Developer ID + notarized DMG (standard path). MAS optional later
   (sandboxing audit needed for TDLib/mpv).
2. Licensing: Ed25519-signed offline keys (public key embedded only), or
   account-activation via a small backend if online features land first.
   Paddle/LemonSqueezy for payments + key generation + VAT.
3. Separate Telegram api_id registered FOR distribution builds — never ship
   the development pair's identity anywhere user-visible.
4. Release hardening checklist: SWIFT_REFLECTION_METADATA_LEVEL=none, symbol
   strip, dead-strip, DEBUG-gated diagnostics (DONE 2026-08-22: streamLog +
   bootLog compile out in Release), EULA prohibiting RE/redistribution
   (DMCA takedown lever).

Done now as cheap-now/expensive-later items:
- streamLog/bootLog bodies wrapped in #if DEBUG (Release builds contain none
  of the fetch-offset/object-ID internals).
- Verified zero .md/docs files in the app bundle or pbxproj resources.

Known accepted risks: determined local RE is always possible on shipped
binaries; scattered print() statements remain in Release stdout paths
(cosmetic; sweep into a DevLog shim if it ever matters); moat = iteration
speed + support + legal layer, not binary secrecy.

## Feature Wave 2 (approved 2026-08-22 — ordered implementation queue)

1. **Subtitles** — ✅ *implemented 2026-08-22 (`34db68b`)*: sidecar `.srt/.ass/
   .ssa/.vtt/.sub` attached via video context menu "Add Subtitles…" (multi-
   select; same-name re-add replaces), stored as vault documents linked on the
   object row (DB v30 JSON column, snapshot-synced, encrypted for private
   videos), auto-materialized + `sub-add`-ed at playback start (queued past
   mpv's no-file-loaded window and the theater's late view attach), manual pick
   + Off row in the track popover. v1 follow-ups parked: upload-time same-stem
   auto-detect, sidecars in share imports, handoff re-add.
2. **Offline pins** — ✅ *implemented 2026-08-22 (`e1f359e`)*: "Keep Downloaded"
   context action (files + folders recursively, multi-select); pinned copies
   exempt from cache budget (cap + floor) AND launch wipe, also excluded from
   budget accounting; visible-card downloads on pin; pin badges in browser
   grid/list/folder cards + Photos/Videos cells; undo/redo. DEVICE-LOCAL flag
   (stripped from remote snapshot adoption — a pin never downloads on another
   Mac).
3. **Finder drop-zone sync** — ✅ *implemented 2026-08-22 (`3fd4c9b`)*: TWO-WAY
   mirrored folder (Settings → "Finder Sync"). Local drops auto-upload
   (FSEvents, debounced); cloud adds materialize within ~30 s (snapshot-
   reconciling poller); same-size adoptions pair silently; conflicts LWW by
   mtime; local edits replace the cloud copy (trash→upload→deleteForever with
   failure restore). v1 does NOT propagate deletions either direction; flat
   scope (no subfolders); manual QA in TESTING.md.
4. **Touch ID for Private Vault** — ✅ *implemented 2026-08-22 (`938c8cb`)*:
   LAContext biometrics-only prompt (no system-passcode fallback; the app PIN
   screen is the fallback) on the lock screen's enter phase with a one-shot
   auto-prompt; success flips the same unlock flag + clears fail backoff;
   create/confirm/recover stay PIN-only (they derive crypto material).
   Settings "Private Vault" toggle, sensor-gated.
5. **Casting/AirPlay + PiP** — AirPlay via AVRouting/mpv output options; PiP as
   floating always-on-top mini window.
6. **Storage dashboard** — Settings page: usage by type/folder, cache + TDLib
   store sizes, largest files.
7. **Duplicate finder UI** — rootHash grouping → review/merge sheet.
8. **Version history** (existing item 18) + **bulk export** (item 19) — as scoped.
9. **Shared-page upgrades** — importer visibility, re-share controls, activity.
10. **Smart search** — Vision OCR index for images; Whisper-local transcripts
    for audio/video; semantic query box. LAST (heaviest).

Deferred by decision: FileProvider native mount (messy; revisit post-iOS),
iOS companion (FIRST task once feature-complete), distribution/licensing
(feature-complete milestone, see plan above).

### Wave 2 kickoff notes (2026-08-22, for item 1 Subtitles — executed same day)
Existing hooks confirmed: MPVController has track-list enumeration
(MPVVideoView:1269+) + selectTrack plumbing (both headless & view paths) —
subtitle TRACKS already surface if present in-container. Missing pieces:
(a) sidecar upload: reuse thumbnail-sidecar pattern (ChunkCaption kindSidecar)
    when user picks a .srt/.ass next to a video, or auto-detect same-stem file;
(b) catalog linkage column or reuse thumb-style linkage on ObjectRecord;
(c) at playback start: if sidecar exists → materialize to scratch + mpv command
    "sub-add <path> auto" before/after loadfile; expose in existing track picker.
Test plan: sidecar round-trip caption codec test + play-with-subs manual check.

All three pieces shipped as designed (kindSidecar became `kindSub`; linkage =
JSON column v30; materialize-to-scratch + queued sub-add). Remaining: the
play-with-subs manual check by the user; auto-detect at upload time parked.
