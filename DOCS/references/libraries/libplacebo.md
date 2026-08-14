---
library: libplacebo
package_names: [libplacebo]
version_scope: "libplacebo v7.365.0 (this mpv checkout); wrap tracks master; meson >=7.360.1; verified 2026-08-14"
context7_id: /haasn/libplacebo
last_verified: 2026-08-14
---

# libplacebo

GPU-accelerated image/video processing library used by mpv’s `--vo=gpu-next`.
Context7 ID: `/haasn/libplacebo` (also `/websites/libplacebo`). For end-user
option names and defaults, prefer the [mpv](mpv.md) manual — mpv wraps
libplacebo with its own flags.

## Relevant capabilities (README / docs)

- High-quality up/downscaling including polar (EWA) filters
- Dynamic HDR tone mapping with scene / peak analysis
- Native Dolby Vision support
- Colorimetrically accurate color management
- Custom shaders

## Options docs (libplacebo-native names)

| libplacebo | mpv counterpart (approx.) | Defaults / notes (ctx7 2026-08-11) |
| --- | --- | --- |
| `peak_detect` | `--hdr-compute-peak` | default **yes**; helps when dynamic metadata absent |
| `peak_detection_preset` / `high_quality` | HQ peak path | `high_quality` enables frame histogram measurement |
| `color_map_preset=high_quality` | HQ color-map path | also enables HDR contrast recovery |
| `contrast_recovery` | `--hdr-contrast-recovery` | default **0.0**; HQ preset **0.3** |
| `contrast_smoothness` | `--hdr-contrast-smoothness` | default **3.5**; lowpass kernel size for recovery |

### contrast_recovery

- Restores high-frequency detail after tone-mapping
- `0.0` disables; `high_quality` uses **0.3** for subtle enhancement

### Debanding

libplacebo GLSL docs describe iterative average sampling with a per-iteration
threshold that falls off with iteration index — consistent with mpv’s note that
high iteration counts have rapidly diminishing returns (&gt;4 practically useless).

## Use with mpv

mpv exposes libplacebo features under GPU renderer options when
`--vo=gpu-next`. Verify behavior and defaults via mpv’s manual
(`/websites/mpv_io_manual_master`) rather than raw libplacebo option names,
unless writing against libplacebo APIs directly.

## Shader compilation and cache (ctx7 2026-08-14)

From `docs/renderer.md` (master):

- `pl_renderer` **internally** compiles and stores shader programs.
- After `pl_renderer_create`, callers may `pl_renderer_load(renderer, cache)`
  from a previously `pl_renderer_save`’d blob; save on uninit.
- Cache restore is **recommended** where shader recompilation is costly;
  docs explicitly name **D3D11**. Loading untrusted cache is a security risk
  (RCE).
- Docs do **not** state whether compilation happens at `pl_renderer_create`
  vs the first `pl_render_image`. There is **no** documented prewarm /
  precompile API beyond load/save of that cache. Tier 3 `dispatch.h` also
  caches shaders; no separate “compile now” entry point in ctx7 snippets.

`pl_renderer` is otherwise almost stateless (`pl_render_params` per call).
Exceptions: frame mixing and HDR peak detection, which may need
`pl_renderer_flush_cache`.

## Polar / EWA scalers

`docs/options.md`: `upscaler` default `lanczos`. `ewa_lanczos` variants are
documented as highest quality but **slowest**; `none` / `nearest` for speed.
`<scaler>_polar` selects polar/2D (EWA) vs separable/1D (default `no`).
No documented extra **first-frame** cost vs bilinear specifically.

## HDR peak detection vs first presented frame

- `peak_detect` default **yes**.
- `allow_delayed_peak` (default **no**): if `yes`, the peak-detection
  **result** may be delayed by one frame (throughput vs flicker). Docs do
  **not** say peak detection holds back the first presented swapchain frame.

## Swapchain / vsync

`docs/basic-rendering.md` shows a generic loop:
`pl_swapchain_start_frame` → render → `pl_swapchain_submit_frame` →
`pl_swapchain_swap_buffers`. Failed `start_frame` is treated as hidden/
minimized (wait for events). **No** D3D11-specific first-frame latency notes
in ctx7 beyond the shader-cache / recompilation remark.

## Gaps

Context7 libplacebo coverage is thinner than mpv’s manual for end-user
scaler/deband/dither knobs; those remain documented mainly on the mpv side.
Tone-mapping algorithm names (`bt.2446a`, `spline`, etc.) are documented in
mpv’s `--tone-mapping` option, not always mirrored 1:1 in libplacebo ctx7
snippets.
Exact shader-compile timing (create vs first `pl_render_image`), a prewarm
API, EWA vs bilinear **first-frame** delta, and D3D11 swapchain first-frame
latency are **not** specified in fetched ctx7 docs.
