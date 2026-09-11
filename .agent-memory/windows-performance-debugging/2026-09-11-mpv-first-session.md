# 2026-09-11 — first MPV `I:\XXX` performance session

## Environment

- Repository: `C:\Users\andre\Projects\mpv`; working tree was already dirty in
  unrelated files. No source or user configuration was changed.
- Deployed binary: `dist\mpv.exe` / `dist\mpv.com`, mpv
  `v0.41.0-947-gd37b8c1a7-dirty`, built 2026-09-11 03:34:59, x64.
- Windows 11 Insider build 26220; Ryzen 9 9950X3D, 16 cores/32 logical
  processors; approximately 102.7 GB RAM.
- WPR: `10.0.26100.9306`; WPA/WPAExporter: `11.7.395.48728`; PowerShell 7.6.6.
- The recursive `I:\XXX` tree contained 9,797 video files at investigation time.
- Background-load preflight: not recorded. Possible contamination by unrelated
  CPU, memory, disk, network, or GPU activity is `INCONCLUSIVE` for these runs.

## Findings

### VERIFIED — direct folder playback was disabled by configuration

The active `%APPDATA%\mpv\mpv.conf` contained `directory-mode=ignore`. A direct
`mpv I:\XXX` attempt logged `Opening failed or was aborted: I:\XXX` and
`Failed to recognize file format`, then exited. The minimal diagnostic override
`--directory-mode=recursive` opened and played the folder.

Future runs should verify this option before treating a folder-open failure as a
performance problem. Do not edit the config automatically; use the override or
ask whether folder playback should be enabled by default.

### VERIFIED — directory expansion dominates first-output latency

For the same representative AV1 file, the single-file/no-autocreate control
logged video output at about 0.81 s. Corrected folder playback logged folder
open at about 2.13 s and AO/VO initialization at about 2.59 s. The difference is
an observed scenario interval; without ETW it is not proof of a specific disk or
thread cause.

### VERIFIED — prefetch adds resource pressure but little measured CPU change

In one 30-second corrected-folder sample, active prefetch reached approximately
466 MB working set, 1,047 MB private memory, and 147 threads.
The no-prefetch control reached approximately 361 MB working set, 949 MB private
memory, and 137 threads. Recomputed sampled CPU deltas were similar: 14.891 s
with prefetch and 14.485 s without prefetch. These are single process samples,
not statistical before/after results and not ETW causal attribution.

The active log showed several sibling entries opening within roughly 0.6 s after
the folder became playable, plus multiple VO reconfigurations. Treat those
prefetch operations as overlapping work.

The sampler's `ReadMB=0` and `WriteMB=0` fields were unavailable-counter
placeholders, not proof that playback performed no I/O.

### INCONCLUSIVE — scheduler, disk, GPU, and underrun causality

The WPR plan used `CPU.Light,GPU.Light,FileIO.Light`, but capture was refused
because the host token was not elevated. No ETL, WPA tables, Procmon PML, thread
IDs, READY/WAIT breakdown, disk service times, GPU packet timing, or stacks were
collected. An audio under-run was observed in MPV logs, but its system cause is
not established.

## Retained evidence

- Main report: `C:\Users\andre\PerfRuns\mpv-directory-playback-20260911T073730633Z-bcc0a336932041f8a1322d0e783ce240\report.md`
- Corrected folder run: same directory, `measurements\runtime-corrected-*.csv`
  and `measurements\mpv-corrected-*.log`.
- No-prefetch control:
  `C:\Users\andre\PerfRuns\mpv-directory-no-prefetch-20260911T074451598Z-da46177d91294e89a23bf6cbd592dd8b`
- Single-file control:
  `C:\Users\andre\PerfRuns\mpv-single-file-no-autocreate-20260911T074559707Z-577925d3602740a6a307f6ec645ffffd`
- WPR plan (not executed): main run `measurements\wpr-plan-e895754d83564f70b1a0d1204266cb17.json`.
- Project coder package:
  `benchmarks\Run-20260911-143730-mpv-directory-playback\report.md`.

The first WPR helper attempt used `mpv.com` and was rejected because
`Invoke-WprCapture.ps1 -Executable` requires a native `.exe`. Retrying through
`pwsh.exe` reached the real blocker: the session was not elevated.

## Next run

Run the corrected folder workload from an elevated PowerShell using the saved
WPR plan, but first run and retain the system-load preflight. If unrelated heavy
activity persists after one 60-second stabilization wait, stop and ask the user
to close it or abort. Export CPU precise/sampled, File I/O, GPU/DxgKrnl, and
marker-range tables. Add Procmon separately only if path/operation attribution
remains unresolved. Preserve the same build, display mode, input, cache label,
and 30-second window before comparing changes.
