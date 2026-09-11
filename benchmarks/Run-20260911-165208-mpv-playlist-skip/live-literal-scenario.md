# Live literal playlist-skip replay after Fix 1 — single-shot, no retry

Boundary: launch `dist\mpv.exe` (real user config) on one random top-level
`I:\XXX\new2` file; T1 = first `playback-restart`; at **T1+5000 ms send exactly
one `playlist-next`, immediately send exactly one more** (no retry, no
probe-and-retry); `quit` at the third distinct file's `playback-restart`
(playlist position `pos0+2`) or at `next2+30 s`. Measured live on 2026-09-11,
after Fix 1 (`playlist-sort.lua` async Explorer lookup).

Two live batches were run under the named-mutex gate (no analysis tools running,
system-load preflight passed):

| batch | harness | trials | role |
| --- | --- | --- | --- |
| **B** `mpv-playlist-skip-literal-rerun-20260911T110025Z-c951e185` | wrapper `550DEB99…` (fixed) | t0, t1 | **primary** |
| A `mpv-playlist-skip-literal-20260911T104800Z-7c1e2a4f` | wrapper `09566200…` | t0, t1 | physical outcomes retained; IPC reply capture defective (see §6) |

Raw artifacts are in the external run directories (§7); the durable
`Invoke-MpvSkipBatch.ps1` cannot express this test (see §6).

## 1. Verdict

- **VERIFIED — the literal scenario works now in both corrected trials.**
  Batch B t0/t1: `playlist-next` #1 and #2 each replied `success` on the first
  (only) attempt; `playlist-pos` moved `96→98` / `90→92`; the third distinct
  file's `playback-restart` occurred at **next2 + 694.7 ms / 290.6 ms**; `quit`
  was sent 2.9/3.7 ms after T4 and replied `success`; exit code 0.
- **VERIFIED — readiness was not the limiter in batch B.** `Autocreate
  playlist: 257 siblings.` was logged at **0.243 s / 0.237 s** (wall ≈ 703/697 ms,
  i.e. at/just before T1), so the T1+5 s action landed ~5.0 s *after* the
  playlist became usable. Both nexts were accepted immediately.
- **VERIFIED (4/4 trials, high variance) — readiness is the remaining risk.**
  Observed splice times across all four real trials: **0.237 s, 0.243 s, 3.05 s,
  25.406 s**. When it exceeds T1+5 s, the literal next pair is a no-op and the
  user-visible skip fails (batch A t1; §3).
- **VERIFIED (source) — the failure mode is strict-next semantics.** Bare
  `playlist-next` is non-force: `player/command.c:6204` `cmd_playlist_next_prev`
  sets `cmd->success = false` when `mp_next_file()` returns no entry (`force =
  args[0].v.i` = 0, `player/command.c:7580`). With `playlist-count = 1` at command
  time there is no next entry, so mpv replies an error and does nothing.
- **VERIFIED — Fix 1 keeps the Explorer lookup off the open path.** In both
  batch B trials the target file's `playlist_sort/on_before_start_file` hook and
  `Playing:` line are 2 ms apart t0 (5.923→5.925 s) and ~3 ms t1 (5.269 s), while
  the async `powershell.exe … explorer-sort.ps1` lookup still costs ~0.6–0.8 s
  (started 0.174/0.168 s, failed `status 2` at 1.030/0.975 s) off the critical
  path. No hook was observed waiting on the subprocess.
- **INCONCLUSIVE — cause of the 25.4 s splice outlier (batch A t1).** The trial
  launched ~1.5 s after two `wpaexporter` processes and an `xperf` process
  exited (gate observations), and the user's own mpv session was concurrently
  active; no thread-level evidence separates those from mount/metadata variance.
- **INCONCLUSIVE — t0's 2120.8 ms `quit→exit`** (vs 979.0 ms in t1). It is
  measured, but attribution to teardown of the just-opened file + RTX VPP filter
  chain is not proven without stacks.

## 2. Batch B — per-trial results (primary)

Aliases only; raw names/paths are in the external run. Both inputs were fully
present in the rclone VFS disk cache (exact path, byte-exact size) and no cache
was purged.

| | t0 | t1 |
| --- | --- | --- |
| input | rank-97/257, 269,864,776 B | rank-91/257, 137,461,323 B |
| launch → T1 | 726.4 ms | 700.2 ms |
| T1 → next-1 (target 5000) | 5034.0 ms | 5014.6 ms |
| next-1 → next-2 | 3.4 ms | 3.0 ms |
| "257 siblings" (log) | 0.243 s (≈703 ms wall) | 0.237 s (≈697 ms wall) |
| pre-action pos/count (probed) | 96 / 257 | 90 / 257 |
| post-action pos/count (probed) | 98 / 257 | 92 / 257 |
| next-1 reply | `success` | `success` |
| next-2 reply | `success` | `success` |
| third file restart (T4) | 6458.5 ms, pos 98 | 6008.3 ms, pos 92 |
| **next2 → T4** | **694.7 ms** | **290.6 ms** |
| T4 detection | observed-pos | observed-pos |
| quit (after T4) | +2.9 ms, reply `success` | +3.7 ms, reply `success` |
| quit → exit | 2120.8 ms | 979.0 ms |
| exit code | 0 | 0 |
| skip worked | **YES (2 positions, third file playing)** | **YES** |

