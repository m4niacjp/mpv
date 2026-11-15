#requires -Version 7.4
<#
.SYNOPSIS
Runs the local live checks against a deployed mpv binary and gates the result.

.DESCRIPTION
Three stages, each with machine-checked pass criteria:

  harness  Every Roaming tests\*-regression.lua must exit 0, print a PASS:
           line and print no FAIL:/FAILURES: line.
  rtx      The two-entry D3D11 RTX render warmup probe (d3d11vpp
           nvidia-true-hdr, fresh shader cache, MPV_RENDER_WARMUP_TRACE).
           Requires a verified worker thread, an imported hardware frame,
           rendered=1, stale=0, both files reaching the frame target and no
           error log lines.
  mount    Invoke-QuickPlaylistTrace.ps1 on the live config and mount.
           Requires the 7-start/6-command protocol, a normal exit, hardware
           decoding for every first frame and at least one prefetch
           adoption. Latency, CPU and I/O are recorded but never gated: VFS
           and OS cache state are uncontrolled. With -BaselineExe the
           candidate and baseline runs are interleaved for an A/B; baseline
           results are informational and never fail the run.

Writes summary.json and summary.md under -OutDir and exits 1 when any gated
check fails. Nothing is deleted and no cache is cleared.

.EXAMPLE
pwsh benchmarks\vfs-bench\Invoke-LiveChecks.ps1 -BaselineExe dist\mpv_bck.exe
#>
[CmdletBinding()]
param(
    # Binary under test. Default: the main checkout's dist\mpv.exe.
    [string]$Exe,
    # Optional previous binary for an interleaved mount A/B.
    [string]$BaselineExe,
    # New directory for all evidence. Default: measurements\live-checks-<time>.
    [string]$OutDir,
    [ValidateSet('harness', 'rtx', 'mount')][string[]]$Stages = @('harness', 'rtx', 'mount'),
    [string]$RoamingDir = (Join-Path $env:APPDATA 'mpv'),
    [string]$MountFolder = 'X:\XXX\Best',
    # Short test video for the RTX probe. Default: build\test\samples\video.mkv.
    [string]$Sample,
    [ValidateRange(1, 10)][int]$MountRuns = 2,
    [ValidateRange(1, 60)][int]$HoldSeconds = 3,
    # Error log lines matching this are known and reported, not counted.
    [string]$KnownErrorPattern = 'scripts[\\/]__pycache__'
)
$ErrorActionPreference = 'Stop'

$worktreeRoot = (git -C $PSScriptRoot rev-parse --show-toplevel).Trim()
$mainRoot = Split-Path (git -C $PSScriptRoot rev-parse --path-format=absolute --git-common-dir).Trim() -Parent
$worktreeRoot = [IO.Path]::GetFullPath($worktreeRoot)
$mainRoot = [IO.Path]::GetFullPath($mainRoot)

