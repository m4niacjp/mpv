# Performance investigation: mpv rclone-VFS cold/warm first-frame and next-frame matrix

## Question and environment

- **Operation / expected behavior / primary metric.** Play a remote playlist
  through the WinFsp mount: 300 presented video frames of the first file, issue
  `playlist-next`, 300 frames of the second file, quit. Primary metrics:
  `Opening done` → first presented frame, probe `cmd-playlist-next` → first
  presented frame of file 2, `playback-restart` times, and prefetch/backend
  deltas. Expected: warm VFS ≪ cold VFS; the real user config prefetches the
  next entry while `--no-config` does not.
- **Boundary and timebase.** Process start → probe `quit`. All event times are
  mpv `mp_get_time()` (same clock as the `[%8.3f]` mpv log lines). Anchors:
  `first video frame after restart shown`, `Opening done:`, probe events
  `frames-reached`, `cmd-playlist-next`, `cmd-quit`.
- **Input identity.** `PB01`–`PB25.mkv`, each 288 MiB (301–302 MB), 1920×1080
  H.264 30 fps, 5:00, AAC 2ch, 25/25 full-decode verified
  (`C:\PerfBench\verify\verify-media.json`); per-file manifests under
  `C:\PerfBench\manifests\`. Remote: `wcrypt:PerformanceBench/{Cold,Warm}`.
- **Executable / build.** `dist\mpv.exe`, SHA-256
  `587027333113EF9C3EC13A0E619A131CAC3243144CCD35BC2174AC73BEC2A302`,
  `mpv v0.41.0-947-gd37b8c1a7-dirty`, HEAD `2b0f9f46ca`.
- **Machine.** Ryzen 9 9950X3D (16C/32LP), 95.7 GB RAM, RTX 5070 Ti,
  Windows 11 Pro Insider 26220; D: free 1405 GB, C: free 549 GB (at setup).
- **Mount.** rclone v1.76.0-beta.10339.ef6968730, `--vfs-cache-mode full`,
  `--vfs-read-chunk-size 1M`, `--vfs-read-chunk-size-limit 256M`,
  `--vfs-read-chunk-streams 0`, `--buffer-size 0`, `--vfs-read-ahead 0`,
  `--vfs-handle-caching 60s`, `--dir-cache-time 72h`, `--transfers 240`,
  `--s3-chunk-size 32M`; RC `http://127.0.0.1:5574`.

## Measurement and collection

Conditions (serial, one mpv at a time; n = 1 per cell):

| Condition | Config | Cache | Input spans (plain / WPR / Procmon) |
| --- | --- | --- | --- |
| `config-cold` | real `%APPDATA%\mpv` | Cold | PB01–05 / PB06–10 / PB11–15 |
| `config-warm` | real `%APPDATA%\mpv` | Warm | PB01–05 / PB06–10 / PB11–15 |
| `noconfig-cold` | `--no-config --autocreate-playlist=filter` | Cold | PB16–17 / PB18–19 / PB20–21 |
| `noconfig-warm` | `--no-config --autocreate-playlist=filter` | Warm | PB16–17 / PB18–19 / PB20–21 |

- **Cache state control.** Cold: per-trial span `vfs` data+meta deleted and
  verified absent; spans are disjoint so the 60 s VFS handle grace never races
  the reset. Warm: `vfsMeta Rs` coverage verified 100 % after the meta-flush
  wait (75 s settle + poll). System-wide standby purge before every trial.
- **Trial kinds.** `plain` (probe + in-process samples + rclone `core/stats`
  deltas), `wpr` (CPU.Light + GPU.Light + FileIO.Light + Network.Light, memory
  logging), `procmon` (duration/TID config, begin/end marker check, PML → CSV).
- **Failures retained.** The first matrix attempt (run dir
  `mpv-vfs-config-cold-20260911T210941914Z-26784bc7d54a24aa6713157…`, 04:09)
  aborted after trial 1: `observe_property("estimated-frame-number")` never
  fires (computed property) and two `Set-StrictMode` hazards
  (`@(...)[0]` on empty results, new keys on `[ordered]@{}`). Harness fixed and
  smoke-tested (20.6 s probe run, `frames-reached` ×2, `cmd-playlist-next`,
  `cmd-quit`); the retained attempt has no trial JSON. The successful matrix ran
  04:14:16 → 04:28:32 local, 12/12 trials `ok`, 0 errors.
