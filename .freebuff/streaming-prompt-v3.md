## Streaming buffering — encrypted video path breaks after ~1 minute

### What works
- Plaintext streaming with 8-slice batching: rock solid
- Cached playback: perfect
- Initial stream startup (1-2 seconds): fine
- Volume controls: fixed (item 134 in HANDOVER.md)

### What's broken
- Encrypted video streaming starts fine, plays ~1 minute, then stops and buffers permanently
- Fresh cache purge works but isn't perfectly smooth
- Single-slice encrypted fetch works initially but can't sustain throughput
- 8-slice batching on encrypted path makes startup slow (10+ seconds)
- Continuous download model (`downloadFile(limit:0)` + polling) didn't work

### Architecture
- mpv plays via loopback HTTP server (`VaultStreamServer`)
- `VideoStreamingEngine.plaintextSlice()` fetches 1 MB slices from TDLib
- `ObjectFetcher` actor serializes per-chunk (one request at a time)
- `SliceCache`: 48 MB LRU in RAM
- `fetchWithRetry`: 30s timeout, chain cancellation on failure
- Files encrypted: each 1 MB plaintext → 1 MB + 28 byte sealed slice

### Root cause analysis (from Claude)
TDLib's `downloadFile(limit=N)` auto-cancels after N bytes. Each slice (1 MB) is a brand-new download negotiation with Telegram's servers — not a continuation of a streaming connection. After 60-150 of these per minute, one unlucky network jitter kills the buffer. The plaintext path with 8-slice batching works because one fetch covers 6 seconds of playback, giving the SliceCache a multi-second safety margin.

### What was tried
1. 8-slice batching on encrypted path → slow startup (`synchronous: true` blocks)
2. Continuous download (`downloadFile(limit:0)`) → `downloadedSize` doesn't track sparse files accurately
3. Restored ObjectFetcher + fetchWithRetry → still buffers
4. Binary search fix (`<=` → `<`) → fixed retry storms but not buffering

### Key constraint
The old working version (Aug 19 backup) was **plaintext only** — no encryption, no sealed slices. 8-slice batching worked perfectly. The encrypted path added sealed slices (1 MB + 28 bytes) and per-slice decryption, which is the new bottleneck.

### What we need
A way to sustain ~1.25 MB/s throughput on the encrypted path without either:
- Slow startup (batching blocks on `synchronous: true`)
- Fragile per-slice re-negotiation (single slice = one TDLib round-trip per MB)

Possible directions:
- Can we batch sealed slices WITHOUT `synchronous: true`? (start download, poll for availability, read when ready)
- Can we use TDLib's `updateFile` push notifications instead of polling?
- Can we pre-fetch the next N slices in a background task while the current slice is being served?
- Is there a TDLib API that keeps a connection open and streams bytes without auto-cancel?

### Files
- `Engine/VideoStreamingEngine.swift` — `plaintextSlice()`, `ObjectFetcher`, `SliceCache`
- `Telegram/TelegramClient.swift` — `fetchRangeData()`, `downloadFile()` wrapper
- Backup: `/Users/zainulnazir/Projects/Backups/cascade-pre-rename-backup-2026-08-19.zip`

### Constraints
- macOS SwiftUI app, NO AVFoundation
- mpv is the only media engine (pre-built framework, can't modify)
- Must work with encrypted files (AES-GCM sealed slices)
- Must stream smoothly without buffering interruptions
