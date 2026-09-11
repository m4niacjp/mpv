# Commands run for this investigation

All commands were run from `C:\Users\andre\Projects\mpv` in an elevated
PowerShell 7 session unless noted. Only the commands that produced the reported
results are listed.

## Corpus and state (setup)

```powershell
# Adopt verified encodes / generate the 25-file corpus (x264 capped at 6 threads)
pwsh -NoProfile -File benchmarks\vfs-bench\New-BenchVideos.ps1 -EncoderThreads 6
pwsh -NoProfile -File benchmarks\vfs-bench\Resume-BenchVideos.ps1

# Full decode verification (25/25)
pwsh -NoProfile -File benchmarks\vfs-bench\Verify-BenchMedia.ps1

# Upload to wcrypt:PerformanceBench/{Cold,Warm} (8 concurrent RC copyfile calls)
pwsh -NoProfile -File benchmarks\vfs-bench\Sync-BenchMedia.ps1 -Folder Both -Parallel 8

# Cold census (0%) and warm fill (parallel reads, flush-wait verification)
pwsh -NoProfile -File benchmarks\vfs-bench\Set-BenchCacheState.ps1 -Mode status -Folder Cold
pwsh -NoProfile -File benchmarks\vfs-bench\Set-BenchCacheState.ps1 -Mode warm -Folder Warm -Parallel 6 -Label par6
```

## Trial matrix

```powershell
pwsh -NoProfile -File benchmarks\vfs-bench\Invoke-BenchTrials.ps1
# conditions config-cold, config-warm, noconfig-cold, noconfig-warm
# kinds plain, wpr, procmon; frames 300; trial timeout 150 s
# warm-up: one 90-frame playback of C:\PerfBench\warmup\PBWARM.mkv
```

Matrix summary: `C:\Users\andre\PerfRuns\vfs-bench-matrix-20260911-212832.json`

## Analysis

```powershell
pwsh -NoProfile -File benchmarks\vfs-bench\Summarize-BenchTrials.ps1 `
  -MatrixPath 'C:\Users\andre\PerfRuns\vfs-bench-matrix-20260911-212832.json'
# -> C:\PerfBench\analysis\summarize-trials.csv
# -> C:\PerfBench\analysis\summarize-conditions.json
```

## Probe smoke test (harness validation after the first attempt failed)

```powershell
& dist\mpv.exe --no-config --autocreate-playlist=filter `
  --log-file=C:\PerfBench\smoke\probe-smoke.log `
  --script=benchmarks\vfs-bench\bench-probe.lua `
  --script-opts=benchprobe-out=C:\PerfBench\smoke\probe-smoke.json,benchprobe-frames=300,benchprobe-trial=smoke,benchprobe-timeout=60 `
  'I:\PerformanceBench\Warm\PB01.mkv'
# 20.6 s; frames-reached x2, cmd-playlist-next, cmd-quit
```

## Traces (recorded by the trial runner; not run by hand)

```powershell
# WPR: CPU.Light,GPU.Light,FileIO.Light,Network.Light (memory mode), markers workload-start/end
# Procmon: /BackingFile ... /Runtime <watchdog>, /LoadConfig assets\procmon-duration-tid.pmc,
#          /OpenLog <pml> /SaveAs <csv>, begin/end marker check
```

## Trace analysis (next step; not yet run)

```powershell
& 'C:\Users\andre\.claude\skills\windows-performance-debugging\scripts\Export-WpaTables.ps1' `
  -EtlPath <capture.etl> -OutDir <dir> -Profile Cpu,FileIO,Network
# plus per-PID Procmon duration extraction from the four exported CSVs
```
