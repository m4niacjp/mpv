# 2026-09-12 — playlist-sort switch-stall fix: OQ#1 resolution + applied/validated

Follow-up to `2026-09-12-mpv-playlist-sort-prefetch-stall.md`. Fix applied and
validated the same day; deliverable
`benchmarks\Run-20260912-041416-mpv-vfs-cold-warm\fix-validation.md`; brief
`benchmarks\vfs-bench\handoff.md`.

## Scenario

Apply and validate the switch-stall fix for the user's Roaming
`playlist-sort.lua` on the real rclone/WinFsp mount (same corpus/harness as the
2026-09-12 matrix; binary `58702733…`, HEAD `2b0f9f46ca`).

## OQ#1 — why `finish_sort` did not finalize — VERIFIED (not a branch)

The failed-Explorer fallback pass *does* start and `apply_order` *does* call
`finish_sort`; it never got there because the synchronous key fill blocked the
script thread: `utils.file_info()` is a raw `stat()` (`player/lua.c:1118`).
Decisive Procmon (`config-cold-procmon-t2`, input PB11, pre-fix script):
TID 2068 `CreateFile` `Desired Access: Read Attributes, Synchronize` on the
playing file started 04:17:07.086 (probe `file-loaded` + debounce = when
`begin_sort` ran) and took **10.223 s**, completing at 04:17:17.309 = `end-file`
(probe t=19.151). Sibling stats ≤1 ms; a no-script control had no such op
(PB11 max 3 ms). While blocked, no finish/timer could run; the queued
`end-file` handler was the first Lua code after the switch aborted the read.
Scanner: `%TEMP%\opencode\find-precursor-ops.ps1`; CSV in the 21:14 run dir.

## Applied edits (Roaming Lua, authorized)

Pre-fix `D6A59AC2…` → final **`ADDBFB64D766CED10546486549C96C0B0B8136290A292ABD2F5D0AA9D16F8EB4`**
(intermediate #1+#2 `86287D21…`). Backups in `%TEMP%\opencode\`.
1. Retarget kick only after a real order change; deferred to `playback-restart`
   while `playing == NULL` (removes the end-file identity kick).
2. Release the prefetch gate when a memoized Explorer failure starts the
   fallback pass (before its blocking stat); a later real reorder retargets via
   core.
3. Key-fill transition guard: capture the current playlist entry id at
   `begin_sort`, abort the pass when it changes. Needed because the stat batch
   straddling a switch delayed the next file's `on_before_start_file` hook
   reply by the batch remainder (4.1–11.6 s cold with prefetch loading the
   stat'ed siblings); the queued `start-file`/`cancel_job` cannot run while the
   Lua batch is executing.
   Also fixed a Lua idiom bug found in validation: `dir and
   request_explorer_sort(dir) or nil` converted the memoized `false` failure
   marker back to `nil`, silently disabling edit #2.

## Validation (VERIFIED)

- Order regression: original fixture folder had been emptied; synthetic
  fixture A/B (success + memoized-failure) — final output byte-identical to
  pre-fix in both paths.
- Benchmark matrix `vfs-bench-matrix-20260911-225854.json` (config-cold/warm,
  plain ×2), 4/4 ok: 0 `Aborting ongoing prefetch of wrong URL`,
  `Using prefetched URL` 4/4, `prefetchedAtNext=3`, `maxPrefetched=3`,
  `nextAttempts=1`. `next→frame2`: cold 1.06/0.40 s (no-script 1.13/2.48;
  pre-fix script 3.38/1.63), warm 0.08/0.08 s.
- Hook gap (next→start-file2) collapsed from 11.62/4.05 s (#1+#2 only,
  retained matrix `…224807.json`) to 1.00/0.36 s with the guard.
- Caveat: the two cold preflights flagged pages/s 31 430 / 4 633 (recorded,
  not enforced); warm preflights clean.

## Residual / open

- `utils.file_info` can still block the script thread for the rest of a file
  on cold WinFsp; the guard now bounds its impact to the next-file handoff.
  **The mpv core guard (#3) was implemented later the same day** — see
  `2026-09-12-mpv-prefetch-core-guard.md`.
- `DOCS/references/libraries/win32-shell/` tie-break note **done later the
  same day** — see the same note.