Per-trial timeline detail (`measurements\result-literal-tN.json`,
`timeline-literal-tN.json`, `mpv-literal-tN.log`):

- t0: spawn → T1 726.4 ms; 257-sibling splice logged 0.243 s; async Explorer
  lookup failed `status 2` at 1.030 s; T1+5 s burst at 5757.8/5759.3/5760.4/
  5763.8 ms (pos probe, count probe, next-1, next-2); replies `success` at
  5781.2/5781.6 ms; post probes `pos=98,count=257` at 5796.7/5798.7 ms; target
  `Playing:` 5.925 s; `end-file` reason `stop` for the aborted intermediate
  entry at 6403.3 ms; T4 6458.5 ms; `quit` 6461.7 ms; `Exiting… (Quit)` at
  8.001 s; exit 8582.5 ms.
- t1: spawn → T1 700.2 ms; splice logged 0.237 s; Explorer lookup failed at
  0.975 s; T1+5 s burst at 5712.4/5713.9/5714.8/5717.8 ms; replies `success` at
  5728.9/5729.5 ms; post probes `pos=92,count=257` at 5745.5/5746.6 ms; target
  `Playing:` 5.269 s; `end-file` `stop` for the aborted intermediate entry at
  5744.1 ms; T4 6008.3 ms; `quit` 6011.5 ms; `Exiting… (Quit)` 6.426 s; exit
  6990.5 ms.

Both trials issued **exactly two** `playlist-next` commands (log
`Run command: playlist-next` count = 2/2; no retries, no extra probes beyond the
four observation `get_property` reads). The intermediate `pos0+1` entry never
reached `start-file` (startFileCount = 2: initial + final), consistent with the
immediate second next aborting its open.

Mechanics smoke (`t99`, local 3-file dir, `--no-config
--autocreate-playlist=filter`, not one of the scenario trials): both nexts
`success`, T4 at next2+33.6 ms, quit→exit 50.1 ms, 10/10 IPC replies captured —
the fixed wrapper end-to-end path is validated.

## 3. Batch A — retained physical outcomes (harness reply capture defective)

| | A/t0 | A/t1 |
| --- | --- | --- |
| input | rank-34/257, 84.7 MB | rank-235/257, 121.8 MB |
| launch → T1 | 1879.5 ms | 771.1 ms |
| T1 → next-1 | 5025.5 ms | 5010.9 ms |
| "257 siblings" (log) | 3.050 s (≈3455 ms wall, T1+1.58 s) | **25.406 s (≈25 922 ms wall, T1+25.15 s)** |
| nexts accepted | yes (pos 33→35; third file `Playing:` 6.517 s) | **no (pos stayed 0; no `Playing:`, no restart)** |
| third file restart | 8054.5 ms = next2+1147.4 ms | none |
| quit / exit | deadline quit at 36.9 s / exit 37.08 s | deadline quit at 35.8 s / exit 36.02 s |
| quit → exit | 153.4 ms | 233.3 ms |

In A/t1 the playlist count was 1 when the two nexts were issued, and the splice
completed 20.1 s later; nothing retried the nexts (by design), so the
user-visible outcome was **no skip at all**. The exact reply strings were lost
to the batch-A harness defect (§6); the no-op is VERIFIED from position, restart,
`Playing:` and `end-file` evidence, and the strict-next source path (§1).

## 4. Where the remaining readiness delay is

- The dominant residual is the **core autocreate splice** (`Autocreate playlist:
  257 siblings.`), not the playlist-sort hook and not the Explorer lookup:
  splice 0.24 s (batch B) vs 3.05 s and 25.41 s (batch A) for the same 257-entry
  directory. The output line appears when the core worker finishes splicing; the
  script's reorder/prefetch-restore happened later without blocking playback
  (batch B t0 restore at 5.925 s on end-file; t1 at 4.079 s on order
  finalization).
- When the splice finishes by T1, the literal action is safe (batch B) — even a
  3.05 s splice is safe (batch A t0, ready 3.4 s before the action). The risky
  case is the long tail (25.4 s observed).
- The post-accept skip cost is small and mount/teardown-bound: next2→T4
  290.6–694.7 ms (batch B) and 1147.4 ms (batch A t0), with the aborted
  `pos0+1` entry's `end-file … stop` 55.2 ms (t0) and 264.3 ms (t1) before the
  target's restart.

## 5. Gates, preflight, environment

- **Gate 1 (no analysis tools):** batch B — clear at every check. Batch A —
  waited 20 s for `wpaexporter:49880`; between trials waited 2 m 20 s while two
  `wpaexporter` + `xperf` ran. No tool was killed.
