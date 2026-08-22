# Cascade — Feature Testing Tracker

> Living checklist of shipped features: what was implemented, what the automated
> suite already covers, and the MANUAL tests Zainul should run to confirm each
> feature behaves correctly in the real app. Newest items at the TOP.
>
> How to use: after a build lands, work through the unchecked boxes of the
> newest section. Tick nothing here preemptively — a box means "verified by
> hand on the real Debug build".
>
> Automated tests run via:
> `xcodebuild test -project Cascade.xcodeproj -scheme Cascade -destination 'platform=macOS' -only-testing:CascadeTests`

---

## Wave 2 · Item 2 — Offline pins ("Keep Downloaded") — `e1f359e` (2026-08-22)

**Implemented:** right-click any file or folder → "Keep Downloaded" (multi-select
aware; folders apply recursively). Pinning downloads every uncached target with
visible transfer cards. Pinned copies live in scratch and are exempt from cache
eviction (size cap + free-space floor) AND the launch wipe; pinned bytes don't
count toward the cache cap. Pin badges show in browser grid/list/folder cards
and Photos/Videos cells. Unpin ("Remove Download") lifts protection — the copy
ages out naturally. Undo/redo wired. The flag is device-local: pinning on one
Mac never triggers downloads on another.

**Automated tests:** `offlinePinFlagSurvivesOldSnapshots`,
`pinnedFileStemMatching` (incl. prefix-collision cases),
`deviceLocalPinStrippedFromRemoteAdoption` (remote pin stripped; local pin
survives a remote LWW win).

### Manual QA checklist

- [ ] Grid: right-click a small uncached video → "Keep Downloaded" → a transfer card appears and completes; a pin badge shows on the tile.
- [ ] The pinned file opens instantly with Wi-Fi turned OFF (offline playback from the local copy).
- [ ] List view: pinned row shows the trailing pin badge; folder rows show the pin glyph next to the ellipsis menu.
- [ ] Photos/Videos pages: pinned cells show the small accent pin badge (when not selected).
- [ ] Right-click the pinned file again → label reads "Remove Download"; clicking it clears the badge.
- [ ] Pin a FOLDER containing several files → every descendant gets a card + badge (folder itself shows the pin glyph).
- [ ] Relaunch the app → pinned files still open offline (launch wipe spared them); unpinned scratch files are gone (normal behavior).
- [ ] Set Settings → Cache Limit to the smallest value and trigger some downloads → pinned files are NOT evicted while unpinned ones are.
- [ ] ⌘Z right after pinning → badges disappear (undo), ⌘⇧Z re-pins (redo).
- [ ] (Two Macs, optional) Pin on Mac A → Mac B does NOT start downloading that file after its next sync.

---

## Wave 2 · Item 1 — Sidecar subtitles — `34db68b` (2026-08-22)

**Implemented:** right-click any video → "Add Subtitles…" → pick one or more
`.srt/.ass/.ssa/.vtt/.sub` files. Each subtitle is stored as its own encrypted
(or plain, matching the video) vault document linked to the video, mirrored to
the backup channel, and synced to other devices through snapshots. At playback
the subs are downloaded to scratch and loaded into mpv automatically — the
first one selected, extras attached unselected. The player's captions-bubble
menu lists them alongside embedded tracks plus a new "Off" row. Re-adding a
same-named subtitle replaces it; a "Subtitles (n)" submenu removes entries.
Deleting the video deletes its subtitles everywhere.

**Automated tests:** `subCaptionCodecMarksSidecarDocuments`,
`subtitleSidecarJSONRoundTripAndLegacyDecode`, `subtitleExtensionClassification`.

### Manual QA checklist

- [ ] Right-click a video in All Files → "Add Subtitles…" appears (not on non-videos).
- [ ] Pick a `.srt` whose name matches the movie (e.g. `Movie.en.srt`) → upload completes quickly (small document, visible in Transfers).
- [ ] Play the video (theater or fullscreen player) → subtitles render automatically, correct timing.
- [ ] Captions-bubble popover lists the sidecar track (named like the file, e.g. "Movie.en") WITH a checkmark, plus any embedded tracks, plus "Off".
- [ ] Click "Off" → subtitles disappear; click the track again → they return.
- [ ] Add a SECOND subtitle (different language) → plays with the FIRST still default; switch between them from the popover; ASS styling renders correctly on an `.ass` file.
- [ ] Re-add a file with the SAME name as an existing subtitle → replaces it (no duplicate entries in the "Subtitles (n)" submenu).
- [ ] Quit the app, relaunch, play again → subtitles load again (scratch was wiped; they re-download silently).
- [ ] Right-click the video → "Subtitles (n)" → click a name → it disappears from the submenu and no longer loads at playback.
- [ ] Trash → Delete Forever the video → the subtitle documents are gone from the vault channel (no orphans; check via --dump-channel if convenient).
- [ ] Videos page: context menu on a video tile also shows "Add Subtitles…".

---
