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
