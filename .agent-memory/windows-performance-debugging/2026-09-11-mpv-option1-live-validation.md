# 2026-09-11 — Option 1 live validation: include-file `stat()` removed (real mount)

## Scenario

Commit `2b0f9f46ca`, deployed `dist\mpv.exe` SHA-256
`587027333113EF9C3EC13A0E619A131CAC3243144CCD35BC2174AC73BEC2A302` (stable
before/after). Real config, one random `I:\XXX\new2` input per trial; Procmon
Duration/TID pass around t0 (rank-203, cold, streaming) plus 3 plain trials
(t1 rank-117 cold; t2/t3 warm). Mutex `Global\MpvPerfLiveLane` held per batch;
no `wpaexporter`/`wpa`/`xperf` at any guard check. Preflight clean (CPU 2.79 %,
76 GB free, disk 0.02 %, no hot process).

## Outcome (VERIFIED unless noted)

- **Playing-file stall removed:** autocreate worker TID 17628 issued **0**
  `CreateFile(Read Attributes)` on the playing/include file while the file had
  46 concurrent `ReadFile` ops overlapping the scan window (baseline: one
  5.2492 s open). Remaining: 256 entry + 1 directory attr opens, max
  **3.31 ms**, no worker op >= 50 ms; scan window **0.317 s** (baseline
  5.356 s); `Opening done` -> `Autocreate` **0.334 s** (baseline 5.364 s).
- **New readiness distribution:** 0.054 / 0.055 / 0.058 / 0.334 s (median
  0.057 s) over 4 real-config trials; literal T1+5 s next pair accepted on the
  **first attempt 4/4** (pre-fix: 1/3 real trials, 36/46/60 attempts on
  cold-fetch trials). Residual variance moved to accepted-next->T4
  (292 ms-2.23 s target open) and quit->exit (0.86-2.02 s), outside the scan.
- Only sibling stats remain (256/scan) plus the directory enumeration; they
  measured sub-4 ms on this mount, but a stall on any sibling or the listing
  is still theoretically possible.
- **INCONCLUSIVE:** pre-fix cold-fetch degradation (20.7 / 25.0 / >30 s in
  `live-cold-warm.md`) did not reproduce post-fix in 2/2 cold trials (t1 used
  rank-117, the same input that took 25.0 s pre-fix), but the baseline
  mechanism was never per-op traced. Option 2 necessity therefore unresolved.
- Deviation: two lane-driver bugs (StrictMode `$null.Count`; a `Join-Path`
  arity error) split measurements into two mutex-held batches (18:41:38-18:43:34Z
  t0; 18:44:57-18:45:47Z t1-t3) instead of one continuous hold; no measurement
  overlapped another lane. The cold/warm `Measure-Load.ps1` copy in this lane
  has a one-line StrictMode fix for a summary-only `$rc.inUse` access (JSON
  schema unchanged; the older copy throws after writing the JSON).

## Evidence and artifacts

- Deliverable:
  `benchmarks\Run-20260911-165208-mpv-playlist-skip\option1-live-validation.md`
- External run:
  `C:\Users\andre\PerfRuns\mpv-playlist-option1-live-20260911T113300435Z-437b7674f4d744548dc93a0c14ab4700\`
  (`traces\procmon-745c36a4...pml` 739.7 MB; `exports\procmon-*` CSV
  1,830,606 rows; `measurements\{scan-after,check-playing-file,readiness-opt1-t0..t3,option1-live-summary}.json`;
  `logs\{gate-wait,trial-guards,driver-events}.jsonl`).
- Reproduce with `scripts\Invoke-Option1LiveValidation.ps1` (+
  `Check-PlayingFileAttr.ps1`, `Get-MpvReadiness.ps1`).

## Next discriminating measurement

Procmon Duration/TID pass post-fix on the 2.28 GB rank-254 cold input that
never completed pre-fix within 30 s; if a multi-second stall appears, its
path/TID decides whether Option 2 (remove per-entry stats) is still needed.
