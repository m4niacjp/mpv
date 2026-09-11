# MPV Windows performance benchmark runbook

## Before the run

Use the deployed binary that matches the user runtime, and record its version:

```powershell
git status --short --branch
& 'C:\Users\andre\Projects\mpv\dist\mpv.com' --no-config --version
& 'C:\Users\andre\.codex\skills\windows-performance-debugging\scripts\Resolve-PerformanceTools.ps1'
& 'C:\Users\andre\.codex\skills\windows-performance-debugging\scripts\Get-PerformanceEnvironment.ps1'
```

Create every run outside the repository. The helper creates `manifest.json`,
`environment.json`, `measurements`, `traces`, `exports`, and `report.md`:

```powershell
$root = 'C:\Users\andre\PerfRuns'
New-Item -ItemType Directory -Force -Path $root | Out-Null
& 'C:\Users\andre\.codex\skills\windows-performance-debugging\scripts\New-PerformanceRun.ps1' `
  -Root $root -Scenario 'mpv-<scenario>' `
  -Boundary 'directory-open-to-first-output' `
  -Workload 'dist\mpv.exe --directory-mode=recursive I:\XXX' `
  -CacheState unknown -WorkerCount 1
```

Do not purge caches. Label cold, warm, and unknown explicitly. Use at least
five lightweight trials when variance matters; retain failures and do not call
one trial a median.

## System-load preflight

Before every baseline, trace, or validation batch, observe a short representative
interval and record total plus top unrelated consumers for CPU, available/committed
memory and paging, disk/volume activity, network throughput, and GPU activity when
relevant. Note update, indexing, security-scan, synchronization, build,
VM/container, and other known background work. Define the scenario-specific
threshold that would materially contaminate its metric; do not stop for one
transient spike.

If unrelated heavy activity is present:

1. Do not launch the benchmark. Retain the first observation.
2. Wait once for up to 60 seconds, then repeat the same observation.
3. If material contention remains, stop before testing. Record the process name,
   PID, safely available executable owner, resource, interval, and measured usage;
   inform the user and wait for them to close the processes or abort the tests.

Never terminate, suspend, reprioritize, or reconfigure those processes without
explicit authorization. Do not disclose sensitive unrelated command lines. Store
both checks and the proceed/wait/abort disposition in the run manifest/report, and
repeat the preflight whenever conditions may have changed between batches.

## MPV directory benchmark

This checkout's active user configuration has historically used:

```text
autocreate-playlist=filter
directory-mode=ignore
```

Therefore a direct `mpv I:\XXX` can fail as an unrecognized directory. Verify
the live configuration first. For a diagnostic run that must open the folder,
use the command-line override without editing the user's config:

```powershell
& 'C:\Users\andre\Projects\mpv\dist\mpv.com' `
  --directory-mode=recursive --idle=no --keep-open=no `
  'I:\XXX'
```

`autocreate-playlist` applies to local regular files and can discover siblings;
directory expansion and playlist prefetch can open multiple entries concurrently.
Do not sum overlapping prefetch operations as elapsed time.

Do not rely on `--length` or `--frames` alone to bound a directory playlist:
they may end the current item and allow the playlist to advance. For GUI/first-
frame work, use an external bounded harness that starts MPV, samples it once per
second, captures the MPV log, and stops only the PID it created. Record the
sampling interval and the fact that it is not ETW scheduling evidence.

A useful unprivileged sample records:

- MPV PID and lifetime;
- CPU seconds;
- working set and private memory;
- thread and handle counts;
- MPV log timestamps for `Opening done`, hardware decoder selection, AO, VO,
  underruns, prefetch, playlist changes, and errors;
- the exact active options and command-line overrides.

Treat unavailable process counters as unavailable. In the first-session sampler,
`ReadMB` and `WriteMB` were emitted as zero because the intended counters were not
available from the sampled process object. Those values do not prove zero logical
or physical I/O. Use ETW File I/O and Disk I/O tables, or a separately captured
Procmon PML, for storage conclusions.

For a single-file rendering control, disable sibling discovery:

