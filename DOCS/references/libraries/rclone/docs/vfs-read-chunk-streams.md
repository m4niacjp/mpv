---
section: vfs-read-chunk-streams
last_verified: 2026-09-12
claims:
  - "streams == 0: one sequential chunk stream per open file; size starts at --vfs-read-chunk-size and doubles for each read"
  - "Doubling is capped only when --vfs-read-chunk-size-limit is greater than --vfs-read-chunk-size; 'off' (default) grows indefinitely; a limit of 0 leaves the chunk size constant"
  - "streams > 0: rclone reads that many chunks of --vfs-read-chunk-size concurrently; the size for each read stays constant"
---

# VFS read chunk streams (`--vfs-read-chunk-streams`)

Source: rclone docs section "VFS Chunked Reading" (`vfs/vfs.md`, embedded on
the `rclone mount`, `rclone nfsmount`, and `rclone serve *` command pages),
retrieved via Context7 `/websites/rclone`.

## `--vfs-read-chunk-streams` == 0 — one sequential chunk stream per open file

- "Rclone will start reading a chunk of size `--vfs-read-chunk-size`, and
  then double the size for each read. When `--vfs-read-chunk-size-limit` is
  specified, and greater than `--vfs-read-chunk-size`, the chunk size for
  each open file will get doubled only until the specified value is reached.
  If the value is "off", which is the default, the limit is disabled and the
  chunk size will grow indefinitely."
- Doubling applies only when a limit greater than the chunk size is set.
  Docs example: `--vfs-read-chunk-size 100M` with limit `0` downloads
  0-100M, 100M-200M, 200M-300M, ... (constant 100M chunks); with limit
  `500M` it downloads 0-100M, 100M-300M, 300M-700M, 700M-1200M,
  1200M-1700M, ... (doubling until the cap).
- `--vfs-read-chunk-size 0`/"off" disables chunked reading; chunks are not
  buffered in memory.

## `--vfs-read-chunk-streams` > 0 — N concurrent constant-size chunks

- "Rclone reads `--vfs-read-chunk-streams` chunks of size
  `--vfs-read-chunk-size` concurrently. The size for each read will stay
  constant." (No doubling in this mode.)
- Docs recommend per-backend experimentation; a stated starting point for
  high-performance object stores (e.g. AWS S3) is
  `--vfs-read-chunk-streams 16` with `--vfs-read-chunk-size 4M`.

## Flag reference (same docs block)

- `--vfs-read-chunk-size` — "Read the source objects in chunks (default 128M)"
- `--vfs-read-chunk-size-limit` — "If greater than --vfs-read-chunk-size,
  double the chunk size after each chunk read, until the limit is reached
  ('off' is unlimited) (default off)"
- `--vfs-read-chunk-streams` — "The number of parallel streams to read at
  once" (no default is printed in this flag block)

## `--transfers` interaction — not documented

The VFS docs state only that, with write caching (`--vfs-cache-mode` writes
or full), "the global flag `--transfers` can be set to adjust the number of
parallel uploads of modified files from the cache (the related global flag
`--checkers` has no effect on the VFS)". No statement in the VFS docs bounds
or exempts VFS read chunk streams by `--transfers`; documented read
concurrency is governed solely by `--vfs-read-chunk-streams`.

## Version

Context7 has no versioned rclone IDs. Snapshots used: `/websites/rclone`
(rclone.org mirror, 2026-09-05) and `/rclone/rclone` (official repo,
2026-08-25). Pinned build: rclone v1.76.0-beta.10339.ef6968730 (commit
ef6968730, 2026-09-09). The quoted "VFS Chunked Reading" and "VFS
Performance" text matches the checkout's `vfs/vfs.md` at that commit, so
this surface has no snapshot-vs-commit delta.
