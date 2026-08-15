# Consult: black video thumbnails — headless frame capture with bundled libmpv 0.38

*Self-contained prompt for Claude / Qwen / any external model. No project access needed.*

---

## Problem

A macOS media app needs to generate a **representative (non-black) thumbnail** for video
uploads. The current generator (QuickLook, `QLThumbnailGenerator`) always picks the
**first frame** of the video, which is frequently a black title card — so many videos get
black thumbnails even though later frames contain real imagery. QuickLook has **no API to
choose a time**.

## Hard constraints (the app's rules)

1. **AVFoundation is banned by user mandate** — no `AVAssetImageGenerator`, no `AVPlayer`,
   no `AVAsset`. mpv is the ONLY media engine allowed.
2. The app bundles its own media stack as XCFrameworks (`LocalMPVKit`):
   - **libmpv v0.38.0-dirty** (`Libmpv.framework`)
   - FFmpeg **libavformat / libavcodec / libavutil / libswscale** etc. — built as a
     **decode-only player** — **NO image/video encoders** (verified: mpv's `screenshot`
     command and `--vo=image` both fail with "encoder failed to open" for jpg/png/webp).
   - **Zero zimg symbols** in libmpv (verified with `nm`). mpv ≥ 0.36 requires zimg for
     its software-render path.
   - **libswscale IS bundled** (`Libswscale.xcframework` exists).
3. Hardware decode via VideoToolbox is available for H.264/HEVC on Apple Silicon; AV1 has
   no hardware decoder on M1/M2 (software decode via dav1d works).

## What works today

The app's real player renders video perfectly **inside a composited window**:

- `MPVLayerView` (an `NSView` backed by `CAOpenGLLayer`), whose `MPVLayer.draw(inCGLContext:)`
  does: `mpv_render_context_update()` → `mpv_render_context_render()` with
  `MPV_RENDER_PARAM_OPENGL_FBO` = the layer's default framebuffer → `mpv_render_context_report_swap()`
  → `glFlush()`.
- Render context created via `mpv_render_context_create` with `MPV_RENDER_PARAM_API_TYPE = "opengl"`
  + `MPV_RENDER_PARAM_OPENGL_INIT_PARAMS` (get-proc-address via `dlsym(RTLD_DEFAULT)`).
- Works in the user's normally-launched app (windows composite; video visible; mpv telemetry
  shows 60fps, zero drops).

## The approach being tried (and where it fails)

**Plan:** a tiny invisible window hosting the app's own `MPVLayerView`; load the file; seek to
candidate fractions of duration (8%, 15%, 25%, 40%, 60%); read the frame back with
`glReadPixels` immediately after `mpv_render_context_report_swap` in `draw()`; pick the frame
with the highest luma variance (so a black opening can never win).

**Mechanics work:** mpv decodes, and exact seeks land correctly at 12.8s / 24.0s / 39.9s /
63.9s / 95.8s (verified via `time-pos`).

**Failure:** every readback is pure black (meanLuma 0.0, luma variance 0.0). Diagnostics:

- `glCheckFramebufferStatus(GL_FRAMEBUFFER)` → **`0x8219` = `GL_FRAMEBUFFER_UNDEFINED`**
  on every draw, even though the window reports `isVisible=true`, occlusion visible, on a
  screen, key, and the app active.
- `glReadPixels` → `GL_INVALID_FRAMEBUFFER_OPERATION` (1286).
- mpv logs: `[MPV libmpv_render][error] after creating texture: OpenGL error INVALID_FRAMEBUFFER_OPERATION.`

**Root cause (environment, verified):** when the app is launched by automation (agent/CLI —
`nohup`, direct binary, `open`, even `launchctl asuser <uid>`) rather than by the user
clicking, the macOS window server gives the process **ZERO composited windows**:
`CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, ...)` returns no windows for the
process, and System Events reports 0 windows — even after `NSApp.activate(ignoringOtherApps:)`,
`makeKeyAndOrderFront`, `.mainMenu` window level, on-screen positioning, `alphaValue` 0.02 vs
0 vs 1, borderless vs titled. Consequently `CAOpenGLLayer` has no window-server surface →
its CGL context has no drawable → `GL_FRAMEBUFFER_UNDEFINED` → black. The user's normal
launches composite fine (their player renders video), so the window-based capture would likely
work in production — **but it cannot be verified from the automation context**, which is
unacceptable for a feature we must trust.

## What has been tried and ruled out (headless, no window)

1. **`MPV_RENDER_API_TYPE_SW`** (software renderer, `MPV_RENDER_PARAM_SW_SIZE` at native
   video size): renders a flat gray placeholder. Cause: mpv 0.38's SW path is zimg-only and
   the bundled libmpv has zero zimg symbols.
