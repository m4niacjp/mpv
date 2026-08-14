---
library: mpv
package_names: [mpv]
version_scope: "master manual (ctx7 /websites/mpv_io_manual_master) + this checkout mpv v0.41.0-911; verified 2026-08-14"
context7_id: /websites/mpv_io_manual_master
last_verified: 2026-08-14
---

# mpv (Windows d3d11 + gpu-next + HDR options)

Command-line media player. Primary Context7 ID: `/websites/mpv_io_manual_master`
(also `/websites/mpv_io_manual_stable`, `/mpv-player/mpv`). Companion:
[libplacebo](libplacebo.md) (backend for `vo=gpu-next`).

Runtime cross-check for this checkout: `dist/mpv.com --no-config --list-options`
and `--show-profile=high-quality`. Context7 snippets for some options are thin;
defaults below are confirmed from the master manual source in-tree
(`DOCS/man/options.rst`, `etc/builtin.conf`) plus `--list-options`.

## Builtin profiles (`etc/builtin.conf`)

`[high-quality]` sets only:

- `scale=ewa_lanczossharp`
- `scale-antiring=0.6`
- `hdr-peak-percentile=99.995`
- `hdr-contrast-recovery=0.30`

`[gpu-hq]` is a **deprecated** alias that loads `high-quality`.

`[fast]` sets `scale/dscale=bilinear`, `dither=no`,
`correct-downscaling/linear-downscaling/sigmoid-upscaling=no`,
`hdr-compute-peak=no`, `allow-delayed-peak-detect=yes`.

## Playback / directory UX

| Option | Default | Notes |
| --- | --- | --- |
| `--osc` | **yes** | Builtin OSC; `--osc=no` disables |
| `--fullscreen` / `--fs` | **no** | Valid |
| `--autocreate-playlist` | **no** | `filter` / `same` also valid |
| `--directory-filter-types` | `video,audio,image,archive,playlist` | `video` alone is valid narrowing |
| `--directory-mode` | **auto** | `lazy` / `recursive` / `ignore` |

## Demux / stream

| Option | Default | Notes |
| --- | --- | --- |
| `--demuxer-mkv-probe-start-time` | **yes** | `no` skips first-cluster start probe (can reduce live latency by ~1 frame) |
| `--curl-buffer-size` | **4 MiB** (min 32 KiB) | Lower may reduce in-flight data/latency |
| `--stream-buffer-size` | **128 KiB** | Larger can help mp4 with many small seeks |

## Buffering / cache

| Option | Default | Notes |
| --- | --- | --- |
| `--cache` | **auto** | `yes` forces; use `--demuxer-max-bytes` for size |
| `--cache-on-disk` | **no** | Packet data to temp file; metadata still in RAM |
| `--cache-pause` | **yes** | Auto-pause on underrun |
| `--cache-pause-initial` | **no** | Prefill before start/seek |
| `--cache-pause-wait` | **1** | Seconds to rebuffer before resume |
| `--cache-secs` | **3600000** (very high) | With cache on, max(this, readahead); usually byte-capped |
| `--demuxer-max-bytes` | **150 MiB** | Forward packet buffer cap |
| `--demuxer-max-back-bytes` | **50 MiB** | Past data when cache enabled |
| `--demuxer-readahead-secs` | **1** | Mostly ignored when cache active (`cache-secs` wins if larger) |
| `--demuxer-hysteresis-secs` | **0** | Manual suggests ~10 for power/load; 0 = continuous fill |

Manual example profile uses `demuxer-max-bytes=512MiB` as a “big cache” illustration — not multi-GiB.

## Lua / playlist / events (master manual, ctx7 2026-08-14)

Commands (not Lua-specific wrappers; `mp.commandv` is the usual Lua vector form):

- `playlist-move <index1> <index2>` — “Move the playlist entry at index1, so that it takes the place of the entry index2.”
- `playlist-shuffle` / `playlist-unshuffle` — reorder the current playlist.

