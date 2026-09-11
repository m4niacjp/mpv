# web-search memory (pointers only)

- Facet index: `docs/references/web-search/index.md`
- `rclone-vfs-concurrent-read-starvation` -> `docs/references/web-search/docs/rclone-vfs-concurrent-read-starvation.md`
  - retrieved_at 2026-09-12; search_id `search_7cd2984aff07391cbef3c82b8f13bede`;
    session_id `session_c61be9174590940783ae73533cc7f391` (extract session)
  - Key: mpv prefetch open shares one open slot and `cancel_open()` joins the thread
    (upstream v0.41.0 `player/loadfile.c`) -> real open waits for aborted prefetch;
    rclone cross-file open starvation has no external evidence; version-matched rclone
    docs/source at commit `ef6968730` show per-open chunk state, no VFS download scheduler.
  - Open gap: whether chunked reading applies in `--vfs-cache-mode full`
    (`vfs/vfscache/downloaders/` package not read).