- **Gate 2 (mutex `Global\MpvPerfLiveLane`):** acquired in 2.6/2.7 ms, not
  abandoned; held across preflight + smoke + both trials; released in `finally`.
- **Gate 3 (preflight), batch B:** CPU utility avg 25.8% (max 35.1%), disk busy
  1.4%, available RAM min 73.8 GB, paging 0.28%, network peak 30.9 MB/s, GPU
  decode/3D ≤14.4% (user's own mpv), top CPU SearchIndexer 3.3% / MsMpEng 2.9%.
  All under the scenario thresholds → proceed. Batch A preflight: CPU 4.7%,
  RAM 75.0 GB, paging 0.28% → proceed. Both `preflight-*.json` retained.
- **Binary:** `dist\mpv.exe`, `v0.41.0-947-gd37b8c1a7-dirty`, build 2026-09-11,
  SHA-256 `777FB94487DD…`; PowerShell 7.6.6; rclone `v1.76.0-beta.10339…`;
  elevated (High IL), so the medium-IL case remains unmeasured.
- **User scripts (Fix 1 in force):** `playlist-sort.lua` SHA-256
  `845471B3D7…`, `explorer-sort.ps1` `2E02228966…` (match the fix record).
- **VFS cache:** `diskCache` 62.8–65.1 GB during the session, 12 836–12 838
  files; every top-level `new2` file (257/257) present in
  `D:\rclone-wasabi-cache\vfs\wcrypt\XXX\new2`, including both batch-B inputs
  (exact name path, byte-exact size). No purge, no `vfs/forget`.
- **Concurrent activity caveat:** an earlier user mpv session (PID 48124) was
  observed on the box before batch A; batch B's preflight showed the user's mpv
  (PID 59796) actively decoding (up to 14.4% GPU) from the same rclone mount.
  rclone `core/stats` is mount-global, so the byte/transfer deltas in
  `rclone-literal-*.json` include other sessions/background work and are **not**
  attributable to the trial; only per-file cache presence/size is used.

## 6. Harness notes (why A is not the primary evidence)

- The durable `Invoke-MpvSkipBatch.ps1` can send a single pair with
  `-MaxNextAttempts 1`, but on any rejected next it throws
  `All 1 playlist-next attempts were rejected` and then skips the T4/deadline
  and `quit` phases, so it cannot capture the literal failure outcome. A
  purpose-built single-shot wrapper was used instead (documented deviation).
- Batch A defect: replies were stored in an `OrderedDictionary`; `$replies[int]`
  resolved to its IList integer indexer, so all 11 replies per trial raised
  `Specified argument was out of the range of valid values (Parameter 'index')`
  and were dropped. Physical events were unaffected. Batch A t0 therefore also
  failed to set the T4 target before the target restart and quit at the 30 s
  deadline instead of at T4.
- Batch B fix (wrapper hash `550DEB99B181…` vs A `09566200227F…`): replies use a
  hashtable, and the T4 target is preset from the observed `playlist-pos` at the
  send instant so detection no longer depends on reply timing. Wrapper,
  analyzer and orchestrator copies and their hashes are in each run's
  `measurements\harness-versions.json`.

## 7. Raw artifacts

- Batch B (primary): `C:\Users\andre\PerfRuns\mpv-playlist-skip-literal-rerun-20260911T110025Z-c951e185\`
  - `batch-literal.json`, `environment.json`, `preflight-1.json`
  - `measurements\result-literal-t{0,1}.json` (replies, positions, T4, exit),
    `timeline-literal-t{0,1}.json`, `events-literal-t{0,1}.json`,
    `samples-literal-t{0,1}.json`, `rclone-literal-t{0,1}.json`,
    `readiness-t{0,1}.json`, `mpv-literal-t{0,1}.log`
  - smoke: `result-literal-t99.json`, `readiness-smoke-t99.json`
- Batch A (retained): `C:\Users\andre\PerfRuns\mpv-playlist-skip-literal-20260911T104800Z-7c1e2a4f\`
  (same layout; `harness-hashes-batchA-prefix.json` records the pre-fix hashes)
- Project package: this file, plus the earlier `report.md`,
  `fix-playlist-sort.md` in `benchmarks\Run-20260911-165208-mpv-playlist-skip\`.

## 8. Caveats and next discriminating measurements

- n = 2 corrected trials; the 4-trial readiness spread (0.24–25.4 s) is the
  finding to test further. Next: 5+ real-config trials with per-trial
  metadata-cache state and a repeated-`257 siblings` timestamp, to bound the
  splice distribution and its tail.
- The 25.4 s splice outlier needs a CPU.Verbose/FileIO.Verbose trace of the
  autocreate worker (mpv has no PDBs here; symbol-less thread stacks were the
  stated gap in the prior session).
- Medium-IL launch remains unmeasured; all runs were elevated.
- Verdict scope: this replay covers the literal user sequence only; it does not
  re-test `prefetch-playlist` tuning or the `explorer-sort.ps1` failure itself
  (`status 2`, folder not open in Explorer, still logged every session).