- **Observer overhead.** Procmon dominates cold-config startup: `config-cold`
  probe load 0.16 s → 7.52 s and `playback-restart` 1.76 s → 8.76 s under
  capture (5×), while `noconfig-cold` restart stayed 1.22 s → 1.33 s. WPR
  overhead was small (restart 1.54 s vs 1.76 s plain). WPR recorded 0 dropped
  events; Procmon found both markers (6 begin / 6 end rows) and restored its
  settings.

## Results

Plain-runner metrics (seconds on the mpv clock); traced rows use the same probe
anchors. `open→frame1` = first frame − `Opening done`, file 1; `next→frame2` =
first frame of file 2 − probe `cmd-playlist-next`. **`Opening done` is emitted
only after the demuxer has probed the file** — i.e. after the network fetch on
cold runs — so the 0.05–0.36 s `open→frame1` values are post-demux pipeline
latency, not cold-open latency. Absolute anchors (plain): config-cold
`Opening done` 1.704 s / first frame 1.756 s; noconfig-cold 0.840 / 1.199 s;
config-warm 0.192 / 0.251 s; noconfig-warm 0.009 / 0.314 s.

| Trial | wall | open→frame1 | restart1 | next→frame2 | restart2 | next attempts | maxPrefetched | prefetchedAtNext | backend ΔMB |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| config-cold plain | 25.94 | 0.052 | 1.759 | 3.382 | 15.147 | 1 | 3 | 0 | 675.8 |
| config-cold WPR | — | 0.080 | 1.537 | 4.169 | 15.707 | 1 | 3 | 0 | — |
| config-cold Procmon | — | 0.075 | 8.763 | 1.070 | 19.827 | 1 | 3 | 0 | — |
| config-warm plain | 20.60 | 0.059 | 0.256 | 0.047 | 10.289 | 1 | 3 | 3 | 0 |
| config-warm WPR | — | 0.098 | 0.307 | 0.117 | 10.435 | 1 | 3 | 3 | — |
| config-warm Procmon | — | 0.285 | 0.560 | 0.072 | 10.925 | 1 | 3 | 3 | — |
| noconfig-cold plain | 23.15 | 0.359 | 1.216 | 1.769 | 12.947 | 1 | 0 | 0 | 308.3 |
| noconfig-cold WPR | — | 0.397 | 0.942 | 0.728 | 11.619 | 1 | 0 | 0 | — |
| noconfig-cold Procmon | — | 0.819 | 1.331 | 2.396 | 13.694 | 1 | 0 | 0 | — |
| noconfig-warm plain | 20.56 | 0.305 | 0.333 | 0.073 | 10.359 | 1 | 0 | 0 | 0 |
| noconfig-warm WPR | — | 0.362 | 0.392 | 0.080 | 10.458 | 1 | 0 | 0 | — |
| noconfig-warm Procmon | — | 0.467 | 0.505 | 0.080 | 10.576 | 1 | 0 | 0 | — |

## Findings, ordered by measured impact

1. **VERIFIED — warm VFS removes the next-file fetch penalty.** `next→frame2`
   for the plain trials: config 3.382 s (cold) vs 0.047 s (warm) — ~72×;
   noconfig 1.769 s vs 0.073 s — ~24×. Evidence: probe `cmd-playlist-next` and
   `first video frame after restart shown` anchors in the matrix summary and
   `measurements/summary.csv` (n = 1 per cell).
2. **VERIFIED — the first-file cold cost is before `Opening done`; `open→frame1`
   does not measure it.** Cold config open: request at 0.167 s → `Opening done`
   1.704 s (1.54 s) → first frame 1.756 s. noconfig-cold: 0.01 → 0.840 s
   (0.83 s). Config-warm open completed at 0.192 s. The config-vs-noconfig
   pre-open difference (~0.7 s, n = 1) is not yet attributed: the
   `playlist-sort.lua` Explorer lookup is asynchronous and the hook only writes
   the prefetch gate (script header, 2026-09-11), so a blocking-script
   explanation is **CONTRADICTED**; remaining candidates are script
   initialization, hook dispatch, and the rclone/S3 fetch itself. Trace exports
   must split this.