```powershell
& 'C:\Users\andre\Projects\mpv\dist\mpv.com' `
  --autocreate-playlist=no --idle=no --keep-open=no `
  'I:\XXX\<representative-file>.mkv'
```

Compare folder versus single-file and prefetch versus no-prefetch with the same
binary, input, display, and cache condition. A process-level CPU or memory
difference identifies pressure, not the causal thread or storage/GPU cause.

For the literal single-shot skip test (T1+5 s: one `playlist-next`, immediately
one more, quit at the third file's restart, no retries) the durable
`Invoke-MpvSkipBatch.ps1` is unsuitable: `-MaxNextAttempts 1` throws
`All 1 playlist-next attempts were rejected` and then skips the T4/deadline/quit
phases, losing the failure outcome. Use the purpose-built single-shot wrapper
recorded in the run's `measurements\` (see
`2026-09-11-mpv-playlist-skip-literal.md`), and avoid two instrumented traps:
store command replies in a hashtable, not `[ordered]@{}` (its integer indexer
throws and silently drops replies), and preset the T4 target from the observed
`playlist-pos` at the send instant instead of waiting for replies. Budget for the
core autocreate splice before the T1+5 s action: 0.24-25.4 s observed over four
trials; if the splice exceeds the window, the literal next pair is a strict
no-op (`player/command.c` `cmd_playlist_next_prev`, `force=0`).

## WPR/WPA/Procmon escalation

Prepare a reviewable plan with the smallest useful profiles. For combined MPV
CPU, GPU, and file-I/O questions, the first-session plan used:

```powershell
& 'C:\Users\andre\.codex\skills\windows-performance-debugging\scripts\New-WprCapturePlan.ps1' `
  -RunDirectory '<run-directory>' -Profile CPU.Light,GPU.Light,FileIO.Light
```

Run `Invoke-WprCapture.ps1` in one elevated PowerShell process so start, markers,
workload, and stop share a guaranteed `finally` cleanup. WPR capture and Procmon
may require elevation. Never bypass UAC, cancel an unrelated session, or accept
an EULA automatically. If elevation is unavailable, collect unprivileged logs
and process samples but mark RUNNING/READY/WAITING, disk causality, GPU timing,
and stack-based source attribution `INCONCLUSIVE`.

`Invoke-WprCapture.ps1 -Executable` requires a native `.exe`; it rejects console
shim files such as `.com`. Point it at the native application executable, or at
`pwsh.exe` when an explicit PowerShell wrapper is required. Using a valid `.exe`
does not remove WPR's elevation requirement.

Before interpreting an ETL, verify marker coverage, process lifetime/PID,
providers, dropped events, timestamp ordering, image/rundown data, stacks, and
symbols. Export tables through `Export-WpaTables.ps1`; WPAExporter exit code 0
alone is not proof of a successful export. For Procmon, retain the native PML
and use the duration/TID configuration when operation cost matters.

## Report contract

Create a unique project-relative package for every material investigation:

```text
benchmarks\Run-YYYYMMDD-HHMMSS-<scenario-slug>\
  report.md
  manifest.json
  environment.json
  commands.md
  artifacts.md
  measurements\summary.csv or summary.json
```

Do not overwrite prior or failed runs. Keep raw ETL/PML, dumps, symbol caches,
and oversized logs outside Git; record their exact locations and hashes when
useful in `artifacts.md`.

Use the bundled report template for `report.md`. Include exact commands and
outcomes, scenario and reproduction boundary, expected/observed behavior, input
identity, build/commit/configuration, environment/tool versions, cache state,
process tree, background-load preflight and disposition, all trials and failures,
observer overhead, critical-path evidence,
and one of `VERIFIED`, `CONTRADICTED`, or `INCONCLUSIVE` for every material
claim. Identify relevant source files/functions and distinguish measured bugs
from hypotheses. Record proposed fixes or experiments, validation performed,
remaining risks, and the next measurement that would discriminate each
unresolved hypothesis.

Link the package from the dated memory and include the final `report.md` path in
the user handoff.
