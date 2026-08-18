# doc-keeper session log

## 2026-08-15 — autocreate-playlist bulk splice

Updated outdated local-fork mentions after merge no longer rebuilds siblings with `playlist_entry_new` + O(N²) `playlist_insert_at` on the core/playloop thread. Scan remains on a worker; core drops the duplicate current file and splices remaining entries via `playlist_move_entries`. Directory-open still lists before playback.

Changed:
- `AGENTS.md` local user-script routing sentence: worker scan + bulk splice / reuse worker playlist.
- `DOCS/local-workflow.md` fork-hash paragraph: same bulk-splice note.

Left unchanged (already current):
- `DOCS/man/options.rst` (`--autocreate-playlist`: bulk splice, large folders should not stall after scan)
- `DOCS/interface-changes/autocreate-playlist.txt` (core splice reuses worker playlist)

Skipped:
- No `DOCS/Internal.md` / `docs/Internal.md` created (existing `DOCS/` + `AGENTS.md` layout; initialize not requested).
- Did not rewrite `DOCS/references/libraries/mpv.md` (doc-search owned).

Pending: none for this change.

## 2026-08-15 — origin/master merge hash check

Verified after merge `b42cf71a7fb7a96e2926804d1e3b4d147ad8da25` (`Merge origin/master into master`):

- `origin/master` == `7b8915bc1d04c7e1b61184e00c7fbfaab1911e75` (`ra_pl: add x2bgr10/x2rgb10 special RA formats`) — matches `DOCS/local-workflow.md`.
- Prefetch-end / local feature `72a875bd10322089d60525093a415a7cdbe52761` (`player: splice autocreate siblings in bulk`) — matches `DOCS/local-workflow.md`. Both SHAs are ancestors of `HEAD`.
- `AGENTS.md` has no commit hashes; autocreate bulk-splice sentence already current.
- Did not document `.git/info/exclude`; `DOCS/local-workflow.md` already says keep local build artifacts out of scope.

Changed: none in `AGENTS.md` / `DOCS/local-workflow.md`. This log only.

Pending: none.

## 2026-08-15 — playlist-reorder command

Documented one-shot `playlist-reorder` (permutation by current 0-based indexes;
no current-file restart; one `MP_EVENT_CHANGE_PLAYLIST` + one `prefetch_next()`).

Changed:
- `AGENTS.md` local prefetch testing: add `playlist-reorder` to retarget list;
  note it replaces many `playlist-move` calls for large autocreate sorts.
- `DOCS/local-workflow.md` playlist-edit retarget list: add `playlist-reorder`.
- `DOCS/interface-changes/prefetch-playlist-on-cache.txt`: same retarget list.

Left unchanged (already current):
- `DOCS/man/input.rst` (`playlist-reorder` command)
- `DOCS/man/options.rst` (prefetch playlist-edit list includes `playlist-reorder`)
- `DOCS/interface-changes/playlist-reorder.txt`

Skipped:
- No `DOCS/Internal.md` created.
- Did not edit Roaming mpv config.
- Did not rewrite `DOCS/references/libraries/mpv.md` (doc-search owned).

Pending: none for this change.

## 2026-08-17 — documentation audit and references cleanup

Comprehensive audit of `DOCS/`, `AGENTS.md`, and `README.md`:

- Removed broken links and stale references to `.cursor/rules/mpv-lua-scripter.mdc` and `.cursor/agents/mpv-lua-scripter.md` (dropped in commit `c06acd0326`).
- Fixed path formatting for Roaming configuration in `AGENTS.md`.
- Updated prefetch commit SHA in `DOCS/local-workflow.md` to `496f5920bdab10e5ee2a93e0b4b09e072e07f7a3` (`player: add playlist-reorder for one-shot permutation`). Upstream `origin/master` (`7b8915bc1d04c7e1b61184e00c7fbfaab1911e75`) verified.
- Verified `DOCS/interface-changes/` and `DOCS/man/` consistency for recent features (`playlist-reorder`, `prefetch-playlist-on-cache`, `autocreate-playlist`).
- Verified formatting, links, and docutils generation (`rst2man`, `rst2html`) for `DOCS/man/mpv.rst`.

