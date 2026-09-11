---
topic: rclone-vfs-concurrent-read-starvation
retrieved_at: 2026-09-12
sources:
  - https://rclone.org/commands/rclone_mount/
  - https://raw.githubusercontent.com/rclone/rclone/ef6968730/docs/content/commands/rclone_mount.md
  - https://raw.githubusercontent.com/rclone/rclone/ef6968730/vfs/read.go
  - https://api.github.com/repos/rclone/rclone/contents/vfs/vfscache?ref=ef6968730
  - https://forum.rclone.org/t/the-new-parameter-vfs-read-chunk-streams-for-vfs/47677
  - https://github.com/rclone/rclone/issues/4760
  - https://forum.rclone.org/t/new-feature-vfs-read-chunk-size/5683
  - https://forum.rclone.org/t/concurrent-read-accesses-on-the-same-file-through-rclone-vfs-mount/17192
  - https://raw.githubusercontent.com/mpv-player/mpv/v0.41.0/player/loadfile.c
  - https://raw.githubusercontent.com/mpv-player/mpv/v0.41.0/DOCS/interface-changes.rst
  - https://mpv.io/manual/stable/
  - https://github.com/mpv-player/mpv/issues/5940
search_id: search_7cd2984aff07391cbef3c82b8f13bede
---

# rclone VFS concurrent reads and mpv prefetch open contention

Question under test (measured on Windows 11 + WinFsp, rclone v1.76.0-beta.10339.ef6968730,
mpv v0.41.0-947-gd37b8c1a7 fork): with
`--vfs-cache-mode full --vfs-read-chunk-streams 0 --vfs-read-chunk-size 1M
--vfs-read-chunk-size-limit 256M --buffer-size 0 --vfs-read-ahead 0`, can a *new* file
open be delayed or starved while file A's VFS download is in flight, and can an mpv
`prefetch-playlist` open contend with the main open?

Per-sub-question results (external evidence only; local fork code not analyzed here):

1. **Chunk-doubling mechanics — VERIFIED (official docs).**
2. **mpv prefetch vs. real open serialization — VERIFIED (upstream mpv v0.41.0 source).**
3. **rclone cross-file open starvation — NOT SUPPORTED by any external evidence found;
   not refuted. Treat as unproven (INCONCLUSIVE).**
4. **Whether chunked reading applies under `--vfs-cache-mode full` — UNVERIFIED (gap).**

## 1. rclone chunked reading at `--vfs-read-chunk-streams 0` (official docs)

