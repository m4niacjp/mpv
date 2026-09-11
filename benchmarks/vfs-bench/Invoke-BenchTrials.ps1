#requires -Version 7.4
<#
.SYNOPSIS
Runs the mpv rclone-VFS cold/warm benchmark trial matrix.

.DESCRIPTION
Conditions (3 trials each: plain, WPR, Procmon - per the approved decision):
  config-cold    real user config, Cold folder, inputs PB01/06/11 (+4 prefetch span)
  config-warm    real user config, Warm folder, same bases, standby-purged
  noconfig-cold  --no-config --autocreate-playlist=filter, Cold, PB16/18/20 (+1)
  noconfig-warm  same, Warm folder, standby-purged

Each trial:
  1. optional preflight (Measure-Load.ps1), recorded
  2. standby purge (authorized) and, for cold conditions, deletion of the
     involved entries' vfs data+meta under the live rclone (unique inputs per
     trial, so the handle grace has always expired)
  3. mpv (dist\mpv.exe) + bench-probe.lua: 300 frames -> playlist-next -> 300
     frames -> quit, with an mpv log file for mp_time_sec anchors
  4. traced trials use the windows-performance-debugging helpers in an own run
     directory, with the rclone log at DEBUG (restored right after)
Writes per-trial JSON and a matrix summary CSV under the run root. Never starts
two mpv processes at once; failures are retained and reported.

.PARAMETER Conditions
Subset of the four conditions (default all).

.PARAMETER Kinds
Trial kinds to run per condition (default plain,wpr,procmon).

.PARAMETER EnforcePreflight
Abort the matrix (throw) when a preflight exceeds the contamination thresholds
after one 60 s stabilization wait. Default: record only.

.PARAMETER PlainRepeats
Extra plain trials per condition, reusing the plain kind's input span. Repeats
of a cold span wait out the rclone handle grace (75 s) before the reset, so the
vfs data+meta deletion is safe. Default: 0.
#>
[CmdletBinding()]
param(
    [ValidateSet('config-cold', 'config-warm', 'noconfig-cold', 'noconfig-warm',
        'config-cold-no-playlist-sort', 'config-warm-no-playlist-sort')][string[]] $Conditions =
        @('config-cold', 'config-warm', 'noconfig-cold', 'noconfig-warm'),
    [ValidateSet('plain', 'wpr', 'procmon')][string[]] $Kinds = @('plain', 'wpr', 'procmon'),
    [string] $RunRoot = 'C:\Users\andre\PerfRuns',
    [string] $SkillDir = 'C:\Users\andre\.claude\skills\windows-performance-debugging',
    [int] $Frames = 300,
    [int] $PlainRepeats = 0,
    [int] $TrialTimeoutSec = 150,
    [switch] $SkipWarmup,
    [switch] $SkipPreflight,
    [switch] $EnforcePreflight,
    [switch] $WhatIfOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'VfsBench.psm1') -Force
$cfg = Get-BenchConfig
$harnessDir = $PSScriptRoot
$mpvDir = Split-Path -Parent $cfg.MpvPath
$skillScripts = Join-Path $SkillDir 'scripts'

if (-not (Test-Path -LiteralPath $cfg.MpvPath)) { throw "mpv missing: $($cfg.MpvPath)" }
if (-not (Test-Path -LiteralPath (Join-Path $harnessDir 'bench-probe.lua'))) { throw 'bench-probe.lua missing' }
New-Item -ItemType Directory -Force -Path $RunRoot | Out-Null

