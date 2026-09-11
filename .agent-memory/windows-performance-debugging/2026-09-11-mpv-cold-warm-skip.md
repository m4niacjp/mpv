# 2026-09-11 — Cold/warm VFS cache playlist-skip test (real config)

## Scenario

Real config, random `I:\XXX\new2` inputs, T1 = first playback-restart, next at
T1+5000 ms, immediate second next, quit at position+2 playback-restart.
5 uniform random draws + 3 supplementary draws from the census cold pool.
Per-input VFS cache class recorded pre-trial (cache file size vs remote size)
and confirmed with rclone `core/stats` windows. Mutex `Global\MpvPerfLiveLane`
held for the whole batch; no `wpaexporter`/`wpa`/`xperf` ran during trials.

## Outcome (VERIFIED unless noted)

- Start census: 245/257 `new2` files `full` (warm), 12 `absent` (cold pool
  ranks 35, 90, 117, 147, 152, 182, 190, 202, 203, 254, 256, 257; ~5.6 GB).
- Warm inputs: both nexts accepted on first attempt; sequence 8.4-11.3 s;
  accepted next->T4 54-1683 ms.
- Cold inputs did **not** slow T1 (416-1009 ms vs 403-1307 ms warm) and the
  post-readiness skip was small (233 ms / 849 ms). First-frame latency does not
  track cache state.
- The dominant cost is `autocreate` playlist expansion under concurrent mount
  fetch: `Autocreate playlist: 257 siblings` at ~0.2 s warm/idle but 20.7 s,
  25.0 s, and >30 s in the three heavy-fetch trials; the T1+5 s nexts were
  rejected 36/46/60 times before the playlist existed. One census-`full` input
  behaved the same way (677 MB fetched during its trial).
- `quit->exit` 1.36-3.10 s, no split by cache class.
- **INCONCLUSIVE:** exact cause of the autocreate stall (rclone/WinFsp metadata
  queueing is the hypothesis; no ETW/Procmon in this lane); whether the t4
  `full` entry was stale (remote mtimes through the mount are synthetic =
  mount start time for every file, so fingerprint mismatch is unprovable).

## Evidence and artifacts

- Deliverable: `benchmarks\Run-20260911-165208-mpv-playlist-skip\live-cold-warm.md`
- External run: `C:\Users\andre\PerfRuns\mpv-playlist-skip-coldwarm-20260911T1050Z-7c1e5b3a\`
  (`measurements\coldwarm-summary.json|.csv`, per-trial
  `batch/events/rclone/samples-real-tN`, mpv logs, preflights, gate/guard logs,
  scripts).

## Caveats

- User's own mpv streamed 6-22 MB/s through the same rclone instance during
  most trials (recorded); no cache purge; mpv ran elevated (High IL).
- Harness `-Arm` is limited to `real|control`; per-trial batch JSON was copied
  to `batch-real-tN.json` to avoid overwrite.

## Next discriminating measurements

1. Procmon or ETW FileIO on `I:\XXX\new2` during a cold input, to decompose the
   20-30 s autocreate delay (directory/stat durations, rclone/WinFsp queueing).
2. A/B with prefetch disabled after playlist readiness, to separate prefetch
   from target open in the post-readiness fetch burst.
3. Repeat the warm series with the user stream quiesced for a clean baseline;
   medium-IL launch comparison.
