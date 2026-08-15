# xCloud — Media Playback Pipeline (mpv-only)

> Last verified: 2026-08-15 (streaming, HDR, Dolby, telemetry all checked live).
> Read this before touching anything in `Features/MPVVideoView.swift`,
> `Engine/AudioPlayerEngine.swift`, `Engine/VideoStreamingEngine.swift`,
> `Engine/VaultStreamServer.swift`, or `Engine/ThumbnailService.swift`.

## 0. The mandate (non-negotiable)

**mpv is the ONLY media engine in xCloud. AVFoundation/AVKit are REMOVED from the codebase
and must NEVER come back.**

This was a user mandate after a week of recurring incidents: the AVPlayer fallback kept
resurrecting through side doors (AVAssetResourceLoader streaming, `AVPlayerView`, thumbnail
frame extraction via `AVAssetImageGenerator`, `AVURLAsset` duration reads) and each time it
surfaced as "opens in the old/QuickTime player" or a CPU storm (AV1 thumbnails hammering
VideoToolbox, `-12430`, on multiple threads during playback).

Practical rules:

- No `import AVFoundation` / `import AVKit` anywhere in app code (verified by grep before
  every release-ish build).
- Playback of **every** container goes through mpv: cached files → local file URL; uncached
  files → the local byte-range stream server. There is no "native" player.
- Video/audio **thumbnails** come from Telegram's attached thumbnail, never local frame
  extraction. **Durations** come from mpv during playback (`duration` property), not from
  media files on disk.
- If a feature "needs" AVFoundation (frame extraction, metadata, durations), the answer is a
  Telegram thumbnail, an mpv property, or dropping the feature.

> Note: the bundled libmpv itself links AVFoundation/VideoToolbox internally (for macOS
> hardware decode). That is the engine's own dependency — allowed. The ban is on OUR code.

## 1. Architecture at a glance

```
                        ┌────────────────────────────────────────────┐
  TheaterView / Mini   │  AudioPlayerEngine (singleton)              │
  Player / grid taps   │   · decides source (cached vs stream)      │
         │             │   · owns MPVController (the ONLY player)   │
         ▼             └──────────────┬─────────────────────────────┘
  AudioPlayerEngine.play(file:)       │ cached → DownloadEngine.cacheURL(file)
                                      │ uncached → VideoStreamingEngine.mpvStreamURL()
                                      ▼
                          ┌──────────────────────────┐
                          │      MPVController       │  (libmpv, in-process)
                          │  · setupMpv() options    │
                          │  · event loop (thread)   │
                          │  · telemetry 1/s         │
                          └────────────┬─────────────┘
                         video renders │              │ audio out
                                       ▼              ▼
                          MPVLayerView          CoreAudio (ao=coreaudio)
                     (CAOpenGLLayer/CGL)         (decoded PCM or S/PDIF
                       + color pipeline           bitstream for Dolby/DTS)
                                       ▲
  uncached files only:                  │  HTTP Range requests
  VideoStreamingEngine ──► VaultStreamServer ── 127.0.0.1:<random port>/stream/<id>
        (layout, slice fetch,           │
         decrypt, SliceCache)           │  fetch+decrypt 1 MB slices
                                        ▼
                          ObjectFetcher ──► Telegram (TDLib) chunk downloads
```

## 2. Source selection (AudioPlayerEngine.play)

Order of resolution, always ending in mpv:

1. If `DownloadEngine.isCached(file)` → **local file URL** (`DownloadEngine.cacheURL`).
   `isCached` requires the cached file to be **exactly** `object.size` bytes (a partial
   file counts as NOT cached — regression test `partialCachedFileIsNotCached`).
2. Else if `VideoStreamingEngine.shared.mpvStreamURL(for:)` returns a URL → play the
   **`http://127.0.0.1:<port>/stream/<objectID>`** stream URL.
   (`mpvStreamURL` returns nil for cached files or unloadable layouts.)
3. Else → full `DownloadEngine.download`, then play the local file.

Audio-only files play headless: `MPVController.playHeadless(url:)` — same mpv core, no GL
surface.

**End-of-file auto-advance** rides mpv's `MPV_EVENT_END_FILE` (reason `MPV_END_FILE_REASON_EOF`)
→ `onEndOfFile` → `AudioPlayerEngine.skipNext()`. (Replaces the old AVPlayer periodic time
observer. If EOF fires with `MPV_END_FILE_REASON_ERROR`, `onPlaybackError` surfaces the error
UI instead.)

## 3. mpv options (setupMpv — matches the Stremio-style player, commit 98f7827)

