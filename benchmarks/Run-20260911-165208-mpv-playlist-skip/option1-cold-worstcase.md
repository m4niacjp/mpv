# Option 1 cold worst-case validation — heavy-fetch readiness and Option-2 necessity

Resolves the two INCONCLUSIVE items (6, 7) from
`option1-live-validation.md`. Binary under test:
`C:\Users\andre\Projects\mpv\dist\mpv.exe`, SHA-256
`587027333113EF9C3EC13A0E619A131CAC3243144CCD35BC2174AC73BEC2A302`
(post-Option-1, HEAD `2b0f9f46ca`; hash stable before/after every batch). LANE:
live rclone/WinFsp mount, 2026-09-11 18:56–20:21 local (UTC+07). mpv ran
elevated (High IL) as in all prior lanes.

## Verdict

**(6) Heavy-fetch readiness variability (`20.7 / 25.0 / >30 s` pre-fix) is
gone — VERIFIED (8 trials, 3 inputs, 4 gated batches).** Post-fix
`Opening done` → `Autocreate playlist: 257 siblings.` was **0.037–0.194 s**
(median ≈ 0.06 s) in every trial; the literal T1+5 s next pair was accepted on
the **first attempt 8/8** (pre-fix real trials: 1/3, with 36/46/60 rejected
attempts on the heavy-fetch cases). In the decisive trial (rank-152, 0.53 %
cached) the mount was **actively fetching the playing file during the worker
scan window** (+3.0 MB backend bytes in the 0.23 s window; +113.3 MB across the
pre-next window; input coverage 0.53 % → 38.75 %), and the worker still
completed the 257-entry scan in **0.162 s** with **max single attribute open
0.677 ms** and **zero** playing-file attribute opens.

**(7) Option 2 (d_type bypass of per-entry `stat()`) is not needed for the
measured built-in-scan risk — the "still needed" hypothesis is CONTRADICTED;
low priority.** The 256 per-entry stats that Option 2 would remove cost
**≤ 0.68 ms each / 0.162 s per scan** while the playing file was downloading
(≤ 2.26 ms / 0.171 s in the second Procmon pass), and no sibling or directory
attribute open exceeded 100 ms in the scan. However, a **different,
non-built-in consumer still produces multi-second stalls**: the user's
`playlist-sort.lua` Explorer-fallback pass calls `utils.file_info()` on every
playlist entry, and its stat of the **playing file** blocked **4.79 s** behind
that file's active download (4.75 s in the second pass; sibling stats on an
actively downloading target/prefetch file blocked 152/489/522 ms). Option 2
would not fix those. Residual risk lives in that path
(script/config/rclone queueing), not in `demux_playlist`'s scan.

## Input selection — census "cold" classes were false negatives

The previous lanes selected "cold" inputs from the census rule *cache file size
vs remote size* (`absent`/`full`). Both signals are wrong for the 12 files whose
names contain characters invalid on Windows:

- WinFsp exposes e.g. `?` as **U+F03F**, while rclone's cache/vfsMeta uses the
  fullwidth form **U+FF1F** (same for `"` U+F022 ↔ U+FF02, `:` U+F03A ↔
  U+FF1A, `|` U+F07C ↔ U+FF5C …). Census basename matching therefore reports
  `absent` for these 12 files regardless of real cache state.
- rclone pre-allocates the cache content file at full remote size, so
  `cacheBytes == remoteBytes` does **not** mean fully cached. The authoritative
  signal is the vfsMeta `Rs` read-span list.

Corrected state of the designated inputs at lane start (vfsMeta `Rs`, verified
with `Get-VfsCacheState.ps1`, which maps U+F0xx → U+FFxx and falls back to a
folded-name match):

| rank | alias | remote bytes | cached `Rs` bytes | coverage |
| ---: | --- | ---: | ---: | ---: |
| 254 | `...xhTrUYZ...` (pre-fix never completed) | 2,393,421,304 | 425,754,624 | 17.8 % |
| 182 | `...xhINC2A...` | 902,106,834 | 39,886,546 | 4.4 % |
| 152 | `...milfs-and-virgins...-1...` | 205,729,195 | 1,081,344 | 0.53 % |

