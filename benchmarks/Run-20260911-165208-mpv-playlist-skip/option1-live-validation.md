# Option 1 live validation — skip include-file `stat()` in autocreate scans

Commit under test: `2b0f9f46ca` (`demux_playlist: skip stat() of the include
file in directory scans`). Lane: live validation on the real rclone/WinFsp
mount, 2026-09-11 18:39–18:46 local (UTC+07). Deployed binary:
`C:\Users\andre\Projects\mpv\dist\mpv.exe`, SHA-256
`587027333113EF9C3EC13A0E619A131CAC3243144CCD35BC2174AC73BEC2A302`
(hash identical before and after all measured trials; HEAD `2b0f9f46ca`,
unchanged). mpv ran elevated (High IL) as in all prior lanes.

## Verdict

**VERIFIED — the playing-file stall is gone.** In the same cold-input,
actively-streamed condition that produced the 5.249 s attribute-open stall
pre-fix, the autocreate worker now issues **zero** `CreateFile(Read
Attributes)` calls on the playing/include file. The remaining **256** sibling
stats + 1 directory open complete in a **0.317 s** worker scan window (max
single attribute open **3.31 ms**, none > 100 ms), and the mpv-log interval
`Opening done` → `Autocreate playlist: 257 siblings.` is **0.334 s**
(pre-fix Procmon t6: 5.364 s; pre-fix real-config trials 5.36/6.70/7.34 s).

New readiness distribution (4 real-config trials, `Opening done` →
`Autocreate`): **0.054 / 0.055 / 0.058 / 0.334 s** (median 0.057 s), including
two cold-cache inputs and one Procmon-instrumented trial. The literal
T1+5 s `playlist-next` pair was accepted on the **first attempt in 4/4**
trials; pre-fix real-config accepted first try only 1/3 (retries 5/7/2), and
cold-fetch trials needed 36/46/60 attempts or never completed.

Residual: the pre-fix cold-fetch degradation (20.7 / 25.0 / >30 s) did **not**
reproduce in this lane's cold trials (t0 0.334 s, t1 0.058 s — t1 used
rank-117-of-257, the same input that took 25.0 s pre-fix). Because the pre-fix
mechanism for those 20–30 s stalls was never per-op traced, "eliminated under
all fetch loads" remains **INCONCLUSIVE**; see *Remaining uncertainty*.

## Scenario, boundary, method

