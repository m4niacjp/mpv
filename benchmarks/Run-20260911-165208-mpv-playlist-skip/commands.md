# Commands actually run (condensed; outcomes in report.md)

All commands ran in the elevated session (High integrity, parent `opencode2.exe
serve --service` PID 7804). `R` below =
`C:\Users\andre\PerfRuns\mpv-playlist-skip-20260911T090749482Z-da38e1520da444cca96c26acd325bc27`.

## Environment / preflight

```powershell
fltmc                                    # filter list OK, High IL verified
git -C C:\Users\andre\Projects\mpv status --short --branch   # unchanged dirty state
& C:\Users\andre\Projects\mpv\dist\mpv.com --no-config --version
$r = & "$R\measurements\Get-PreflightSample.ps1" -Seconds 10 -OutJson "$R\measurements\preflight-1.json"
$r = & "$R\measurements\Get-PreflightSample.ps1" -Seconds 6  -OutJson "$R\measurements\preflight-2.json"
```

## Run creation, WPR planning and probes

```powershell
& <skill>\New-PerformanceRun.ps1 -Root C:\Users\andre\PerfRuns -Scenario mpv-playlist-skip `
  -Boundary process-spawn-to-exit -Workload '<see manifest>' -CacheState unknown -WorkerCount 1
& <skill>\New-WprCapturePlan.ps1 -RunDirectory $R -Profile CPU.Light,FileIO.Light,DiskIO.Light,GPU.Light,Network.Light
& <skill>\Invoke-WprCapture.ps1 -PlanPath <plan> -DurationSeconds 10        # idle volume probe -> 3.18 GB / 32.7 s, stop 95.6 s
# manual profile-volume probes (raw wpr -start/-stop with try/finally):
#   CPU          6 s -> 319 MB (53 MB/s)
#   CPU.Verbose  6 s -> 406 MB (68 MB/s)
#   light set    6 s -> 730 MB total wall 51.8 s
#   stack set    6 s -> 2644 MB total wall 82.7 s
& 'C:\Program Files (x86)\Windows Kits\10\Windows Performance Toolkit\xperf.exe' -i <etl> -a marks
```

## Scenario trials (bespoke IPC harness; exact spec + documented retry policy)

```powershell
# smoke validations (arm real, extra unused inputs): t100, t101, t102, t103
& pwsh -NoProfile -NonInteractive -File "$R\measurements\Invoke-MpvSkipBatch.ps1" `
  -RunDirectory $R -MpvPath C:\Users\andre\Projects\mpv\dist\mpv.exe `
  -MediaRoot I:\XXX\new2 -Arm real -TrialCount 1 -FirstTrialIndex 103 `
  -MarkerMode none -RclonePid 55588 -SelectionJson "$R\measurements\selection-smoke4.json" -T4TimeoutSec 30
```

## WPR captures under guaranteed cleanup

```powershell
# real arm (t0-t2), profiles CPU.Light+FileIO.Light+DiskIO.Light+GPU.Light+Network.Light
$plan = & <skill>\New-WprCapturePlan.ps1 -RunDirectory $R -Profile CPU.Light,FileIO.Light,DiskIO.Light,GPU.Light,Network.Light
& <skill>\Invoke-WprCapture.ps1 -PlanPath $plan.planPath -Executable pwsh.exe `
  -ArgumentList @('-NoProfile','-NonInteractive','-File',"$R\measurements\Invoke-MpvSkipBatch.ps1",
    '-RunDirectory',$R,'-MpvPath','C:\Users\andre\Projects\mpv\dist\mpv.exe','-MediaRoot','I:\XXX\new2',
    '-Arm','real','-TrialCount','3','-FirstTrialIndex','0','-MarkerMode','wpr','-WprInstance',$plan.instanceName,
    '-RclonePid','55588','-SelectionJson',"$R\measurements\selection.json") -TimeoutSeconds 300
# -> capture-0e2d39e5e6764bb8b4f87adc2b97c9f6.etl 4.30 GB, 0 dropped events, 16/16 markers, stop OK
# control arm (t3-t5): same with -Arm control -FirstTrialIndex 3
# -> capture-ad502a227d644e9ab0fd901439b771f6.etl 1.14 GB, 0 dropped events, stop OK
```

## Procmon observer pass (extra real trial t6)

```powershell
& <skill>\Invoke-ProcmonCapture.ps1 -RunDirectory $R -Executable pwsh.exe -ArgumentList @(... '-Arm','real',
    '-TrialCount','1','-FirstTrialIndex','6','-MarkerMode','none','-SelectionJson',"$R\measurements\selection-procmon.json") `
  -TimeoutSeconds 120 -ConfigPath <skill>\assets\procmon-duration-tid.pmc -SettleSeconds 3 `
  -ProcmonPath 'C:\Users\andre\Desktop\Mem\ProcMon\Procmon.exe'
