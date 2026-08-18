# mpv Reference Documentation

This directory contains reference materials, external library summaries, and subsystem integration guides used by developers and documentation workflows.

## Library References

Curated summaries for external dependencies and core runtime subsystems are located under [`libraries/`](libraries/):

| Document | Primary Library / Subsystem | Role & Scope |
| --- | --- | --- |
| [`libraries/ffmpeg.md`](libraries/ffmpeg.md) | **FFmpeg** (`libavformat`, `libavcodec`, `libavutil`, `libavfilter`, `libswscale`, `libswresample`) | Documents container probing, demuxing (`avformat_open_input`, `avformat_find_stream_info`), custom AVIO buffering, decoding pipelines, and hardware acceleration interop (e.g. D3D11VA, NVDEC). |
| [`libraries/libplacebo.md`](libraries/libplacebo.md) | **libplacebo** | Documents GPU-accelerated rendering and video processing powering `--vo=gpu-next`, including scaling algorithms (polar/EWA), dynamic HDR tone mapping, peak detection, debanding, shader compilation, and swapchain synchronization. |
| [`libraries/mpv.md`](libraries/mpv.md) | **mpv** (Runtime & Subsystems) | Catalogs player options, builtin profiles (`high-quality`, `fast`), demuxer and cache sizing, Lua scripting/event lifecycle, playlist generation (`--autocreate-playlist`), and playlist prefetching behavior. |

## Structure & Guidelines

- **Canonical Path:** All documentation files must reside within the canonical `DOCS/` tree (uppercase). Do not create lowercase `docs/` paths.
- **Library Reference Ownership:** Files under `DOCS/references/libraries/` maintain metadata headers (library name, package list, version scope, Context7 ID, and last verification timestamp) and are updated in coordination with documentation/search agent roles.
- **Relationship to User Manuals:** Library reference docs summarize underlying API contracts and architectural details. For end-user option documentation, command references, and scripting manuals, refer to the primary manual sources in [`DOCS/man/`](../man/).
