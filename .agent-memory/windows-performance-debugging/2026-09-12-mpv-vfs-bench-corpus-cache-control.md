# 2026-09-12 — VFS cold/warm corpus seed + cache-state control fixes (vfs-bench)

## Scenario

Harness `benchmarks\vfs-bench\` (this checkout); run area `C:\PerfBench\`;
remote `wcrypt:PerformanceBench\{Cold,Warm}` on the live WinFsp mount
`I:\PerformanceBench` (rclone v1.76.0-beta.10339.ef6968730 = rclone repo commit
`ef6968730`). Goal: seed 25 × 288 MiB files out-of-band, control the VFS cache
cold/warm per folder, then run the first-frame/next-frame trial matrix.
Mount flags come from `C:\ProgramData\Rclone\wcrypt\mount-flags.psd1`; relevant
VFS values: cache-mode full, `--vfs-read-chunk-size 1M`,
`--vfs-read-chunk-size-limit 256M`, `--vfs-read-chunk-streams 0`,
`--buffer-size 0`, `--vfs-read-ahead 0`, `--vfs-handle-caching 60s`,
`--dir-cache-time 72h`, `--transfers/--checkers 240`,
`--s3-chunk-size 32M`, `--s3-upload-concurrency 8`.

## Verified findings

- **Parallel RC uploads scale; serial uploads underuse the link.** Serial
  `operations/copyfile` uploaded 13 files / ~3.9 GB in 129.3 s wall
  (~30 MB/s). Eight concurrent `operations/copyfile` calls uploaded
  37 files / 11,154,068,740 B in **109.2 s wall (~102 MB/s)**, per-file
  8.3 / 21.4 / 43.5 s (min/median/max), each remote size re-verified with
  `operations/stat`; failed=0. Evidence:
  `C:\PerfBench\upload\upload-manifest.json` (schema 2, `parallel=8`),
  output-file timestamps; script `Sync-BenchMedia.ps1 -Parallel 8`. Sub-path
  `dstFs` still fails; use `dstFs='wcrypt:'` + `dstRemote='PerformanceBench/…'`.
- **`vfs/refresh` must refresh the root first.** With `--dir-cache-time 72h`, a
  direct subdir refresh after out-of-band object creation returned
  `{"PerformanceBench":"file does not exist"}` and `I:\PerformanceBench` stayed
  invisible (`Test-Path` false) although the remote listed 25+25 entries. Fix:
  call `vfs/refresh` with **no parameters** (root) → `{"":"OK"}`, then
  `{dir:"PerformanceBench", recursive:"true"}` → OK; the path became visible
  immediately (no remount). `recursive` must be the string `"true"`; a JSON
  bool fails with `value must be string "recursive"=true`. Source:
  rclone `vfs/rc.go` (`getDir` walks the cached root listing).
- **vfsMeta `Rs` lags reads by the 60 s handle grace; immediate coverage checks
  are false negatives.** During the first serial fill the script reported
  `coverage=0% FAIL` for every file, yet PB01–PB13 metas later showed
  `"Rs":[{"Pos":0,"Size":<full>}]`; PB14/PB15 (process killed mid-read) stayed
  `"Rs":null`. Warm verification now waits 75 s after the last handle closes,
  then polls up to 180 s; warm mode is idempotent (skip files whose flushed
  `Rs` coverage is 100 %) — `Set-BenchCacheState.ps1`, fixed 2026-09-12.
- **Live VFS options cannot be retuned via RC `options/set`.** `options/get`
  exposes the `vfs` block, but `fs.RegisterGlobalOptions("vfs", &Opt)` has no
  `Reload` hook (`vfs/vfscommon/options.go:181`), `rcOptionsSet` only writes
  the registered struct (`fs/rc/config.go:182-199`), and `vfs.New()` copies
  the options into the live VFS (`vfs.Opt = *opt`, `vfs/vfs.go:215-227`) where
  read handles use that copy (`vfs/read.go:79,153`). `--vfs-read-chunk-streams`
  changes therefore require a remount; that was avoided because a remount also
  re-runs `--vfs-refresh` (background recursive scan) and perturbs the run.
  `C:\ProgramData\Rclone\restart-rclone-wcrypt-mount.ps1` exists if needed.
- **No-remount read-throughput lever: concurrent open handles.** With the
  production flags one sequential file read runs **~11.4 MB/s** (12 × 288 MiB
  in ~5.3 min; stopped serial fill). Each open file gets its own chunked reader,
  so N concurrent file reads are N independent chunk streams. Measured
  2026-09-12: 10 × 288 MiB with `-Parallel 6` read in 29.0–40.5 s per file
  (6-way), **~2.81 GiB in ~68 s ≈ 42.5 MB/s aggregate (~3.7×)**, plus a 2.4 s
  tail for the partially cached PB15; whole fill 222.7 s wall including both
  75 s meta-flush settles. Artifact:
  `C:\PerfBench\cache-state\cache-warm-warm-par6.json`. rclone docs: streams=0
  doubles chunks up to the limit; streams>0 reads N constant-size chunks
  concurrently and is the S3/high-latency lever (docs suggest starting
  ~16 × 4M) — remount-only via RC.

## Harness bugs found by the first matrix run (fixed 2026-09-12)

- `estimated-frame-number` is a get-computed property with **no change
  notifications**: `mp.observe_property` never fired, so the first trial played
  to the probe safety timeout (125 s, `next_attempts=0`, ~3705 frames at 30 fps).
  `bench-probe.lua` now polls it on a 50 ms timer; standalone smoke test ran
  20.6 s with `frames-reached` ×2, `cmd-playlist-next`, `cmd-quit`.
- PowerShell `Set-StrictMode -Version Latest` makes `@(...)[0]` throw on an empty
  pipeline result ("Index was outside the bounds of the array") and makes
  assigning a **new** key on `[ordered]@{}` throw ("property cannot be found").
  Both aborted the first matrix run after trial 1. `Invoke-BenchTrials.ps1` now
  uses `Select-Object -First 1` and initializes every trial key
  (`userStateRestore`, `mpvTimeline`, `completedUtc`) in the ordered dict.
- `Summarize-BenchTrials.ps1` had two more of the same class: a function
  returning a **one-element array is unrolled to a scalar** at the call site
  (`.Count` then throws), and traced `result` objects hold `{kind;capture}` with
  no `wallSec`/`exitCode`/`backend` (direct property reads throw). Fixed with
  `, @(...)` returns and `PSObject.Properties[...]` guards; after the fix the
  analysis produced 0 row errors.

## Harness / environment facts

- WPR plan for the matrix validated today:
  `New-WprCapturePlan.ps1 -Profile CPU.Light,GPU.Light,FileIO.Light,Network.Light`
  → memory mode, requiresElevation true, plan+ETL paths under the run dir.
- The vfs-bench harness resolves skill scripts from
  `C:\Users\andre\.claude\skills\windows-performance-debugging`
  (`Get-BenchConfig.SkillDir`), while the runbook shows `.codex` paths — verify
  which tree exists before relying on either.
- Warm runs through the mount affect only `PerformanceBench` entries; Cold
  entries stayed at 0 % coverage through the upload and Warm fill
  (`C:\PerfBench\cache-state\`).

## Artifacts

- `C:\PerfBench\upload\upload-manifest.json` — upload proof (schema 2, failed 0)
- `C:\PerfBench\cache-state\cache-warm-warm-par6.json` — parallel warm fill
  (per-file `readMs`, coverage after flush)
- `C:\PerfBench\verify\verify-media.json` — 25/25 full-decode verification
- `C:\PerfBench\environment\{bench-environment,tooling-environment}.json`
- Harness: `benchmarks\vfs-bench\{Sync-BenchMedia,Set-BenchCacheState,
  Invoke-BenchTrials,Summarize-BenchTrials}.ps1`, `VfsBench.psm1`

## Results (2026-09-12 matrix, 12/12 trials ok, 0 errors)

- Deliverable: `benchmarks\Run-20260912-041416-mpv-vfs-cold-warm\`
  (`report.md`, `measurements\summary.csv`, `conditions.json`, `captures.json`).
  Matrix record: `C:\Users\andre\PerfRuns\vfs-bench-matrix-20260911-212832.json`.
- Warm VFS removes the next-file fetch penalty (plain, probe anchors):
  `cmd-playlist-next` → first frame of file 2 = config 3.382 s cold vs 0.047 s
  warm (~72×); noconfig 1.769 s vs 0.073 s (~24×). First-file cold cost sits in
  `playback-restart` (config 1.759 vs 0.256 s; noconfig 1.216 vs 0.333 s), not
  in `Opening done`→frame (≤0.36 s all plain trials).
- Real-config prefetch visible: `maxPrefetched` 3 in all config trials and
  0 in all noconfig trials; `prefetchedAtNext` 3 (config-warm) vs 0. Backend
  deltas inside the plain trials: config-cold 675.8 MB / 25.9 s, noconfig-cold
  308.3 MB / 23.1 s, warm 0 MB.
- **Mechanism (VERIFIED in mpv source, HEAD 2b0f9f46ca): the playlist-sort
  `playlist-reorder` at the switch starts a prefetch open that blocks the main
  open.** One `mpctx->open` slot (`player/loadfile_async.c:175`); the main open
  cannot start until a pending prefetch opener is joined (`destroy_open`
  :145-147). `playlist-reorder` invokes `prefetch_next`
  (`player/command.c:6624`); inside `on_before_start_file` the playlist current
  is B but `mpctx->playing` is NULL (`player/loadfile.c:1594-1596, 1990-1992`),
  so it opens C; B then logs `Aborting ongoing prefetch of wrong URL`
  (`loadfile_async.c:351-368`) and joins C's opener. Cancellation is
  cooperative, so the join equals the remainder of C's `demux_open_url` (2 ms
  to ~2 s; a prior local ETL caught the aborted opener in `WrPageIn`).
  Prediction under test: without playlist-sort the reorder and the gate are
  gone, so B is prefetched during A and the switch is warm-fast
  (`config-*-no-playlist-sort` A/B runs, 2026-09-12).
- rclone side (commit ef6968730): cross-file download gate **CONTRADICTED** —
  each open file owns its own `Downloaders` (`vfs/vfscache/item.go:64,616`;
  `// FIXME implement max downloaders`, `downloaders/downloaders.go:20`),
  a goroutine per downloader; `--transfers` only sizes the HTTP idle pool and
  copy/writeback paths, not VFS reads; `--vfs-handle-caching 60s` defers
  teardown and an abort cancels the current range read without requeue. The
  switch stall is therefore mpv's single-open-slot join plus the aborted
  opener's own I/O latency, not an rclone scheduler.
