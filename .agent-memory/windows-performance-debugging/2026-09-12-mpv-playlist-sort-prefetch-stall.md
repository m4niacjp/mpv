# 2026-09-12 — playlist-sort switch stall: wrong-URL prefetch + gate analysis

## Scenario

Post-A/B follow-up of the VFS cold/warm benchmark (see
`2026-09-12-mpv-vfs-bench-corpus-cache-control.md` and the run package
`benchmarks\Run-20260912-041416-mpv-vfs-cold-warm\`). Live config
`%APPDATA%\mpv` with `autocreate-playlist=filter`, `prefetch-playlist=yes`
(max 3, realtime, on-cache) and the user script
`%APPDATA%\mpv\scripts\playlist-sort.lua` (pre-fix sha `845471B3…`; tie-break
fix applied after the matrix, sha `D6A59AC2…`).

## Verified mechanism (mpv source, HEAD 2b0f9f46ca)

- One `mpctx->open` slot (`player/loadfile_async.c:175`); the main open cannot
  start until a pending prefetch opener is joined (`destroy_open` `:145-147`).
- `restore_prefetch` in `playlist-sort.lua` (lines 149-166) issues an identity
  `playlist-reorder` at end-file to "retarget final prefetch". That command
  calls `prefetch_next` (`player/command.c:6624`) while `mpctx->playing` is
  NULL (end-file / file-start transition), so it opens the entry AFTER the one
  about to play. The main open then logs `Aborting ongoing prefetch of wrong
  URL` (`loadfile_async.c:351-368`) and joins the aborted opener. Cancellation
  is cooperative; observed join 2 ms–2.07 s.
- The existing guard (`loadfile_async.c:529-534`, `stop_play == PT_CURRENT_ENTRY
  && playlist->current != playing`) is bypassed because `play_current_file`
  zeroes `stop_play` before the hook (`player/loadfile.c:1594`, hook `:1596`).
- The prefetch gate (`gate_initial_autocreate_prefetch`, script lines 198-246)
  is released by `finish_sort` → `restore_prefetch("playlist order
  finalization")` (line 673) or at end-file (line 1113). In the benchmark
  corpus no finalization restore happened during file 1 (Explorer lookup for
  `I:\PerformanceBench\Cold` failed, status 2), so prefetch never ran for the
  next entry and the end-file kick caused the stall. `apply_order` already
  skips identity reorders and does call `finish_sort` (lines 793-796), so the
  missing piece is that the failed-lookup fallback pass did not finalize
  during playback.

## A/B numbers (merged 24 trials; n=2 plains)

- With script: `prefetchedAtNext=0`; every switch wrong-URL abort; plain
  3.382/1.631 s, WPR 4.169 s, Procmon 1.070 s.
- Without script (parked): `prefetchedAtNext=3`, `Using prefetched URL`, first
  frame ~26-30 ms after old-demuxer teardown; plain 1.126/2.480 s, WPR 0.494 s,
  Procmon 0.719 s. Residual = demuxer force-termination (0.5-2.5 s,
  cooperative cancel of the old demuxer thread).
- Procmon switch windows: with script main `ReadFile`s block 0.50-0.61 s each;
  without, prefetched reads 0.16-0.18 s while the old file's `CloseFile` costs
  0.56 s. rclone-process rows are ~0 ms (cache writes/TCP receive); the wait is
  WinFsp-side. rclone at commit `ef6968730` has no cross-file download gate.

## Recommended fix path (analysed, NOT applied)

1. Script (primary): make `restore_prefetch`'s retarget kick safe — skip the
   identity reorder, and if a retarget is genuinely needed after a real reorder,
   defer it until the new file is playing (`playback-restart`) instead of the
   file-start transition.
2. Script (primary): release the gate during playback whenever the sort is
   final or will not change the order (failed-Explorer fallback path), so
   prefetch runs for the next entry during file 1.
3. mpv core (defense in depth): stop `prefetch_next` from starting an open
   while a file start is pending (fix the bypassed guard); extend
   `test/libmpv_test_prefetch.c`.
4. Core "detach the aborted opener" — rejected (conflicts with the single-open
   slot design).
5. rclone chunk-size cap — deferred; addresses only the teardown residual and
   is a global config change needing a re-benchmark.

Best path: 1+2 (reproduces the no-script A/B end state); 3 optional hardening.

## Current state / next

- **Fixed and validated 2026-09-12**: see
  `2026-09-12-mpv-playlist-sort-fix-applied.md` and
  `benchmarks\Run-20260912-041416-mpv-vfs-cold-warm\fix-validation.md`.
  Final script sha `ADDBFB64…`; cold `next→frame2` 1.06/0.40 s (no-script
  1.13/2.48), warm 0.08 s; no wrong-URL aborts; `prefetchedAtNext=3`.
- Remaining open items: mpv core guard #3 and the `win32-shell` tie-break
  reference note.
- Fresh-session brief: `benchmarks\vfs-bench\handoff.md`.