# ------------------------------------------------- user-script toggle (A/B runs)
# Disabling one user script means moving it out of the auto-load directory for
# the duration of the run (mpv probes every entry under scripts\, so a merely
# renamed file there logs "Can't load unknown script"). The move is reversed
# after the conditions loop, and a leftover file is restored at startup in case
# a previous run died.
$script:DisabledUserScripts = [Collections.Generic.List[object]]::new()
$script:DisabledScriptsDir = Join-Path $cfg.UserConfigDir 'bench-disabled-scripts'
function Restore-LeftoverBenchScripts {
    $scriptsDir = Join-Path $cfg.UserConfigDir 'scripts'
    # old scheme: <script>.bench-off left next to the script
    foreach ($off in @(Get-ChildItem -LiteralPath $scriptsDir -File -Filter '*.bench-off' -ErrorAction SilentlyContinue)) {
        $target = $off.FullName -replace '\.bench-off$', ''
        if (-not (Test-Path -LiteralPath $target)) {
            Rename-Item -LiteralPath $off.FullName -NewName (Split-Path -Leaf $target)
            Write-Host "restored leftover disabled script: $(Split-Path -Leaf $target)"
        }
    }
    # current scheme: moved to the sibling bench-disabled-scripts directory
    if (Test-Path -LiteralPath $script:DisabledScriptsDir) {
        foreach ($f in @(Get-ChildItem -LiteralPath $script:DisabledScriptsDir -File -Filter '*.lua' -ErrorAction SilentlyContinue)) {
            $target = Join-Path $scriptsDir $f.Name
            if (-not (Test-Path -LiteralPath $target)) {
                Move-Item -LiteralPath $f.FullName -Destination $target
                Write-Host "restored leftover disabled script: $($f.Name)"
            }
        }
    }
}
function Disable-BenchUserScript([string] $Name) {
    $src = Join-Path (Join-Path $cfg.UserConfigDir 'scripts') $Name
    $dst = Join-Path $script:DisabledScriptsDir $Name
    if (-not (Test-Path -LiteralPath $src)) {
        if (Test-Path -LiteralPath $dst) { return }   # already disabled
        throw "user script not found: $src"
    }
    New-Item -ItemType Directory -Force -Path $script:DisabledScriptsDir | Out-Null
    Move-Item -LiteralPath $src -Destination $dst
    $script:DisabledUserScripts.Add([pscustomobject]@{
        source = $src; disabled = $dst
        sha256 = (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash
    })
    Write-Host "disabled user script for this run: $Name"
}
function Restore-BenchUserScripts {
    foreach ($d in $script:DisabledUserScripts) {
        if (Test-Path -LiteralPath $d.disabled) {
            if ((Get-FileHash -LiteralPath $d.disabled -Algorithm SHA256).Hash -ne $d.sha256) {
                throw "disabled script changed on disk; not restoring: $($d.disabled)"
            }
            Move-Item -LiteralPath $d.disabled -Destination $d.source
            Write-Host "restored user script: $(Split-Path -Leaf $d.source)"
        }
    }
    $script:DisabledUserScripts.Clear()
}
Restore-LeftoverBenchScripts

$defs = [ordered]@{
    'config-cold'   = [pscustomobject]@{ config = 'real';     cache = 'cold'; bases = @(1, 6, 11);  span = 5; folder = 'Cold'; disableScript = $null }
    'config-warm'   = [pscustomobject]@{ config = 'real';     cache = 'warm'; bases = @(1, 6, 11);  span = 5; folder = 'Warm'; disableScript = $null }
    'noconfig-cold' = [pscustomobject]@{ config = 'noconfig'; cache = 'cold'; bases = @(16, 18, 20); span = 2; folder = 'Cold'; disableScript = $null }
    'noconfig-warm' = [pscustomobject]@{ config = 'noconfig'; cache = 'warm'; bases = @(16, 18, 20); span = 2; folder = 'Warm'; disableScript = $null }
    # A/B for the playlist-sort/prefetch switch theory: real config minus
    # playlist-sort.lua (the script is renamed aside for the duration).
    'config-cold-no-playlist-sort' = [pscustomobject]@{ config = 'real'; cache = 'cold'; bases = @(1, 6, 11); span = 5; folder = 'Cold'; disableScript = 'playlist-sort.lua' }
    'config-warm-no-playlist-sort' = [pscustomobject]@{ config = 'real'; cache = 'warm'; bases = @(1, 6, 11); span = 5; folder = 'Warm'; disableScript = 'playlist-sort.lua' }
}

function Get-PreflightVerdict($jsonPath) {
    try {
        $p = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
        $cpu = $null; $pages = $null; $disk = $null
        foreach ($k in $p.systemCounters.PSObject.Properties.Name) {
            if ($k -match 'Processor\(_Total\)% Processor Time') { $cpu = $p.systemCounters.$k.avg }
            if ($k -match 'Pages/sec') { $pages = $p.systemCounters.$k.avg }
            if ($k -match 'PhysicalDisk\(_Total\)% Disk Time') { $disk = $p.systemCounters.$k.avg }
        }
        $heavy = ($cpu -gt 60) -or ($pages -gt 4000) -or ($disk -gt 85)
        [pscustomobject]@{ ok = (-not $heavy); cpu = $cpu; pagesPerSec = $pages; diskPct = $disk }
    } catch {
        [pscustomobject]@{ ok = $true; error = "$_" }
    }
}

function Invoke-PreflightBlock([string] $Label, [string] $OutJson) {
    & (Join-Path $harnessDir 'Measure-Load.ps1') -Seconds 20 -Label $Label -OutJson $OutJson | Out-Null
    $v = Get-PreflightVerdict $OutJson
    if ($EnforcePreflight -and -not $v.ok) {
        Write-Host "preflight heavy ($($v | ConvertTo-Json -Compress)); waiting 60 s"
        Start-Sleep -Seconds 60
        & (Join-Path $harnessDir 'Measure-Load.ps1') -Seconds 20 -Label "$Label-retry" -OutJson $OutJson | Out-Null
        $v = Get-PreflightVerdict $OutJson
        if (-not $v.ok) { throw "preflight contamination persists: $($v | ConvertTo-Json -Compress)" }
    }
    $v
}

function Parse-MpvLog([string] $Path) {
    $events = [Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    foreach ($line in Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue) {
        if ($line -match '^\[\s*([0-9]+\.[0-9]+)\]\[[a-z]\]\s*(.*)$') {
            $t = [double]$Matches[1]; $text = $Matches[2]
            $kind = $null
            foreach ($pat in @(
                @('first-video-frame', 'first video frame after restart shown'),
                @('playback-restart-complete', 'playback restart complete'),
                @('opening-done', 'Opening done:'),
                @('opening-failed', 'Opening failed or was aborted:'),
                @('autocreate', 'Autocreate playlist:'),
                @('using-prefetched', 'Using prefetched URL'),
                @('using-prefetching', 'Using prefetched/prefetching URL'),
                @('prefetching', 'Prefetching: '),
                @('prefetch-start-window', 'Prefetch start window ready.'),
                @('prefetch-expanding', 'Prefetch expanding cache.'),
                @('hwdec', 'Using hardware decoding'),
                @('vo-configured', 'VO: ['),
                @('ao-init', 'AO: ['),
                @('buffering-enter', 'Enter buffering'),
                @('buffering-end', 'End buffering'),
                @('drop-stale', 'Dropping stale prefetched URL'),
                @('abort-stale', 'Aborting prefetch outside playlist next'))) {
                if ($text.Contains($pat[1])) { $kind = $pat[0]; break }
            }
            if ($kind) { $events.Add([pscustomobject]@{ t = $t; kind = $kind; text = $text }) }
        }
    }
    @($events)
}

function Get-ProbePhases($probe) {
    $ev = @($probe.events)
    function Ev([string] $name, [int] $nth = 0) {
        @($ev | Where-Object { $_.name -eq $name })[$nth]
    }
    $playback = @($ev | Where-Object { $_.name -eq 'playback-restart' })
    # Select-Object -First 1 returns $null on no match; @()[0] throws under
    # Set-StrictMode and aborted the first trial when no next event existed.
    $firstNext = $ev | Where-Object { $_.name -eq 'cmd-playlist-next' } | Select-Object -First 1
    $quit = $ev | Where-Object { $_.name -eq 'cmd-quit' } | Select-Object -First 1
    [pscustomobject]@{
        tLoad = $probe.t_load
        tPlaybackRestart1 = if ($playback.Count -ge 1) { $playback[0].t } else { $null }
        tPlaybackRestart2 = if ($playback.Count -ge 2) { $playback[1].t } else { $null }
        tNext = if ($firstNext) { $firstNext.t } else { $null }
        tQuit = if ($quit) { $quit.t } else { $null }
        nextAttempts = $probe.next_attempts
        eventCount = $ev.Count
    }
}

function Invoke-PlainTrial([string] $MpvArgsLine, [string[]] $ArgList, [string] $TrialJson, [string] $Id) {
    $samples = [Collections.Generic.List[object]]::new()
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $cfg.MpvPath
    $psi.WorkingDirectory = $mpvDir
    $psi.UseShellExecute = $false
    foreach ($a in $ArgList) { $psi.ArgumentList.Add($a) }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = [Diagnostics.Process]::Start($psi)
    $lastSample = 0.0
    $auth = Get-Content -LiteralPath $cfg.RcAuthPath -Raw | ConvertFrom-Json
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($auth.user):$($auth.pass)"))
    $hdr = @{ Authorization = "Basic $b64" }
    $rc0 = $null
    try { $rc0 = Invoke-RestMethod -Uri 'http://127.0.0.1:5574/core/stats' -Headers $hdr -Method Post -TimeoutSec 3 } catch { }
    $rcSamples = [Collections.Generic.List[object]]::new()
    $startWallUtc = [DateTimeOffset]::UtcNow.ToString('o')
    while (-not $p.HasExited) {
        if ($sw.Elapsed.TotalSeconds -ge $TrialTimeoutSec) {
            try { $p.Kill($true) } catch { }
            break
        }
        if (($sw.Elapsed.TotalSeconds - $lastSample) -ge 0.2) {
            $lastSample = $sw.Elapsed.TotalSeconds
            $cpu = $null; $ws = $null
            try { $p.Refresh(); $cpu = [math]::Round($p.TotalProcessorTime.TotalSeconds, 3); $ws = $p.WorkingSet64 } catch { }
            $samples.Add([pscustomobject]@{ t = [math]::Round($sw.Elapsed.TotalSeconds, 3); cpu = $cpu; ws = $ws })
            try {
                $rc = Invoke-RestMethod -Uri 'http://127.0.0.1:5574/core/stats' -Headers $hdr -Method Post -TimeoutSec 2
                $rcSamples.Add([pscustomobject]@{ t = [math]::Round($sw.Elapsed.TotalSeconds, 3); bytes = [double]$rc.bytes; transfers = [double]$rc.transfers; speed = [double]$rc.speed })
            } catch { }
        }
        Start-Sleep -Milliseconds 50
    }
    [void]$p.WaitForExit(5000)
    $sw.Stop()
    $rc1 = $null
    try { $rc1 = Invoke-RestMethod -Uri 'http://127.0.0.1:5574/core/stats' -Headers $hdr -Method Post -TimeoutSec 3 } catch { }
    $backend = $null
    if ($rc0 -and $rc1) { $backend = [pscustomobject]@{ deltaBytes = $rc1.bytes - $rc0.bytes; deltaTransfers = $rc1.transfers - $rc0.transfers } }
    [pscustomobject]@{ exitCode = $(try { $p.ExitCode } catch { $null }); wallSec = [math]::Round($sw.Elapsed.TotalSeconds, 3); startWallUtc = $startWallUtc; samples = @($samples); rcSamples = @($rcSamples); backend = $backend }
}

$matrix = [Collections.Generic.List[object]]::new()
$warmupDone = $false

# Script-toggle conditions must not mix with normal conditions in one run,
# because the disable applies to the whole invocation.
$needDisable = @($Conditions | Where-Object { $defs[$_].disableScript }).Count -gt 0
$anyEnabled = @($Conditions | Where-Object { -not $defs[$_].disableScript }).Count -gt 0
if ($needDisable -and $anyEnabled) {
    throw 'Conditions with disableScript must run in their own invocation (do not mix with normal conditions).'
}
if ($needDisable -and -not $WhatIfOnly) {
    foreach ($name in @($Conditions | ForEach-Object { $defs[$_].disableScript } | Select-Object -Unique)) {
        Disable-BenchUserScript $name
    }
}

foreach ($condName in $Conditions) {
    $def = $defs[$condName]
    # Trial plan: one trial per requested kind, then optional repeated plains
    # that reuse the plain kind's input span. Named trialPlan: $plan is used
    # later for the WPR capture plan.
    $trialPlan = [Collections.Generic.List[object]]::new()
    for ($ki = 0; $ki -lt $Kinds.Count; $ki++) {
        $trialPlan.Add([pscustomobject]@{ kind = $Kinds[$ki]; base = $def.bases[$ki] })
    }
    $plainIndex = [array]::IndexOf($Kinds, 'plain')
    if ($PlainRepeats -gt 0 -and $plainIndex -ge 0) {
        for ($r = 1; $r -le $PlainRepeats; $r++) {
            $trialPlan.Add([pscustomobject]@{ kind = 'plain'; base = $def.bases[$plainIndex] })
        }
    }
    $scenario = "mpv-vfs-$condName"
    $run = if ($WhatIfOnly) { Join-Path $RunRoot "DRY-$scenario" } else {
        & (Join-Path $skillScripts 'New-PerformanceRun.ps1') -Root $RunRoot -Scenario $scenario `
            -Boundary 'process-start-to-first-frame-and-next-frame' `
            -Workload "dist\mpv.exe [$($def.config)] $($def.folder) PB base $($def.bases -join ',')" `
            -CacheState $def.cache -WorkerCount 1
    }
    Write-Host "== condition $condName -> $run =="
    New-Item -ItemType Directory -Force -Path (Join-Path $run 'measurements') | Out-Null
    $markerDir = Join-Path $run 'markers'
    New-Item -ItemType Directory -Force -Path $markerDir | Out-Null

    if (-not $SkipWarmup -and -not $warmupDone -and -not $WhatIfOnly) {
        Write-Host 'warm-up playback of PBWARM (shader/VO caches)'
        $warmupLog = Join-Path $run 'measurements\warmup-mpv.log'
        $psi = [Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $cfg.MpvPath; $psi.WorkingDirectory = $mpvDir; $psi.UseShellExecute = $false
        foreach ($a in @("--log-file=$warmupLog", '--frames=90', $cfg.WarmupClip)) { $psi.ArgumentList.Add($a) }
        $wp = [Diagnostics.Process]::Start($psi)
        if (-not $wp.WaitForExit(90000)) { try { $wp.Kill($true) } catch { } }
        $warmupDone = $true
    }

    $planPath = $null
    if (($Kinds -contains 'wpr') -and -not $WhatIfOnly) {
        $plan = & (Join-Path $skillScripts 'New-WprCapturePlan.ps1') -RunDirectory $run `
            -Profile CPU.Light, GPU.Light, FileIO.Light, Network.Light
        $planPath = $plan.planPath
    }

    $prevNames = $null
    for ($t = 0; $t -lt $trialPlan.Count; $t++) {
        $kind = $trialPlan[$t].kind
        $base = $trialPlan[$t].base
        $id = "$condName-$kind-t$t"
        $names = @(for ($n = 0; $n -lt $def.span; $n++) { 'PB{0:D2}.mkv' -f ($base + $n) })
        # A repeated trial reads the same cold span as the previous one, so wait
        # out --vfs-handle-caching before deleting its vfs data+meta.
        $spanReused = ($null -ne $prevNames) -and (@(Compare-Object -ReferenceObject $prevNames -DifferenceObject $names -SyncWindow 0).Count -eq 0)
        $cooldown = if ($def.cache -eq 'cold' -and $spanReused) { $cfg.GraceSeconds + 15 } else { 0 }
        $inputPath = Join-Path (Join-Path $cfg.MountRoot $def.folder) ('PB{0:D2}.mkv' -f $base)
        $probeJson = Join-Path $run "measurements\probe-$id.json"
        $mpvLog = Join-Path $run "measurements\mpv-$id.log"
        $trialJson = Join-Path $run "measurements\trial-$id.json"

        Write-Host "-- trial $id (input PB$('{0:D2}' -f $base), span $($names -join ','))"
        $trial = [ordered]@{
            id = $id; condition = $condName; kind = $kind; base = $base; names = $names
            runDir = $run; probeJson = $probeJson
            inputPath = $inputPath; mpvArgs = $null; preflight = $null; cachePrep = $null
            standbyPurge = $null; userState = $null; userStateRestore = $null; rcloneLog = $null
            probe = $null; mpvTimeline = $null; mpvLog = $mpvLog; result = $null; error = $null
            startedUtc = [DateTimeOffset]::UtcNow.ToString('o'); completedUtc = $null
        }
        $debugWasSet = $false

        try {
            if (-not $SkipPreflight) {
                $trial.preflight = Invoke-PreflightBlock $id (Join-Path $run "measurements\preflight-$id.json")
            }

            $trial.standbyPurge = Invoke-StandbyPurge

            $cacheDir = Join-Path $run 'measurements\cache'
            if ($def.cache -eq 'cold') {
                & (Join-Path $harnessDir 'Set-BenchCacheState.ps1') -Mode cold -Folder $def.folder `
                    -Names $names -OutDir $cacheDir -Label $id -CoolDownSeconds $cooldown
                if (-not $?) { throw 'cold cache reset failed' }
                $trial.cachePrep = Get-Content -LiteralPath (Join-Path $cacheDir "cache-$($def.folder.ToLower())-cold-$id.json") -Raw | ConvertFrom-Json
            } else {
                # verify the span is fully cached; re-read missing files (rare)
                Import-Module (Join-Path $harnessDir 'VfsBench.psm1') -Force
                $bad = @()
                foreach ($n in $names) {
                    $e = Get-BenchCacheEntry $def.folder $n
                    if ($null -eq $e.coveragePct -or $e.coveragePct -lt 99.999) { $bad += $n }
                }
                if ($bad.Count) {
                    & (Join-Path $harnessDir 'Set-BenchCacheState.ps1') -Mode warm -Folder $def.folder `
                        -Names $bad -OutDir $cacheDir -Label $id
                    if (-not $?) { throw 'warm cache fill failed' }
                    $trial.cachePrep = Get-Content -LiteralPath (Join-Path $cacheDir "cache-$($def.folder.ToLower())-warm-$id.json") -Raw | ConvertFrom-Json
                } else {
                    $trial.cachePrep = [pscustomobject]@{ mode = 'warm'; checked = $names; allCached = $true }
                }
            }

            if ($def.config -eq 'real') {
                $trial.userState = Save-BenchUserState (Join-Path $run "measurements\userstate-$id")
            }

            $scriptOpts = "benchprobe-out=$probeJson,benchprobe-frames=$Frames,benchprobe-trial=$id,benchprobe-timeout=$($TrialTimeoutSec - 25)"
            if ($kind -ne 'plain') { $scriptOpts += ",benchprobe-markerdir=$markerDir" }
            $argList = [Collections.Generic.List[string]]::new()
            if ($def.config -eq 'noconfig') {
                $argList.Add('--no-config'); $argList.Add('--autocreate-playlist=filter')
            }
            $argList.Add("--log-file=$mpvLog")
            $argList.Add("--script=$(Join-Path $harnessDir 'bench-probe.lua')")
            $argList.Add("--script-opts=$scriptOpts")
            $argList.Add($inputPath)
            $trial.mpvArgs = @($argList)

            $rcloneLogBefore = Get-RcloneLogLength
            $debugWasSet = $false
            if ($kind -ne 'plain') { $null = Set-RcloneLogLevel 'DEBUG'; $debugWasSet = $true }

            if ($kind -eq 'plain') {
                if ($WhatIfOnly) { Write-Host "  [dry] $($cfg.MpvPath) $($argList -join ' ')" }
                else {
                    $trial.result = Invoke-PlainTrial ($argList -join ' ') @($argList) $trialJson $id
                }
            } elseif ($kind -eq 'wpr') {
                if ($WhatIfOnly) { Write-Host "  [dry-wpr] $planPath" }
                else {
                    $cap = & (Join-Path $skillScripts 'Invoke-WprCapture.ps1') -PlanPath $planPath `
                        -Executable $cfg.MpvPath -ArgumentList @($argList) -WorkingDirectory $mpvDir `
                        -TimeoutSeconds $TrialTimeoutSec
                    $trial.result = [pscustomobject]@{ kind = 'wpr'; capture = $cap }
                }
            } elseif ($kind -eq 'procmon') {
                if ($WhatIfOnly) { Write-Host "  [dry-procmon] $run" }
                else {
                    $cap = & (Join-Path $skillScripts 'Invoke-ProcmonCapture.ps1') -RunDirectory $run `
                        -Executable $cfg.MpvPath -ArgumentList @($argList) -WorkingDirectory $mpvDir `
                        -ConfigPath (Join-Path $SkillDir 'assets\procmon-duration-tid.pmc') `
                        -TimeoutSeconds $TrialTimeoutSec
                    $trial.result = [pscustomobject]@{ kind = 'procmon'; capture = $cap }
                }
            }

            if ($debugWasSet) {
                $null = Set-RcloneLogLevel 'INFO'
                $slice = Get-RcloneLogSlice $rcloneLogBefore
                $slicePath = Join-Path $run "measurements\rclone-$id.log"
                [IO.File]::WriteAllLines($slicePath, $slice)
                $trial.rcloneLog = $slicePath
            }

            if (-not $WhatIfOnly) {
                if (Test-Path -LiteralPath $probeJson) {
                    $trial.probe = Get-ProbePhases (Get-Content -LiteralPath $probeJson -Raw | ConvertFrom-Json)
                } else {
                    throw "probe result missing: $probeJson"
                }
                $trial.mpvTimeline = @(Parse-MpvLog $mpvLog)
            }

            if ($def.config -eq 'real' -and $null -ne $trial.userState) {
                $trial.userStateRestore = Restore-BenchUserState (Join-Path $run "measurements\userstate-$id") $trial.userState
            }
        } catch {
            $trial.error = "$_"
            try { if ($debugWasSet) { $null = Set-RcloneLogLevel 'INFO' } } catch { }
            Write-Host "   TRIAL ERROR: $_"
        }
        if ($def.config -eq 'real' -and $null -ne $trial.userState -and $null -eq $trial.userStateRestore) {
            try {
                $trial.userStateRestore = Restore-BenchUserState (Join-Path $run "measurements\userstate-$id") $trial.userState
            } catch {
                $trial.error = "$($trial.error) state-restore: $_"
            }
        }

        $trial.completedUtc = [DateTimeOffset]::UtcNow.ToString('o')
        Write-BenchJson $trialJson $trial
        $matrix.Add([pscustomobject]$trial)
        Write-Host "   -> $trialJson $(if ($trial.error) { 'ERROR' } else { 'ok' })"
        $prevNames = $names
    }
}

Restore-BenchUserScripts

$summary = [ordered]@{
    schemaVersion = 1
    completedUtc = [DateTimeOffset]::UtcNow.ToString('o')
    conditions = $Conditions; kinds = $Kinds; frames = $Frames
    trials = @($matrix)
}
$summaryPath = Join-Path $RunRoot ("vfs-bench-matrix-{0}.json" -f [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
Write-BenchJson $summaryPath $summary
Write-Host "matrix summary: $summaryPath"
