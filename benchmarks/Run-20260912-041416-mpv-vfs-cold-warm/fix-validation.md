# playlist-sort switch-stall fix — applied and validated (2026-09-12)

Follow-up to this package's A/B: the wrong-entry prefetch open at the
`playlist-next` transition (dominant stall) was fixed in the user script and
re-validated. Companion memory:
`.agent-memory/windows-performance-debugging/2026-09-12-mpv-playlist-sort-prefetch-stall.md`
(plus `…-fix-applied.md`) and the fresh-session brief
`benchmarks\vfs-bench\handoff.md`.

## Applied script changes

Script: `%APPDATA%\mpv\scripts\playlist-sort.lua`.

| state | sha256 | note |
| --- | --- | --- |
| pre-fix (tie-break only) | `D6A59AC2…` | backup `%TEMP%\opencode\playlist-sort-D6A59AC2-backup.lua` |
| #1+#2 only | `86287D2165…` | intermediate, retained matrix `vfs-bench-matrix-20260911-224807.json` |
| final (#1+#2+#2b) | `ADDBFB64D7…` | copy `%TEMP%\opencode\playlist-sort-fixed-2b.lua` |

1. **#1 retarget kick is transition-safe**: the identity `playlist-reorder`
   kick now runs only after a real order change (`prefetch_gate_order_applied`)
   and is deferred to `playback-restart` when no file is playing; the
   `end-file` identity kick that started the wrong-URL prefetch is gone.
2. **#2 fallback gate pre-release**: when the Explorer lookup for the directory
   is a memoized failure, the prefetch gate is released as the fallback pass
   starts (before its blocking `utils.file_info` key fill), so the correct next
   entry is prefetched during file 1.
3. **#2b key-fill transition guard**: `begin_sort` captures the current
   playlist entry id and `fill_keys` aborts (`cancel_job`) as soon as the
   current entry changes. Without it, the synchronous stat batch straddling a
   switch delayed the next file's `on_before_start_file` hook reply by the rest
   of the batch (4.1–11.6 s cold with prefetch loading the stat'ed siblings).

## OQ#1 — why `finish_sort` did not finalize — VERIFIED (no branch)

The failed-Explorer path does enter the fallback pass and `apply_order` does
call `finish_sort`; the pass never reached them because
`fill_keys` → `assign_stat_key` → `utils.file_info()` is a raw blocking
`stat()` on the script thread (`player/lua.c:1118`). Decisive Procmon evidence
(`config-cold-procmon-t2`, input PB11, pre-fix script): TID 2068 opened the
playing file with `Desired Access: Read Attributes, Synchronize` at
04:17:07.086 — `file-loaded + debounce`, when `begin_sort` ran — and the single
`CreateFile` took **10.223 s**, completing at 04:17:17.309, exactly `end-file`
(probe t=19.151). Sibling stats were ≤1 ms; the no-script control trial showed
no such op (PB11 max 3 ms). While the script thread was blocked, no
`finish_sort`/timer could run; the queued `end-file` handler was the first Lua
code to run after the switch aborted the read.

Raw scan helper: `%TEMP%\opencode\find-precursor-ops.ps1`; Procmon CSV under
`C:\Users\andre\PerfRuns\mpv-vfs-config-cold-20260911T211415412Z-…\exports\`.

## Validation

### Order regression

The original harness input (`Downloads\Video\ytdlp`) was empty at validation
time, so an equivalent local fixture was used
(`%TEMP%\opencode\plsort-fixture{,-nox}`, controlled mtimes incl. a tied pair;
Explorer forced for the success path). Pre-fix vs final script on the same
fixture produced **byte-identical** final orders in both paths (Explorer
success: name ascending; memoized failure: mtime ascending with the tied pair
resolved by name). Harness: `run-plsort.ps1` / `run-plsort-gated.ps1` +
`plsort-observer*.lua` in `%TEMP%\opencode\`.

### Benchmark switch check (section 6.2)

Matrix `C:\Users\andre\PerfRuns\vfs-bench-matrix-20260911-225854.json`
(`config-cold`, `config-warm`; plain; `-PlainRepeats 1`), 4/4 trials ok, 0
errors, `nextAttempts=1` all trials.

| trial | hook gap (next→start-file2) | open gap | next→frame2 | prefetched at next |
| --- | ---: | ---: | ---: | ---: |
| config-cold-plain-t0 | 1.00 | 0.03 | **1.06** | 3 |
| config-cold-plain-t1 | 0.36 | 0.02 | **0.40** | 3 |
| config-warm-plain-t0 | 0.01 | 0.04 | **0.08** | 3 |
| config-warm-plain-t1 | 0.01 | 0.03 | **0.08** | 3 |

Summarizer (`measurements\fix-validation\summarize-trials.csv`):
`nextToFirstFrame2` config-cold min 0.386 / median 1.039 (n=2); config-warm
min 0.063 / median 0.065; `maxPrefetched=3`, `prefetchedAtNext=3` all trials.

Assertions: **0** `Aborting ongoing prefetch of wrong URL`; `Using prefetched
URL` and the #2 pre-release message in all four logs; next entry (PB02),
next+1 (PB03) and next+2 (PB04) prefetched in all `before-next` snapshots.

Comparisons: no-script cold arm 1.126 / 2.480 s; pre-fix script cold
3.382 / 1.631 s; intermediate #1+#2 cold 11.67 / 4.10 s (hook gap dominated —
that matrix is retained as evidence for #2b). Warm was 0.047–0.093 s in all
arms.

Caveat: the two `config-cold` preflights flagged pages/s 31 430 / 4 633
(threshold 4 000; `-EnforcePreflight` not used). The effect is recorded, not
corrected; the warm preflights were clean.

## Follow-up (2026-09-12, later)

- **Core guard #3 implemented.** `prefetch_next()` now returns while
  `playlist->current != mpctx->playing` for the whole file-start handover,
  not only while `stop_play == PT_CURRENT_ENTRY` (`player/loadfile_async.c`);
  hooks/events that call playlist commands in that window can no longer start
  a wrong-entry open. Regression case `test_prefetch_hook_command` in
  `test/libmpv_test_prefetch.c` fails on the old guard ("prefetch started
  while the file start was pending") and passes with it. `dist\mpv.exe`
  refreshed to sha256
  `7C30234D1D33419B111975302279D9489E5D150A18FA7D1F3C792363A0A7889F`
  (mpv `v0.41.0-948-g2b0f9f46c-dirty`, built 2026-09-12 06:09:49); the
  previously validated binary remains at `dist\mpv_bck.exe`
  (`58702733…`).
- **#4 done.** The verified Explorer equal-key name tie-break is persisted in
  `DOCS/references/libraries/win32-shell/docs/sortcolumns.md` ("Equal-key
  tie-break") with the live-verification summary and caveats.
