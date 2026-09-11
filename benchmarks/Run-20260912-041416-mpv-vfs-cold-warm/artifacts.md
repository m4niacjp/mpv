# Artifacts

Raw traces stay outside Git (`C:\Users\andre\PerfRuns\`). The package keeps
only summaries; see `measurements/` here and `captures.json` for exact paths.

## Run directories and traces

| Condition | Run directory (under `C:\Users\andre\PerfRuns\`) | WPR ETL | Procmon PML | Procmon CSV |
| --- | --- | --- | --- | --- |
| config-cold | `mpv-vfs-config-cold-20260911T211415412Z-1fa65bae3788404f9373452864313497` | 1928 MB | 970 MB | 2,654,045 rows |
| config-warm | `mpv-vfs-config-warm-20260911T211840096Z-5e78d63943484431973b03a927fd233f` | 828 MB | 562 MB | 1,557,925 rows |
| noconfig-cold | `mpv-vfs-noconfig-cold-20260911T212153484Z-f6516e682fc04f9fafffe6a3a1fd2ffe` | 721 MB | 708 MB | 1,981,428 rows |
| noconfig-warm | `mpv-vfs-noconfig-warm-20260911T212528993Z-e4d1b7daf086413ba19559ac201fcb41` | 346 MB | 536 MB | 1,489,842 rows |

Each run directory contains: `manifest.json`, `environment.json`, `report.md`,
`measurements\` (trial JSON, probe JSON, mpv log, rclone log slice, preflight,
userstate, capture records, stdout/stderr), `traces\` (ETL/PML/markers), and
`exports\` (Procmon CSV).

## Package measurement files

- `measurements/summary.csv` — per-trial metrics (source:
  `C:\PerfBench\analysis\summarize-trials.csv`).
- `measurements/conditions.json` — per-condition aggregates (source:
  `C:\PerfBench\analysis\summarize-conditions.json`).
- `measurements/matrix-summary.json` — full matrix record incl. probe phases,
  capture metadata and per-trial JSON references (source:
  `C:\Users\andre\PerfRuns\vfs-bench-matrix-20260911-212832.json`).
- `measurements/captures.json` — WPR/Procmon capture summaries (ETL/PML paths,
  sizes, row counts, marker rows, settings restore).

## Supporting environment / corpus artifacts

- `C:\PerfBench\upload\upload-manifest.json` — 37 files / 10.39 GiB uploaded,
  failed 0 (schema 2, `parallel=8`).
- `C:\PerfBench\cache-state\cache-warm-warm-par6.json` — parallel warm fill,
  25/25 coverage 100 % after flush.
- `C:\PerfBench\cache-state\cache-cold-status-prematrix.json` — 25/25 at 0 %.
- `C:\PerfBench\verify\verify-media.json` — 25/25 full-decode verification.
- `C:\PerfBench\videos\PB01..PB25.mkv`, `C:\PerfBench\manifests\*.json`.
- `C:\PerfBench\environment\bench-environment.json`,
  `tooling-environment.json` — copied into `environment.json` here.
- `C:\PerfBench\gen-resume.log` — corpus generation/regeneration record.

## Additional artifacts (A/B + traces)

- `measurements/procmon-switch/*.json` — per-Procmon-trial switch window
  (marker-anchored `cmd-playlist-next`→`playback-restart`, mpv+rclone rows,
  slowest operations, per-file read counts/bytes). Sources:
  `C:\PerfBench\analysis\procmon\*.json`.
- `C:\PerfBench\analysis\merged\` — 24-trial merged matrix, summary CSV and
  condition aggregates (batches 1–3).
- `C:\PerfBench\analysis\wpa\config-cold-wpr\` and
  `C:\PerfBench\analysis\wpa\config-cold-no-ps-wpr\` — WPA table exports
  (marks-restricted to `workload-start`/`workload-end`,
  `control-delays.wpaProfile`), launched 2026-09-12.
- Playlist-sort fix provenance: pre-fix script backup at
  `C:\Users\andre\AppData\Local\Temp\opencode\playlist-sort-prefix-backup.lua`
  (SHA-256 `845471B3…4B414`); post-fix script SHA-256 `D6A59AC2…E567E514`;
  verification order output `%TEMP%\opencode\plsort-after.final` vs pre-fix
  `plsort-report.final`.

## Retained failed attempt

- `C:\Users\andre\PerfRuns\mpv-vfs-config-cold-20260911T210941914Z-2678904bc7d54a24aa671315712e473b`
  — first matrix attempt, aborted after trial 1; no trial JSON. Cause and fixes
  in `report.md` (“Failures retained”).