Official `rclone mount` docs, VFS Chunked Reading (text identical in the version-matched
copy at the user's commit `ef6968730`):

- `--vfs-read-chunk-streams == 0`: "Rclone will start reading a chunk of size
  `--vfs-read-chunk-size`, and then double the size for each read. When
  `--vfs-read-chunk-size-limit` is specified, and greater than `--vfs-read-chunk-size`,
  **the chunk size for each open file** will get doubled only until the specified value
  is reached."
- Worked example: `--vfs-read-chunk-size 100M --vfs-read-chunk-size-limit 500M` produces
  parts 0-100M, 100M-300M, 300M-700M, 700M-1200M, ... (geometric growth until the cap).
  So `1M + limit 256M` yields 1M, 2M, 4M ... capped at 256M per request.
- "The chunks will not be buffered in memory." (Sequential reader; `--buffer-size` /
  `--vfs-read-ahead` are what buffer, which are 0 in the measured config.)
- The docs' next subsection heading is `#### 0` but its text describes *concurrent*
  chunk reads ("Rclone reads `--vfs-read-chunk-streams` chunks ... concurrently. The
  size for each read will stay constant."). This heading appears to be an upstream docs
  bug; the concurrent/constant-size behavior belongs to `streams > 0`. Do not read the
  `#### 0` heading as applying to the measured `streams 0` config.
- No official statement was found about *per-request latency* as chunks grow; that
  latency effect is inference, not documented.

Version note: docs retrieved 2026-09-12 and cross-checked against
`docs/content/commands/rclone_mount.md` at commit `ef6968730` (the measured build);
wording matches.

## 2. Concurrency model of VFS reads (per open file, no documented cross-file scheduler)

- Version-matched source `vfs/read.go` @ `ef6968730`: each `ReadFileHandle` has its own
  `mu sync.Mutex` and its own reader created in `openPending()`:
  `chunkedreader.New(ctx, o, ChunkSize, ChunkSizeLimit, ChunkStreams)`. Chunk state is
  per open file; the file contains no global read lock/semaphore shared across files.
- Official docs, VFS Performance: for VFS write caching, "the global flag `--transfers`
  can be set to adjust the number of parallel **uploads** of modified files from the
  cache (the related global flag `--checkers` has no effect on the VFS)." No VFS
  *download* concurrency limit or scheduler is documented.
- Feature author (B4dM4n, 2018-05-20, forum guide for `--vfs-read-chunk-size`, v1.42-era):
  "`--vfs-read-chunk-size` will not cache or share any data between multiple readers. It
  works fully transparent in the vfs layer..." — per-reader chunk state, no sharing.
  (Version differs from 1.76; concept unchanged in the docs above.)
- Maintainer ncw (2024-09-13/17, forum): "The new `--vfs-read-chunk-streams` parameter
  enables parallel downloading of files" and points to rclone issue #4760 as the
  rationale; ncw suggests `--vfs-read-chunk-streams 16 --vfs-read-chunk-size 4M` for
  high-performance backends. Issue #4760 ("Support multi-threaded downloads when
  downloading a file to the cache", opened 2020-11-11, closed 2024-09-23) is about
  parallelizing **one file's** download, not about cross-file scheduling.
- Same-file serialization is real (but only within one file): ncw, June 2020, on
  concurrent random reads of the *same* file: "the filehandle mutex still
  sequentializes all the concurrent random IO requests"; "For the ReadFileHandle the
  reads need to proceed sequentially at the moment." (v1.52-era, pre-`--vfs-read-chunk-streams`.)
- Not inspected: `vfs/vfscache/downloaders/` is a *package directory* at `ef6968730`
  (per the GitHub contents API), i.e. the full-mode cache downloader was reorganized
  out of a single `downloaders.go`. Cross-file synchronization inside that package was
  not read (budget stop), so a hidden per-cache or per-remote constraint there is not
  excluded by evidence.

## 3. mpv `prefetch-playlist` vs. the next real open (upstream v0.41.0 source — VERIFIED)

Source: `player/loadfile.c` at tag `v0.41.0` (the measured mpv is a fork
`v0.41.0-947-gd37b8c1a7`; this checkout contains the same message in
`player/loadfile_async.c`, but only upstream was verified externally):

- Exactly **one open in flight, shared by prefetch and real opens**: `prefetch_next()`
  returns early `if (!mpctx->opts->prefetch_open || mpctx->open_active)`; a real open
  calls `start_open(..., for_prefetch=false)` into the same `open_active` slot/thread.
- `open_demux_reentrant()`: when a real open arrives while the active open is a prefetch
  of a different URL, it logs `Aborting ongoing prefetch of wrong URL.` (also
  "...because demuxer options changed") and calls `cancel_open(mpctx)`.
- `cancel_open()` is **synchronous**: it triggers `mp_cancel_trigger(open_cancel)`, then,
  if `open_active`, executes `mp_thread_join(mpctx->open_thread)` and frees the result
  demuxer. Only afterwards does `open_demux_reentrant()` run `start_open()` for the new
  URL and then wait for `open_done`.
- Consequence (source-level): the real open cannot be started or complete until the
  aborted prefetch open's `demux_open_url()` call returns to its thread and the join
  completes. A slow/pending prefetch open (e.g. blocking I/O into the rclone mount)
  therefore delays the next real open even though mpv discards the prefetch. This is the
  exact ordering observed in the benchmark; it needs no rclone-side cross-file starvation.
- `prefetch_next()` is only called when the current entry is near its end (manual:
  "as soon as the current URL is fully read"), so in the measured scenario the prefetch
  of C must have started at the very end of A and was still opening when B was requested.

Official option doc (mpv.io manual, stable/master as retrieved 2026-09-12):
`--prefetch-playlist` "Prefetch next playlist entry while playback of the current entry
is ending (**default: no**). This merely opens the URL of the next playlist entry as
soon as the current URL is fully read." `DOCS/interface-changes.rst` at v0.41.0 lists
"change `--prefetch-playlist` default to `no`" (current), and a historical entry
"change `--prefetch-playlist`'s default to `yes`" (earlier release). Version matters
when comparing reports.

Only related community report found: mpv issue #5940 "Parallel prefetch"
(2018-06-21, closed 2019-10-25; mpv 0.30-era): user reported the prefetch did not start
until the current URL was fully downloaded, i.e. the opposite direction of contention;
a commenter could not reproduce. No public report was found of a prefetch open delaying
the user's next open; that behavior is visible only in the source above.

## 4. Cross-file starvation reports (rclone)

Targeted searches (rclone forum, GitHub, general web) for a new open/read being delayed
or blocked by another file's in-flight chunked download or read-ahead returned **no
matching report** at rclone >= 1.70. The nearest items were unrelated open-hang bugs
(e.g. forum topic 53986, 2026-06-30, v1.74.x, `--vfs-handle-caching` + Excel; not a
concurrent-file case). Absence of a report is weak evidence of absence; it does not
refute a WinFsp/backend/transport-level queueing effect.

## Statements that would change the mechanism being tested

- If the mechanism assumes a *rclone-side* cross-file scheduler or lock, current official
  docs and `vfs/read.go` show none; the observed serialization is already explained by
  mpv's single open slot plus `mp_thread_join` in `cancel_open()`.
- If chunk doubling does not apply in `--vfs-cache-mode full` (unverified; see Gaps),
  then A's in-flight request size is governed by the vfscache downloader, not by the
  1M→256M sequence, and the chunk-limit hypothesis needs re-basing.
- If it does apply, the largest single in-flight range for A is 256M (not 1M), which
  sets the scale of any backend/transport queueing effect on C/B.
- mpv's join means the delay is bounded below by the residual `demux_open_url()` time of
  the aborted prefetch; the "abort" does not shorten that call, it only prevents reuse.
  Disabling prefetch (or not issuing a prefetch that must be aborted) removes the join
  dependency entirely.

## Gaps (for a follow-up facet, not settled here)

1. Does `--vfs-read-chunk-size`/chunk doubling apply under `--vfs-cache-mode full` at
   commit `ef6968730`? Next step: read `vfs/vfscache/downloaders/` package (contents API
   at that commit) and check for `chunkedreader` usage; or run a controlled rclone mount
   with `-vv --log-level DEBUG` and look for `ChunkedReader.openRange` while in full mode.
2. Is there any per-cache or per-remote download concurrency/queue inside
   `vfs/vfscache/downloaders/`? Same source read as above.
3. Fork-specific: the measured mpv (`m4niacjp/mpv`, `player/loadfile_async.c`) may have
   different locking than upstream v0.41.0; verify its prefetch cancel path locally.
