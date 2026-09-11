# MPV rapid playlist-skip on an rclone/Wasabi mount — Windows performance investigation

Scenario: open one random top-level video from `I:\XXX\new2` (rclone `wcrypt:`
over Wasabi, WinFsp network-mode mount), wait 5 s after the first video starts,
send `playlist-next` twice back-to-back over IPC, and quit as soon as the third
distinct file's playback restarts. Two arms:

- **real** — normal launch (`%APPDATA%\mpv\` config + Lua scripts apply).
- **control** — `--no-config --autocreate-playlist=filter` (clean defaults; also
  disables hwdec/VO choice/caches/scripts — this is not a pure prefetch A/B).

Three trials per arm (user order: real first), plus one observer (Procmon) extra
trial and several unmarked smoke trials. No source, user config, or cache was
modified.

## 1. Result summary

All timings are wall clock on one monotonic stopwatch; `T1` = first
`playback-restart`; `T4` = playback-restart of the file two playlist positions
after the first (the "third distinct file"); `T5` = process exit.

| arm | trial | input (anonymized) | input bytes | launch→T1 | T1→first next | next attempts accepted | successful next→T4 | T4→quit | quit→T5 | exit |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| real | t0 | rank-101/257 | 70,944,895 | 1106.9 ms | 5026.5 ms | 1 | 812.5 ms | 2.0 ms | 1103.0 ms | 0 |
| real | t1 | rank-63/257 | 401,439,207 | 1146.9 ms | 5017.3 ms | 5 | 4170.6 ms | 6.6 ms | 694.7 ms | 0 |
| real | t2 | rank-44/257 | 116,662,298 | 1123.0 ms | 5010.9 ms | 7 | 3236.5 ms | 0.2 ms | 923.8 ms | 0 |
| control | t3 | rank-244/257 | 320,376,561 | 397.8 ms | 5042.4 ms | 1 | 120.4 ms | 1.9 ms | 352.3 ms | 0 |
| control | t4 | rank-39/257 | 398,189,639 | 1216.3 ms | 5006.0 ms | 1 | 483.5 ms | 1.1 ms | 107.2 ms | 0 |
| control | t5 | rank-188/257 | 419,756,111 | 389.6 ms | 5006.2 ms | 1 | 86.3 ms | 0.2 ms | 60.2 ms | 0 |
| real+Procmon | t6 | rank-95/257 | 87,177,521 | 480.1 ms | 5033.5 ms | 2 | 1258.8 ms | 2.2 ms | 3512.6 ms | 0 |

Headline facts:

- In the real arm the literal user sequence **does not work 2 times out of 3**:
  `playlist-next` at T1+5 s is rejected with `"error running command"` because
  the autocreated playlist is not populated yet. The file open that the user
  intends does not start; the harness retried (5 and 7 attempts) to complete the
  three-file sequence. Control arm: both nexts accepted on the first try in 3/3.
- Once the nexts are accepted, the real arm takes **0.81/4.17/3.24 s** to reach
  the third file's first playback vs **86-484 ms** for control.
- The dominant real-arm terms are (a) the local `playlist-sort` script's
  `explorer-sort.ps1` PowerShell subprocess sitting on the file-open hook
  (~0.5-0.8 s per open), (b) the aborted open of the skipped v2 entry (observed
  CreateFile/CloseFile of 3.09 s/2.13 s under the Procmon observer pass), and
  (c) cold WinFsp→rclone→Wasabi reads with ~0.4-0.76 s individual latencies.
- No rclone retries/errors and no cache-pause stalls occurred in any trial.

## 2. Boundary, inputs, cache state

- Media root: `I:\XXX\new2`, 257 top-level `.mkv` files, 98,371,163,700 bytes
  total. Inputs are reported by name-rank alias only; the raw mapping stays in
  `C:\Users\andre\PerfRuns\mpv-playlist-skip-20260911T090749482Z-da38e1520da444cca96c26acd325bc27\measurements\selection.json`.
  File mtimes are synthesized equal by the mount (`NoModTime=true`), so size and
  rank are the usable identities.
- Launch boundary: `Process.Start` of `dist\mpv.exe`. First frame: first
  `playback-restart` IPC event (`player/playloop.c`, `handle_playback_restart()`).
  T4 definition and the retry policy are documented in section 4.
- Cache state: no purge; the rclone VFS full cache was 33.6 GB at session start
  and ~39 GB during the batches. Because the real arm ran before control and its
  prefetch had pulled sibling entries, the control batch partly hit cache
  (0-2 backend transfers per 5 s window); this is a real confound for arm
  comparison of byte counts, though not for the harness timings.
- Host: Windows 11 Insider 26220; Ryzen 9 9950X3D 16C/32LP; 102.7 GB RAM.
- Elevation: the harness ran with High integrity (admin); mpv inherited High IL.
  A normal user launch is medium IL and was **not** measured (gap).

## 3. Environment, build, tools

- Binary: `C:\Users\andre\Projects\mpv\dist\mpv.exe`, mpv
  `v0.41.0-947-gd37b8c1a7-dirty`, built 2026-09-11 03:34:59, x64; no PDBs
  shipped in `build\`, so mpv frames cannot be symbolized from this build.
- Real-arm active options (user config, unmodified): `autocreate-playlist=filter`,
  `directory-mode=ignore`, `keep-open=yes`, `cache=yes cache-secs=600
  demuxer-max-bytes=4096MiB demuxer-hysteresis-secs=400 cache-pause=yes
  cache-pause-wait=1`, `prefetch-playlist=yes` max 10 with 300 s/2 GiB expanded
  and 60 s/1 GiB start windows, `vo=gpu-next`, `gpu-api=d3d11`,
  `hwdec=d3d11va`, fullscreen; Lua scripts include `playlist-sort.lua`,
  `rtx-video-auto.lua`, `remember-rtx.lua`, `modernz.lua`.
- rclone mount: PID 55588, `rclone mount wcrypt: I: --network-mode`; exposed to
  mpv as `\\server\RcloneWcrypt\...`; VFS full cache on
  `D:\rclone-wasabi-cache\vfs\wcrypt`, `--vfs-read-chunk-size 1M`→256M,
  `--vfs-read-chunk-streams 0`, `--buffer-size 0`, `--vfs-read-ahead 0`,
  handle caching 60 s; RC API `http://127.0.0.1:5574`.
- Tools: WPR 10.0.26100.9306; WPAExporter 11.7.395.48728; Sysinternals Procmon
  (`C:\Users\andre\Desktop\Mem\ProcMon\Procmon.exe`, EULA previously accepted);
  xperf from the same WPT install; PowerShell 7.6.6.
- `environment.json` records the same machine facts as archived by the run
  helper.

## 4. Method, observer, deviations

- Harness: `measurements\Invoke-MpvSkipBatch.ps1` in the external run (a durable
  copy is available at the skill's `scripts\` dir). It selects inputs, spawns
  `mpv.exe`, connects to `--input-ipc-server`, observes
  `playlist-pos/filename/prefetch-active/prefetched-count/cache-buffering-state`,
  samples mpv process counters every 100 ms, samples rclone `core/stats` and
  `vfs/stats` every 200 ms, samples `nvidia-smi` every 500 ms, and inserts WPR
  markers (`tN-launch`, `tN-T1`, `tN-nexts`, `tN-T4-quit`, `tN-exit`).
- **Deviation (documented)**: the spec's literal sequence (one next at T1+5 s,
  immediately a second) was attempted first in every real trial. When mpv
  rejected both commands, the harness retried the pair after 400 ms until both
  replies were `"success"` (max 60 attempts). Attempt times, spacing, probe
  positions and replies are recorded per trial. The reported `successful
  next→T4` is measured from the accepted attempt's second write.
- T4 detection is position-based: a synchronous `get_property playlist-pos`
  before the first attempt defines `pos0`; T4 is the first playback-restart after
  the nexts with current position ≥ `pos0+2` (or the position carried by the
  event). Per-trial event files retain every restart with its position.
- Observer: WPR `CPU.Light+FileIO.Light+DiskIO.Light+GPU.Light+Network.Light`
  captures per arm (markers per phase), one Procmon trial with
  Duration/TID columns, one 10 s idle WPR probe set for ETL-volume planning, and
  the parent's retained CPU.Verbose ETLs (see artifacts) for future stack work.
  `CPU.Light` has **no stacks** (verified with `wpr -profiledetails`); no
  decision-critical stack claim is made from these captures.
- Observer overhead: the Procmon trial's `quit→exit` was 3512 ms vs 695-1103 ms
  untraced; WPR per-arm captures add process/thread tracing but the harness
  phase numbers are measured by the workload itself.
- Incident: the Procmon pass ran with `-Arm real`, so the harness rewrote
  `batch-real.json`. The three real trials were reconstructed from the retained
  per-trial event files (`real-batch-reconstructed.json`); the accepted-attempt
  T4 latencies were preserved in the session transcript and are marked as such
  in `summary.csv`.

## 5. Preflight and disposition

| check | CPU | RAM / paging | disk | network | GPU | top unrelated consumers | disposition |
| --- | --- | --- | --- | --- | --- | --- | --- |
| preflight-1 10 s | 10.2% avg (16.8% utility) | 72.2 GB avail; paging 0.69% | 99.25% idle, queue 0, 164 MB/s | 36 MB/s (yt-dlp/downloader) | ~1% | System, MsMpEng, dwm, firefox, 3× yt-dlp | proceed (network noted) |
| preflight-2 6 s | 26.8% avg | 74.5 GB avail; paging 0.60% | 99.23% idle, queue 0, 6.5 MB/s | 0.77 MB/s | 6-7% (one decoder) | StateRepository, AppX Deployment, observer pwsh, explorer | proceed |

Scenario-specific contamination thresholds: CPU saturation (>50% total) or any
single unrelated process >25%; disk busy >20% or queue >2 on the media/cache
volumes; network >50 MB/s sustained unrelated; available RAM <8 GB or paging
>10%; unrelated GPU decode >50%. No threshold was exceeded during the batches;
the preflight-2 CPU level includes the observer's own WMI sampling and two
observer PowerShell shells. Both checks are archived as `preflight-1.json` /
`preflight-2.json` in the external run.

## 6. Critical-path evidence per phase

### 6.1 launch → T1 (real 1.11-1.15 s; control 0.39-1.22 s)

- mpv logs show a repeated ~840-850 ms gap between `Trying demuxers for
  level=normal` / `Trying demuxer: directory` and the next demuxer attempt
  (`mpv-real-t1.log` 0.195→1.036 s, `mpv-real-t2.log` 0.191→1.021 s).
- The gap appears in both real trials; control logs were not decomposed at this
  level, so whether the gap is script-independent is **INCONCLUSIVE**. It sits
  inside `demux_open()` before any stream read is logged.
- Procmon (observer pass, t6): first `ReadFile` on the mount 4:37:41.39 and a
  `CreateFile` on the same file at 4:37:41.42; the first reads complete in
  0.4-0.76 s each. Every long operation in the trial is on
  `\\server\RcloneWcrypt\...`; the local physical disks are idle.
- WPA (real t1 window 12712-23813 ms): mpv.exe sampled CPU 4.2 s (~38% of one
  core over the 11.1 s window); rclone.exe 16.0 s across its threads; no thread
  stacks were captured (CPU.Light).

### 6.2 T1 → first next (all trials 5.01-5.04 s)

Harness timer; no mpv-side delay observed. The 5 s wait itself is exact within
3-18 ms of the 5000 ms target (recorded per trial).

### 6.3 first next (the user's action) — rejected in 2/3 real trials

- t1: `Run command: playlist-next` twice at 6.142 s log time; replies
  `"error running command"`. Probe before the attempt returned `playlist-pos=0`.
  `Autocreate playlist: 257 siblings.` only appears at 7.740 s log time. The
  fifth attempt (at ~8.65 s log) succeeded after the sort restored prefetch.
- t2: 7 attempts; `Autocreate playlist: 257 siblings.` at 8.361 s log.
- t0 (rank-101, smaller file, warmer metadata): playlist ready by T1+5 s;
  first attempt accepted, T4 at +812 ms.
- Control: no `playlist-sort` script; the playlist becomes usable sooner and all
  first attempts are accepted (probe positions 243/38/187 immediately).

Interpretation: with `autocreate-playlist=filter` on this 257-entry rclone
directory, the playlist is only complete ~7-8 s after launch in the real arm
(sorting script included). The user's "5 s after start" action lands inside that
window. VERIFIED by IPC replies, property probes, and mpv logs.

### 6.4 successful next → T4 (real 0.81/4.17/3.24 s; control 86-484 ms)

t1 (4.17 s) decomposition from `mpv-real-t1.log`:

1. `EOF code: 3` / end-file at 7.928 s; `Running hook:
   playlist_sort/on_before_start_file` at 7.944 s.
2. The hook runs `powershell.exe ... explorer-sort.ps1 -LiteralPath I:\XXX\new2`
   (started 7.901 s, **completed 8.648 s, ~0.70 s**, exit status 1 →
   `explorer sort lookup failed`), then an identity `playlist-reorder` and
   prefetch restore at 8.651 s.
3. v3 `Playing:` at 8.652 s; stream open 8.653 s; the `directory` demuxer probe
   ends at 9.227 s (**574 ms**); Matroska is detected and `Opening done` at
   10.254 s (another ~1.0 s for header parse/reads).
4. AO/VO/hwdec/RTX VPP reconfiguration follows; the third file's
   `playback-restart` lands ~4.17 s after the accepted next.

t2 (3.24 s) follows the same shape: hook subprocess 8.511→9.281 s (~0.77 s),
v3 `Playing:` 9.285 s, demux open fast (Matroska at 9.299 s), slower tail to
restart. Procmon (t6) shows the aborted v2 open explicitly — `CreateFile`
3.09 s + `CloseFile` 2.13 s + `ReadFile` 1.25 s on the aborted second entry — plus
v3 reads of 0.38-0.65 s each. So both the skipped entry's aborted open and the
target open pay WinFsp/S3 latency in cold conditions.

mpv logical read bytes (process IO counters) during the transition window:
t0 18.4 MB / 0.81 s, t1 58.2 MB / 4.17 s, t2 193.2 MB / 3.24 s. rclone fetched
from the backend during the preceding 5 s windows: 89/187/215 MB with 9/22/38
transfers (real) vs 75-113 MB with 0-2 transfers (control, cache-warm).
No rclone `errors`/`retryError`/`fatalError` in any sample.

### 6.5 Prefetch interaction

`playlist-sort.lua` explicitly **gates prefetch off** from the first file load
until the autocreate sort completes (`gated prefetch until autocreate sorting
finishes`, `restored prefetch-playlist after playlist sorting/end-file`), so the
aggressive prefetch does *not* compete during the T1+5 s window. After the sort
is restored, prefetch starts for the entries after the new current one and
overlaps the target open; in t1 one prefetch open was aborted and re-issued
(`Aborting ongoing prefetch of wrong URL`, repeated `Prefetching:`), which is
wasted work but not separable from the target-open time without stacks. The
control arm has no prefetch at all and still reaches T4 in ≤484 ms (cache-warm),
so prefetch is not required for a fast skip.

### 6.6 quit → exit (real 0.69-1.10 s; control 0.06-0.35 s; Procmon 3.51 s)

- `end-file` reason `quit` is logged at exit; `T4→quit` is 0.2-6.6 ms, so the
  0.7-1.1 s is post-quit teardown while a file open/decoder/VPP chain is in
  flight (mpv log shows demuxer termination plus `vf remove @rtxvideo` and
  VO/audio uninit paths).
- No rclone/WinFsp shutdown wait is visible in logs or RC stats (no in-flight
  transfer growth after quit); the Procmon trial's 3.5 s is observer-inflated.
- Exact shutdown blocking chain is INCONCLUSIVE without thread stacks.

### 6.7 GPU

Logs show RTX VPP (`d3d11vpp`) reconfiguration on every transition
(`RTX Video disabled` → `enabled`, `vf remove/add @rtxvideo`, HDR tagging) and
nvidia-smi samples are retained. No present/queue stall was isolated; GPU
contribution to the transition latencies is INCONCLUSIVE.

## 7. Findings, ranked

1. **VERIFIED — the literal scenario misses its window in the real config.**
   At T1+5 s the autocreated playlist is not yet populated (probe
   `playlist-pos=0`, 5-7 rejected `playlist-next` pairs in t1/t2), so the user's
   next action is a no-op. Evidence: `events-real-t1/t2.json`,
   `mpv-real-t1/t2.log`, `summary.csv`. This is a config/script interaction
   (`autocreate-playlist=filter` + 257-entry rclone dir + `playlist-sort.lua`),
   not a demonstrated mpv core defect.
2. **VERIFIED — the local `playlist-sort` hook adds a 0.5-0.8 s PowerShell
   subprocess to every gated file open**, and its `explorer-sort.ps1` fails
   (status 1) before falling back to a no-op reorder. Source: user-owned
   `%APPDATA%\mpv\scripts\playlist-sort.lua`; log lines and Procmon
   `Process Create powershell.exe` correlate. Proposed experiment: disable the
   script for one arm and re-measure.
3. **VERIFIED — cold WinFsp→rclone→Wasabi reads dominate the target open.**
   Individual mpv reads on `\\server\RcloneWcrypt\...` take 0.38-0.76 s
   (Procmon, t6), all long ops are on the mount, physical disk service time is
   negligible (WPA Disk Usage, Procmon), and rclone fetches 0-215 MB from the
   backend per phase with no errors. File paths, TIDs and durations are in
   `procmon-summary.json`.
4. **VERIFIED — the immediate second next aborts the first next's open at real
   cost.** Procmon t6 shows the aborted second entry with a 3.09 s
   CreateFile and 2.13 s CloseFile while v3 is opened. The skip is not free;
   the aborted open/close competes with the target open.
5. **VERIFIED — control arm skip latency is 1-2 orders of magnitude smaller**
   (86/484/120 ms) with the same harness, but the control files benefited from
   VFS cache warmth created by real-arm prefetch; treat the ratio as an upper
   bound, not a pure config effect.
6. **VERIFIED (negative) — no rclone retries/errors, no cache-pause stalls on
   transitions.** Two startup WASAPI underruns in the real arm at ~1.37 s after
   launch (t0/t1) and one benign Lua `__pycache__` error per real run.
7. **INCONCLUSIVE — thread-level READY/WAIT and stack attribution.** The
   captures intentionally used `.Light` profiles (ETL volume 1.1-4.3 GB per
   arm); CPU.Light has no stacks, mpv ships no PDBs, and the retained
   CPU.Verbose parent ETLs were not exported in this session.
8. **INCONCLUSIVE — GPU present stalls and medium-IL behavior** (mpv ran
   elevated).

## 8. Source-level follow-up map

- `player/loadfile_async.c` — `start_open()`, `prefetch_next()`, stale/aborted
  open handling (`Aborting ongoing prefetch of wrong URL`, `Dropping stale
  prefetched URL`).
- `player/autocreate_playlist.c` — `mp_start_autocreate_playlist()`; sibling
  scan completing ~7-8 s after launch here.
- `demux/demux_playlist.c` — `scan_dir()` / directory probing (the
  `Trying demuxer: directory` step sits in the 840 ms first-open gap).
- `player/playloop.c` — `handle_playback_restart()`, cache-pause and quit path.
- `options/options.c` — `prefetch-playlist*` option definitions and defaults.
- User-owned: `%APPDATA%\mpv\scripts\playlist-sort.lua` +
  `%APPDATA%\mpv\explorer-sort.ps1` (gate + per-open subprocess; the script's
  own failure path is a plain perf issue, not an mpv bug).

Note: mpv logged `playlist-next` as `args=[flags="weak"]` even for the bare IPC
command; when the playlist is incomplete these calls error immediately rather
than queueing. A coder should confirm whether `weak`-default semantics are
intended for IPC (`player/command.c`, `loadfile_async.c`) before treating the
rejection as a defect.

## 9. Proposed next experiments (discriminating)

1. Re-run the real arm with `playlist-sort` temporarily disabled (script-dir
   override, no user-file edits) to isolate the hook cost (~0.5-0.8 s/open).
2. Export the retained CPU.Verbose parent ETLs (`mpv-wpd-20260911`) with
   `-symbols` around their next-next-quit windows, or capture one CPU.Verbose
   trial per arm, to obtain READY/WAIT stacks for the target open and the
   aborted v2 open.
3. Five+ trials per arm with explicit cache state per input (verify each
   input's VFS presence via `vfs/stats`/rclone RC before the run) to separate
   cold-S3 from warm-cache skip latency.
4. Time `explorer-sort.ps1` standalone; fix its failure and re-measure.
5. Launch mpv at medium integrity (scheduled task) and compare phase timings.
6. Marker-instrumented `demux_open`/`stream_open` phase timing to attribute the
   840 ms first-open gap precisely.

## 10. Validation and remaining risks

- No fix was applied and no optimization is claimed; all numbers are raw
  measurements.
- The real-arm `batch-real.json` was overwritten by the Procmon pass and
  reconstructed from per-trial files; the accepted-attempt T4 values were
  transcribed from the pre-overwrite extract and are flagged in `summary.csv`.
- ETL sizes: real arm 4.30 GB, control arm 1.14 GB, planning probes 7.1 GB
  (retained externally, not in Git). Procmon PML 2.21 GB; original CSV 1.03 GB,
  filtered 364 MB.
- The elevated-vs-medium input-token difference and the cache-order confound
  are the main limitations of the arm comparison.
- No WPR session or Procmon process was left running (`wpr -status` clean;
  Procmon settings restored by the helper).

## 11. Artifacts

- External run root:
  `C:\Users\andre\PerfRuns\mpv-playlist-skip-20260911T090749482Z-da38e1520da444cca96c26acd325bc27\`
  - `traces\capture-0e2d39e5e6764bb8b4f87adc2b97c9f6.etl` (real arm, 4.30 GB)
  - `traces\capture-ad502a227d644e9ab0fd901439b771f6.etl` (control arm, 1.14 GB)
  - `traces\procmon-7208286fc6514ac087fb0fba7db64fb0.pml` (2.21 GB)
  - `exports\wpa-real-t1\`, `exports\wpa-control-t3\` (CPU precise/sampled,
    disk-usage tables with WPAExporter logs and `export-summary.json`)
  - `exports\procmon-filtered.csv` (mpv/rclone/mount paths), original CSV in
    `exports\procmon-*.csv`
  - `measurements\` harness, per-trial events/samples/rclone JSON, mpv logs,
    `summary.csv`, `phase-deltas-*.csv`, `procmon-summary.json`,
    `wpa-summary-*.json`, `preflight-*.json`, `selection*.json`
- Parent deep captures used for follow-up only:
  `C:\Users\andre\PerfRuns\mpv-wpd-20260911\...\traces\capture-27b08a25da7f4e81b77092c46603bff6.etl`
  (real, CPU.Verbose+FileIO.Verbose, 3.68 GB) and
  `capture-a091ae2dc1e04322825042b4a27aec4d.etl` (control, 3.6 GB).

Project package: `benchmarks\Run-20260911-165208-mpv-playlist-skip\` (this report,
manifest, environment, commands, artifacts, `measurements\summary.csv`).