3. **VERIFIED — real-config prefetch is observable and absent with
   `--no-config`.** `maxPrefetched` = 3 in all config trials and 0 in all
   noconfig trials; `prefetchedAtNext` = 3 for config-warm vs 0 for
   config-cold/noconfig. Backend delta inside the plain trials (other clients
   idle): config-cold 675.8 MB in 25.9 s, noconfig-cold 308.3 MB in 23.1 s,
   warm trials 0 MB.
4. **VERIFIED — Procmon capture overhead is material for the real config.**
   config-cold `playback-restart` 8.763 s and probe load 7.52 s under Procmon
   vs 1.759 s / 0.16 s plain; noconfig-cold changed little (1.331 s vs
   1.216 s). Use plain/WPR for latency and Procmon for operation-level I/O
   attribution, not the reverse.
5. **VERIFIED — matrix integrity.** 12/12 trials completed with 0 errors; every
   trial accepted `playlist-next` on the first attempt; 4 WPR captures
   succeeded (ETL 346–1928 MB, 0 dropped events); 4 Procmon captures succeeded
   (PML 536–970 MB, 1.49–2.65 M CSV rows, 485 k–505 k workload rows, markers
   found, settings restored).
6. **VERIFIED (mechanism, mpv source) — the playlist-sort `playlist-reorder`
   at switch starts a prefetch that blocks the main open, then is aborted.**
   - `player/loadfile_async.c`: one `mpctx->open` slot (`:175`); the main open
     (`open_demux_reentrant`) cannot start until a pending prefetch opener is
     joined in `destroy_open` (`:145-147`). `playlist-reorder` invokes
     `prefetch_next` (`player/command.c:6624`); inside `on_before_start_file`
     the playlist current index is already B while `mpctx->playing` is still
     NULL (`player/loadfile.c:1594-1596, 1990-1992`), so it opens entry C.
     B's open then logs `Aborting ongoing prefetch of wrong URL`
     (`loadfile_async.c:351-368`) and joins C's opener. Cancellation is
     cooperative (`misc/thread_tools.c:157-162`; stream/libavformat poll
     points), so the join equals the remainder of C's `demux_open_url` — 2 ms
     to ~2 s; a prior local ETL caught the aborted opener in `WrPageIn`.
   - Observed ordering matches: plain prefetch C open 11.976 → abort 13.841 →
     B `Opening done` 15.083 s; WPR 12.118 → 14.186 → 15.448 s; Procmon abort
     2 ms → B open 0.61 s later. Upstream v0.41.0 source (external check)
     shows the same single-slot/join design.
   - A/B outcome (2026-09-12, n=2 plains): with the script present, prefetch is
     gated (`prefetchedAtNext` = 0) and every switch performs the wrong-URL
     prefetch whose abort the main open joins (observed 2 ms–2.07 s; plain
     3.382/1.631 s, WPR 4.169 s, Procmon 1.070 s). With `playlist-sort.lua`
     absent, prefetch runs during A (`prefetchedAtNext` = 3), the switch logs
     `Using prefetched URL` and the first frame follows the old demuxer's
     teardown by ~26–30 ms (plain 1.126/2.480 s, WPR 0.494 s, Procmon 0.719 s).
     The mechanism is deterministic; the end-to-end win at n=2 is directional
     and overlapping because the bottleneck shifts to previous-demuxer
     force-termination (0.5–2.5 s), a separate cooperative-cancel cost.
   - rclone side: a cross-file download gate is **CONTRADICTED** at commit
     ef6968730. Each open file owns its own `Downloaders` (`vfs/vfscache/item.go:64,616`;
     the source notes `// FIXME implement max downloaders`,
     `vfs/vfscache/downloaders/downloaders.go:20`), each downloader is an
     independent goroutine, `--transfers` only sizes the HTTP idle pool and the
     copy/writeback paths (not VFS reads), and there is no cross-file queue or
     priority. With 60 s handle caching, closing A defers teardown; an abort
     cancels the current range read and never requeues it. The stall is
     therefore mpv's join plus the aborted opener's own I/O latency; shared
     backend/network contention is external and not code-decidable.
