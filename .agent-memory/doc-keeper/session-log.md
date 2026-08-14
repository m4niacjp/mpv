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
