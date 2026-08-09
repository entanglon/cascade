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

### 1. Parallel chunk uploads
**Why:** the single biggest speed lever. Currently one chunk uploads at a time; uploading
3–4 chunks concurrently can cut a 1 GB transfer by 60–70%. No competitor does this well.
**How:** architecture already supports it — independent chunk objects, per-chunk completion
records, per-chunk resume. Work is a concurrency limit + FLOOD_WAIT backoff in `UploadEngine`.
Respect the daily message cap and per-chat flood limits; back off on `FLOOD_WAIT_X`.

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

## Tier 2 — competitive polish

### 4. Menu bar presence + background transfers
Transfers continue when the window closes; menu bar icon shows collective progress (the
liquid FAB condensed to a small dot). Clicking opens the main window / mini transfer list.
Every serious macOS cloud app has this; its absence reads as "not production software".

### 5. Duplicate detection
Hash a file before upload; if identical content already exists, link to it instead of burning
a daily-message slot and channel space. Saves the user's quota and keeps the channel clean.
Pairs well with the existing VaultRepair orphan/duplicate purge.

### 6. Smart folders / saved searches
"Recently Added", "Large Files", "Videos over 1 GB", "Favorites in Photos" — saved-search
predicates like macOS smart folders. Cheap to build on the existing sort/filter machinery.

### 7. Storage analytics
A "Storage" screen: usage per file type and per folder, top-10 files, daily message usage with
a warning before approaching flood limits. All the data already exists; this is presentation.

---

## Tier 3 — ambitious / fun

### 8. Finder integration
Right-click any file in Finder → "Upload to xCloud" via a Share / Finder-Sync extension.
High fame-per-effort for the OSS story.

### 9. Offline pinning
Mark files "available offline" and pre-download into the LRU cache (Google-Drive-pin style)
so they open instantly with no network.

### 10. Share links via a small bot
A Telegram bot that hands out expiring download links for individual files. Turns a private
vault into a sharing tool; strong "why this is different" story.

### 11. AI organization (hold)
Auto-tagging, similar-image grouping, face-based albums. Coolest-sounding, most expensive,
least aligned with the app's identity right now. Hold until the core is bulletproof.

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

## Recommended order (my honest top 3)

1. **Parallel chunk uploads** — speed.
2. **Folder auto-sync** — category shift (backup tool, not uploader).
3. **Vault recovery key** — trust.

Together they tell a story no Telegram-storage app tells: *fast, automatic, and safe*.
