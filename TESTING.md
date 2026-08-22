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

## Wave 2 · Item 7 — Duplicate finder — `839e62f` (2026-08-22)

**Implemented:** All Files → right-click empty area → "Find Duplicates…".
A review sheet groups every file pair/set sharing identical content (SHA-256
rootHash) and shows: set count + total reclaimable bytes, per-set rows with
location and add-date, a radio keep-selection (oldest copy pre-selected), and
a one-tap "Keep 1 · Delete N (save X)" button. Deletion runs through the full
deleteForever path — channel messages, backup mirror, share revocation,
tombstones, fresh checkpoint. Trash/hashless/folders/in-flight uploads never
group; archived/private copies do.

**Automated tests:** `duplicateFinderGroupsByRootHash` (grouping, oldest-first
keep candidates, wasted-bytes math, selection overrides),
`duplicateFinderExclusions` (singletons, trash, hashless, folders, uploading).

### Manual QA checklist

- [ ] All Files → right-click background → "Find Duplicates…" opens the review sheet.
- [ ] Upload the same file twice into different folders → both appear as one 2-copy set with correct locations.
- [ ] The OLDEST copy is pre-selected as "keep" (checkmark filled).
- [ ] Selecting the other copy moves the checkmark and updates the "(save X)" amount.
- [ ] "Keep 1 · Delete N" → copies disappear from the grid, one remains playable; sheet shows the cleaned-up count.
- [ ] After cleanup, re-open Find Duplicates → that set is gone.
- [ ] A vault with no duplicates shows the "No duplicates found" state.
- [ ] Deleting a duplicate that had an active share link → the link stops working (share dies with the file).

---


## Wave 2 · Item 6 — Storage dashboard — `cd3cd5e` (2026-08-22)

**Implemented:** Settings → new "Storage Dashboard" card between Vault Usage
and Local Storage. Two lists, live from the catalog:
- **Top Folders** (up to 6): each folder's RECURSIVE subtree bytes — a parent
  shows its whole tree's weight — with a mini usage bar + share-of-vault %.
- **Largest Files** (up to 6): heaviest files anywhere in the vault.
Trashed and deleted objects never count; archived/private files do (they hold
real vault bytes). Cycle-safe against corrupted parent graphs. The by-type
breakdown (Images/Videos/Audio/Documents/Other) already lived in "Vault
Usage", and cache/TDLib-store sizes in "Local Storage" — the dashboard
completes the picture.

**Automated tests:** `storageDashboardRecursiveFolderSizes` (subtree sums,
largest-files ordering, trash exclusion),
`storageDashboardCycleSafe` (A↔B parent cycle tolerated).

### Manual QA checklist

- [ ] Settings → Storage Dashboard shows your top folders sorted by size, biggest first.
- [ ] A folder containing subfolders shows the COMBINED size (parent = whole tree).
- [ ] Mini bars roughly match each folder's share; percentages sum sensibly (~100% across all folders+root files).
- [ ] Largest Files list matches reality (biggest videos first).
- [ ] Trash a large file → its bytes vanish from both lists after the catalog refreshes.
- [ ] Numbers agree with the existing "Vault Usage → Cloud Storage Used" total.

---


## Wave 2 · Item 5 — Casting/AirPlay + Picture-in-Picture — `548816c` (2026-08-22)

**Implemented:** Two pieces, scoped honestly for an mpv-only app (AVKit is
banned):
1. **PiP** — the theater's PiP button (or chevron minimize) floats the live
   video into an always-on-top mini panel (bottom-right, draggable, survives
   Spaces/app switches) and CLOSES THE THEATER — the panel is where playback
   lives. Full traffic lights: RED = stop, YELLOW = greyed out, GREEN =
   seamless expand back into the theater (the live layer is ADOPTED by the
   fresh theater view — same mpv core, zero restart/buffering). Hover shows a
   play/pause strip. Double-clicking the floating file's tile in Cascade also
   expands seamlessly; playing a DIFFERENT video retires the panel cleanly.
2. **Audio output picker** — a hi-fi-speaker button in the player's pill row
   lists every endpoint mpv sees (built-in speakers, AirPlay speakers when
   connected, headphones, HDMI, USB DACs); selecting one switches output LIVE
   during playback. This is the practical "casting" story: AirPlay AUDIO via
   device selection; AirPlay VIDEO happens through macOS system Screen
   Mirroring (true AirPlay video routing needs AVKit, which is banned).
No automated tests — pure window/AppKit mechanics, untestable headless. The
manual checklist below is the verification.

### Manual QA checklist