Pre-init: `terminal=yes`, `load-scripts=no`, `load-osd-console=no`, `load-stats-overlay=no`,
`load-auto-profiles=no`, `ytdl=no`, `osc=no`, **`vd-lavc-dr=no`** (software-decoded frames
bypass mpv's DR buffer pool — prevents a stale-plane-stride assert crash on 8K AV1).

Post-init properties:

| Property | Value | Why |
|---|---|---|
| `vo` | `libmpv` | render into our CAOpenGLLayer |
| `profile` | `fast` | Stremio parity |
| `scale` | `bilinear` | cheap, smooth |
| `hwdec` | `auto` | videotoolbox for h264/hevc; AV1 falls back to software dav1d on pre-M3 |
| `video-sync` | `audio` | never drift from audio |
| `cache` / `cache-secs` | `yes` / `20` | 20 s readahead |
| `demuxer-readahead-secs` | `20` | streaming friendliness |
| `demuxer-max-bytes` / `demuxer-max-back-bytes` | `104857600` / `26214400` | bounded memory |
| `framedrop` | `vo` | drop at render, not decode |
| `audio-fallback-to-null` | `yes` | video with no audio still plays |
| `audio-spdif` + `audio-exclusive` | `ac3,eac3,truehd,dts` / `yes` | **only when user enables "Audio passthrough"** (`xc.audioPassthrough`) |
| log level | `warn` | `"v"` floods the log with per-frame lines and adds thread load |

## 4. Streaming pipeline (uncached playback)

- **`VaultStreamServer`** — loopback-only HTTP/1.1 (`NWListener` bound to 127.0.0.1,
  random port), keep-alive connection pooling (mpv reuses connections; closing per-request
  churns sockets). Serves `GET /stream/<objectID>` with `Range:` support, `206 Partial
  Content`, `Accept-Ranges: bytes`, `Cache-Control: no-store` (decrypted plaintext never
  touches disk). Started lazily on first playback, or at launch via the `--stream-server`
  debug hook.
- **`VideoStreamingEngine`** — maps a file offset to `(chunk, slice)` and fetches/decrypts
  on demand. Layout invariant: chunk sizes are multiples of the 1 MB slice (except the final
  chunk), so no slice straddles two chunks.
  - Public files: range maps 1:1.
  - Private files: each 1 MB plaintext slice is AES-GCM sealed to `slice + 28` bytes
    (12 B nonce + 16 B tag) with a per-chunk slice index. GCM can't open mid-box, so a fetch
    always pulls the FULL sealed slice from its boundary, then trims in memory.
- **`ObjectFetcher`** — per-object serialized TDLib file downloads with retry; feeds the
  slice pipeline. **`SliceCache`** dedupes overlapping re-reads around seeks.
- mpv/FFmpeg demuxes **any container** (mkv, webm, avi, ts, flac, ogg...) from the byte-range
  HTTP source and seeks via the same Range requests.

Verified live 2026-08-15 (real vault, House of the Dragon, 1,098,879,765 B, uncached):

```
$ curl -s -r 0-63 http://127.0.0.1:<port>/stream/<id> -D -
HTTP/1.1 206 Partial Content
Accept-Ranges: bytes
Content-Range: bytes 0-63/1098879765
Cache-Control: no-store
payload: 0000 001c 6674 7970 6973 6f6d ...   (valid "ftyp isom" MP4 header — decrypted!)
$ curl -s -r 536870912-536870943 ...           → exact 32 bytes at 512 MB (mid-file seek OK)
$ curl -s -r 1098879761-1098879764 ...         → exact tail bytes ("ARBG" — file's true end)
```

## 5. HDR / color pipeline (applyColorPipeline)

Mirrors IINA. EDR is **off by default**; the pipeline observes `video-params/gamma` +
`video-params/primaries` (via `MPV_FORMAT_STRING` property events) and decides:

- **SDR content, or HDR content on an SDR display** → layer pinned to sRGB, mpv `target-*`
  options reset to `auto` → **mpv tone-maps itself**. Log line: `SDR pipeline active`.
  (This is the user's case: their file is PQ/BT.2020 on an SDR MacBook Air — verified live.)
- **Real HDR (PQ on BT.2020/P3) on an EDR-capable display** → layer switches to
  `itur_2100_PQ`/`displayP3_PQ`, EDR on, mpv gets `target-trc=pq`, `target-prim=...`,
  `target-peak=<nits>`, `tone-mapping=clip`. Log line: `HDR/EDR active`.

Render surface: **8-bit** backbuffer on SDR displays; the float (RGBA16F) backbuffer +
`extendedSRGB` window colorspace are applied **only on EDR displays** (the unconditional
float path was a regression — pure bandwidth overhead on SDR, plus a transient
`INVALID_FRAMEBUFFER_OPERATION` at VO start). `applyColorPipeline` is guarded by a pipeline
key so it only reconfigures when the decided pipeline actually changes (it used to fire
4× in one tick at load, forcing repeated VO/GPU reconfigs).

Dolby Vision note: files are demuxed and the **HDR10 base layer** is decoded + tone-mapped
(this is what the "8K HDR Dolby Vision" sample actually is — AV1 10-bit PQ). The DV
enhancement layer is not applied, which matches every software player including Stremio.

## 6. Audio & Dolby

- Default: mpv decodes via FFmpeg → PCM → `ao=coreaudio`. FFmpeg (Lavc 61.x bundled) includes
  **AC-3, E-AC-3 (Dolby Digital Plus, the Atmos carrier), TrueHD (lossless Atmos), and DTS**
  decoders — verified 2026-08-15 by playing generated AC-3 and E-AC-3 files through the app's
  exact bundled libmpv (harness below): both reached `finished playback, success (reason 0)`.
- Optional passthrough: Settings → "Audio passthrough" (`xc.audioPassthrough`) sets
  `audio-spdif=ac3,eac3,truehd,dts` + `audio-exclusive=yes`, bitstreaming raw Dolby/DTS to an
  HDMI receiver/soundbar. mpv falls back to decoding when the output can't take the bitstream.

## 7. Thumbnails (AVFoundation-free)

- **Photos** — generated locally: `ThumbnailCrop.subjectSquare` (Vision: largest face →
  saliency → center crop, EXIF upright first), stored `thumbs/<id>.jpg/.png`.
- **Videos — frame extraction via direct FFmpeg**
  (`Engine/VideoFrameExtractor.swift`): the bundled `Libavformat`/`Libavcodec`/
  `Libswscale` modules decode a representative frame headlessly — no window, no GL, no
  zimg, no image encoders needed. Seeks BACKWARD to keyframe ≤ target, decodes forward to
  the first frame ≥ target, scores 5 candidate positions (8%→60% of duration) by
  subsampled luma variance (a black opening can never win), converts the winner via
  `sws_scale` to RGBA with `sws_setColorspaceDetails` from the source's real
  colorspace/range, applies rotation (`AV_FRAME_DATA_DISPLAYMATRIX` on FFmpeg 7), and
  encodes via `NSBitmapImageRep`. This replaced the old QuickLook generator, which always
  picked the FIRST frame (black for videos that open with a fade/black) and had no time
  API. Never attempt a windowed/mpv-render capture — automation launches get zero
  composited WindowServer surfaces (`GL_FRAMEBUFFER_UNDEFINED`), the SW renderer is
  zimg-only (not bundled), and the bundled FFmpeg has no image encoders.
  **Sources**: cached videos extract from the local cache file; NEVER-downloaded videos
  (they stream — e.g. House of the Dragon) extract through the loopback stream URL
  (`http://127.0.0.1:<port>/stream/<id>`) — `avformat_open_input` accepts HTTP and
  seeks via byte-range requests, so a thumbnail costs a few MB of range fetches, not a
  whole-file download. Verified with a C harness against the bundled libs: HTTP open,
  seek, decode all work and produce byte-identical scoring to local files.
- **Audio** — previews come from **Telegram's attached thumbnail**
  (`fetchFromTelegram` → `thumbs/<id>-tg.jpg`), which works for any codec with zero CPU
  cost.
- **HDR caveat**: swscale converts 10-bit YUV→RGBA but does NOT tone-map PQ/HLG — HDR
  thumbs can look dim/flat but are never black; correct primaries/range via
  `sws_setColorspaceDetails` is enough for a thumbnail (full tone-mapping needs zimg,
  which isn't bundled).
- Last-resort thumbnail-only download applies to **photos only** (a multi-GB video is never
  downloaded whole just for a preview). Single-flight (`generatingIDs`) + 600 s failure
  backoff (`failedIDs`).
- Warm-up pass 3 s after post-auth setup walks every ready, non-private media object missing
  a thumbnail (videos last); `.xcThumbnailReady` bumps grid `thumbnailVersion` so thumbs pop
  in live.

### Background playback (mini player)

- **Audio** has always played headless (`MPVController.playHeadless`, `vo=null`), so it
  survives theater close. **Video** is view-bound (the GL surface lives in the theater's
  `MPVVideoView`), and dismantling the theater destroys the mpv core — so closing used to
  kill video playback.
- On theater close while a video plays, `AudioPlayerEngine.continueInBackground()` hands
  the exact `timePos` to a fresh headless mpv instance (audio keeps playing in the mini
  player); `playInBackground(file:in:)` starts a video straight into the background from
  the minimize button when paused. Expanding the mini player runs
  `MPVController.takeHeadlessHandoff()` — the new view-side core loads the same URL via
  `MPVLayerView.loadFile(url, startAt:)` and seeks to the position once
  `MPV_EVENT_FILE_LOADED` fires (mpv drops pre-load seeks). The X button still stops
  playback intentionally; paused+ESC still stops.

## 8. Telemetry & debugging

- Per-second line (event loop): written to stdout, the unified log
  (`subsystem com.xcloud.app`, category `mpv`), AND `/tmp/xcloud-mpv-telemetry.log`:

  ```
  [MPV TELEMETRY] vcodec:av01 acodec:aac hwdec:no cache:20.0s paused4cache:false
                  | mistimed:0 voDrop:0 decDrop:0 drop:0 vfps:60.0
  ```

  Fields: `vcodec`/`acodec` (top-level mpv properties — `video-params/codec` reads
  unavailable on this build), `hwdec` (`hwdec-current`: `no` = software/dav1d, expected for
  AV1 on M2), `cache` (demuxer-cache-duration), `paused4cache`, and the drop counters.
  **`mistimed/voDrop/decDrop/drop` all 0 at a steady 60 vfps = the player is perfect**; if a
  video ever lags again, this file is the first place to look (the previous "lag" was CPU
  contention from AVFoundation thumbnail storms — now impossible, but the file proves it).
- Debug hooks (`AppState.bootstrap`): `--stream-server` (start server, stay running —
  exercise with curl / the mpv harness), `--cache-video <id>`, `--chunk-info <id>`,
  `--dump-channel`, `--dump-chat <chatID>`.
- **mpv harness** — reproduce playback with the app's EXACT bundled libmpv/FFmpeg, no UI:

  ```bash
  XC=~/Projects/xCloud/LocalPackages/LocalMPVKit/XCFrameworks
  clang -O2 -I"$XC/Libmpv.xcframework/macos-arm64_x86_64/Libmpv.framework/Versions/A/Headers" \
    -o /tmp/mpvtest /tmp/mpvtest.c \
    $(for d in "$XC"/*.xcframework/macos-arm64_x86_64; do echo -n "-F $d "; done) \
    $(for b in $(ls "$XC" | sed 's/.xcframework//' | grep -v MoltenVK); do echo -n "-framework $b "; done) \
    -L"$XC/MoltenVK.xcframework/macos-arm64" -lMoltenVK \
    -Wl,-rpath,"$XC/MoltenVK.xcframework/macos-arm64" \
    -framework AppKit -framework AudioToolbox -framework CoreAudio -framework CoreFoundation \
    -framework CoreGraphics -framework CoreMedia -framework CoreVideo -framework Foundation \
    -framework Metal -framework OpenGL -framework QuartzCore -framework Security -framework VideoToolbox \
    -lxml2 -lexpat -lz -lbz2 -liconv -lresolv -lc++ \
    '-Wl,-U,__swift_FORCE_LOAD_$_swiftCompatibility56' \
    '-Wl,-U,__swift_FORCE_LOAD_$_swiftCompatibilityConcurrency'
  /tmp/mpvtest /path/to/file
  ```

## 9. Known benign log noise (do NOT "fix" by changing the player)

- At AV1 load: `av1: Device does not support the VK_KHR_video_decode_queue extension!`,
  `Your platform doesn't support hardware accelerated AV1 decoding`, then clean fallback to
  software dav1d. mpv tries Vulkan (bundled MoltenVK) before settling. Harmless — telemetry
  shows zero drops after.
- One-time `OpenGL error INVALID_FRAMEBUFFER_OPERATION` right at VO start on SDR displays.
  Transient; playback continues at 60 fps with zero drops.

## 10. Key files

| File | Role |
|---|---|
| `Engine/AudioPlayerEngine.swift` | Source selection, owns MPVController, playlist/EOF |
| `Features/MPVVideoView.swift` | libmpv bindings, render layer, color pipeline, telemetry |
| `Engine/VideoStreamingEngine.swift` | Stream layout, slice fetch/decrypt, ObjectFetcher |
| `Engine/VaultStreamServer.swift` | Loopback HTTP Range server |
| `Engine/DownloadEngine.swift` | Cache, `isCached` (exact size), quiet downloads |
| `Engine/ThumbnailService.swift` | Photo thumbs (local) + video/audio (Telegram) |
| `LocalPackages/LocalMPVKit/` | Bundled libmpv + FFmpeg + MoltenVK XCFrameworks |

Evidence archive (2026-08-15): telemetry at `/tmp/xcloud-mpv-telemetry.log`; harness at
`/tmp/mpvtest.c`; Dolby/stream curl outputs at `/tmp/{eac3,ac3}.out`, `/tmp/range{1,2,3}.bin`.