`observe_property`: watch a property; changes generate `property-change` (IPC example uses numeric observe id + name). Lua also has `mp.register_event("file-loaded", …)`.

File lifecycle (List of events): `start-file` when a file **begins loading**; `end-file` after a file is **unloaded**, with a termination reason (EOF, stop, quit, error) plus playlist entry IDs / error text. Manual does **not** state when `--autocreate-playlist` finishes filling `playlist` relative to these events.

Script lifecycle: scripts run in their own threads; main chunk then event loop. “Because scripts initialize concurrently with the player, properties may not be immediately available; … use property observation or event handlers.” The player waits until a script finishes initial setup (waiting for events or exiting the main chunk) so handlers can be registered before playback.

`user-data` persistence across script reload: **not returned** by ctx7 master queries on 2026-08-14.

Directory playlist construction:

- `--autocreate-playlist`: load only the selected file, **filter the parent directory by file types**, or match by category/extension of the current file (`filter` / `same` / off).
- `--directory-filter-types`: restrict types when opening directories/archives.
- `--directory-mode`: `lazy` / `recursive` / `ignore` for subdirectories.
- Sort order of directory playlists: **not documented** in these fetches. No documented “sort before playback/prefetch” option; post-build `playlist-move` / `playlist-shuffle` exist.

`--prefetch-playlist` (pseudo-GUI / options): “open the next entry in a playlist as the current one ends.” Not youtube-dl wrapper URLs; not HLS (internal prefetch). “may make incorrect predictions if the playlist is edited or navigated non-linearly” — not an explicit cancel/invalidate API.

## Playlist prefetch (upstream vs this fork)

| Option | Upstream? | Default | Notes |
| --- | --- | --- | --- |
| `--prefetch-playlist` | **yes** (upstream) | **no** | Opens next URL(s) near end of current; not youtube-dl wrapper |
| `--prefetch-playlist-max` | **this checkout / local fork** | **1** | Retain N future entries |
| `--prefetch-playlist-on-cache` | **this checkout / local fork** | **no** | Prefetch when current hits cache/readahead/`max-bytes` |
| `--prefetch-playlist-realtime` | **this checkout / local fork** | **no** | Prefetch immediately (I/O contention) |
| `--prefetch-playlist-cache-secs` | **this checkout / local fork** | **0** | Per-prefetched-entry readahead override; 0 = inherit |
| `--prefetch-playlist-cache-bytes` | **this checkout / local fork** | **0** | Per-entry `--demuxer-max-bytes` override; 0 = inherit |

Context7 master manual did **not** return the fork extensions in 2026-08-11 fetches.
They are documented in this tree’s `DOCS/man/options.rst` and
`DOCS/interface-changes/prefetch-playlist-on-cache.txt`, and present in the dirty
runtime binary. Caps apply **per** prefetched entry (memory/I/O multiplies with
`prefetch-playlist-max`).

## GPU / hwdec (Windows)

| Option | Default | Notes |
| --- | --- | --- |
| `--vo` | auto | `gpu-next` = libplacebo path |
| `--gpu-api` | **auto** (must not rely on which API auto picks) | Explicit `d3d11` / `vulkan` / `opengl` |
| `--hwdec` | **no** | Prefer runtime enable (`Ctrl+h`); first fix for weird color = disable |

Windows APIs of interest:

- `d3d11va` — needs `vo=gpu`/`gpu-next` + `gpu-context=d3d11` (or angle)
- `d3d11va-copy` — copies decoded frames to **system RAM** (safer/interop, costlier)
- `vulkan` / `vulkan-copy` — `vo=gpu-next` only
- Nvidia: manual recommends **`nvdec` / `nvdec-copy`** over legacy `cuda`

`--d3d11va-zero-copy`: skips GPU copy when using d3d11 interop; may mis-sample padded edges / hit driver bugs.

## HDR / tone (gpu-next)

