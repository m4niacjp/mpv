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
