# doc-search memory

### mpv
- aliases: mpv player, mpv.io, vo=gpu-next
- ecosystem: c / media-player
- package_names: mpv
- context7_id: `/websites/mpv_io_manual_master`
- version_ids:
  - `/websites/mpv_io_manual_stable`
  - `/mpv-player/mpv`
- last_verified: 2026-08-14
- repo_doc: docs/references/libraries/mpv.md
- notes: Prefer master manual for this checkout. GPU quality under GPU renderer options; builtin high-quality in etc/builtin.conf. Prefetch-on-cache family is local-fork in this dirty tree (not confirmed in Context7). Lua playlist-move/shuffle, start-file vs end-file, prefetch-playlist next-at-EOF, autocreate-playlist filter documented; user-data persistence and directory sort order not in ctx7. Cross-check defaults with dist/mpv.com --list-options.

### FFmpeg
- aliases: libavformat, libavcodec, ffmpeg
- ecosystem: c / multimedia
- package_names: libavformat, libavcodec, libavutil, libavfilter, libswscale, libswresample
- context7_id: `/websites/ffmpeg_doxygen_8_0`
- version_ids:
  - `/websites/ffmpeg_doxygen_trunk`
  - `/websites/ffmpeg_documentation`
- last_verified: 2026-08-14
- repo_doc: DOCS/references/libraries/ffmpeg.md
- notes: Checkout wrap is meson-8.1; Context7 has no 8.1 Doxygen ID. Prefer 8.0 over 4.4/7.0. User options live under /websites/ffmpeg_documentation (ffmpeg-all.html).

### libplacebo
- aliases: placebo, pl_
- ecosystem: c / gpu-rendering
- package_names: libplacebo
- context7_id: `/haasn/libplacebo`
- version_ids:
  - `/websites/libplacebo`
- last_verified: 2026-08-14
- repo_doc: docs/references/libraries/libplacebo.md
- notes: Backend for mpv vo=gpu-next (v7.365.0; wrap master; meson >=7.360.1). Shader cache pl_renderer_load/save; D3D11 recompile costly. No documented prewarm. allow_delayed_peak default no. Polar/EWA slowest in options.md.