- Real user config (`%APPDATA%\mpv\` + Lua), one random top-level
  `I:\XXX\new2\*.mkv` per trial; media reported by rank alias only
  (`rank-N-of-257`), raw mapping stays external.
- Boundary: mpv spawn → first `playback-restart` (T1) → T1+5000 ms
  `playlist-next` + immediate second `playlist-next` → first restart at
  playlist position +2 (T4) → `quit` → exit. Harness:
  `Invoke-MpvSkipBatch.ps1` (SHA-256 `B8654DE7B5D9E6CB0CC841F512CD8FA74F0178981E50ACF0D4E6637FD8DC469C`,
  identical to the cold/warm lane), one trial per invocation.
- Readiness metric: mpv clock interval between the last `Opening done:` before
  the first `Autocreate playlist: N siblings.` line (same parser as
  `option2\measure-scan.ps1`).
- Input draw (session-start census: 245 `full` / 12 `absent`, unchanged from
  the cold/warm lane):
  - t0 = rank-203-of-257, 163.9 MB, `absent` (cold) — Procmon trial;
  - t1 = rank-117-of-257, 422.3 MB, `absent` (cold) — plain;
  - t2 = rank-54-of-257, 203.4 MB, `full` — plain;
  - t3 = rank-186-of-257, 296.1 MB, `full` — plain.
  Ranks 256/257 were excluded so position+2 always exists. The cold/plain
  split was stratified (random draw from the cold pool for the discriminating
  trials); documented, not a uniform draw.
- t0 was instrumented with `Invoke-ProcmonCapture.ps1`
  (`assets\procmon-duration-tid.pmc`, Duration + TID columns), settle 3 s,
  watchdog 273 s; workload = the harness trial, 17.19 s, exit 0.
  t1–t3 were plain harness trials (no observer).

## Gates and contamination

- **WPA/xperf gate:** `wpaexporter`/`wpa`/`xperf` absent at every check
  (`logs\gate-wait.jsonl`; `logs\trial-guards.jsonl` shows `tools:[], []` at
  every trial boundary and after the capture). No offline export ran during
  any measurement.
- **Live-lane mutex:** acquired and held for each measurement batch
  (attempt-3 driver 11:41:38Z → 11:43:34Z for t0; attempt-4 driver
  11:44:57Z → 11:45:47Z for t1–t3). **Deviation to report:** two driver
  bugs (StrictMode array/inUse and a `Join-Path` argument error, see
  *Retained failed attempts*) released the mutex between the two batches;
  no measurements ran in the gap and no other lane's measurement was
  observed concurrently, but the mutex was not held continuously across the
  whole session as the lane spec intends.
- **Preflight** (final batch, `measurements\preflight-1.json` +
  `.verdict.json`, 20.0 s): CPU 2.79 % avg, available RAM 76.1 GB,
  pages/s 6.67, `PhysicalDisk(_Total)\% Disk Time` 0.02 %, rclone idle
  (0 MB/20 s), no process above the 25 %-of-total CPU "hot" threshold.
  Background recorded and accepted: the user's own mpv streaming through the
  same wcrypt mount (PID 40976 → 16444 during the session), opencode2,
  HWiNFO64, explorer/thumbnail activity. Disposition: proceed.
- **Cache state:** no purge. Session-start census copied to
  `measurements\cache-census-session-start.json`; per-trial pre-class against
  the rclone VFS cache file (`measurements\cache-opt1-t1..3.json`). t0's
  pre-trial class is from the census (`absent`).
- rclone `core/stats` is shared with other clients of the same mount (the
  user's mpv), so per-trial backend byte deltas (88–150 MB) are upper bounds,
  not isolated per-file cost; cold class was established by the cache-file
  check, and the include file's `ReadFile` activity in the Procmon capture
  (below) proves it was streaming during the scan.

## Procmon pass (t0) — acceptance evidence

Capture: `procmon-capture-745c36a447a14f4f805d9d3227a71407` — Procmon64 4.11,
Duration/TID `.pmc`, PML 739.7 MB, CSV 1,830,606 rows, begin/end markers 6/6,
stop `terminate`, no warnings, Procmon settings restored. Worker TID
discovered structurally: **17628**.

| metric | pre-fix t6 (baseline) | post-fix t0 (this lane) |
| --- | ---: | ---: |
| worker `CreateFile(Read Attributes)`, entries (`child`) | 257 | **256** |
| worker attr opens on the **playing/include file** | 1 (5.2492 s) | **0** |
| worker attr opens on the directory (`self`) | 1 | 1 |
| worker attr opens total | 258 | 257 |
| max single attribute-open duration | 5249.2 ms | **3.31 ms** |
| attribute opens > 100 ms | ≥1 | **0** |
| worker `Query*` ops | not measured (est. ~5/entry) | 1557 (~6.1/entry) |
| worker scan window (first→last row) | 5.356 s | **0.317 s** (0.3135 s measured) |
| directory listing open | n/a | 1 × 0.156 ms |
| `Opening done` → `Autocreate` delta | 5.364 s | **0.334 s** |
| siblings spliced | 257 | 257 |

Critical-path overlap (the reason the zero matters): in the capture window the
playing file was **actively being read while the worker scanned it** — 46
`ReadFile` ops on the include file span `18:42:08.2402`–`18:42:08.5111`, and
the worker's 257 attribute opens span `18:42:08.3789`–`18:42:08.6924`
(overlap = true). Pre-fix, the include-file attribute open was the one call
that blocked 5.249 s in exactly this situation.

Global cross-check (all mpv TIDs, not only the worker): the include file had
3 `CreateFile` (one `Generic Read` 1.12 ms, one `Read Attributes` **0.40 ms on
TID 55072** — not the worker, one data open), 46 `ReadFile` (max 132.5 ms,
first non-cached 2 MB read), and no operation ≥ 1 s anywhere. The single
0.4 ms attribute open is normal mpv open-path metadata, not the autocreate
scan, and it is three orders of magnitude below the pre-fix stall.

The worker TID itself had **no operation ≥ 50 ms at all** (`slowOps` empty in
`check-playing-file.json`; `maxAnyMs` 3.31 ms).

## Plain trials — new readiness

| trial | input | pre-class | `Opening done`→`Autocreate` | T1 (spawn→restart) | nexts accepted | attempts | accepted next→T4 | quit→exit | failure |
| --- | --- | --- | ---: | ---: | --- | ---: | ---: | ---: | --- |
| t0 (Procmon) | rank-203, 163.9 MB | absent (cold) | 0.334 s | 950 ms | first try | 1 | 292 ms | 1163 ms | none |
| t1 | rank-117, 422.3 MB | absent (cold) | **0.058 s** | 449 ms | first try | 1 | 582 ms | 1182 ms | none |
| t2 | rank-54, 203.4 MB | full | 0.054 s | 474 ms | first try | 1 | 2234 ms | 2021 ms | none |
| t3 | rank-186, 296.1 MB | full | 0.055 s | 287 ms | first try | 1 | 469 ms | 857 ms | none |

`nextConfirmedAttempt = 1` and `nextAttemptCount = 1` in all four trials: the
literal T1+5 s pair succeeded on the first attempt, so the retry loop (which
dominated the pre-fix stall windows) never ran. The remaining variance moved
to `accepted next→T4` (292 ms–2.23 s, the target-file open) and `quit→exit`
(0.86–2.02 s teardown), both outside the autocreate scan.

Pre/post context: pre-fix real-config real-arm deltas 5.36/6.70/7.34 s with
1/3 first-try acceptance; pre-fix cold/warm lane 20.7/25.0/>30 s on
cold/concurrent-fetch trials (36/46/60 attempts); control (auto-create, warm
metadata) scans 0.16–1.0 s. Post-fix median 0.057 s, range 0.054–0.334 s.

## Acceptance verdict per claim

| # | claim | status | evidence |
| --- | --- | --- | --- |
| 1 | Zero `Read Attributes` opens of the playing/include file under the autocreate worker TID | **VERIFIED** | `check-playing-file.json`: `playingFileAttributeOpens = 0`, `playingFileOpCount = 0`, worker TID 17628; global scan found only a 0.40 ms attr open on another TID |
| 2 | Remaining entry scans ≈ 256 + 1 directory open (no coverage regression) | **VERIFIED** | `scan-after.json`: `entryAttributeOpens = 256`, `dirAttributeOpens = 1`, `queryOps = 1557`, siblings = 257 |
| 3 | Max attribute-open duration in milliseconds, not seconds | **VERIFIED** | max 3.3148 ms (baseline 5249.2 ms); 0 opens > 100 ms; worker `maxAnyMs` 3.3148 ms |
| 4 | The measured 5.25 s playing-file stall is removed on the real mount | **VERIFIED** | t0: worker scan 0.3135 s while the include file had 46 concurrent reads; delta 0.334 s vs baseline 5.364 s under the same scenario/observer |
| 5 | New readiness is sub-second and literal T1+5 s skips work | **VERIFIED (4/4 trials)** | deltas 0.054–0.334 s; first-attempt acceptance 4/4; range includes 2 cold inputs |
| 6 | Heavy-fetch readiness variability (20.7/25.0/>30 s) is eliminated, not just moved | **INCONCLUSIVE** | not reproduced in 2/2 cold trials (t0 0.334 s; t1 0.058 s on the same rank-117 input that took 25.0 s pre-fix), but n=2 and the pre-fix 20–30 s mechanism was never per-op traced; residual could depend on fetch load/duration not exercised here |
| 7 | Option 2 (per-entry `stat()` removal) is now unnecessary | **INCONCLUSIVE (not tested)** | Option 1 leaves 256 entry stats per scan; they measured sub-4 ms here, but a stall on any sibling (or the directory listing) is still possible on a busier mount. Option 2 remains the only change that removes them |

## Remaining uncertainty and next discriminating measurement

- Pre-fix cold-fetch stalls of 20–30 s (`live-cold-warm.md` t4/t5/t7) were
  never per-op traced, so it is not proven that they were caused by the
  include-file `stat()` rather than by other entry stats or the directory
  enumeration. With the fix, they did not reproduce in this lane.
- **Next discriminating measurement:** repeat the t5-style trial (rank-254,
  2.28 GB cold — the input that never completed pre-fix within 30 s) with the
  Procmon Duration/TID pass, post-fix. If readiness stays sub-second and the
  worker shows no `Read Attributes` op > 50 ms, Option 1 is sufficient for
  this workload; if a multi-second stall appears, its path/TID in that capture
  identifies whether Option 2 is still needed.
- Only t0 has per-op traces; t1–t3 readiness is log-based.
- rclone backend deltas are shared with the user's own mpv (upper bounds).
- Elevated (High IL) mpv only; normal medium-IL unmeasured.
- No cache purge; the two cold inputs were downloaded by these trials and are
  warm now (census after batch retained).

## Retained failed attempts (no measurements lost)

Three driver attempts failed before/around measurements because of local
driver bugs; all artifacts are retained:

1. 18:35:25 — StrictMode `$null.Count` on an empty WPA-tool array; no trial ran.
2. 18:36:57 — copied `Measure-Load.ps1` summary line reads `$rc.inUse` under
   StrictMode (pre-existing bug; patched one line, JSON schema unchanged);
   preflight JSON retained as `preflight-run2-attempt.json`.
3. 18:41:38 — `Join-Path` with a single-argument outer call in the per-trial
   cache check; t0 (Procmon + filter + scan + check + readiness) completed and
   was reused by the final run; t1–t3 ran under the final driver at 18:44:57.

## Raw artifacts (outside Git)

External run directory:
`C:\Users\andre\PerfRuns\mpv-playlist-option1-live-20260911T113300435Z-437b7674f4d744548dc93a0c14ab4700\`

- `traces\procmon-745c36a447a14f4f805d9d3227a71407.pml` — 739.7 MB native PML.
- `exports\procmon-745c36a447a14f4f805d9d3227a71407.csv` — 320.9 MB / 1,830,606 rows (Duration/TID).
- `exports\procmon-option1-filtered.csv` — 97.9 MB mpv/rclone/media-root subset.
- `measurements\scan-after.json` — measure-scan result (worker TID 17628).
- `measurements\check-playing-file.json` — playing-file / slow-op acceptance check.
- `measurements\readiness-opt1-t0..t3.json`, `batch-real-t0..t3.json`,
  `mpv-real-t0..t3.log` — per-trial readiness and IPC timings.
- `measurements\option1-live-summary.json` — aggregated lane summary.
- `measurements\procmon-capture-745c36a447a14f4f805d9d3227a71407.json` — capture record.
- `measurements\preflight-1.json` (+`.verdict.json`),
  `preflight-run2-attempt.json`, `cache-census-session-start.json`,
  `cache-pool-after.json`, `cache-opt1-t1..3.json`, `selection-option1.json`.
- `logs\gate-wait.jsonl`, `trial-guards.jsonl`, `driver-events.jsonl`,
  `live-lane-status.json`, `driver-transcript.txt`, `driver-stdout*.log`.
- `scripts\Invoke-Option1LiveValidation.ps1`, `Check-PlayingFileAttr.ps1`,
  `Get-MpvReadiness.ps1`, `Measure-Load.ps1` (one-line StrictMode fix),
  `Measure-CachePool.ps1`, `Filter-ProcmonCsv.ps1`.
