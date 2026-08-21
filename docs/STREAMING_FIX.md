# Streaming Fix — Encrypted Video Buffering (2026-08-21)

> Case file for the encrypted-streaming buffering problem: symptoms, investigation,
> root causes, fixes, and verification. Companion to `docs/PLAYER.md` (media pipeline
> reference) and HANDOVER items 136–141.
> Final state: fixed across three rounds — commits `473c940`, `d6b395d`, `caa4873`.

---

## 1. The problem

**Symptom (2026-08-21, after the zero-knowledge encryption phases landed):**
encrypted video streaming started fine (1–2 s to first frame), played smoothly for
about a minute, then stopped and buffered — sometimes permanently. Plaintext
streaming with 8-slice batching was rock solid by comparison; cached playback was
perfect.

**Why the encrypted path was fragile by design:**
TDLib's `downloadFile(limit:)` auto-cancels after the requested bytes. Each sealed
slice (1 MB plaintext → 1 MB + 28 B ciphertext) meant a brand-new download
negotiation with Telegram's servers — ~60–150 round trips per minute with zero
safety margin. One unlucky network jitter collapsed mpv's buffer into endless
pause-for-cache (telemetry: cache 9.4 s → 0.1 s, then a permanent trickle).

**Earlier attempts that failed (do not retry):**
- 8-slice batching on the serve path → slow startup (`synchronous: true` blocks
  until the full 8 MB is on disk before mpv sees byte one).
- Continuous download model (`downloadFile(limit:0)` + polling `downloadedSize`)
  → TDLib's `downloadedSize` doesn't track byte availability in sparse files.
- Single-slice + retry → still buffered after ~1 minute.

---

## 2. Round 1 — read-ahead prefetcher + cache-wipe bug (`473c940`)

### Root cause A: the retry handler wiped the buffer
`fetchWithRetry` called `sliceCache.removeAll(for: objectID)` on ANY transient fetch
error — evicting up to 48 MB of buffered, GCM-verified playback. One network hiccup
discarded everything mpv had, turning a blip into permanent buffering. Cached slices
were decrypted and authenticated *before* caching; they cannot be corrupted by a
later failed request. **Fix:** never wipe on transient errors; timeout-wrap every
retry attempt.

### Root cause B: no read-ahead on the encrypted path
The serve path fetched exactly one sealed slice per round trip with nothing filling
ahead of the playhead. **Fix:** background read-ahead — the serve path still fetches
ONE slice synchronously (startup stays fast: mpv gets its first byte after a single
~1 MB round trip), while a short-lived background run fills slices ahead of the
playhead using BATCHED fetches (several sealed slices per TDLib round trip). This is
the proven plaintext batching moved OFF the critical path — blocking a background
task for a few MB cannot delay startup.

Also in this round:
- `ObjectLayout.chunkAndLocalIndex` binary search: an intermediate edit had flipped
  the comparison `<` → wrong direction; a slice landing EXACTLY on a chunk boundary
  mapped one chunk early with `localIndex` one-past-the-end (`fetchLen = 0` →
  range-fetch retry storms). Correct semantics: **a boundary slice belongs to the
  NEXT chunk**, i.e. `chunkStarts[mid] <= sliceBytes`. Unit test
  `streamingSliceMappingAcrossChunks` guards this.
- `SliceCache` 48 → 128 entries; added non-LRU-perturbing `contains(_:)`.
- Carried over the prior session's volume/balance fixes (Bluetooth A2DP writes both
  per-channel volume elements) and slider drag guards.

---

## 3. Round 2 — the mid-playback state wipe (`d6b395d`)

**User report:** whole file played now (no more permanent death), first ~10 min
smooth, buffering in the second half. Plus: macOS showed a screen-recording
permission prompt when entering fullscreen.

### Telemetry evidence (`/tmp/cascade-mpv-telemetry.log`, HEVC + TrueHD session)
2390 samples bucketed per minute:

| Phase | Forward buffer | Meaning |
|---|---|---|
| min 0–10 | pegged 20 s | pipeline keeping up easily |
| min 10–15 | dips to 4–11 s | first hiccups |
| min 15–23 | stable 18–20 s | recovered |
| **min 24–28** | **pinned 0.0 s, paused continuously ~4 min** | total pipeline stall |
| min 32–39 | 0.3–9 s, stutter bursts | partial recovery |

A multi-minute TOTAL stall means requests hung/failed wholesale — not jitter.

### Root cause C: layout eviction destroyed the playing file mid-stream
`loadLayoutUncached` wiped ALL streaming state whenever 8 layouts accumulated —
including the PLAYING object's cached fileIDs and per-chunk fetchers. Background
probes (thumbnail generation, other files' stream URLs) build layouts during
playback; once the wipe fired mid-play, new fetches created a SECOND concurrent
TDLib chain on the same fileId — supersede semantics made them clobber each other →
hang/retry storms → exactly a minutes-long total stall.

**Fix:** LRU layout store (`layoutRecency`, cap 16) that NEVER evicts the
most-recently-touched object; `plaintextSlice` touches recency on every served slice
so the active playback is always protected; evicted objects' fetcher chains and
read-ahead runs are cancelled cleanly.

### Also in this round
- Prefetch made self-healing: back off (0.3 s doubling, 5 s cap) and KEEP TRYING
  instead of giving up after 3 failures (re-arm depended on successful serves,
  which stop during a stall).
- Window 24 → 48 slices (~48 MB ≈ 38 s buffer at TrueHD bitrate); batch 4 → 8;
  `fetchWithRetry` up to 3 attempts with chain-cancel between attempts.
- Screen-recording prompt fixed: `captureTheaterSnapshot` uses ScreenCaptureKit
  (`SCShareableContent`), which triggers the TCC prompt. Added a
  `CGPreflightScreenCaptureAccess()` guard — unauthorized → skip the ghost snapshot
  silently; the live-attach fallback covers the fullscreen transition.
- **Instrumentation**: `/tmp/cascade-stream.log` — layout built/evicted, serve
  misses, batch outcomes with ms timings, timeouts/errors with attempt counts,
  read-ahead lifecycle, invalidatePlayback. The unified log is unreadable on this
  machine and stdout is lost via `open`; this file is the evidence trail.

---

## 4. Round 3 — the prefetcher deadlock exposed by its own log (`caa4873`)

**User report:** "smooth and clean even after cache purge". The stream log told a
more honest story:

| Signal | Session 1 value | Interpretation |
|---|---|---|
| Read-ahead run starts | **1623** | restart churn every ~0.6 s |
| Completed batches | **99** | almost no batch survived |
| Serve misses | **793** | nearly every slice fetched individually |
| Errors | 2214 CancellationError, 204 TDLib error 1 | cancelled in-flight batches |
| Timeouts | **0** | no genuine hangs |
| Per-fetch latency | 2–14 ms | served from TDLib's local disk copy |

Playback was smooth because TDLib's persistent chunk download cache made
single-slice fetches nearly free — **despite** the prefetcher, not because of it.

### Root cause D: single-run design vs mpv's two streams
mpv opens a SECOND byte-range stream (moov/tail probe) while the main stream plays.
One run cannot cover two distant positions, and my coverage check required
`servedSlice >= run.startSlice - 2` — so main (~slice 205) and probe (~484) each saw
the other's run as "not covering me" and cancelled+restarted it. Ping-pong deadlock:
every restart killed the in-flight batch, head never advanced, condition stayed
true forever.

**Fix:**
- Up to **3 concurrent runs per object**, spawned only when no live run SPANS the
  position's needed window (`r.start <= start+B && r.end >= start && r.head+B >= start`,
  or fully-filled `r.head >= start+W`). At capacity, replace the OLDEST span — a
  tail probe can never starve the playhead's run.
- Backward movement triggers nothing: uncached backward data is served by single
  fetches until playback advances past the old window.
- `fetchWithRetry` rethrows `CancellationError` immediately instead of retrying a
  cancelled operation three times.
- `ReadAheadRun` carries its end slice for span math.

---

