# Live cold/warm playlist-skip latency (real config, rclone VFS cache state)

Date: 2026-09-11 18:17-18:22 local (UTC+07). Lane: live mpv lane behind mutex
`Global\MpvPerfLiveLane`; no `wpaexporter`/`wpa`/`xperf` process ran during any
trial (checked before/after each trial, `logs\trial-guards.jsonl`).

## Scenario

Real user config, `C:\Users\andre\Projects\mpv\dist\mpv.exe`
(v0.41.0-947-gd37b8c1a7-dirty, SHA256 777FB944…), random top-level
`I:\XXX\new2\*.mkv` input per trial. Boundary per trial: process start → first
`playback-restart` (T1) → wait 5 s → `playlist-next` + immediate second
`playlist-next` → first `playback-restart` at playlist position +2 (T4) → `quit`
→ exit. Durable harness `Invoke-MpvSkipBatch.ps1` (SHA256 B8654DE7…), one
harness trial per invocation, arm name `real` (harness validates arm as
real|control; per-trial batch copies `batch-real-tN.json`), context arms
`real-cw-tN`. Inputs were drawn without replacement from the sorted top-level
list, excluding ranks 255-257 so position+2 exists.

Primary = 5 uniform random draws (t0-t4). Supplementary = 3 draws from the
census cold pool (t5-t7), added because the primary draw produced no cold input.
No cache purge was performed.

## Cache classification rule (explicit)

Mount `rclone mount wcrypt: I:` (PID 55588, RC 127.0.0.1:5574,
`--vfs-cache-mode=full`, cache `D:\rclone-wasabi-cache`, chunk 1M, max-size 1000G,
max-age 8760h). Per playlist entry, compare the cache file
`D:\rclone-wasabi-cache\vfs\wcrypt\XXX\new2\<name>` with the remote file:

| class | rule (pre-trial census) | expected service |
| --- | --- | --- |
| `full` (warm) | cache file exists and size == remote size | local disk; no backend data fetch |
| `partial` | 0 < cache size < remote size | mixed |
| `absent`/`zero` (cold) | no cache file (or 0 bytes) | backend fetch expected |

Confirmation used in-trial rclone `core/stats` byte/transfer deltas sampled by
the harness every ~200 ms (per-phase windows) plus the rclone log slice.
Caveats (important): size match does **not** prove rclone's fingerprint match,
and `core/stats` is shared with other mount clients (the user's own mpv streamed
through the same rclone instance during most trials), so per-file backend bytes
are not isolated. rclone at INFO does not log per-file downloads; no
`removed cache file as stale` line appeared for any trial file in its log slice.

Startup census (18:52-18:55, before the batch): 257 remote files, 257 cache
files: **245 `full`, 12 `absent`** (cold pool ranks 35, 90, 117, 147, 152, 182,
190, 202, 203, 254, 256, 257; ~5.6 GB total). The 12 absent names had no cache
counterpart; 12 orphan cache entries existed under different names.

## Environment

- Windows 11 Pro Insider Preview 26220, Ryzen 9 9950X3D (32 logical), 95.7 GB
  RAM, RTX 5070 Ti 616.92. mpv ran elevated (High IL) - documented deviation.
- rclone v1.76.0-beta.10339; mount PID 55588 (warm since 14:34).
- Preflight 18:16:20-18:16:37: CPU 6.8 %, RAM 75.8 GB free, D: 9.8 MB/s /
  0.19 % busy, pages/s ~89, no wpa/xperf. Background present and recorded: the
  user's own mpv streaming 6-22 MB/s through the same wcrypt mount (PID 36064
  exited, PID 59764/52948 active), a sibling analysis process reading ~10 MB/s,
  Explorer/thumbnail activity. Disposition: proceed with recorded contention
  (parent instruction: user mpv/Explorer activity is expected; no cache purge).
- `quit->exit` includes mpv teardown; keep visible in table.

## Results (per trial; times in ms, harness stopwatch)

| trial | input class (rank) | target class (rank) | nexts 1st attempt | T1 | accepted next->T4 | quit->exit | backend whole (spawn->exit) | backend pre-next window | notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| t0 | full (130) | full (132) | yes | 547 | 1683 | 1477 | 231.0 MB / 29 | 146.6 MB / 20 | autocreate ready 0.23 s |
| t1 | full (67) | full (69) | yes | 1307 | 326 | 3100 | 141.9 MB / 12 | 121.0 MB / 10 | autocreate fast |
| t2 | full (14) | full (16) | yes | 1006 | 879 | 1850 | 169.5 MB / 20 | 151.6 MB / 19 | autocreate fast |
| t3 | full (173) | full (175) | yes | 403 | 54 | 1356 | 115.0 MB / 10 | 109.6 MB / 9 | autocreate fast |
| t4 | full (78) | full (80) | **no (36)** | 1212 | **6472** | 1809 | **676.9 MB / 66** | 119.4 MB / 11 | autocreate ready only 20.7 s; 554 MB fetched during target window |
| t5 | **absent (254)** | n/a | **never (60)** | 416 | n/a | n/a | 195.1 MB / 19 | n/a | **FAILED**: all 60 nexts rejected; autocreate never completed in 30 s |
| t6 | **absent (203)** | full (205) | yes | 510 | **233** | 1665 | 71.9 MB / 6 | 58.7 MB / 4 | cold 156 MB input; autocreate ready 0.20 s |
| t7 | **absent (117)** | full (119) | **no (46)** | 1009 | **849** | 1602 | 531.1 MB / 54 | 146.5 MB / 14 | cold 402 MB input; autocreate ready only 25.0 s |

