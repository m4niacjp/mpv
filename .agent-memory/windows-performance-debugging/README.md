# Windows performance-debugging memories

This directory is the durable startup memory for future Windows performance
investigations in this MPV checkout.

## Startup procedure

1. Read this file as the index. Load only the runbook, topical summaries, dated
   session notes, and external artifacts relevant to the current question.
2. Treat remembered tool versions, paths, configuration, and timings as leads,
   not current truth. Recheck them with the live checkout, runtime, and machine.
3. Inspect `git status --short --branch` before changing the repository. Preserve
   unrelated work and keep ETL/PML/large CSV artifacts outside Git.
4. Before each performance batch, measure background CPU, memory/paging,
   disk/volume, network, and relevant GPU activity over a short interval. If
   unrelated heavy activity is present, wait once for up to 60 seconds and
   recheck. If it remains, stop before testing, identify the processes with
   read-only evidence, inform the user, and wait for close-or-abort direction.
5. Define the operation, input, start/end boundary, primary metric, cache state,
   process tree, and worker count before collecting evidence.
6. Use the smallest measurement that can discriminate the current hypothesis;
   escalate to WPR/WPA/Procmon only when the missing evidence requires it.
7. Record material conclusions as exactly `VERIFIED`, `CONTRADICTED`, or
   `INCONCLUSIVE`, with the command, artifact path, and evidence scope.
8. After the run, reconcile the index and affected guidance. Add one concise dated
   memory only for novel evidence or a meaningful decision.

## Progressive discovery

1. Always start with this index.
2. Read `benchmark-runbook.md` only when designing, running, or comparing a
   benchmark.
3. Read only the newest relevant dated note or focused topical summary first.
   Load older notes only when provenance, regression history, or a conflict needs
   them.
4. Follow links to external reports, ETL/PML, logs, and detailed measurements only
   when the current decision depends on that evidence.
5. Never preload the entire memory directory.

## Memory hygiene

- Live evidence overrides stale memory. If they conflict, record the conflict in
  the new session note.
- Keep secrets, credentials, tokens, and unnecessarily identifying media names
  out of memory. Store paths only when they are needed to reproduce the test.
- Keep raw traces and large logs in the external performance-run directory, not
  here. Memories should point to those artifacts rather than copy them.
- Do not claim a performance improvement from one favorable run. Report counts,
  ranges/medians when available, cache conditions, and observer limitations.
- Keep notes precise: scenario, outcome, evidence, exact command or artifact,
  caveat, and next measurement. Avoid narrative repetition and copied logs.
- Never kill, suspend, reprioritize, or reconfigure unrelated background
  processes to obtain a clean benchmark without explicit user authorization.

## Maintenance and compaction

- Keep this README as a scannable index and current-rule summary. Update links and
  mark superseded guidance whenever new evidence changes a remembered rule.
- Refactor when this README exceeds roughly 200 lines, active dated notes exceed
  20, or duplicated/superseded guidance makes discovery unclear.
- Consolidate repeated durable knowledge into focused topical files. Move
  superseded dated notes to `archive\YYYY`, preserve unique evidence and
  provenance, and replace detailed index text with short links.
- Never discard VERIFIED/CONTRADICTED/INCONCLUSIVE status, artifact locations, or
  the evidence needed to understand why a rule changed.

## Project report packages

Each material investigation ends with a unique project-relative directory:

`benchmarks\Run-YYYYMMDD-HHMMSS-<scenario-slug>\`

The package contains `report.md`, `manifest.json`, `environment.json`,
`commands.md`, structured measurement summaries when available, and
`artifacts.md` linking to externally retained raw traces and large logs. The
report must support source-level follow-up by a coder and must be linked from the
relevant dated memory.

## Files

- `benchmark-runbook.md` — repeatable MPV/Windows benchmark workflow and known
  traps.
- `2026-09-11-mpv-first-session.md` — findings and retained artifacts from the
  first `I:\XXX` playback investigation; coder report at
  `benchmarks\Run-20260911-143730-mpv-directory-playback\report.md`.
- `2026-09-11-mpv-playlist-skip.md` — elevated IPC-driven rapid playlist-skip
  investigation (real config vs `--no-config`), phase latencies, prefetch gating,
  and retained ETL/PML artifacts; coder report at
  `benchmarks\Run-20260911-165208-mpv-playlist-skip\report.md`.
- `2026-09-11-mpv-cold-warm-skip.md` — cold/warm VFS cache split of the same
  skip scenario; autocreate readiness is the dominant cost under cold fetches;
  deliverable at
  `benchmarks\Run-20260911-165208-mpv-playlist-skip\live-cold-warm.md`.
- `2026-09-11-mpv-playlist-skip-literal.md` — gated literal single-shot replay
  after Fix 1: corrected batch works 2/2 (readiness 0.24 s, next2→T4 291/695 ms),
  retained reply-capture-defective batch, splice spread 0.24–25.4 s; coder file
  at `benchmarks\Run-20260911-165208-mpv-playlist-skip\live-literal-scenario.md`.
- `2026-09-11-mpv-option1-live-validation.md` — Option 1 (`2b0f9f46ca`)
  validated on the real mount: worker TID has zero include-file attribute opens
  while the file streams; 256 entry stats max 3.31 ms; readiness 0.054–0.334 s,
  first-try nexts 4/4; cold-fetch 20–30 s stalls not reproduced (n=2,
  INCONCLUSIVE); deliverable at
  `benchmarks\Run-20260911-165208-mpv-playlist-skip\option1-live-validation.md`.
- `2026-09-11-mpv-option1-cold-worstcase.md` — closed the two INCONCLUSIVE
  items: heavy-fetch readiness gone (8 trials, 0.037–0.194 s, first-try 8/8;
  decisive trial with +3.0 MB fetch inside the 0.162 s scan); Option 2
  contradicted/not needed; new residual = `playlist-sort.lua` fallback
  `utils.file_info` pass stalling 4.7–4.8 s on the downloading playing file;
  durable warning: census sizes/`absent` classes are invalid for WinFsp U+F0xx
  names, use vfsMeta `Rs`. Deliverable at
  `benchmarks\Run-20260911-165208-mpv-playlist-skip\option1-cold-worstcase.md`.
- `2026-09-12-mpv-playlist-sort-prefetch-stall.md` — verified switch-stall
  mechanism (identity `playlist-reorder` kick during the file-start transition
  → wrong-URL prefetch → main open joins the opener; gate not released in the
  failed-Explorer path), A/B numbers, and the recommended script/core fix path;
  mechanism resolved as a blocking `utils.file_info` stat, not a branch.
  Fresh-session brief at `benchmarks\vfs-bench\handoff.md`.
- `2026-09-12-mpv-playlist-sort-fix-applied.md` — OQ#1 resolution (Procmon
  10.2 s `stat` of the playing file), the applied script edits #1/#2/#2b
  (final sha `ADDBFB64…`), and the validation matrix: cold `next→frame2`
  1.06/0.40 s vs no-script 1.13/2.48 s, 0 wrong-URL aborts, prefetchedAtNext=3;
  deliverable `benchmarks\Run-20260912-041416-mpv-vfs-cold-warm\
  fix-validation.md`.
- `2026-09-12-mpv-prefetch-core-guard.md` — core guard #3
  (`prefetch_next` handover condition broadened) with the
  `test_prefetch_hook_command` before/after proof; `dist\mpv.exe` refreshed to
  `7C30234D…` (old `58702733…` kept as `dist\mpv_bck.exe`); MSYS2 `PWD` /
  `meson test` trap; win32-shell equal-key tie-break note (#4).
- `2026-09-12-mpv-vfs-bench-corpus-cache-control.md` — VFS cold/warm corpus
  seed and cache-control fixes: parallel RC upload ~102 MB/s vs ~30 MB/s
  serial; `vfs/refresh` root-first + string `recursive`; vfsMeta `Rs` 60 s
  flush lag (immediate warm coverage checks are false negatives); live VFS
  options cannot be changed via `options/set` (remount required); concurrent
  handle reads are the no-remount fill lever. Harness `benchmarks\vfs-bench\`,
  bench data in `C:\PerfBench`. First full cold/warm matrix 12/12 ok: warm
  removes the next-file fetch penalty (config 3.38→0.05 s; noconfig
  1.77→0.07 s), Procmon inflates real-config start, prefetch visible only with
  the real config; deliverable at
  `benchmarks\Run-20260912-041416-mpv-vfs-cold-warm\report.md`.
  Follow-up A/B (24 trials, n=2 plains): `playlist-sort.lua`'s switch-time
  `playlist-reorder` starts a wrong-URL prefetch whose abort the main open
  joins (2 ms–2.07 s; mpv source-verified) — with the script absent,
  prefetch works (`prefetchedAtNext=3`, `Using prefetched URL`) and the switch
  bottleneck shifts to demuxer teardown; verified tie-break fix applied
  (post-fix sha `D6A59AC2…`) after the matrix.
