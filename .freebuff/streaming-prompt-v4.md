# Streaming pipeline review request — encrypted byte-range streaming over TDLib (post-fix audit)

You previously consulted on this problem (the "per-slice re-negotiation fragility"
analysis). We implemented fixes across four rounds, the user has live-verified
smooth playback and seeking, and we now want a **critical review of the final
design**: remaining failure modes, race conditions, and anything smarter we
missed. Please be adversarial — tell us what will break.

## Context (self-contained)

Native macOS SwiftUI app ("Cascade") that turns a Telegram account into a private
cloud drive. Files are split into ~128 MB chunk documents uploaded to a private
Telegram channel. Playback is **mpv only** (bundled libmpv; AVFoundation is banned
from the codebase) fed by a loopback HTTP/1.1 byte-range server
(`VaultStreamServer`, Network.framework, 127.0.0.1 only). mpv issues normal HTTP
Range requests; it typically opens ONE large sequential range for playback plus
SHORT probe ranges (moov/tail) — i.e., 2+ concurrent range streams per file.

**Encryption layout** (zero-knowledge phase): each 1 MiB plaintext slice is sealed
with AES-GCM using a per-slice key `HKDF(objectKey, "cascade-slice-v1:", index)`
where index is the FILE-WIDE slice index → sealed slice = 1 MiB + 28 B tag. Chunks
are sequences of sealed slices; non-final chunks are exact multiples of the sealed
slice size (verified byte-perfect on real files). GCM authenticates every slice at
stream time — corruption fails loudly or not at all.

**TDLib facts that constrain everything:**
- `downloadFile(fileId, offset, limit, priority, synchronous: true)` returns when
  the requested range is written into TDLib's persistent local partial file for
  that fileId (ranges land at their ORIGINAL offsets — sparse file).
- A new downloadFile call for the same fileId SUPERSEDES the in-flight one → all
  range requests for one chunk must be serialized.
- Observed: TDLib keeps downloading the whole 128 MB chunk in the background after
  our ranged request returns; its local copy persists across launches, so repeat
  fetches of cached ranges complete in 2–14 ms from disk.
- Telegram-side throttling is explicitly OUT OF SCOPE per product decision.

## The original failure

Encrypted streaming buffered permanently after ~1 minute while plaintext streaming
(8×1 MiB batched fetches) was rock solid. Root causes found (four rounds):

### Round 1 (`473c940`)
1. **Retry handler wiped the whole object's RAM cache on any transient error**
   (`sliceCache.removeAll(for:)` inside the catch) — one hiccup discarded megabytes
   of buffered playback. Removed; retries now never evict.
2. **No read-ahead on the encrypted path** — one sealed slice per round trip on the
   serve path. Added background read-ahead runs (below).
3. Boundary binary search had been flipped the wrong way (`<` instead of `<=`);
   boundary slices mapped one chunk early with localIndex past-the-end →
   limit=0 retry storms. Fixed + unit test.

### Round 2 (`d6b395d`)
4. **Layout store wiped ALL objects' state (fileIds, fetcher chains) when 8 layouts
   accumulated** — background probes build layouts during playback, so the wipe hit
   the PLAYING file mid-stream; new fetches then ran CONCURRENTLY with the abandoned
   chain on the same fileId → supersede clobbering → minutes-long total stall
   (telemetry: cache pinned at 0 s for ~4 min). Fixed with an LRU layout store
   (cap 16) that NEVER evicts the most-recently-touched object; recency is touched
   per served slice; eviction cancels victims' chains/runs.
5. Read-ahead loop made self-healing: backoff 0.3 s doubling to 5 s cap, keeps
   trying until window filled or cancelled (re-arm used to depend on successful
   serves, which stop during a stall).
6. Screen-recording TCC prompt fixed via CGPreflightScreenCaptureAccess preflight.

### Round 3 (`caa4873`) — the deadlock round
User test passed smoothly BUT the new stream log exposed that the prefetcher had
deadlocked: **1623 run starts vs 99 completed batches**, every slice served as an
individual fetch. Cause: single-run design + mpv's second (tail-probe) stream —
main (~slice 205) and probe (~484) each saw the other's run as "not covering me"
and cancelled+restarted it every ~0.6 s (a backward-jump restart condition made it
worse). Fix:
- Up to **3 concurrent runs per object**; spawn only when no live run SPANS the
  needed window: `r.start <= start+B && r.end >= start && r.head+B >= start`
  (or fully-filled `r.head >= start+W`). At capacity replace the OLDEST span so a
  tail probe can never starve the playhead run. Backward movement triggers nothing.