## 5. Final architecture

```
mpv ──HTTP byte-range──▶ VaultStreamServer (loopback)
                             │ plaintextSliceStream(start, length)
                             ▼
                     plaintextSlice(N)          ← serve path
                     ├─ SliceCache hit? return  (LRU, 128 × 1 MB)
                     ├─ miss: ONE sealed-slice fetch (prio 32, ≤3 attempts)
                     │    decrypt AES-GCM(slice key = objectKey ⊗ N)
                     ├─ ensureReadAhead(N):
                     │    spawn run [firstUncached(N+1) … N+48] only if no live
                     │    run spans it (max 3 runs; oldest replaced at capacity)
                     ▼
                     readAheadLoop              ← background
                      ├─ batches of 8 sealed slices per TDLib round trip (prio 8)
                      ├─ clamp to chunk boundary; decrypt each piece with its
                      │  file-wide slice index; cache
                      ├─ failures: backoff 0.3 s → 5 s cap, keep trying until
                      │  filled or cancelled (never give up mid-stall)
                      └─ cancelled by invalidatePlayback / seek-span replacement
```

Supporting pieces:
- **Layout store**: LRU, cap 16, playing file never evicted (recency touched per
  slice); eviction cancels victims' fetchers/runs.
- **Per-chunk `ObjectFetcher` chains**: serialize range requests per TDLib fileId
  (concurrent downloads of one file supersede each other).
- **Boundary math**: non-final chunks are exact multiples of the 1 MB slice size;
  boundary slices belong to the NEXT chunk (`<=` in the binary search).

---

## 6. Verification checklist (how we know it's right)

- Frames: mpv telemetry steady `vfps 24.0`, `mistimed/voDrop/decDrop/drop` all 0
  for entire sessions.
- Not from the app's disk cache: zero files for the object in the cache dir; all
  bytes logged through VaultStreamServer.
- Upload integrity ruled out: the tested file's chunks verified against the
  sealed-slice grid byte-perfect (chunks 0–2 = exactly 128 sealed slices each; tail
  = 100 full + partial remainder; Σ plaintext == object.size). AES-GCM authenticates
  every slice during playback — corruption would fail loudly, not slowly.
- Healthy session in `/tmp/cascade-stream.log` looks like: serve misses clustered at
  startup/seeks only; hundreds of `read-ahead batch … ms=` lines; few or no errors.

## 7. If buffering ever comes back

1. Note the timestamp of the stall.
2. Read `/tmp/cascade-stream.log` around that time:
   - `fetch TIMEOUT` storms → TDLib hang; check attempt counts.
   - Slow-but-successful `read-ahead batch … ms=…` (hundreds+) → Telegram-side
     throttling (server behavior, not a bug).
   - `serve miss` for every slice again → prefetch starvation; check run starts vs
     completed batches (the round-3 signature).
3. Correlate with `/tmp/cascade-mpv-telemetry.log` (cache trajectory, drops).
4. Old sessions are preserved (`/tmp/cascade-stream-session1.log` = the deadlocked
   one).

---

## 8. Round 4 — sequential-access batching (`e39b553`)

**User's full protocol passed**: two cold-cache complete playthroughs + 4 s /
1 min / 30 s seeks — zero buffering, zero errors/timeouts, seeks clean, and the
log showed eleven read-ahead windows chain-filling all 485 slices in 2.7 s after
a cache clear (multi-run system proven live).

**Last gap found in the log**: linear playback still fetched 1 TDLib round trip
per slice — mpv's huge byte-range requests walk slices through
`plaintextSliceStream`, each an individual `downloadFile`. TDLib's disk cache hid
it (2–14 ms/slice); on a cold network this was the original fragile pattern
resurfacing inside the fixed architecture.

**Fix**: per-object sequential detection (`lastServedSlice`) — a slice directly
continuing the previous one fetches an 8-slice batch in that same round trip;
the first slice after a jump (start/seek) stays single-slice so startup and seek
latency are unchanged. Linear playback now costs ~1 negotiation per 8 MB instead
of per 1 MB.