- [ ] Play a video → click PiP (top bar button or chevron minimize) → the THEATER CLOSES and a small floating panel appears bottom-right; playback never stutters or restarts.
- [ ] Hover over the panel → control strip fades in: play/pause works; the expand button (fullscreen arrows) reopens the theater — playback RESUMES at the position where the panel left off (brief buffering while the stream re-opens is expected).
- [ ] Drag the panel anywhere; open another app over Cascade → panel stays on top; switch Spaces → follows and keeps playing.
- [ ] With PiP active, play a DIFFERENT video from the grid → the panel retires cleanly and the new video plays in the theater (no frozen orphan panel).
- [ ] Click the panel's close (X) traffic light with no theater open → playback stops entirely, panel gone (no zombie audio).
- [ ] Fullscreen player: the PiP button is hidden there; entering fullscreen while PiP is active is refused until PiP exits.
- [ ] Output picker: click the hi-fi speaker button in the pill row (next to waveform) → popover lists "auto" + devices; current one has a checkmark.
- [ ] Connect an AirPlay speaker (or Bluetooth headphones), reopen the popover → it appears in the list; select it → sound moves there instantly mid-video; switch back to built-in.
- [ ] Subtitles still work in PiP (sidecar subs render in the floating picture).
- [ ] (Optional) Enable macOS Screen Mirroring to an Apple TV → the floating video mirrors (system-level AirPlay video).

---


## Wave 2 · Item 4 — Touch ID / Face ID vault unlock — `938c8cb` (2026-08-22)

**Implemented:** Settings → new "Private Vault" card (only shown when the Mac
has a sensor) → "Touch ID Unlock" toggle. When enabled, the Private Vault lock
screen shows an "Unlock with Touch ID" button and auto-prompts ONCE when it
appears; a successful match flips the exact same unlock flag as the PIN and
clears any failed-attempt backoff. The PIN remains fully in charge: PIN
creation/confirm/recovery always need literal digits, wrong biometrics fall
back to the PIN with a message, and disabling the toggle restores the
PIN-only behavior. Face ID Macs get "Face ID" labels + the required usage
description.

**Automated tests:** `biometricEligibilityGate` (enabled × PIN-exists ×
sensor-present matrix, toggle persistence). The system prompt itself cannot be
automated — manual QA below is essential.

### Manual QA checklist

- [ ] Settings shows the "Private Vault" card with "Touch ID Unlock" (on a Touch ID Mac).
- [ ] Toggle it ON, go to the Private Vault page after relaunching the app (lock state resets each launch) → the system Touch ID prompt appears automatically once.
- [ ] Matching your finger → vault opens instantly (same crossfade as PIN unlock).
- [ ] Lock Now from the page context menu → return → prompt re-offers; this time CANCEL it → a message suggests entering the PIN, and typing the PIN still unlocks normally.
- [ ] Toggle OFF → the lock screen shows NO biometric button at all (pure PIN, exactly like before).
- [ ] Enter a wrong PIN 3+ times to trigger backoff, then use Touch ID → success clears the wait ("Too many attempts" gone).
- [ ] PIN creation on a fresh vault NEVER offers biometrics until a PIN exists.
- [ ] Relaunch → toggle state persisted.

---

## Wave 2 · Item 3 — Finder drop-zone sync (two-way mirror) — `3fd4c9b` (2026-08-22)

**Implemented:** Settings → "Finder Sync" card. Pick a Mac folder + a cloud
destination (any vault folder or root), flip the toggle on: new files dropped
into the Finder folder upload automatically; cloud files added from anywhere
(other device, phone, share import) materialize in the Finder folder within
~30 s or immediately on local changes. Same-named identical files pair
silently; genuine conflicts resolve last-writer-wins by modification time;
local edits of already-synced files replace the cloud copy. Deletions are NOT
propagated in v1 either direction (a removed file just un-pairs). Hidden and
partial files (.DS_Store, .crdownload, ~$ Office locks…) are ignored. Status
dot + last-event line live in the card.

**Automated tests:** `mirrorStateTableRoundTrip` (DB v32 CRUD),
`mirrorDecisionMatrix` (13 decision branches incl. both LWW orders),
`mirrorNameFilter` (hidden/partial exclusion).

### Manual QA checklist

- [ ] Settings → Finder Sync → toggle ON with no folder chosen → folder picker opens.
- [ ] Choose (or create) an empty folder like ~/CascadeMirror, leave destination "Vault Root".
- [ ] Status row shows a green dot once watching.
- [ ] Drag 2–3 files into the folder in Finder → transfer cards appear; files show up in All Files in the app.
- [ ] In the app, upload a small file into any folder (or copy one between folders into the destination) → it appears in the Finder folder within ~30 s.
- [ ] Copy a file that ALREADY exists identically in the destination → it pairs without a duplicate upload ("file (1).ext" never appears).
- [ ] Edit a synced file locally (e.g. append text to a .txt) → after the change settles, the cloud copy updates (old version replaced; name unchanged).
- [ ] Change a file's content from another device/session → the Finder folder copy updates to the newer content.
- [ ] Delete a file from the Finder folder → its cloud copy REMAINS (v1 skips delete propagation); the pin/badge pairing silently drops.
- [ ] Save a file mid-write (e.g. large download into the folder) → no partial/temporary file gets uploaded (watch Transfers for no ".crdownload" entries).
- [ ] Toggle OFF → green dot disappears; files stay on disk and in the cloud untouched. Toggle back ON → sync resumes.
- [ ] Restart the app (still enabled) → watcher resumes automatically at launch.

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