- CancellationError is rethrown immediately by the retry wrapper instead of being
  retried 3×.

### Round 4 (`e39b553`) — sequential-access batching
Log showed linear playback still did 1 round trip PER SLICE: mpv's huge range
requests walk slices sequentially through the server's AsyncThrowingStream, each an
individual downloadFile (fine off TDLib's disk cache at 2–14 ms/slice; fragile on a
cold network). Fix: per-object `lastServedSlice` — if the requested slice directly
continues the previous serve, the serve path itself fetches an **8-sealed-slice
batch** (one round trip, decrypt each piece with its file-wide index, cache all);
the first slice after any jump stays single-slice so startup/seek latency is
unchanged.

## Final architecture (Swift, actor-chained fetchers)

```
mpv ──HTTP Range──▶ VaultStreamServer (loopback)
   plaintextSliceStream(start,length): yields 1 MiB slices sequentially
     └─ plaintextSlice(N):
          SliceCache hit? → return                (LRU 128 × 1 MiB, global across objects)
          miss:
            sequential = lastServed[N-1]          (per-object)
            batch = sequential ? 8 : 1            (one TDLib round trip, prio 32)
            fetchWithRetry(chain, off, len):      ≤3 attempts, 30 s timeout each,
                                                  cancel chain between attempts,
                                                  CancellationError → rethrow
            AES-GCM open each piece (index-keyed) → SliceCache.put
            ensureReadAhead(N + batch - 1)
ensureReadAhead(P):
    scan first uncached slice in (P, P+48]; none → return
    covered iff ∃ live run: head ≥ start+48
       or (start ≤ start_scan+8 && end ≥ start_scan && head+8 ≥ start_scan)
    else spawn run [firstUncached … P+48]           (max 3/object; oldest replaced)
readAheadLoop(run):
    while index ≤ end ∧ ¬cancelled:
      cached? advance; else batch-of-8 fetch (prio 8) → decrypt → cache
      failures: backoff 0.3→5 s, RETRY FOREVER until filled/cancelled
invalidatePlayback(obj): cancel runs + fetcher chains + TDLib cancelDownload per fileId;
                         clear slice-cache entries, lastServed, layout recency entry
ObjectFetcher (actor per object×chunk): chains Tasks serially (previous.value awaited
                                        before next fetch) — enforces TDLib's
                                        one-download-per-fileId rule
```

## Verification evidence

- Two cold-cache full playthroughs + 4 s / 1 min / 30 s seeks: zero buffering, zero
  frame drops (mpv telemetry vfps steady 24.0, mistimed/voDrop/decDrop/drop = 0),
  seeks clean, startup fast.
- Stream log after round 3/4: 0 errors/timeouts; multi-run refill proven (11 windows
  chain-filled a 485-slice file in 2.7 s post-cache-clear); run churn gone (37
  starts vs 1623 during the deadlock).
- Upload-side integrity independently verified: chunk sizes match the sealed-slice
  grid exactly; Σ plaintext == object.size.

## Questions for you

1. **Remaining races/failure modes** you can find in this design? Specifically
   interested in: concurrent streams sharing `lastServedSlice` (sequential detection
   flicker), LRU thrash between the 48-slice windows and mpv's own readahead under
   the 128-entry cap, completed-but-uncancelled runs lingering in the coverage set,
   defer-based lastServed update ordering under task cancellation.
2. **Is the span-overlap coverage logic sound**, or is there a cleaner canonical
   pattern for "N producers keeping ahead of K consumers at arbitrary positions"?
3. **Smarter TDLib patterns we might be missing**: given TDLib continues pulling the
   whole chunk after a ranged request anyway, is there a better model than
   request/response batching — e.g., issuing one low-priority whole-chunk download
   and harvesting `updateFile` progress events / reading the sparse local file as it
   grows? Any experience with TDLib media streaming defaults worth copying?
4. **Memory sanity**: 128 MiB slice LRU + up to 3×48-slice windows on macOS desktop
   — reasonable, or should windows shrink/cancel under pressure?
5. Anything about the **actor-chain serialization** (await previous Task.value) that
   can leak tasks, reorder under cancellation, or deadlock?

Constraints for any suggestion: mpv fixed (can't modify), no AVFoundation ever,
must keep startup ≤1 round trip, must stay correct against supersede semantics.
