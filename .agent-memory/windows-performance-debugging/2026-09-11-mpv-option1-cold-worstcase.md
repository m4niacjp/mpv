# 2026-09-11 — Option 1 cold worst-case: heavy-fetch readiness + Option-2 decision

## Scenario

Post-Option-1 binary (`587027333113EF9C3EC13A0E619A131CAC3243144CCD35BC2174AC73BEC2A302`,
HEAD `2b0f9f46ca`), real config on the rclone `wcrypt:` WinFsp mount. Gated
live-lane driver (gate → `Global\MpvPerfLiveLane` → preflight → Procmon
Duration/TID pass t0 → 2 plain trials), 4 batches 18:56–20:21 local. Inputs:
rank-254 (2 trials; 17.8 % cached), rank-182 (3 trials, 4.4 %), rank-152
(3 trials, 0.53 %; batch 3 aborted at preflight (background paging storm) and
was retried as batch 4). 8 measured trials total.

## Outcome (VERIFIED unless noted)

- **(6) Pre-fix heavy-fetch readiness variability is gone.** Readiness
  (`Opening done` → `Autocreate playlist: 257 siblings.`) = 0.037–0.194 s
  (median ~0.06), first-attempt next acceptance 8/8; pre-fix was 20.7 / 25.0 /
  never >30 s with 36/46/60 rejected nexts. Decisive trial (rank-152, 0.53 %
  cached) had **active backend fetch during the scan** (+3.0 MB inside the
  0.23 s window; +113.3 MB pre-next; coverage 0.53→38.8 %), worker scan
  0.162 s, max single attr open **0.677 ms**.
- **(7) Option 2 (d_type bypass of per-entry stat) NOT needed — the "still
  needed" hypothesis is CONTRADICTED; low priority.** The 256 per-entry stats
  cost ≤0.68 ms (rank-152) / ≤2.26 ms (rank-182) each under active fetch, no
  sibling/listing attr open >100 ms; removing them would save ≤0.17 s of scan.
- **(7c, new) Residual multi-second stat stalls still exist off the built-in
  path.** `%APPDATA%\mpv\scripts\playlist-sort.lua`'s Explorer-fallback pass
  (`assign_stat_key` → `utils.file_info` per entry) stats the playing file
  while it downloads: **4.79 s** attr open (rank-152; TID 3288) and 4.75 s
  (rank-182; TID 8280), plus 151/489/522 ms stalls on downloading
  target/prefetch siblings; it delays `prefetch-playlist` restore ~5 s.
  Option 1 and Option 2 both leave this untouched.
- **Census cache classes are invalid for WinFsp-mapped names (durable rule).**
  WinFsp exposes invalid-on-Windows chars as U+F0xx (`?`→U+F03F, `"`→U+F022,
  `:`→U+F03A); rclone cache/vfsMeta use fullwidth U+FFxx. The census
  basename+size rule mislabels all 12 such files as `absent`, and content-file
  size is pre-allocated to full remote size, so it is not a coverage signal.
  Authoritative = vfsMeta `Rs` read spans (`Get-VfsCacheState.ps1` maps the
  names). Sizes at lane start: rank-254 17.8 %, rank-182 4.4 %, rank-152 0.53 %.
- Batch 1's Procmon pass failed because the hand-made run dir lacked
  `manifest.json` (skill helper requires `schemaVersion: 1`); batch 3 aborted by
  preflight policy (pages/s 3.3k→6.8k, attributed to `chatgpt` (10 PIDs),
  `svchost`, `MsMpEng` 5708, `explorer`; no trial ran). Both retained.

## Evidence and artifacts

- Deliverable:
  `benchmarks\Run-20260911-165208-mpv-playlist-skip\option1-cold-worstcase.md`
  + `measurements\option1-cold-worstcase-trials.csv` (8 trials).
- External runs (`C:\Users\andre\PerfRuns\`):
  - batch 2 `mpv-playlist-option1-coldworst2-20260911T120919Z-e2e65fc7`
    (PML 559.7 MB; scan 0.171 s; include stat 4745.28 ms TID 8280)
  - batch 4 `mpv-playlist-option1-coldworst4-20260911T131724Z-c9ccd0c8`
    (PML 1.07 GB; scan 0.162 s / 0.677 ms; include stat 4789.97 ms TID 3288)
  - batch 1 `…-coldworst-20260911T115609Z-ed0524be` (rank-254, no Procmon);
    batch 3 `…-coldworst3-…-afaabce0` (preflight abort).
- Procmon analysis tools added:
  `scripts\Analyze-WorstCase.ps1` (target-classified >100 ms opens, worker
  window, include read offsets), `scripts\Analyze-StatPasses.ps1` (stat passes
  per TID/time), `scripts\Get-VfsCacheState.ps1`, `scripts\Get-FetchWindow.ps1`.

## Caveats

- The exact pre-fix multi-client load (user stream 6–22 MB/s + large cold file)
  was not recreated; only batch 4 t0 had confirmed fetch overlapping the scan;
  `core/stats` deltas remain upper bounds while other clients are active.
- The Lua path's user-visible skip cost was not isolated (post-readiness).
- Elevated (High IL) mpv only; no cache purge; inputs are warmer now.

## Next discriminating measurements

1. Re-run batch 4's condition with a second simultaneous reader on the mount.
2. Disable `playlist-sort.lua` (or open `I:\XXX\new2` in Explorer so the
   Explorer sort succeeds and no fallback stat pass runs) and measure prefetch
   restore + `accepted next→T4`; route the script/config change to
   `mpv-lua-scripter`.
3. Re-evaluate Option 2 only in a config that prefetches next entries before
   the scan (none observed today).