rank-254 has a 426 MB cached prefix, so the reader never crosses it during the
sub-second scan (trial t1/t2: `Rs` unchanged, scan-window fetch 0 MB) — the
heavy-fetch condition cannot be replayed on that file without a cache purge,
which was not performed. The lane therefore tested the **next effectively cold
candidates** in sequence as the instruction allows: rank-182 (fetch starts at
the prefix edge, ~40 MB) and **rank-152 (network fetch from the first read)** as
the decisive input.

## Scenario, boundary, method

- Real user config (`%APPDATA%\mpv\` + Lua scripts). One `I:\XXX\new2` input per
  trial; media reported by rank alias only, raw mapping stays in the external
  run dirs.
- Boundary: mpv spawn → first `playback-restart` (T1) → T1+5000 ms
  `playlist-next` + immediate second `playlist-next` → first restart at
  playlist position +2 (T4) → `quit` → exit. Harness `Invoke-MpvSkipBatch.ps1`
  SHA-256 `B8654DE7B5D9E6CB0CC841F512CD8FA74F0178981E50ACF0D4E6637FD8DC469C`
  (identical to the cold/warm and Option-1 lanes), one trial per invocation.
- Readiness = mpv-clock interval between the last `Opening done:` before the
  first `Autocreate playlist: N siblings.` line (`Get-MpvReadiness.ps1`,
  parser identical to `option2\measure-scan.ps1`).
- Procmon pass = skill `Invoke-ProcmonCapture.ps1` + `assets\procmon-duration-tid.pmc`
  (Duration + TID columns) around one harness trial; analysis with
  `option2\measure-scan.ps1` (Option-1 thresholds), `Check-PlayingFileAttr.ps1`,
  and new `Analyze-WorstCase.ps1` (target classification + >100 ms checks +
  worker window + include-file read offsets). Raw PML retained; CSV filtered to
  mpv/rclone/media-root rows.
- Backend fetch = rclone RC `core/stats` sampled every ~200 ms by the harness;
  windows computed from mpv-log/spawn timestamps (`Get-FetchWindow.ps1`). All
  deltas are upper bounds for the trial because the mount is shared with other
  clients (recorded per batch).
- Gates: no `wpaexporter`/`wpa`/`xperf` at any check; `Global\MpvPerfLiveLane`
  mutex held across each whole batch and released in `finally` (4 batches:
  18:56–18:58, 19:09–19:12, 20:11 aborted, 20:17–20:21 local).

## Environment and cache state

- Windows 11 Pro Insider Preview 26220, Ryzen 9 9950X3D (32 logical), 95.7 GB
  RAM, RTX 5070 Ti. mpv `v0.41.0-947-gd37b8c1a7-dirty` built 2026-09-11
  03:34:59.
- Mount: rclone `mount wcrypt: I:` PID 2236 (started 18:33) with
  `--vfs-cache-mode full --vfs-read-chunk-size 1M --vfs-read-chunk-size-limit
  256M --vfs-read-ahead 0 --vfs-handle-caching 60s --dir-cache-time 72h
  --vfs-cache-max-age 8760h --rc 127.0.0.1:5574`, cache
  `D:\rclone-wasabi-cache`. No cache purge at any point.
- Concurrent context (recorded, not isolated):
  - batches 1–2: user's own mpv streaming `I:\XXX\BJ-HJ\...` on the same mount
    (PID 16444 then 47504/46832; stopped before batch 4);
  - batch 3 preflight: unrelated background paging storm (below);
  - batch 4: only the two rclone mounts; the test trial was the only reader of
    `I:\XXX\new2` (`context-before.json`).
- Preflights: batch 1 `preflight-run2-attempt` style check + batch 2
  `preflight-1` (CPU 2.38 %, RAM 76.1 GB free, pages/s 0.0, disk 0.02 %);
  batch 4 `preflight-1` (CPU 3.19 %, pages/s 19.9, disk 0.29 %). All
  dispositions: proceed.

## Trial results

All harness stopwatch values. `preNext` = backend bytes [Opening done → first
next]; `scanΔ` = backend bytes [Opening done → Autocreate]; `cov` = vfsMeta
`Rs` coverage of the trial input. Structured copy:
`measurements\option1-cold-worstcase-trials.csv`.

| batch | trial | input | readiness s | spawn→T1 ms | next attempts / first try | accepted next→T4 ms | quit→exit ms | preNext MB | scanΔ MB | cov pre→post | failure |
| --- | ---: | --- | ---: | ---: | --- | ---: | ---: | ---: | ---: | --- | --- |
| 1 | t1 | rank-254 (17.8 %) | 0.045 | 313 | 1 / yes | 805 | 1163 | 81.8 | 0 | 17.8→17.8 % | none |
| 1 | t2 | rank-254 | 0.067 | 271 | 1 / yes | 481 | 1181 | 75.9 | 0 | 17.8→17.8 % | none |
| 2 | t0 (Procmon) | rank-182 (4.4 %) | 0.194 | 647 | 1 / yes | 1138 | 918 | 53.4 | 0 | 4.4→10.9 %¹ | none |
| 2 | t1 | rank-182 | 0.080 | 411 | 1 / yes | 533 | 4808 | 86.4 | 0 | 10.9→10.9 % | none |
| 2 | t2 | rank-182 | 0.058 | 234 | 1 / yes | 1351 | 1761 | 68.0 | 0 | 10.9→10.9 % | none |
| 4 | t0 (Procmon) | rank-152 (0.53 %) | 0.171 | 1566 | 1 / yes | 1061 | 1109 | **113.3** | **3.0** | 0.53→38.8 % | none |
| 4 | t1 | rank-152 | 0.037 | 248 | 1 / yes | 776 | 1846 | 32.1 | 0 | 38.8→38.8 % | none |
| 4 | t2 | rank-152 | 0.058 | 230 | 1 / yes | 718 | 2188 | 35.6 | 0 | 38.8→38.8 % | none |

¹ vfsMeta read at 12:11:05 was stale (4.42 %); the file was flushed at
12:11:14 with 10.93 % (confirmed by the next trial's pre-check). In batches
1–2 the user's mpv was also streaming through the mount, so `preNext` bytes are
not attributable to the trial there; in batch 1 `Rs` did not move at all, i.e.
rank-254 was served from its cached prefix (the 75–82 MB are prefetch/other
clients). Batch 4 had no other reader; +113.3 MB preNext ≈ the file's own
download (Rs +78.6 MB flushed; `scanΔ` +3.0 MB is the only directly
scan-overlapping fetch).

Pre/post context: pre-fix cold/warm lane readiness was **20.7 s (rank-78),
25.0 s (rank-117), never >30 s (rank-254)** with 36/46/60 rejected attempts and
post-readiness target opens of 6.5 s / 0.85 s. The Option-1 validation lane
already measured 0.054–0.334 s (4 trials). This lane adds 8 more trials with
0.037–0.194 s.

## Procmon evidence

Two Duration/TID captures on the corrected cold inputs: batch 2 t0
(rank-182; PML 559.7 MB, 98.1 M filtered CSV) and batch 4 t0 (rank-152;
PML 1.07 GB, 98.1 M filtered CSV). Both captures interpreted; begin/end markers
complete; stop `terminate`; Procmon settings restored.

Worker-TID scan metrics (identical parser/thresholds across lanes):

| metric | pre-fix t6 (rank-203, baseline) | batch 2 t0 (rank-182) | batch 4 t0 (rank-152) |
| --- | ---: | ---: | ---: |
| worker TID | 17628 | 45684 | 15936 |
| worker attr opens total | 258 | 257 | 257 |
| — entry (`child`) | 257 | 256 | 256 |
| — directory | 1 | 1 | 1 |
| worker attr opens on **playing file** | 1 × 5.2492 s | **0** | **0** |
| max single attribute open | 5249.2 ms | 2.263 ms | **0.677 ms** |
| worker `Query*` ops | ~5/entry | 1557 | 1557 |
| attribute opens > 100 ms | ≥1 | **0** | **0** |
| worker scan window (first→last row) | 5.356 s | 0.1708 s | 0.1618 s |
| directory listing open | n/a | 1 × 0.096 ms | 1 × 0.096 ms |
| siblings spliced | 257 | 257 | 257 |

Critical-path overlap (the point of the exercise):
- batch 4 t0: the playing file had **only 1.08 MB cached**; its first reads at
  mpv 0.6–1.3 s took 597–757 ms (network), and during the 0.162 s worker scan
  the file had **one 2 MB read ending at offset 6.29 MB** while rclone fetched
  **+3.0 MB** in the same window. The worker's 256 sibling stats and the
  directory open finished with max 0.677 ms.
- batch 2 t0: the playing file's read during the scan ended at 39.96 MB — just
  at the 39.89 MB cached-prefix edge; the first slow network read (770 ms)
  started 1.4 s later. Sibling stats still max 2.263 ms.

Explicit > 100 ms attribute/open checks in both captures (all targets):

| capture | time | TID / owner | op | target | duration | context |
| --- | --- | --- | --- | --- | ---: | --- |
| batch 4 t0 | 20:17:55.920 | 3288, mpv PID 55972 | `CreateFile(Read Attributes)` | **playing file** (rank-152) | **4789.97 ms** | playlist-sort.lua fallback stat pass; not the worker (worker TID 15936) |
| batch 4 t0 | 20:18:01.952 | 3288 | `CreateFile(Read Attributes)` | sibling rank-155 (`MMV FILMS…`) | 521.88 ms | same pass; sibling was downloading (its reads took 665 ms) |
| batch 4 t0 | 20:18:01.797 | 3288 | `CreateFile(Read Attributes)` | sibling rank-154 (`Mistress wife…`, the skip target) | 151.34 ms | same pass; target was being streamed (reads 753 ms) |
| batch 2 t0 | 19:10:06.449 | 8280 | `CreateFile(Read Attributes)` | **playing file** (rank-182) | **4745.28 ms** | same path (see below) |
| batch 2 t0 | 19:10:11.644 | 8280 | `CreateFile(Read Attributes)` | sibling `PLEASE BANG MY WIFE…` (target) | 489.43 ms | same path |

No directory-listing open exceeded 0.18 ms in either capture. All remaining
> 100 ms ops are mpv's own IPC pipes or the user's/sidecar processes, not
media-root metadata.

## New finding — the residual stall is the playlist-sort fallback stat pass

The 4.8 s playing-file attribute open is reproduced across both Procmon
captures and is **not** the built-in autocreate scan:

1. `%APPDATA%\mpv\scripts\playlist-sort.lua` calls
   `utils.file_info(path)` for every playlist entry in `assign_stat_key()`
   (fallback modes mtime/ctime/size, 20 entries per idle tick).
2. In both t0 logs the Explorer sort lookup fails shortly after playback
   starts (batch 4: `1.619 s`, batch 2: `1.473 s`), which selects that fallback
   pass.
3. The stall TID's op sequence matches it exactly: one thread (8280/3288)
   stats media-root siblings in playlist order, blocks on the playing file
   (4.7–4.8 s) while it is downloading, then continues with the remaining
   entries; the script's `restored prefetch-playlist` line lands immediately
   after the stall (batch 4: `6.749 s`, i.e. ~5.1 s after the Explorer failure;
   the stall ended at 20:18:00.71). The pass also stalls on target/prefetch
   siblings that are downloading at the moment they are stat'ed.
4. Effect: prefetch stays disabled (`options/prefetch-playlist=false`) for the
   ~5 s the pass is blocked. It is post-readiness and post-next-acceptance:
   `accepted next→T4` was 0.7–1.4 s and `quit→exit` 1.1–2.2 s in these trials,
   so it did not move the measured skip boundaries — but it is a real ~5 s
   exposure whenever the playing file is being downloaded and the Explorer
   fallback runs.

Pre-fix this class of stall (an `mp_stat` on an actively downloading file) was
5.249 s on the include file inside the worker. Option 1 removed the worker's
exposure; Option 2 would remove the sibling stats but **not** this include-file
stat (Option 2 does not stat the include file either). The residual is a
different consumer and a different fix location.

## Reproduce

Harness and helpers (verified hashes) live in every batch `scripts\` dir. The
driver is one process: gate (wpa tools absent, poll 20 s) → acquire
`Global\MpvPerfLiveLane` (WaitOne 60 min; `AbandonedMutexException` = acquired)
→ preflight (`Measure-Load.ps1 -Seconds 20`; one 60 s stabilization wait, abort
if still heavy) → VFS state (`Get-VfsCacheState.ps1`) → Procmon pass t0
(`Invoke-ProcmonCapture.ps1` + `procmon-duration-tid.pmc`, settle 3 s, timeout
240 s) → filter + `measure-scan.ps1` + `Check-PlayingFileAttr.ps1` +
`Analyze-WorstCase.ps1` + `Get-FetchWindow.ps1` → two plain trials → summary;
mutex released in `finally`. Example (batch 4):

```powershell
pwsh -NoProfile -File <run>\scripts\Invoke-ColdWorstValidation.ps1 `
  -RunDir <run> -SelectionPath <run>\scripts\selection-coldworst4.json `
  -HarnessPath <run>\scripts\Invoke-MpvSkipBatch.ps1 `
  -MpvPath C:\Users\andre\Projects\mpv\dist\mpv.exe -MediaRoot I:\XXX\new2 `
  -ProcmonHelper <skill>\scripts\Invoke-ProcmonCapture.ps1 `
  -ProcmonConfig <skill>\assets\procmon-duration-tid.pmc `
  -ScanScript <run>\scripts\measure-scan.ps1 `
  -CensusJson <option1-run>\measurements\cache-pool-after.json -RclonePid 2236
```

Procmon helper note: the run directory must contain a `manifest.json` with
`schemaVersion: 1` (skill `New-PerformanceRun.ps1` layout); batch 1 failed its
Procmon pass for this reason and was retained, not overwritten.

## Gates, contamination, failed attempts

- **Batch 3 aborted by preflight (retained):** 20:11–20:12, `\Memory\Pages/sec`
  averaged 3,326 then 6,825 (threshold 2,000) with 24–43 MB/s disk reads and
  349 MB/s transient read bursts; available RAM was still 75 GB, CPU 5.8–6.4 %.
  Read-only attribution at 20:16: top read/fault consumers were `chatgpt`
  (10 PIDs), `svchost`, `MsMpEng` (PID 5708), `rclone`, `explorer`; the user's
  mpv (PID 46832) and the test workload were not reading. No trial ran; mutex
  released. After the metric cleared (20 s average 1,839 pages/s, then 19.9 in
  the batch-4 preflight) the batch was retried as batch 4 on a fresh run
  directory.
- Mutex held for four separate measurement batches (one per run directory);
  batch 3 held nothing measurable. No other lane's measurement overlapped.
- All four batch stdout/stderr and driver event logs retained; the only
  failures were batch 1's Procmon start (missing manifest) and batch 3's
  preflight abort. No measurements were lost or overwritten.
- `quit→exit` outliers (4.8 s in batch 2 t1, 2.2 s in batch 4 t2) are teardown,
  outside the skip path; no failure.

## Verdict per claim

| # | claim | status | evidence |
| --- | --- | --- | --- |
| 6 | Pre-fix heavy-fetch readiness variability (20.7/25.0/>30 s) is gone post-fix | **VERIFIED** (scope) | 8/8 trials 0.037–0.194 s, first-try nexts 8/8; decisive trial rank-152 with +3.0 MB fetch inside the 0.162 s scan window; pre-fix 36/46/60 rejections |
| 7a | The built-in 256 per-entry stats are fast even under active fetch (no sibling/listing stall) | **VERIFIED** | max 0.677 ms (rank-152) / 2.263 ms (rank-182); 0 attribute opens > 100 ms on the worker; 0.16–0.17 s window |
| 7b | Option 2 is still needed to fix the heavy-fetch readiness stalls | **CONTRADICTED** | stalls traced to the playing-file `mp_stat` removed by Option 1; Option 2 targets stats that cost < 1 ms; residual stalls are on a third-party Lua path Option 2 does not touch |
| 7c | No residual multi-second metadata stall exists for downloading files | **CONTRADICTED (new finding)** | 4.79 s / 4.75 s playing-file `CreateFile(Read Attributes)` from `playlist-sort.lua`'s Explorer fallback, TIDs 3288/8280; 151–522 ms sibling stats |
| — | Census size/match cache classes are valid for WinFsp-mapped names | **CONTRADICTED** | 12 files report `absent` while vfsMeta has full ranges; content files are pre-allocated full-size |

## Remaining uncertainty and next discriminating measurements

1. The pre-fix 20–30 s cluster was never per-op traced and its full load
   (user stream 6–22 MB/s + side analysis + one large cold file) was not
   recreated; only one trial (batch 4 t0) has confirmed backend fetch strictly
   overlapping the worker scan. To close completely, rerun batch 4's condition
   with a second simultaneous reader on the same mount.
2. The Lua path's user-visible cost was not isolated: disabling
   `playlist-sort.lua` (or opening `I:\XXX\new2` in Explorer so the Explorer
   sort succeeds and the fallback pass never runs) should remove the 4.8 s
   block and the ~5 s prefetch-gate delay; measure `accepted next→T4` and
   prefetch-restore time for both configurations. This is a user-script/config
   change and should be routed to `mpv-lua-scripter` per the repository rules.
3. Option-2 necessity was tested with one active download and no concurrent
   sibling downloads during the scan (prefetch is gated until the sort
   finishes). If a future config prefetches next entries *before* the scan, the
   sibling stats would be exposed; the fix should be evaluated in that
   configuration, not the built-in scan alone.
4. Elevated (High IL) mpv only; medium-IL behavior unmeasured. Cache was not
   purged, so the three inputs are partially warm now (rank-254 17.8 %,
   rank-182 10.9 %, rank-152 38.8 %).

## Raw artifacts (outside Git)

| batch | run directory (`C:\Users\andre\PerfRuns\`) | key evidence |
| --- | --- | --- |
| 1 | `mpv-playlist-option1-coldworst-20260911T115609Z-ed0524be` | rank-254 readiness t1/t2; Procmon start failed (missing manifest) |
| 2 | `mpv-playlist-option1-coldworst2-20260911T120919Z-e2e65fc7` | PML `traces\procmon-*.pml` 559.7 MB; `exports\procmon-coldworst-filtered.csv` 89.9 MB; `measurements\{scan-after,check-playing-file,worst-case-analysis,stat-passes-trial,fetch-window-t*}.json` |
| 3 | `mpv-playlist-option1-coldworst3-20260911T131107Z-afaabce0` | retained preflight abort (`preflight-1/2.json`, `driver-events.jsonl`) |
| 4 | `mpv-playlist-option1-coldworst4-20260911T131724Z-c9ccd0c8` | PML `traces\procmon-*.pml` 1.07 GB; `exports\procmon-coldworst-filtered.csv` 98.1 MB; `measurements\{scan-after,check-playing-file,worst-case-analysis,fetch-window-t*,vfs-*}.json`; `logs\{gate-wait,trial-guards,driver-events}.jsonl` |

Project package: this file plus
`measurements\option1-cold-worstcase-trials.csv` (8 trials) and updated
`artifacts.md` / `commands.md`. Source context for follow-up:
`demux/demux_playlist.c` (Option 1, commit `2b0f9f46ca`), `osdep/io.c`
(`mp_stat`/`mp_readdir`; the uncommitted `_DIRENT_HAVE_D_TYPE` guard was present
at build time and does not change the measured 256-stat behavior),
`%APPDATA%\mpv\scripts\playlist-sort.lua` (`assign_stat_key` →
`utils.file_info`), rclone mount flags above.