function Resolve-Exe([string]$path, [string]$what) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "$what not found: $path" }
    (Resolve-Path -LiteralPath $path).Path
}
if (-not $Exe) { $Exe = Join-Path $mainRoot 'dist\mpv.exe' }
$Exe = Resolve-Exe $Exe 'mpv binary'
if ($BaselineExe) { $BaselineExe = Resolve-Exe $BaselineExe 'baseline binary' }
if (-not $OutDir) {
    $OutDir = Join-Path $mainRoot ('measurements\live-checks-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
if (Test-Path -LiteralPath $OutDir) { throw "Use a new output directory: $OutDir" }
if (Get-Process -Name mpv -ErrorAction SilentlyContinue) { throw 'Close existing mpv before testing.' }
$OutDir = (New-Item -ItemType Directory -Path $OutDir).FullName

$checks = [Collections.Generic.List[object]]::new()
$metrics = [ordered]@{}

function Add-Check([string]$stage, [string]$name, [bool]$ok, [string]$detail = '', [bool]$gated = $true) {
    $checks.Add([pscustomobject]@{ stage = $stage; name = $name; passed = $ok; gated = $gated; detail = $detail })
    $mark = if ($ok) { 'PASS' } elseif ($gated) { 'FAIL' } else { 'info' }
    Write-Host ("  [{0}] {1,-8} {2}{3}" -f $mark, $stage, $name, $(if ($detail) { " - $detail" } else { '' }))
}

function Invoke-Mpv([string]$exe, [string[]]$arguments, [hashtable]$environment = @{}, [int]$timeoutSec = 120) {
    $info = [Diagnostics.ProcessStartInfo]::new($exe)
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    # MSYS2 shells export a PWD that does not match the process directory.
    [void]$info.Environment.Remove('PWD')
    foreach ($k in $environment.Keys) { $info.Environment[$k] = $environment[$k] }
    foreach ($a in $arguments) { $info.ArgumentList.Add($a) }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $p = [Diagnostics.Process]::Start($info)
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEndAsync()
    # The deployed mpv.exe is GUI-subsystem: wait on the process, not the pipe.
    $timedOut = -not $p.WaitForExit($timeoutSec * 1000)
    if ($timedOut) { $p.Kill($true); [void]$p.WaitForExit(5000) }
    $p.WaitForExit()
    [pscustomobject]@{
        exitCode = if ($timedOut) { $null } else { $p.ExitCode }
        timedOut = $timedOut
        seconds  = [math]::Round($watch.Elapsed.TotalSeconds, 3)
        stdout   = $out.GetAwaiter().GetResult()
        stderr   = $err.GetAwaiter().GetResult()
    }
}

function Get-ErrorLines([string]$logPath) {
    if (-not (Test-Path -LiteralPath $logPath)) { return @() }
    @(Select-String -LiteralPath $logPath -Pattern '\]\[e\]\[' | ForEach-Object Line)
}

function Get-Median([double[]]$values) {
    $s = @($values | Sort-Object)
    if (-not $s.Count) { return $null }
    $m = [int][math]::Floor($s.Count / 2)
    if ($s.Count % 2) { $s[$m] } else { ($s[$m - 1] + $s[$m]) / 2 }
}

Write-Host "Live checks: $Exe"
Write-Host "Evidence:    $OutDir"
$metrics.exe = $Exe
$metrics.exeSha256 = (Get-FileHash -LiteralPath $Exe).Hash
$ver = Invoke-Mpv $Exe @('--no-config', '--version') -timeoutSec 30
$metrics.version = ($ver.stdout -split "`r?`n" | Select-Object -First 1)
Write-Host "Version:     $($metrics.version)"
if ($BaselineExe) {
    $metrics.baselineExe = $BaselineExe
    $metrics.baselineSha256 = (Get-FileHash -LiteralPath $BaselineExe).Hash
}

# --- harness ---------------------------------------------------------------
if ('harness' -in $Stages) {
    Write-Host 'Stage harness'
    $dir = (New-Item -ItemType Directory -Path (Join-Path $OutDir 'harness')).FullName
    $tests = @(Get-ChildItem -LiteralPath (Join-Path $RoamingDir 'tests') -Filter '*-regression.lua' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    Add-Check 'harness' 'discovered' ($tests.Count -gt 0) "$($tests.Count) harness(es) in $RoamingDir\tests"
    $metrics.harness = [ordered]@{}
    foreach ($t in $tests) {
        $r = Invoke-Mpv $Exe @('--no-config', '--load-scripts=no', '--vo=null', '--ao=null', '--idle=yes', "--script=$($t.FullName)")
        $text = $r.stdout + "`n" + $r.stderr
        Set-Content -LiteralPath (Join-Path $dir ($t.BaseName + '.txt')) -Value $text
        $pass = $text -match '\bPASS:'
        $fail = $text -match '\bFAIL(URES)?:'
        $ok = -not $r.timedOut -and $r.exitCode -eq 0 -and $pass -and -not $fail
        $why = if ($r.timedOut) { 'timed out' } else { "exit=$($r.exitCode) pass=$pass fail=$fail $($r.seconds)s" }
        Add-Check 'harness' $t.BaseName $ok $why
        $metrics.harness[$t.BaseName] = [ordered]@{ exitCode = $r.exitCode; seconds = $r.seconds; passed = $ok }
    }
}

# --- rtx -------------------------------------------------------------------
if ('rtx' -in $Stages) {
    Write-Host 'Stage rtx'
    if (-not $Sample) {
        $Sample = @((Join-Path $worktreeRoot 'build\test\samples\video.mkv'),
                    (Join-Path $mainRoot 'build\test\samples\video.mkv')) |
            Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    }
    if (-not $Sample -or -not (Test-Path -LiteralPath $Sample)) {
        Add-Check 'rtx' 'sample' $false 'no build\test\samples\video.mkv; run the Meson suite once or pass -Sample'
    } else {
        $dir = (New-Item -ItemType Directory -Path (Join-Path $OutDir 'rtx-warmup')).FullName
        $cache = (New-Item -ItemType Directory -Path (Join-Path $dir 'shader-cache')).FullName
        $log = Join-Path $dir 'mpv.log'
        $result = Join-Path $dir 'result.json'
        $a = @('--no-config', '--load-scripts=no', '--vo=gpu-next', '--gpu-api=d3d11', '--gpu-context=d3d11',
               '--hwdec=d3d11va', '--vf=d3d11vpp=scale=1.1:nvidia-true-hdr=yes', '--hdr-reference-white=auto',
               '--prefetch-playlist=yes', '--prefetch-playlist-max=1', '--prefetch-playlist-on-cache=no',
               '--prefetch-playlist-render=yes', '--prefetch-playlist-start-secs=0',
               '--prefetch-playlist-start-bytes=0', '--cache=yes', "--gpu-shader-cache-dir=$cache",
               '--msg-level=all=v', "--log-file=$log",
               ('--script=' + (Join-Path $PSScriptRoot 'bench-probe.lua')),
               "--script-opts=benchprobe-out=$result,benchprobe-frames=35,benchprobe-timeout=25",
               $Sample, $Sample)
        $r = Invoke-Mpv $Exe $a @{ MPV_RENDER_WARMUP_TRACE = '1' } 60
        Set-Content -LiteralPath (Join-Path $dir 'stdout.txt') -Value $r.stdout
        Set-Content -LiteralPath (Join-Path $dir 'stderr.txt') -Value $r.stderr
        Add-Check 'rtx' 'exit' (-not $r.timedOut -and $r.exitCode -eq 0) $(if ($r.timedOut) { 'timed out' } else { "exit=$($r.exitCode) $($r.seconds)s" })
        $text = if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Raw } else { '' }
        Add-Check 'rtx' 'worker priority verified' ($text -match 'event=worker-thread\b[^\r\n]*\bverified=1\b')
        $frame = [regex]::Match($text, 'event=worker-frame\b[^\r\n]*\bw=(\d+) h=(\d+) format=(\S+) subformat=(\S+)')
        Add-Check 'rtx' 'hardware frame imported' ($frame.Success -and $frame.Groups[3].Value -eq 'd3d11') $(if ($frame.Success) { "$($frame.Groups[1].Value)x$($frame.Groups[2].Value) $($frame.Groups[3].Value)[$($frame.Groups[4].Value)]" } else { 'no worker-frame event' })
        $planes = [regex]::Match($text, 'event=renderer-end rendered=(\d) reason=(\S+) imported_planes=(\d+)')
        Add-Check 'rtx' 'rendered' ($planes.Success -and $planes.Groups[1].Value -eq '1' -and [int]$planes.Groups[3].Value -ge 1) $(if ($planes.Success) { "rendered=$($planes.Groups[1].Value) reason=$($planes.Groups[2].Value) imported_planes=$($planes.Groups[3].Value)" } else { 'no renderer-end event' })
        $end = [regex]::Match($text, 'event=worker-end\b[^\r\n]*\brendered=(\d) stale=(\d)[^\r\n]*\bwall_ms=([\d.]+)')
        Add-Check 'rtx' 'not stale' ($end.Success -and $end.Groups[1].Value -eq '1' -and $end.Groups[2].Value -eq '0') $(if ($end.Success) { "stale=$($end.Groups[2].Value) wall_ms=$($end.Groups[3].Value)" } else { 'no worker-end event' })
        $reached = 0
        if (Test-Path -LiteralPath $result) {
            $reached = @((Get-Content -LiteralPath $result -Raw | ConvertFrom-Json).events | Where-Object name -eq 'frames-reached').Count
        }
        Add-Check 'rtx' 'both files reached 35 frames' ($reached -eq 2) "frames-reached=$reached"
        $errors = Get-ErrorLines $log
        Add-Check 'rtx' 'no error log lines' ($errors.Count -eq 0) $(if ($errors.Count) { $errors[0] } else { '' })
        $metrics.rtx = [ordered]@{
            sample = $Sample
            workerWallMs = if ($end.Success) { [double]$end.Groups[3].Value } else { $null }
            seconds = $r.seconds
        }
    }
}

# --- mount -----------------------------------------------------------------
if ('mount' -in $Stages) {
    Write-Host 'Stage mount'
    if (-not (Test-Path -LiteralPath $MountFolder -PathType Container)) {
        Add-Check 'mount' 'folder available' $false "$MountFolder is not reachable"
    } else {
        $trace = Join-Path $PSScriptRoot 'Invoke-QuickPlaylistTrace.ps1'
        $plan = foreach ($i in 1..$MountRuns) {
            [pscustomobject]@{ label = 'candidate'; exe = $Exe; i = $i }
            if ($BaselineExe) { [pscustomobject]@{ label = 'baseline'; exe = $BaselineExe; i = $i } }
        }
        $runs = [Collections.Generic.List[object]]::new()
        foreach ($step in $plan) {
            $runDir = Join-Path $OutDir "mount-$($step.label)-$($step.i)"
            $gated = $step.label -eq 'candidate'
            $stage = if ($gated) { 'mount' } else { 'baseline' }
            $name = "run $($step.i)"
            Remove-Item Env:PWD -ErrorAction SilentlyContinue
            $traceError = $null
            try {
                & $trace -Folder $MountFolder -OutDir $runDir -HoldSeconds $HoldSeconds -TraceShutdown -Exe $step.exe *>&1 |
                    Set-Content -LiteralPath "$runDir.trace.txt"
            } catch { $traceError = $_.Exception.Message }
            Add-Check $stage "$name protocol" (-not $traceError) $(if ($traceError) { $traceError } else { '7 starts, 6/6 commands, normal exit' }) $gated
            if (-not (Test-Path -LiteralPath (Join-Path $runDir 'events.jsonl'))) { continue }

            $events = @(Get-Content -LiteralPath (Join-Path $runDir 'events.jsonl') | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
            $run = Get-Content -LiteralPath (Join-Path $runDir 'run.json') -Raw | ConvertFrom-Json
            $log = Join-Path $runDir 'mpv.log'
            $firstFrames = @($events | Where-Object name -eq 'first-frame' | ForEach-Object { [double]$_.t })
            $latencies = @($events | Where-Object name -eq 'next-command' | ForEach-Object {
                $c = [double]$_.t
                $next = @($firstFrames | Where-Object { $_ -gt $c } | Sort-Object | Select-Object -First 1)
                if ($next.Count) { [math]::Round($next[0] - $c, 3) }
            })
            $hw = @(Select-String -LiteralPath $log -Pattern 'Using hardware decoding \(' -ErrorAction SilentlyContinue).Count
            $full = @(Select-String -LiteralPath $log -SimpleMatch 'Using prefetched URL.' -ErrorAction SilentlyContinue).Count
            $partial = @(Select-String -LiteralPath $log -SimpleMatch 'Using prefetched/prefetching URL.' -ErrorAction SilentlyContinue).Count
            $errors = @(Get-ErrorLines $log)
            $unknown = @($errors | Where-Object { $_ -notmatch $KnownErrorPattern })

            Add-Check $stage "$name hardware decoding" ($firstFrames.Count -gt 0 -and $hw -ge $firstFrames.Count) "$hw of $($firstFrames.Count) first frames" $gated
            Add-Check $stage "$name prefetch adoption" (($full + $partial) -ge 1) "full=$full partial=$partial of $($latencies.Count) transitions" $gated
            # Live-config errors vary with scripts and media; list them without gating.
            Add-Check $stage "$name unknown error lines" ($unknown.Count -eq 0) $(if ($unknown.Count) { "$($unknown.Count): $($unknown[0])" } else { "known=$($errors.Count - $unknown.Count)" }) $false

            $runs.Add([pscustomobject]@{
                label = $step.label; i = $step.i; dir = $runDir
                firstOpen = if ($firstFrames.Count) { [math]::Round(($firstFrames | Measure-Object -Minimum).Minimum, 3) } else { $null }
                latencies = $latencies
                adoptedFull = $full; adoptedPartial = $partial
                cpuSec = [math]::Round([double]$run.final.cpuSec, 2)
                readMB = [math]::Round([double]$run.final.readBytes / 1e6, 1)
                elapsedSec = [math]::Round([double]$run.elapsedSec, 2)
            })
        }
        $metrics.mount = [ordered]@{ folder = $MountFolder; runs = $runs; byLabel = [ordered]@{} }
        foreach ($g in ($runs | Group-Object label)) {
            $all = @($g.Group | ForEach-Object { $_.latencies } | ForEach-Object { [double]$_ })
            $metrics.mount.byLabel[$g.Name] = [ordered]@{
                runs = $g.Count
                medianTransitionSec = Get-Median $all
                maxTransitionSec = if ($all.Count) { ($all | Measure-Object -Maximum).Maximum } else { $null }
                medianFirstOpenSec = Get-Median @($g.Group | ForEach-Object { [double]$_.firstOpen })
                adoptedFull = ($g.Group | Measure-Object adoptedFull -Sum).Sum
                adoptedPartial = ($g.Group | Measure-Object adoptedPartial -Sum).Sum
                transitions = $all.Count
            }
        }
    }
}

# --- summary ---------------------------------------------------------------
$failed = @($checks | Where-Object { $_.gated -and -not $_.passed })
$summary = [ordered]@{
    utc = [DateTime]::UtcNow.ToString('o')
    passed = $failed.Count -eq 0
    stages = $Stages
    metrics = $metrics
    checks = $checks
}
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutDir 'summary.json')

$md = [Collections.Generic.List[string]]::new()
$md.Add("# Live checks: $(if ($summary.passed) { 'PASS' } else { 'FAIL' })")
$md.Add('')
$md.Add("- Binary: ``$Exe`` ($($metrics.version))")
if ($BaselineExe) { $md.Add("- Baseline: ``$BaselineExe``") }
$md.Add("- Evidence: ``$OutDir``")
$md.Add('')
$md.Add('| Stage | Check | Result | Detail |')
$md.Add('| --- | --- | --- | --- |')
foreach ($c in $checks) {
    $res = if ($c.passed) { 'pass' } elseif ($c.gated) { '**FAIL**' } else { 'info' }
    $md.Add("| $($c.stage) | $($c.name) | $res | $($c.detail -replace '\|', '/') |")
}
if ($metrics.Contains('mount')) {
    $md.Add('')
    $md.Add('Mount timings are uncontrolled smoke data, not a performance result.')
    $md.Add('')
    $md.Add('| Binary | Runs | Median transition s | Max s | Median first open s | Adopted full/partial |')
    $md.Add('| --- | --- | --- | --- | --- | --- |')
    foreach ($k in $metrics.mount.byLabel.Keys) {
        $b = $metrics.mount.byLabel[$k]
        $md.Add("| $k | $($b.runs) | $($b.medianTransitionSec) | $($b.maxTransitionSec) | $($b.medianFirstOpenSec) | $($b.adoptedFull)/$($b.adoptedPartial) of $($b.transitions) |")
    }
}
$md | Set-Content -LiteralPath (Join-Path $OutDir 'summary.md')

Write-Host ''
Write-Host $(if ($summary.passed) { 'RESULT: PASS' } else { "RESULT: FAIL ($($failed.Count) gated check(s))" })
Write-Host "Summary: $(Join-Path $OutDir 'summary.md')"
exit $(if ($summary.passed) { 0 } else { 1 })