7. **VERIFIED (Procmon trace) / INCONCLUSIVE (WPA) — switch-window I/O.**
   Procmon duration rows for the two config-cold Procmon trials: with the
   script, the main file's `ReadFile` calls block 0.50–0.61 s each inside the
   1.09 s switch window (cold fetch; the rclone process writes the cache
   concurrently); without the script, the prefetched main reads take
   0.16–0.18 s while the previous file's `CloseFile` costs 0.56 s and a
   later-entry prefetch `ReadFile` blocks up to 0.76 s. rclone-process rows in
   the same windows are cache writes and TCP receive with ~0 ms recorded
   durations, so the wait is on the WinFsp/VFS side. Artifacts:
   `measurements/procmon-switch/*.json`. The WPA Thread-Delay export
   (marks-restricted) succeeded for both config-cold ETLs, but WPAExporter
   11.7 aggregates this preset per process (one mpv row without per-event
   `Switch-In Time`), so per-event blocked-stack attribution is not available
   from it; the prior session's ETL analysis already documented the aborted
   opener blocked in `WrPageIn`/`NtReadFile` for the same cancel path.
   Artifacts: `measurements/wpa/{config-cold-wpr,config-cold-no-ps-wpr}/`.

## Change and validation

- No player or production behavior changed. Harness hardening only (all in
  `benchmarks/vfs-bench/`):
  - `bench-probe.lua`: frame gate polled on a 50 ms timer (was
    `observe_property`, which never fired).
  - `Set-BenchCacheState.ps1`: warm mode skips flushed-covered files, reads
    pending files with `-Parallel`, waits 75 s for the `Rs` meta flush, then
    polls coverage.
  - `Sync-BenchMedia.ps1`: parallel RC upload + root-first `vfs/refresh`.
  - `Invoke-BenchTrials.ps1` / `Summarize-BenchTrials.ps1`: StrictMode-safe
    property/array access.
- **Correctness checks actually run:** standalone probe smoke test (20.6 s,
  `frames-reached` ×2, `cmd-playlist-next`, `cmd-quit`); the 12-trial matrix
  with per-trial cache-state verification and 0 errors; 25/25 full-decode
  corpus verification; Cold 0 % / Warm 100 % coverage census before the matrix.
- **Playlist-sort tie-break fix (applied 2026-09-12 after the matrix).**
  Pre-fix SHA-256 `845471B3D70DEF6512A2598B74821893073C24113489A4F43E5156EE3484B414`
  (backup:
  `C:\Users\andre\AppData\Local\Temp\opencode\playlist-sort-prefix-backup.lua`),
  post-fix SHA-256 `D6A59AC26EB7113778C4BC01C21CF35B8970893901F1A97FD48F154BE567E514`.
  `after_keys` now resolves equal non-name keys by `compare_names` first (name
  ascending, matching Explorer) and falls back to the playlist index. Verified
  with the engineer's one-shot harness (`run-plsort.ps1`, real config, Explorer
  sort forced): pre-fix #1 `You Never…`, #2 `♥︎dr…`; post-fix #1 `♥︎dr…`, #2
  `You Never…`; all other 34 positions byte-identical.
- **A/B analysis artifacts:** merged 24-trial matrix and summary under
  `C:\PerfBench\analysis\merged\` (`matrix-merged.json`, `summary.csv`,
  `conditions.json`).
- **Comparable before/after:** none — this is the first complete matrix in this
  shape; the earlier session's cold/warm skip numbers used a different scenario
  and are not comparable beyond direction.

## Remaining work and retained evidence

- **INCONCLUSIVE items and next measurement:** export WPA tables
  (`Export-WpaTables.ps1`) for the 4 ETLs and run the Procmon duration/TID
  analysis on the 4 CSVs, focused on the `cmd-playlist-next` → file-2
  first-frame window of the mpv PID; then extend this report's finding 6.
- **Validation not run:** no repeated plain trials (n = 1 per cell; no variance
  estimate); no second mount/backend comparison; no manual D3D11 present-time
  capture (mpv `first video frame after restart shown` is the present anchor).
- **Raw artifacts (outside Git):** matrix `…\vfs-bench-matrix-20260911-212832.json`;
  run directories under `C:\Users\andre\PerfRuns\mpv-vfs-*` (ETL/PML/CSV paths
  and sizes in `artifacts.md` and `measurements/captures.json`); stdout/stderr
  dumps under each run’s `measurements\`.
- **Cleanup state:** WPR stopped, Procmon exited, rclone log level restored to
  INFO after each traced trial; no trace sessions left running.