| Option | Default | Notes |
| --- | --- | --- |
| `--target-colorspace-hint` | **auto** | `yes`/`no`; D3D11/Wayland/winvk; gpu-next. Manual TL;DR: prefer `auto` + tune `--target-*` |
| `--hdr-compute-peak` | **auto** | Dynamic peak; `auto` if compute+SSBO |
| `--hdr-peak-percentile` | **100** (manual); HQ **99.995** | gpu-next; clips bright outliers when &lt;100 |
| `--hdr-contrast-recovery` | **0.0**; HQ **0.30** | 0–2; &gt;1 may oversharpen |
| `--hdr-contrast-smoothness` | **3.5** | Lower on low-DPI, raise on high-DPI |
| `--tone-mapping` | **auto** → `spline` on gpu-next | `bt.2446a` = “recommended curve for well-mastered content” (gpu-next) |

Removed/deprecated (list-options): `tone-mapping-desaturate`,
`tone-mapping-desaturate-exponent`.

## Scaling / quality

| Option | Default | Notes |
| --- | --- | --- |
| `--scale` | **lanczos**; HQ **ewa_lanczossharp** | `ewa_lanczos4sharpest` = sharper, ringing; gpu-next enables built-in antiring |
| `--cscale` | unset → use `--scale` | |
| `--dscale` | **hermite** | `mitchell` is a valid sharper/balanced choice |
| `--scale-antiring` / `--cscale-antiring` | **0.0**; HQ **0.6** | EWA antiring effective on **gpu-next** |
| `--dither` | **fruit** | `error-diffusion` needs compute + shared memory (fallback to fruit) |
| `--dither-depth` | **auto** | gpu-next: detected; d3d11 wire depth detection is reliable; explicit panel depth OK |
| `--correct-downscaling` / `--linear-downscaling` / `--sigmoid-upscaling` | all **yes** | Already defaults; redundant unless undoing `fast` |
| `--deband` | **no** | “Virtually always an improvement” except perf |
| `--deband-iterations` | **1** | &gt;4 practically useless |
| `--deband-threshold` | **48** | Higher = stronger / more detail loss |
| `--deband-range` | **16** | If raising iterations, **decrease range** |
| `--deband-grain` | **32** | Extra noise cover |

## Profiles / window (PIP-relevant)

| Option | Default | Notes |
| --- | --- | --- |
| `profile=<name>` | — | Nesting via `profile=` inside a profile is supported |
| `profile-restore` | **default** (no restore) | `copy` / `copy-equal` for runtime restore |
| `--ontop` | **no** | On Windows + fullscreen → exclusive FS bypassing DWM |
| `--border` / `--title-bar` | **yes** | title-bar: Windows/X11; border takes precedence |
| `--autofit` / `--geometry` | unset | Initial size/position |
| `--auto-window-resize` | **yes** | `no` keeps window size across playlist advances |

## Official alignment notes (HDR WOLED + d3d11 + gpu-next)

1. Nesting `profile=high-quality` then overriding `scale` to `ewa_lanczos4sharpest` is valid; HQ’s `ewa_lanczossharp` becomes redundant.
2. HQ’s `scale-antiring=0.6`, `hdr-peak-percentile=99.995`, `hdr-contrast-recovery=0.30` match explicit user copies — redundant if HQ is already applied.
3. Prefer `d3d11va` or Nvidia `nvdec` over `*-copy` when interop works; keep `-copy` only if zero-copy path breaks filters/HDR.
4. Prefer `--target-colorspace-hint=auto` first; use `yes` + `--target-*` if auto metadata is wrong.
5. Multi‑GiB `demuxer-max-bytes` / prefetch caps are far above documented examples; watch RAM with `prefetch-playlist-max` &gt; 1.
6. `cache-pause=no` + `cache-pause-wait=0` disables underrun buffering UX (valid for testing, not general playback).

## Context7 coverage gaps

- Truncated GPU/HDR option bodies in `ctx7 docs`; filled from in-tree master man + `--list-options`.
- Local prefetch-on-cache family not confirmed in Context7 upstream index (treat as fork until upstream docs catch up).
- Re-fetch `/websites/mpv_io_manual_master` if option text diverges after a release.