2. **`MPV_RENDER_API_TYPE_OPENGL` into an offscreen CGL context rendering to our OWN FBO**
   (`glGenFramebuffers` + RGBA texture, `MPV_RENDER_PARAM_OPENGL_FBO` = our fbo id, with
   update/report_swap loop): mpv reports "Video: no video", `glReadPixels` still returns
   `GL_INVALID_FRAMEBUFFER_OPERATION`. The offscreen CGL context never has a usable default
   drawable either.
3. **mpv `screenshot` command** (`mpv_command("screenshot")`, also `screenshot-to-file`):
   fails — bundled FFmpeg has no image encoders.
4. **`--vo=image` / `--o=out.jpg`**: same encoder problem.
5. **QuickLook at a time offset**: QuickLook has no time API on macOS.
6. **Window variations**: offscreen at negative origin, on-screen with alpha 0 / 0.02 / 1,
   `.normal` and `.mainMenu` level, `orderFrontRegardless` vs `makeKeyAndOrderFront`,
   pre-created with delays so the surface attaches before mpv init, `NSApp.activate` before
   ordering — all identical `GL_FRAMEBUFFER_UNDEFINED` in the automation context.

## Questions for you

1. Is there a **fundamentally better way to extract a representative video frame** with
   libmpv 0.38 given: no zimg (SW renderer dead), no FFmpeg encoders (screenshot dead), no
   AVFoundation, and no guaranteed composited window?
2. Is `GL_FRAMEBUFFER_UNDEFINED` in automation-launched macOS apps a known WindowServer/TCC
   behavior, and is there ANY known way to force a real GL surface headlessly — e.g., an
   **IOSurface-backed CGL context**, a CGL context with an explicit virtual screen
   (`CGLSetVirtualScreen`), `kCGLPFAAllowOfflineRenderers`, a dummy offscreen drawable, or
   creating the context under a different launch path?
3. **Direct FFmpeg extraction** (the leading candidate): use the bundled
   `libavformat`+`libavcodec`+`libswscale` directly in-app — open the file, seek to ~10%,
   decode one frame, convert to RGBA with **swscale** (which IS bundled), write PNG/JPEG via
   AppKit (`NSBitmapImageRep` — allowed, not AVFoundation). Pitfalls to watch for: seek
   accuracy (keyframe vs exact), 10-bit HDR / PQ content (need proper conversion to SDR
   RGBA), AV1 (software decode cost), rotated videos (display matrix), pixel format
   conversions (swscale flag choices), and thread-safety with the app's own mpv instances.
   Is this the pragmatic, robust answer? What's the cleanest minimal code shape for it?
4. Any way to make mpv's **SW renderer work without zimg** (e.g., linking swscale into mpv
   somehow, or a mpv option to force swscale)?
5. Anything else you'd recommend — a completely different approach to "poster frame" that we
   haven't considered?

---

*For reference: the app targets macOS 13+, SwiftUI, Swift; media is served to mpv from a
local byte-range HTTP server; thumbnails are stored both locally
(`~/Library/Application Support/xCloud/thumbs/<id>.png`, `<id>-up.jpg`) and attached to
Telegram upload chunk messages.*

---

## RESOLVED (2026-08-15) — verdict adopted: direct FFmpeg extraction

All five models (Claude, Deepseek, Grok, ChatGPT, Qwen) converged on the same answer:
**drop the window entirely and decode frames directly with the bundled FFmpeg libs**
(`libavformat` + `libavcodec` + `libswscale` → RGBA → `NSBitmapImageRep`). No window, no
GL, no zimg, no image encoders — and it is fully verifiable from automation contexts.

Implemented as `Engine/VideoFrameExtractor.swift` (FFmpeg 7.0 modules imported directly
from the bundled XCFrameworks):

- Seek `AVSEEK_FLAG_BACKWARD` to the keyframe ≤ target, decode forward until
  `best_effort_timestamp ≥ target` (exact-enough seeking, cheap).
- Score 5 candidate positions (8%→60% of duration) by subsampled luma variance on the
  Y plane — a black opening can never win.
- Convert the winner via `sws_scale` → RGBA with `sws_setColorspaceDetails` from the
  source's real colorspace/range (correct for SDR; HDR looks dim/flat but never black).
- Apply rotation from `AV_FRAME_DATA_DISPLAYMATRIX` (FFmpeg 7 moved it to frame side data).
- Encode with `NSBitmapImageRep` (AppKit — still no AVFoundation).

One required build fix: Libavutil's module map had to exclude Windows-only headers
(`hwcontext_d3d12va.h` etc.) or the app target fails to import — applied in both the main
folder and the worktree's git-tracked copy of `LocalMPVKit`.

Verified headless in the automation context (which the windowed path could never be):
real 605 KB frame, variance 552.7 vs 0.0 for the old black thumb; both black thumbs
regenerated to real frames. All tests green. The windowed mpv-render capture was deleted.