Backend columns are rclone `core/stats` deltas (bytes / accounting transfers)
for the whole harness window and the T1->accepted-next window; they include all
clients of the shared wcrypt instance (mainly the user's mpv stream), so treat
them as upper bounds, not per-file cost.

Mechanism evidence (mpv log timestamps, mpv clock): `Autocreate playlist: 257
siblings` at 0.226 s (t0), 0.200 s (t6), 20.705 s (t4), 25.026 s (t7), never
within 30 s (t5). Before that line, `playlist_sort.lua` gates prefetch and
`playlist-next` gets `error running command` (playlist still 1 entry); the
harness retried every ~400 ms (36/46/60 attempts). In t4 and t7, prefetch plus
concurrent mount fetches resumed at readiness and the target open still took
6.5 s / 0.85 s respectively.

## Verdict: does skip latency track VFS cache state?

- **VERIFIED**: for warm inputs (census `full`), both nexts were accepted on the
  first attempt and the sequence completed in 8.4-11.3 s harness time.
- **VERIFIED (contradicts the naive hypothesis)**: a cold input does **not**
  slow launch->first-frame: T1 was 416-1009 ms cold vs 403-1307 ms warm. Once
  the playlist was ready, the accepted next->T4 was also small cold
  (233 ms, 849 ms) vs warm (54-1683 ms).
- **VERIFIED**: cache state affects the sequence through *playlist readiness*:
  while the same mount was busy fetching (t5: 2.28 GB cold input; t7: 402 MB
  cold input; t4: census-full input but 677 MB fetched during the trial), the
  `autocreate` expansion of 257 siblings took 20.7 / 25.0 / >30 s instead of
  ~0.2 s, so the literal T1+5 s nexts were rejected 36/46/60 times. This is the
  dominant wall-clock cost, not the target-file open.
- **VERIFIED**: `quit->exit` 1.36-3.10 s with no split by cache class.
- **INCONCLUSIVE**: exact reason the directory/autocreate work stalls under
  concurrent downloads (rclone/WinFsp metadata queueing is the leading
  hypothesis; no ETW/Procmon in this lane). Next discriminating measurement:
  Procmon or ETW FileIO on `I:\XXX\new2` during a cold skip to time the
  directory/stat operations.
- **INCONCLUSIVE**: whether t4's `full` cache entry was stale (rclone fingerprint
  mismatch). Wasabi metadata through the mount reports an identical synthetic
  mtime (2026-09-11T07:34:47Z = mount start) for every file, so mtime comparison
  cannot decide it, and no stale-removal line was logged for it.

Practical summary: the dominant cost in this environment is not the skip target
but `autocreate` playlist expansion degrading from ~0.2 s to 20-30+ s while the
rclone mount is downloading (cold input or concurrent user stream); the naive
T1+5 s next is then a no-op and the skip lands when the playlist finally exists.

## Caveats

- No cache purge; the 245/12 composition was pre-existing and only changed by
  the downloads these trials triggered.
- Secondary lane activity: sibling analysis process, user's own mpv streaming
  through the same rclone instance during most trials, Explorer/thumbnail
  activity; no offline export tools ran during trials (per-trial guard +
  `trial-guards.jsonl`).
- Two primary-arm inputs are not rank-ordered by cache state; the supplementary
  cold draws were needed because the random draw produced none.
- mpv ran elevated (High IL); normal medium-IL behavior unmeasured.
- t5 is a retained failure (retry budget exhausted); t4's slow attempt count is
  a censored observation (accepted after 36 retries).

## Artifacts

External run (raw): `C:\Users\andre\PerfRuns\mpv-playlist-skip-coldwarm-20260911T1050Z-7c1e5b3a\`
- `measurements\coldwarm-summary.json` / `.csv` (per-trial table incl. all windows)
- `measurements\batch-real-tN.json`, `events-real-tN.json`, `rclone-real-tN.json`,
  `samples-real-tN.json`, `mpv-real-tN.log` (t0-t7)
- `measurements\cache-real-cw-tN.json`, `cache-pool-real-cw-tN.json`,
  `rc-pre/post-real-cw-tN.json`, `rclone-log-real-cw-tN.txt`
- `measurements\{recon-0,recon-1,preflight-1..3}.json`,
  `measurements\cache-pool-census.json`, `measurements\environment-run.json`,
  `measurements\selection-{primary,supplementary}.json`
- `logs\gate-wait.json(l)`, `logs\gate2-wait.jsonl`, `logs\trial-guards.jsonl`,
  `logs\live-lane-status.json`; scripts in `scripts\`