# -> PML 2.21 GB, CSV 6,065,879 rows, marker check OK; stopMethod=watchdog (a second Procmon PID appeared);
#    settings restored; workload success
```

## Exports and analysis

```powershell
& <skill>\Export-WpaTables.ps1 -EtlPath <real-etl> -ProfilePath "<wpt>\Catalog\AppLaunch.wpaProfile" `
  -OutputDirectory "$R\exports\wpa-real-t1" -Marks t1-launch,t1-exit -RequireFile 'CPU_Usage*' -AllowPartialProfile
& <skill>\Export-WpaTables.ps1 -EtlPath <control-etl> -ProfilePath "<wpt>\Catalog\AppLaunch.wpaProfile" `
  -OutputDirectory "$R\exports\wpa-control-t3" -Marks t3-launch,t3-exit -RequireFile 'CPU_Usage*' -AllowPartialProfile

# Procmon CSV stream filter (mpv.exe/rclone.exe rows and mount paths), then stats
& "$R\measurements\Filter-ProcmonCsv.ps1" -CsvPath "$R\exports\procmon-*.csv" -OutCsv "$R\exports\procmon-filtered.csv"
& "$R\measurements\Summarize-Procmon.ps1" -FilteredCsv "$R\exports\procmon-filtered.csv" `
  -OutSummaryJson "$R\measurements\procmon-summary.json" -ProcessIds 43860,55588,44512
& "$R\measurements\Summarize-WpaExport.ps1" -ExportDirectory "$R\exports\wpa-real-t1"    -OutJson "$R\measurements\wpa-summary-real-t1.json"
& "$R\measurements\Summarize-WpaExport.ps1" -ExportDirectory "$R\exports\wpa-control-t3" -OutJson "$R\measurements\wpa-summary-control-t3.json"
& "$R\measurements\Rebuild-TrialSummary.ps1" -RunDirectory $R -Arm real -TrialIndices 0,1,2 -OutJson "$R\measurements\real-batch-reconstructed.json"
& "$R\measurements\Measure-PhaseDeltas.ps1" -RunDirectory $R -Arm real   -TrialIndices 0,1,2 -EventsDirName ev -OutCsv "$R\measurements\phase-deltas-real.csv"
& "$R\measurements\Measure-PhaseDeltas.ps1" -RunDirectory $R -Arm control -TrialIndices 3,4,5 -EventsDirName ev -OutCsv "$R\measurements\phase-deltas-control.csv"
& "$R\measurements\New-SummaryCsv.ps1" -RunDirectory $R
```

## Cleanup verification

```powershell
& C:\WINDOWS\system32\wpr.exe -status          # "WPR is not recording"
Get-Process Procmon* -ErrorAction SilentlyContinue   # none
git -C C:\Users\andre\Projects\mpv status --short --branch   # unchanged
```

## Option-1 cold worst-case lane (gated driver, batches 1-4)

```powershell
# one process: gate -> mutex -> preflight -> Procmon t0 -> 2 plain trials -> summary
pwsh -NoProfile -File <run>\scripts\Invoke-ColdWorstValidation.ps1 `
  -RunDir <run> -SelectionPath <run>\scripts\selection-coldworst4.json `
  -HarnessPath <run>\scripts\Invoke-MpvSkipBatch.ps1 `
  -MpvPath C:\Users\andre\Projects\mpv\dist\mpv.exe -MediaRoot I:\XXX\new2 `
  -ProcmonHelper <skill>\scripts\Invoke-ProcmonCapture.ps1 `
  -ProcmonConfig <skill>\assets\procmon-duration-tid.pmc `
  -ScanScript <run>\scripts\measure-scan.ps1 `
  -CensusJson <option1-lane>\measurements\cache-pool-after.json -RclonePid 2236
# run dirs: mpv-playlist-option1-coldworst{,-2,-3,-4}-20260911T* (batch 3 aborted at preflight, retained)

# VFS cache state (authoritative coverage; maps WinFsp U+F0xx -> rclone U+FFxx)
& <run>\scripts\Get-VfsCacheState.ps1 -InputPath <I:\...\file.mkv> -OutJson <out>
# per-op analysis of the Procmon pass
& <run>\scripts\Analyze-WorstCase.ps1 -FilteredCsv <filtered.csv> -PathMarker \\server\RcloneWcrypt\XXX\new2 `
  -InputPath <mounted input> -ScanTid <from scan-after.json> -MpvPid <trial pid> -OutJson <out>
& <run>\scripts\Analyze-StatPasses.ps1 -FilteredCsv <filtered.csv> -InputTag xhTrUYZ -MpvPid <trial pid> -OutJson <out>
& <run>\scripts\Get-FetchWindow.ps1 -RcloneJson <measurements\rclone-real-tN.json> `
  -BatchJson <measurements\batch-real-tN.json> -TrialIndex N -MpvLog <measurements\mpv-real-tN.log> -OutJson <out>
```
