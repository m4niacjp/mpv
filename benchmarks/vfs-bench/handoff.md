# Handoff — mpv rclone-VFS cold/warm benchmark + playlist-sort switch stall

Written 2026-09-12 at session end. Start here in a fresh session. The
companion memory index is
`.agent-memory/windows-performance-debugging/README.md`; load the two dated
notes listed under "Where everything lives" before acting.

## 1. Task context

We ran a controlled cold/warm VFS playback benchmark against the user's real
rclone mount (`wcrypt:` on `I:`, Wasabi S3, WinFsp), measured first-frame and
next-frame latency with plain/WPR/Procmon observers, and then investigated a
switch stall the A/B exposed in the user's Roaming Lua script
`playlist-sort.lua`. The benchmark matrix is complete and packaged. The
dominant switch stall was **fixed and validated on 2026-09-12** (script edits
#1/#2/#2b; final sha `ADDBFB64…`); see `fix-validation.md` in the report
package and `.agent-memory/windows-performance-debugging/
2026-09-12-mpv-playlist-sort-prefetch-stall.md`. The remaining job for a next
session is only the two open decisions (#3 core guard, #4 win32-shell note).

## 2. Where everything lives

- Harness: `benchmarks\vfs-bench\` (see `commands.md` in the report package for
  the full command history).
- Report package:
  `benchmarks\Run-20260912-041416-mpv-vfs-cold-warm\` — `report.md`,
  `manifest.json`, `environment.json`, `commands.md`, `artifacts.md`,
  `measurements\summary.csv`, `conditions.json`, `matrix-summary.json`,
  `captures.json`, `procmon-switch\*.json`, `wpa\…`.
- Memory notes:
  - `.agent-memory\windows-performance-debugging\2026-09-12-mpv-vfs-bench-corpus-cache-control.md`
    (corpus, cache control, A/B, fix provenance).
  - `.agent-memory\windows-performance-debugging\2026-09-12-mpv-playlist-sort-prefetch-stall.md`
    (this handoff's technical core).
- Run roots: `C:\Users\andre\PerfRuns\mpv-vfs-*` (trial JSON, logs, ETL/PML)
  and matrices `vfs-bench-matrix-20260911-212832.json` (batch 1),
  `…-220146.json` (batch 2), `…-220455.json` (batch 3).
- Analysis roots: `C:\PerfBench\analysis\{merged,procmon,wpa}\`.
- Corpus: `C:\PerfBench\videos\PB01..PB25.mkv`, manifests, `verify-media.json`.
- External research from this session:
  - `docs/references/web-search/docs/rclone-vfs-concurrent-read-starvation.md`
    (+ index) — external evidence (mpv single-open-slot verified upstream;
    no rclone cross-file starvation reports).
  - `DOCS/references/libraries/rclone/` and
    `.agent-memory/doc-search/libraries/rclone.md` — Context7 rclone docs.
- Facts: mpv `dist\mpv.exe` sha256 `587027333113EF9C3EC13A0E619A131CAC3243144CCD35BC2174AC73BEC2A302`,
  HEAD `2b0f9f46ca`; rclone v1.76.0-beta.10339.ef6968730 (repo commit
  `ef6968730`), mount RC `http://127.0.0.1:5574`, cache
  `D:\rclone-wasabi-cache`, `--vfs-handle-caching 60s`, `--transfers 240`,
  `--vfs-read-chunk-streams 0`, `--vfs-read-chunk-size 1M` limit `256M`.

## 3. What was accomplished

1. **Corpus**: 25 × 288 MiB 1080p30 H.264 files, full-decode verified 25/25,
   uploaded to `wcrypt:PerformanceBench/{Cold,Warm}` with 8 concurrent RC
   `operations/copyfile` calls (10.39 GiB in ~109 s, failed 0).
2. **Cache control**: cold = per-trial vfs data+meta deletion verified absent;
   warm = flushed `vfsMeta Rs` coverage 100 % (75 s settle + poll).
3. **Matrix**: 12 trials (4 conditions × plain/WPR/Procmon), 0 errors, all
   probe nexts first-try; warm removes the next-file penalty (config
   3.38 → 0.05 s; noconfig 1.77 → 0.07 s); Procmon inflates real-config start.
4. **A/B follow-up**: added `config-{cold,warm}-no-playlist-sort` conditions
   (script moved out of `%APPDATA%\mpv\scripts`, hash-guarded restore), plain
   repeats (`-PlainRepeats`, 75 s cooldown on span reuse); 24-trial merged
   analysis.
5. **Mechanism (VERIFIED in mpv source)**: see section 4.
6. **Playlist-sort tie-break fix applied and verified** (unrelated to the
   stall): equal non-name keys now tie-break by name ascending (Explorer
   behavior), then playlist index. Pre-fix sha `845471B3…`, post-fix sha
   `D6A59AC2…`; backup `%TEMP%\opencode\playlist-sort-prefix-backup.lua`.
   Verification: `#1 ♥︎dr…, #2 You Never…` (was reversed), 34 other positions
   unchanged.
7. **Traces**: Procmon switch-window extraction for all 6 procmon trials
   (`measurements/procmon-switch/*.json`); WPA Thread-Delays exports for two
   config-cold ETLs (marks-restricted). WPAExporter aggregates the preset per
   process, so per-event blocked stacks stay open; the prior session's ETL
   analysis already showed the aborted opener in `WrPageIn`/`NtReadFile`.

## 4. The dominant stall — anatomy, pre-fix (all VERIFIED unless noted)

At the first `playlist-next` with the real config, the transition costs an
extra deterministic ~0.9–2.1 s because of a **wrong-entry prefetch open that the
main open must join**. The applied fix is in section 5.

1. `playlist-sort.lua` sets `prefetch-playlist=false` in the first file's
   `on_before_start_file` (`gate_initial_autocreate_prefetch`, lines 198–246)
   and only releases it via `finish_sort` → `restore_prefetch("playlist order
   finalization")` (line 673) or at end-file (line 1113).
2. In the benchmark corpus the Explorer lookup for the folder fails
   (`explorer sort lookup failed … status 2` at 0.891 s) and **no
   finalization restore happens during file 1** — so prefetch never runs for
   the next entry. **OQ#1 resolved 2026-09-12: this is not a control-flow
   branch.** The fallback pass does start (`begin_sort` with
   `resolved_mode`), but `fill_keys` → `assign_stat_key` → `utils.file_info()`
   is a raw blocking `stat()` on the script thread (`player/lua.c:1118`); the
   stat of the actively-downloading playing file blocks it. Decisive Procmon
   (`config-cold-procmon-t2`, input PB11, pre-fix script): TID 2068 opened the
   playing file `Read Attributes, Synchronize` at 04:17:07.086
   (`file-loaded` + debounce, exactly when `begin_sort` ran) and that one
   `CreateFile` took **10.223 s**, completing at 04:17:17.309 = `end-file`;
   sibling stats were ≤1 ms and a no-script control had no such op (PB11 max
   3 ms). `apply_order` already skips identity reorders and does call
   `finish_sort` (lines 786–796), but it was never reached.
3. At end-file, `restore_prefetch` (lines 149–166) issues an **identity
   `playlist-reorder`** to "retarget final prefetch". That command calls
   `prefetch_next` (`player/command.c:6624`) while `mpctx->playing` is NULL
   (end-file/file-start transition), so it opens the entry **after** the one
   about to play.
4. mpv has a single `mpctx->open` slot (`player/loadfile_async.c:175`); the main
   open cannot start until the pending prefetch opener is joined
   (`destroy_open` `:145-147`). The main open logs `Aborting ongoing prefetch of
   wrong URL` (`:351-368`) and waits for the opener to unwind. Cancellation is
   cooperative, so the join equals the remainder of the opener's
   `demux_open_url` — 2 ms–2.07 s observed. The guard meant to prevent this
   (`:529-534`) is bypassed because `play_current_file` zeroes `stop_play`
   before the hook (`player/loadfile.c:1594`, hook `:1596`).

Observed numbers (merged 24 trials, n=2 plains):

| | with playlist-sort | without |
|---|---|---|
| `prefetchedAtNext` | 0 | 3 |
| switch | wrong-URL abort + join every time | `Using prefetched URL`, frame ~26–30 ms after teardown |
| plain `next→frame2` | 3.382 / 1.631 s | 1.126 / 2.480 s |
| WPR | 4.169 s | 0.494 s |
| Procmon | 1.070 s | 0.719 s |

Procmon switch windows: with the script the main file's `ReadFile`s block
0.50–0.61 s each; without it, prefetched reads are 0.16–0.18 s while the old
file's `CloseFile` costs 0.56 s and a later-entry prefetch read blocks up to
0.76 s. rclone-process rows are ~0 ms (cache writes/TCP receive) — the wait is
WinFsp-side. rclone (commit `ef6968730`) has **no cross-file download gate**
(per-file downloaders; `--transfers` does not govern VFS reads).

Residual after any fix: **demuxer force-termination** of the old file
(0.5–2.5 s, also a cooperative-cancel wait). Do not confuse it with the stall.

## 5. Applied fix path (2026-09-12; edits #1+#2+#2b)

Primary — script-level (Roaming Lua; applied with explicit user authorization
in two rounds because no `mpv-lua-scripter` agent exists in this environment):

1. **Made the retarget kick transition-safe** in `restore_prefetch`
   (lines 149–166): the identity `playlist-reorder` kick now runs only after a
   real order change (`prefetch_gate_order_applied`); if a retarget is
   genuinely needed while `playing == NULL`, it is deferred to a
   `playback-restart` handler.
2. **Release the prefetch gate during playback when the Explorer lookup is a
   memoized failure** (the failed-Explorer/fallback path): `try_auto_sort`
   calls `restore_prefetch` before the fallback `begin_sort`, so prefetch runs
   for the correct next entry even though the pass's stat then blocks.
2b. **Key-fill transition guard** (`begin_sort` captures the current playlist
   entry id; `fill_keys` aborts the pass when it changes). Added after the
   first validation showed the stat batch straddling the switch delayed the
   next file's `on_before_start_file` hook reply by the rest of the batch
   (4.1–11.6 s cold). This restores the no-script switch cost.

Final script sha256 `ADDBFB64D766CED10546486549C96C0B0B8136290A292ABD2F5D0AA9D16F8EB4`;
pre-fix `D6A59AC2…`; backups under `%TEMP%\opencode\`
(`playlist-sort-D6A59AC2-backup.lua`, `playlist-sort-fixed-final.lua`,
`playlist-sort-fixed-2b.lua`).

Validation results (matrix `vfs-bench-matrix-20260911-225854.json`, 4/4 ok):
`next→frame2` cold 1.06 / 0.40 s, warm 0.08 / 0.08 s; 0 wrong-URL aborts;
`prefetchedAtNext=3`; `Using prefetched URL` 4/4. Full detail in
`benchmarks\Run-20260912-041416-mpv-vfs-cold-warm\fix-validation.md`.

Secondary — mpv core hardening (applied 2026-09-12, later):

3. `prefetch_next()` no longer starts an open while a file start is pending:
   the guard in `loadfile_async.c` now checks `playlist->current !=
   mpctx->playing` for the whole handover instead of only
   `stop_play == PT_CURRENT_ENTRY`. Regression case
   `test_prefetch_hook_command` added to `test/libmpv_test_prefetch.c`
   (fails on the old guard, passes with it). Packaged-binary smoke
   (`%TEMP%\opencode\prefetch-hook-smoke.lua`): old `dist\mpv_bck.exe` starts a
   prefetch in the hook and aborts it as a wrong URL; new `dist\mpv.exe` does
   neither and prefetches only after the file start. `dist\mpv.exe` refreshed
   to `7C30234D…`; old validated binary kept at `dist\mpv_bck.exe`.

Rejected / deferred:

4. Core "detach the aborted opener and proceed" — rejected; conflicts with the
   deliberate single-open-slot adopt-or-discard design.
5. rclone chunk-size cap (e.g. `--vfs-read-chunk-size 4M`, streams) — deferred;
   it only shortens cooperative-cancel waits (opener and teardown) and is a
   global config change requiring a full re-benchmark. Revisit after 1+2.
6. Disabling `playlist-sort.lua` or `prefetch-playlist` — not acceptable
   feature-wise; the no-script arm was only an experiment.

## 6. Validation — completed 2026-09-12

1. Order regression: the original harness input
   (`Downloads\Video\ytdlp`) had been emptied, so an equivalent synthetic
   fixture was used (`%TEMP%\opencode\plsort-fixture{,-nox}`, controlled
   mtimes incl. a tied pair; Explorer forced for the success path). Pre-fix vs
   final script on the same fixture produced **byte-identical** final orders in
   both paths (Explorer success = name ascending; memoized failure = mtime
   ascending, tied pair by name). The old command still applies when a folder
   is available:
   `pwsh -NoProfile -File C:\Users\andre\AppData\Local\Temp\opencode\run-plsort.ps1 -Out C:\Users\andre\AppData\Local\Temp\opencode\plsort-fixed`.
2. Benchmark switch check: ran
   `pwsh -NoProfile -Command "& 'C:\Users\andre\Projects\mpv\benchmarks\vfs-bench\Invoke-BenchTrials.ps1' -Conditions config-cold,config-warm -Kinds plain -PlainRepeats 1"`
   (`-Command`, not `-File`, so comma arrays split). Final matrix
   `vfs-bench-matrix-20260911-225854.json`: 4/4 ok, 0 wrong-URL aborts,
   `Using prefetched URL` and the #2 pre-release message in all four logs,
   `prefetchedAtNext=3`, `maxPrefetched=3`. `next→frame2` (probe):
   cold 1.06 / 0.40 s (no-script arm 1.13 / 2.48 s; pre-fix script
   3.38 / 1.63 s), warm 0.08 / 0.08 s. Formal summary:
   `%TEMP%` run + `C:\PerfBench\analysis\vfs-bench-guard-20260912\` and
   `measurements\fix-validation\` in the report package.
3. I/O recheck not re-run (no traced trials in this validation); Procmon
   export options are unchanged: `Analyze-ProcmonSwitch.ps1`; WPA
   `-Marks workload-start,workload-end` with
   `C:\Users\andre\PerfRuns\mpv-stack-analysis-20260911\control\control-delays.wpaProfile`.

## 7. Open questions / decisions for the user

1. ~~Confirm which branch suppresses `finish_sort`~~ — **resolved 2026-09-12:
   no branch; the playing file's blocking `utils.file_info` stat held the
   script thread. See section 4 item 2 and `fix-validation.md`.**
2. ~~Authorize the Roaming Lua edit~~ — **authorized and applied; final sha
   `ADDBFB64…` (edits #1, #2, #2b).**
3. ~~Is an mpv core patch acceptable (fix #3)~~ — **implemented 2026-09-12**:
   `prefetch_next` guard broadened, `test_prefetch_hook_command` added;
   `dist\mpv.exe` refreshed to `7C30234D…`. Whether to prepare it as an
   upstream-ready commit remains a packaging choice.
4. ~~Persist the verified Explorer equal-mtime/name tie-break rule in
   `DOCS/references/libraries/win32-shell/`~~ — **done 2026-09-12**:
   `docs/sortcolumns.md` "Equal-key tie-break" section + front matter/index
   updated.
5. The local `DOCS/local-workflow.md` gained a `## VFS cold/warm benchmark
   harness` section (line ~208) and `AGENTS.md` gained a one-line pointer via
   `doc-keeper` during this handoff — **verified landed 2026-09-12** (additive
   only; `git diff --check` and codespell clean).

## 8. Challenges and lessons (avoid re-discovery)

- **Probe frame gating**: `estimated-frame-number` is get-computed and never
  emits change notifications; `observe_property` silently never fires. The
  probe polls on a 50 ms timer.
- **`Set-StrictMode` traps**: empty-pipeline `@(...)[0]` throws; assigning new
  keys on `[ordered]@{}` throws; a function returning a one-element array
  unrolls to a scalar; direct property reads on traced `result` objects throw.
  Fixed in `Invoke-BenchTrials.ps1`/`Summarize-BenchTrials.ps1`.
- **`$LASTEXITCODE`** is only set after a native process; use `$?` around script
  calls.
- **CLI arrays**: `pwsh -File script.ps1 -Conditions a,b` passes one string
  (ValidateSet rejects it); use `pwsh -Command "& script.ps1 -Conditions a,b"`.
  Same for `-Marks a,b` in `Export-WpaTables.ps1`.
- **Script presence toggle**: mpv probes every entry under `scripts\`, so
  renaming in place logs `Can't load unknown script`. Move the file out to
  `%APPDATA%\mpv\bench-disabled-scripts\` and restore with a SHA-256 guard.
- **rclone `vfs/refresh`**: after out-of-band remote changes, refresh the root
  with **no parameters** first, then `{dir, recursive:"true"}` (string), or the
  path stays invisible under `--dir-cache-time 72h`.
- **vfsMeta `Rs` flush lag**: metadata is written only after the 60 s handle
  grace; immediate coverage checks are false negatives. Warm mode waits 75 s
  and polls.
- **`options/set` cannot retune the live VFS** (`vfs.New()` copies options; no
  reload hook); a remount would also re-run `--vfs-refresh`.
- Do not run WPA/Procmon exports or other heavy analysis while trials run; the
  preflight policy will flag contamination.

## 9. Machine state at handoff

- `playlist-sort.lua` is in `%APPDATA%\mpv\scripts\` with the stall fix
  (edits #1/#2/#2b, sha `ADDBFB64…`); no parked copy under
  `bench-disabled-scripts\`. Backups: `%TEMP%\opencode\`
  (`playlist-sort-D6A59AC2-backup.lua`, `playlist-sort-fixed-final.lua`,
  `playlist-sort-fixed-2b.lua`). Synthetic order fixture:
  `%TEMP%\opencode\plsort-fixture{,-nox}`.
- `dist\mpv.exe` now embeds the core guard:
  `7C30234D1D33419B111975302279D9489E5D150A18FA7D1F3C792363A0A7889F`
  (`v0.41.0-948-g2b0f9f46c-dirty`, built 2026-09-12 06:09:49); the previously
  validated benchmark binary `58702733…` is kept at `dist\mpv_bck.exe`.
- No mpv/Procmon/WPR processes left; rclone log level `INFO`; mount PID 29148.
- Validation matrices: `vfs-bench-matrix-20260911-225854.json` (final),
  `…224807.json` (intermediate #1+#2, retained).
- Unrelated user changes to preserve: `DOCS/optimization_implementation.md`,
  `osdep/io.c`, `test/libmpv_test_prefetch.c`; untracked `benchmarks/`,
  `dist/`, `.playwright-cli/`, `.agent-memory/`, `DOCS/references/…`,
  `install.cmd`, `remember-rtx.state`.
- Keep raw ETL/PML/large CSVs out of Git.
