# doc-keeper memory index

Project: mpv (C11 media player, Meson). Docs live under `DOCS/` (uppercase).
Do not create a `docs/` case-variant tree.

- `session-log.md` — append-only run log
- `rules.md` — project-specific documentation rules

Current repository identity and integration policy:

- Canonical clone/publish remote: `origin` =
  `https://github.com/m4niacjp/mpv.git`; local `master` tracks
  `origin/master`.
- Official comparison source: `upstream` =
  `https://github.com/mpv-player/mpv.git`; editor merge-base metadata points to
  `upstream/master`.
- Import upstream through a reviewed staging branch, focused/full verification,
  Windows targeted build and deployment, applicable real `X:\` checks, and
  local/remote SHA proof. Do not blindly pull or merge into `master`.
- `%APPDATA%\mpv` runtime configuration is outside the repository and requires
  separate backup/versioning and compatibility verification.

RTX Video documentation context:

- `nvidia-true-hdr` is a `d3d11vpp` filter parameter, not a top-level mpv
  option. The direct config form is `vf=d3d11vpp=nvidia-true-hdr`.
- The local RTX VSR/HDR pipeline requires `vo=gpu-next`, `gpu-api=d3d11`,
  `gpu-context=d3d11`, and `hwdec=d3d11va`.
- The Roaming `rtx-video-auto.lua` script is outside the repository. Its
  format detection checks `video-params/hw-pixelformat` first and falls back to
  `video-params/pixelformat` (then the track format), because `d3d11va` can
  expose the usable format only through the hardware property.