- A/B (2026-09-12, n=2 plains): with playlist-sort, prefetch gated
  (`prefetchedAtNext`=0), every switch runs the wrong-URL prefetch and the main
  open waits for its abort (2 ms–2.07 s); with the script absent,
  `prefetchedAtNext`=3, `Using prefetched URL`, first frame ~26–30 ms after the
  old demuxer tears down; residual bottleneck is demuxer force-termination
  (0.5–2.5 s). End-to-end win directional, overlapping at n=2.
- `playlist-sort.lua` tie-break fix applied 2026-09-12 after the matrix: equal
  non-name keys now tie-break by name ascending (Explorer behavior), then
  playlist index. Pre-fix sha `845471B3…`, post-fix sha `D6A59AC2…`; verified
  with `run-plsort.ps1` — only the two tied entries swapped, other 34 positions
  identical; pre-fix backup kept in `%TEMP%\opencode\playlist-sort-prefix-backup.lua`.
  Merged A/B artifacts: `C:\PerfBench\analysis\merged\`.
- WPA export (`control-delays.wpaProfile`, marks-restricted) succeeded for both
  config-cold WPR ETLs, but WPAExporter 11.7 exports the Thread-Delays preset
  aggregated per process (single mpv row, no per-event `Switch-In Time`), so
  per-event blocked-stack attribution needs a different preset/extraction.
  Artifacts: `C:\PerfBench\analysis\wpa\{config-cold-wpr,config-cold-no-ps-wpr}\`
  (copies in the run package under `measurements\wpa\`).
- Observer overhead: Procmon inflates the real-config start (config-cold
  `playback-restart` 8.763 s vs 1.759 s plain; probe load 7.52 s) but barely
  noconfig-cold (1.331 vs 1.216 s); WPR overhead small (1.537 s). Traces: 4 ETLs
  346–1928 MB, 0 dropped events; 4 PMLs 536–970 MB, 1.49–2.65 M CSV rows,
  begin/end markers found, Procmon settings restored.
- INCONCLUSIVE: causal split of the cold next-frame latency across network /
  S3 / demuxer (trace exports not yet run); n = 1 per (condition, kind) cell
  with distinct spans, so no variance estimate and kind-vs-input confound.
- First matrix attempt retained (no trial JSON) under
  `mpv-vfs-config-cold-20260911T210941914Z-…`; cause/fixes in the package
  report.

## Next

- WPA Thread-Delay exports for the two config-cold WPR ETLs are running
  (`C:\PerfBench\analysis\wpa\`) to attribute the slow-abort opener waits.
- Optional follow-ups: persist the verified Explorer equal-mtime name tie-break
  in the `win32-shell` reference; decide whether `playlist-sort.lua` should
  also stop gating/retargeting prefetch at the switch (the A/B shows that
  interaction is the dominant stall; the tie-break fix is independent of it).
