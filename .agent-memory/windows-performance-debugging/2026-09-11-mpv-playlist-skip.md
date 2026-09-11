# 2026-09-11 — MPV rapid playlist-skip on the rclone/Wasabi mount

## Scenario

Elevated (High IL) harness drove `dist\mpv.exe` over IPC on random top-level
`I:\XXX\new2` files (257 `.mkv`, 98.4 GB): T1 = first `playback-restart`, next
at T1+5000 ms, immediately a second next, quit at the third distinct file's
playback restart. Arms: real user config vs `--no-config
--autocreate-playlist=filter`. Three trials per arm + one Procmon extra trial.

## Outcome (all VERIFIED unless noted)

- **The literal T1+5 s next is a no-op in 2/3 real trials.** At that moment
  `playlist-pos` is still 0 (autocreate scan + `playlist-sort.lua` not done);
  `playlist-next` replies `error running command`. The playlist becomes usable
  ~7-8 s after launch. Retries (5 and 7 attempts) were needed to complete the
  sequence; control arm succeeded first try 3/3.
- Successful next -> third-file playback: real **0.81 / 4.17 / 3.24 s** vs
  control **120 / 484 / 86 ms** (control partly VFS-cache-warm, so ratio is an
  upper bound).
- Real-arm terms: `playlist-sort.lua`'s `on_before_start_file` hook runs
  `explorer-sort.ps1` as `powershell.exe` for **0.5-0.8 s per gated open** and
  fails (status 1) before falling back; the immediate second next aborts the
  skipped entry's open at real cost (Procmon t6: v2 `CreateFile` 3.09 s +
  `CloseFile` 2.13 s + `ReadFile` 1.25 s); cold WinFsp->rclone->Wasabi reads are
  0.38-0.76 s each (all long ops on `\\server\RcloneWcrypt\...`).
- Prefetch is **gated off** by `playlist-sort.lua` until the sort completes, so
  it does not compete during the 5 s window; after restore it overlaps the
  target open and one prefetch open was aborted/re-issued in t1.
- No rclone errors/retries, no cache-pause stalls; two startup WASAPI underruns
  (~1.37 s) in real t0/t1 only. `quit->exit` real 0.69-1.10 s vs control
  0.06-0.35 s; Procmon trial 3.51 s (observer).
- **INCONCLUSIVE:** thread READY/WAIT stacks (CPU.Light captures have no stacks,
  no mpv PDBs), GPU present stalls, medium-IL behavior (mpv ran elevated).

## Evidence and artifacts

- Project package:
  `benchmarks\Run-20260911-165208-mpv-playlist-skip\report.md`
- External run (ETLs, PML/CSV, WPA exports, harness, per-trial JSON, logs):
  `C:\Users\andre\PerfRuns\mpv-playlist-skip-20260911T090749482Z-da38e1520da444cca96c26acd325bc27\`
- Durable harness: `~\.codex\skills\windows-performance-debugging\scripts\Invoke-MpvSkipBatch.ps1`
- Parent deep ETLs (CPU.Verbose+FileIO.Verbose, rapid next-next-quit, 3.68/3.60 GB)
  remain the best source for the missing stack evidence:
  `C:\Users\andre\PerfRuns\mpv-wpd-20260911\...\traces\capture-27b08a25....etl`
  (real) and `capture-a091ae2dc1e04322825042b4a27aec4d.etl` (control).

## Caveats / conflicts

- `batch-real.json` in the external run was overwritten by the Procmon pass
  (same arm name); real t0-t2 were reconstructed from per-trial event files.
  Use distinct arm names for observer passes in future work.
- Control arm ran second, after real-arm prefetch warmed many siblings in the
  VFS cache: its 0-2 backend transfers per window are not a clean cold-cache
  comparison.
- rclone VFS cache grew 33.6 -> ~39 GB during the session; no purge performed.
- mpv ran elevated (High IL); normal user launch is medium IL and unmeasured.
- `explorer-sort.ps1` failure (status 1) and the per-open powershell subprocess
  are user-script issues, not demonstrated mpv core defects.

## Next discriminating measurements

1. Real arm with `playlist-sort` disabled (script-dir override) to isolate the
   hook cost; time `explorer-sort.ps1` standalone and fix its failure.
2. Export the retained CPU.Verbose parent ETLs with symbols (or capture one
   CPU.Verbose trial per arm) for READY/WAIT stacks on the target and aborted
   opens.
3. Five+ trials per arm with explicit per-input VFS cache state to separate
   cold-S3 from warm-cache skip latency.
4. Medium-IL launch comparison; GPU present-stall trace if a visible stall
   reproduces.
