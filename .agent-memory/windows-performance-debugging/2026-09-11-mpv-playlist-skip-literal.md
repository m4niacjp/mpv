# 2026-09-11 — Literal single-shot playlist-skip replay after Fix 1

## Scenario

Real config `dist\mpv.exe` on a random top-level `I:\XXX\new2` file; T1 = first
`playback-restart`; at T1+5000 ms exactly one `playlist-next`, immediately one
more (no retry, no probe-and-retry); `quit` at the third distinct file's
`playback-restart` (`pos0+2`) or at `next2+30 s`. Enforced gates: 20 s poll until
no wpa/wpaexporter/xperf, `Global\MpvPerfLiveLane` mutex (held across preflight +
smoke + trials), 10 s system-load preflight with one 60 s recheck. Batch B
(corrected harness) = 2 trials; batch A = 2 trials retained with a
reply-capture defect.

## Outcome (VERIFIED unless noted)

- Batch B (primary): literal scenario works **2/2**. `next-1`/`next-2` replies
  `success`; `playlist-pos` 96→98 and 90→92; third file restart at
  **next2+694.7 / +290.6 ms**; `quit` sent +2.9/+3.7 ms after T4 (`success`);
  quit→exit 2120.8 / 979.0 ms; exit code 0.
- Readiness: `Autocreate playlist: 257 siblings.` at log **0.243 / 0.237 s**
  (wall ≈703/697 ms, at or before T1), so the T1+5 s action landed ~5.0 s after
  readiness. Four-trial spread: **0.237 / 0.243 / 3.05 / 25.406 s**.
- Batch A t1: splice 25.406 s → the T1+5 s next pair was a **no-op**
  (`playlist-count=1` at command time; no position/restart change). Exact reply
  text lost to the batch-A defect; failure mechanism matches strict-next source
  (`player/command.c:6204` `cmd_playlist_next_prev`, `:7580` `force=0`).
- Fix 1 structural result holds live: hook→`Playing:` 2–3 ms; the async
  `explorer-sort.ps1` still starts (0.168 s) and fails `status 2` at ~1.0 s,
  off the open path.
- INCONCLUSIVE: cause of the 25.4 s splice outlier (two `wpaexporter` + `xperf`
  had just exited; user's own mpv concurrently reading the mount); attribution
  of the 2120.8 ms quit→exit.

## Evidence and artifacts

- Project file:
  `benchmarks\Run-20260911-165208-mpv-playlist-skip\live-literal-scenario.md`
- Primary run:
  `C:\Users\andre\PerfRuns\mpv-playlist-skip-literal-rerun-20260911T110025Z-c951e185\`
- Retained defective-instrumentation run:
  `C:\Users\andre\PerfRuns\mpv-playlist-skip-literal-20260911T104800Z-7c1e2a4f\`
- Harness hashes per run in `measurements\harness-versions.json` (fixed wrapper
  SHA-256 `550DEB99B181…`; pre-fix `09566200227F…`).

## Caveats / conflicts

- Batch A wrapper defect: replies stored in an `OrderedDictionary` hit the IList
  integer indexer (`$replies[9001]`), so all IPC replies became
  `ipc-parse-error` and t0's T4 target was set too late (deadline quit instead of
  quit-at-T4). Fixed in batch B with a hashtable plus a target preset from the
  observed `playlist-pos` at the send instant.
- `core/stats`/`vfs/stats` are mount-global; the user's own mpv session inflated
  byte/transfer deltas (not used for attribution). All 257 top-level files were
  fully present in the VFS disk cache; no purge.
- Elevated (High IL) only; n=2 corrected trials.
- The durable `Invoke-MpvSkipBatch.ps1` cannot express the literal test
  (`-MaxNextAttempts 1` throws on a rejected next and skips T4/deadline/quit).

## Next discriminating measurement

5+ real-config trials with per-trial metadata-cache state and only the
`257 siblings` timestamp, to bound the splice distribution and its tail; a
CPU.Verbose trace of the autocreate worker for the long tail (mpv ships no PDBs
here).
