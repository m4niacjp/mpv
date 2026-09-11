# Artifact location map

Raw traces, PML/CSV exports, harness outputs, and logs are kept **outside Git**
under:

```text
C:\Users\andre\PerfRuns\mpv-playlist-skip-20260911T090749482Z-da38e1520da444cca96c26acd325bc27\
```

## Traces

| artifact | size | content |
| --- | ---: | --- |
| `traces\capture-0e2d39e5e6764bb8b4f87adc2b97c9f6.etl` | 4.30 GB | real arm t0-t2, CPU.Light+FileIO.Light+DiskIO.Light+GPU.Light+Network.Light, 16/16 markers, 0 dropped |
| `traces\capture-ad502a227d644e9ab0fd901439b771f6.etl` | 1.14 GB | control arm t3-t5, same profiles, markers complete, 0 dropped |
| `traces\procmon-7208286fc6514ac087fb0fba7db64fb0.pml` | 2.21 GB | Procmon observer pass (real t6), Duration/TID columns |
| `traces\capture-5350700418614ae1a48c4a5b84d0fdcd.etl` | 3.03 GB | 10 s idle volume probe of the full light set (stop 95.6 s) |
| `traces\probe-cpu.etl` / `probe-cpuverbose.etl` / `probe-lightset.etl` / `probe-stackset.etl` | 0.3-2.6 GB | profile-volume planning probes |
| `traces\capture-*.etl.NGENPDB`, `probe-*.etl.NGENPDB` | <1 MB | WPR native-format sidecars |

## Exports

- `exports\wpa-real-t1\` — WPAExporter run for the real t1 window
  (`-Marks t1-launch,t1-exit`): CPU Usage (Precise) By Process,
  CPU Usage (Sampled) Breakdown by Process/Thread/Activity/Stack (Stack column
  empty: CPU.Light has no stacks), Disk Usage By Process/IO/Path, plus
  `wpaexporter.log` and `export-summary.json`.
- `exports\wpa-control-t3\` — same for control t3.
- `exports\procmon-7208286fc6514ac087fb0fba7db64fb0.csv` — original 1.03 GB /
  6,065,879 rows.
- `exports\procmon-filtered.csv` — 364 MB; rows for `mpv.exe`, `rclone.exe`, and
  `I:\XXX\new2` / `rclone-wasabi-cache` paths.

## Measurements (external run `measurements\`)

| artifact | content |
| --- | --- |
| `Invoke-MpvSkipBatch.ps1` | the IPC harness (also copied to the skill `scripts\` dir) |
| `Rebuild-TrialSummary.ps1`, `Measure-PhaseDeltas.ps1`, `New-SummaryCsv.ps1`, `Summarize-Procmon.ps1`, `Summarize-WpaExport.ps1`, `Filter-ProcmonCsv.ps1`, `Get-PreflightSample.ps1` | analysis/utility scripts |
| `summary.csv` | per-trial phase latencies (also in the project package) |
| `real-batch-reconstructed.json` | real t0-t2 summary rebuilt from per-trial events |
| `batch-control.json` | control arm summary |
| `batch-real.json` | holdover: Procmon extra trial t6 (overwrote the real t0-t2 summary) |
| `events-<arm>-tN.json` | full IPC timeline incl. markers, commands, restarts, positions |
| `samples-<arm>-tN.json` | mpv process CPU/WS/private/threads/handles/IO counters |
| `rclone-<arm>-tN.json` | rclone RC `core/stats` + `vfs/stats` + mount process counters |
| `mpv-<arm>-tN.log` | mpv `--log-file` (debug level forced by --log-file) |
| `nvidia-<arm>.csv` | nvidia-smi 500 ms samples |
| `phase-deltas-real.csv`, `phase-deltas-control.csv` | per-phase mpv logical IO and rclone byte/transfer deltas |
| `procmon-summary.json` | Procmon operation groups + all ops ≥ 50 ms with TID/path |
| `wpa-summary-real-t1.json`, `wpa-summary-control-t3.json` | CPU/disk table summaries |
| `preflight-1.json`, `preflight-2.json` | background-load observations |
| `selection.json`, `selection-smoke*.json`, `selection-procmon.json` | raw input mapping (titles; do not copy into Git) |
| `wpr-plan-*.json`, `wpr-capture-*.json` | WPR plan and capture records (dropped-event/marker checks) |
| `procmon-capture-*.json` | Procmon capture record (stop method, settings restore) |

## Parent session deep captures (follow-up only, not produced by this run)

```text
C:\Users\andre\PerfRuns\mpv-wpd-20260911\mpv-configured-...\traces\capture-27b08a25da7f4e81b77092c46603bff6.etl   (3.68 GB, CPU.Verbose+FileIO.Verbose)
C:\Users\andre\PerfRuns\mpv-wpd-20260911\mpv-no-config-...\traces\capture-a091ae2dc1e04322825042b4a27aec4d.etl     (3.60 GB, CPU.Verbose+FileIO.Verbose)
```

These retained ETLs contain rapid next-next-quit transitions at 87-89 MB/s
event rate and are the recommended source for the missing stack evidence.

## Option-1 cold worst-case lane (2026-09-11 18:56-20:21, batches 1-4)

Deliverable: `option1-cold-worstcase.md`; per-trial data:
`measurements\option1-cold-worstcase-trials.csv`.

| batch | external run directory (`C:\Users\andre\PerfRuns\`) | retained evidence |
| --- | --- | --- |
| 1 | `mpv-playlist-option1-coldworst-20260911T115609Z-ed0524be` | rank-254 readiness t1/t2; retained Procmon start failure (missing `manifest.json`) |
| 2 | `mpv-playlist-option1-coldworst2-20260911T120919Z-e2e65fc7` | `traces\procmon-*.pml` 559.7 MB; `exports\procmon-coldworst-filtered.csv` 89.9 MB; scan/check/worst-case/stat-passes/fetch-window JSON; rank-182 |
| 3 | `mpv-playlist-option1-coldworst3-20260911T131107Z-afaabce0` | retained preflight abort (paging storm); no trials |
| 4 | `mpv-playlist-option1-coldworst4-20260911T131724Z-c9ccd0c8` | `traces\procmon-*.pml` 1.07 GB; `exports\procmon-coldworst-filtered.csv` 98.1 MB; scan 0.162 s / max attr 0.677 ms; rank-152 |

Each batch has `scripts\` (driver, harness `Invoke-MpvSkipBatch.ps1`
SHA-256 `B8654DE7...`, `measure-scan.ps1`, `Analyze-WorstCase.ps1`,
`Analyze-StatPasses.ps1`, `Get-VfsCacheState.ps1`, `Get-FetchWindow.ps1`,
`Check-PlayingFileAttr.ps1`, `Get-MpvReadiness.ps1`, `Measure-Load.ps1`),
`logs\{gate-wait,trial-guards,driver-events}.jsonl`, and
`measurements\coldworst-summary.json`.