Changed:
- `AGENTS.md`: Remove broken `.cursor/rules/mpv-lua-scripter.mdc` link; fix Roaming path formatting.
- `DOCS/local-workflow.md`: Update committed prefetch work hash to `496f5920bdab10e5ee2a93e0b4b09e072e07f7a3`; update tracked onboarding set sentence (remove `.cursor` agent/rules references).

Left unchanged (already current and verified):
- `DOCS/interface-changes/playlist-reorder.txt`
- `DOCS/interface-changes/prefetch-playlist-on-cache.txt`
- `DOCS/interface-changes/autocreate-playlist.txt`
- `DOCS/man/input.rst`
- `DOCS/man/options.rst`
- `DOCS/man/mpv.rst`
- `README.md`

Skipped:
- Did not rewrite `DOCS/references/libraries/*.md` (doc-search owned).
- Did not create `docs/` or `DOCS/Internal.md`.

Pending: none.

## 2026-08-17 — manpage restore, references index, and layout review

1. Restored missing `DOCS/man/mpv.rst` from git working tree and verified all 19 included `.rst` sub-manpages exist.
2. Created `DOCS/references/README.md` cataloging and describing the roles and scope of `DOCS/references/libraries/` (`ffmpeg.md`, `libplacebo.md`, `mpv.md`).
3. Reviewed the `DOCS/` layout for canonical uppercase directory usage; corrected lowercase `docs/references/...` paths in `.agent-memory/doc-search/MEMORY.md`.
4. Verified docutils generation (`rst2man`, `rst2html`) using `TOOLS/docutils-wrapper.py` with `--halt=2` on `DOCS/man/mpv.rst` (built cleanly with zero errors/warnings). Verified standalone `.rst` syntax across `DOCS/`.

Changed:
- `DOCS/man/mpv.rst`: Restored master manpage entrypoint.
- `DOCS/references/README.md`: Created index file for `DOCS/references/` and library summaries.
- `.agent-memory/doc-search/MEMORY.md`: Updated lowercase `docs/` references to canonical uppercase `DOCS/`.

Left unchanged (verified):
- `DOCS/references/libraries/*.md` (doc-search owned bodies preserved)
- `AGENTS.md` and `README.md` entrypoint references

Pending: none.

## 2026-08-18 — canonical fork and reviewed upstream integration

Documented the personal fork as the canonical clone/publish repository and the
official mpv repository as a comparison-only upstream source.

Changed:
- `AGENTS.md`: Added the canonical `origin` / comparison `upstream` rule and a
  pointer to the staged import procedure.
- `DOCS/local-workflow.md`: Replaced the old remote layout and direct update
  instructions with conventional remote naming, clean-baseline and backup
  requirements, commit-range/path overlap review, staging-branch integration,
  focused/full tests, Windows targeted build and `dist/` deployment, applicable
  real `X:\XXX\Best` verification, and remote-SHA proof.
- `DOCS/local-workflow.md`: Recorded that `%APPDATA%\mpv`, including
  `scripts\playlist-sort.lua`, is outside this repository and must be preserved
  and tested separately.
- `DOCS/references/libraries-docs.md`: Generated the current library metadata
  index from all three library-doc frontmatter blocks.
- `DOCS/references/README.md`: Linked the generated library metadata index.
- `.agent-memory/doc-keeper/MEMORY.md`: Recorded the durable remote and
  integration policy.

Verified:
- `origin` points to `https://github.com/m4niacjp/mpv.git`, `upstream` points to
  `https://github.com/mpv-player/mpv`, `master` tracks `origin/master`, and
  `branch.master.vscode-merge-base` is `upstream/master`.
- All relative Markdown links in changed documentation resolve.
- All three library reference files contain the required frontmatter fields.
- `git diff --check` passes; changed documentation remains below 500 lines.

Pending: none.
