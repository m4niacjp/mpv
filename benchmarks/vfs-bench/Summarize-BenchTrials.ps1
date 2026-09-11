#requires -Version 7.4
<#
.SYNOPSIS
Summarizes the mpv rclone-VFS benchmark trial matrix into per-trial metrics and
a per-condition aggregate.

.DESCRIPTION
Reads a matrix summary produced by Invoke-BenchTrials.ps1 (or discovers the
newest one under -RunRoot), then for every trial loads the trial JSON, the raw
probe JSON, and the mpv log to compute:

  openToFirstFrame1   first presented frame - 'Opening done' (file 1)
  nextToFirstFrame2   first presented frame of file 2 - probe cmd-playlist-next
  restart1/restart2   playback-restart times (mp clock)
  nextAttempts        probe playlist-next attempts
  prefetch            max prefetched-count, prefetch-active seen, playlist
                      snapshot flags at before-next
  backend             rclone core/stats deltas sampled by the plain runner

Writes summarize-trials.csv and summarize-conditions.json under -OutDir.
This is descriptive only; the report must judge causality with the traced data.
#>
[CmdletBinding()]
param(
    [string] $RunRoot = 'C:\Users\andre\PerfRuns',
    [string] $MatrixPath = '',
    [string] $OutDir = 'C:\PerfBench\analysis'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'VfsBench.psm1') -Force

if (-not $MatrixPath) {
    $m = Get-ChildItem -LiteralPath $RunRoot -File -Filter 'vfs-bench-matrix-*.json' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $m) { throw "no matrix summary under $RunRoot" }
    $MatrixPath = $m.FullName
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$matrix = Get-Content -LiteralPath $MatrixPath -Raw | ConvertFrom-Json

function Get-LogTimes([string] $LogPath, [string] $Needle) {
    # The leading comma prevents PowerShell from unrolling a one-element array
    # into a scalar: a scalar double has no .Count under Set-StrictMode.
    $times = [Collections.Generic.List[double]]::new()
    if (-not (Test-Path -LiteralPath $LogPath)) { return ,@() }
    foreach ($line in Get-Content -LiteralPath $LogPath -ErrorAction SilentlyContinue) {
        if ($line.Contains($Needle) -and $line -match '^\[\s*([0-9]+\.[0-9]+)\]') {
            $times.Add([double]$Matches[1])
        }
    }
    , @($times)
}

$rows = [Collections.Generic.List[object]]::new()
foreach ($t in $matrix.trials) {
    $row = [ordered]@{
        id = $t.id; condition = $t.condition; kind = $t.kind; base = $t.base
        error = $t.error
        wallSec = $null; openToFirstFrame1 = $null; nextToFirstFrame2 = $null
        firstFrame1T = $null; firstFrame2T = $null; openingDone1T = $null; autocreateT = $null
        restart1 = $null; restart2 = $null; nextAttempts = $null
        maxPrefetched = $null; sawPrefetchActive = $null; playlistAtNext = $null
        prefetchedAtNext = $null; backendDeltaMB = $null; exitCode = $null
    }
    try {
        if ($t.error) { throw "trial error: $($t.error)" }
        if ($null -ne $t.probe) {
            $row.restart1 = $t.probe.tPlaybackRestart1
            $row.restart2 = $t.probe.tPlaybackRestart2
            $row.nextAttempts = $t.probe.nextAttempts
        }
        if ($null -ne $t.result) {
            # Traced results hold { kind; capture } without the plain-runner
            # fields, so probe for each property instead of reading it blind.
            if ($t.result.PSObject.Properties['wallSec']) { $row.wallSec = $t.result.wallSec }
            if ($t.result.PSObject.Properties['exitCode']) { $row.exitCode = $t.result.exitCode }
            if ($t.result.PSObject.Properties['backend'] -and $null -ne $t.result.backend) {
                $row.backendDeltaMB = [math]::Round([double]$t.result.backend.deltaBytes / 1MB, 2)
            }
        }
        $probePath = if ($t.probeJson) { $t.probeJson } else { Join-Path (Join-Path $t.runDir 'measurements') "probe-$($t.id).json" }
        if (Test-Path -LiteralPath $probePath) {
            $raw = Get-Content -LiteralPath $probePath -Raw | ConvertFrom-Json
            $prefetchActive = @($raw.samples | Where-Object { $_.prefetch_active -eq $true }).Count
            $row.sawPrefetchActive = ($prefetchActive -gt 0)
            $counts = @($raw.samples | ForEach-Object { $_.prefetched_count } | Where-Object { $null -ne $_ })
            if ($counts.Count) { $row.maxPrefetched = ($counts | Measure-Object -Maximum).Maximum }
            $snap = $raw.playlists | Where-Object { $_.tag -eq 'before-next' } | Select-Object -First 1
            if ($snap) {
                $row.playlistAtNext = $snap.count
                $row.prefetchedAtNext = @($snap.entries | Where-Object { $_.prefetched -eq $true }).Count
            }
        }
        $frames = Get-LogTimes $t.mpvLog 'first video frame after restart shown'
        $opens = Get-LogTimes $t.mpvLog 'Opening done:'
        $autocreate = Get-LogTimes $t.mpvLog 'Autocreate playlist:'
        if ($frames.Count -ge 1) { $row.firstFrame1T = $frames[0] }
        if ($frames.Count -ge 2) { $row.firstFrame2T = $frames[1] }
        if ($opens.Count -ge 1) { $row.openingDone1T = $opens[0] }
        if ($autocreate.Count -ge 1) { $row.autocreateT = $autocreate[0] }
        if ($frames.Count -ge 1 -and $opens.Count -ge 1) { $row.openToFirstFrame1 = [math]::Round($frames[0] - $opens[0], 3) }
        if ($frames.Count -ge 2 -and $null -ne $t.probe.tNext) { $row.nextToFirstFrame2 = [math]::Round($frames[1] - $t.probe.tNext, 3) }
    } catch {
        $row.error = "$($row.error) $($_)".Trim()
    }
    $rows.Add([pscustomobject]$row)
}

$csvPath = Join-Path $OutDir 'summarize-trials.csv'
$rows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8

$conditions = [Collections.Generic.List[object]]::new()
foreach ($g in ($rows | Group-Object condition)) {
    foreach ($k in ($g.Group | Group-Object kind)) {
        $plain = @($k.Group | Where-Object { $_.kind -eq 'plain' -and $null -ne $_.openToFirstFrame1 })
        $nexts = @($k.Group | Where-Object { $null -ne $_.nextToFirstFrame2 })
        # Measure-Object on an empty pipeline returns no object; .Maximum would
        # throw under Set-StrictMode (fixed 2026-09-12).
        $mf = @($k.Group | Where-Object { $null -ne $_.maxPrefetched })
        $conditions.Add([pscustomobject]@{
            condition = $g.Name; kind = $k.Name; n = $k.Count
            openToFirstFrame1 = if ($plain.Count) {
                [pscustomobject]@{
                    n = $plain.Count; min = ($plain.openToFirstFrame1 | Measure-Object -Minimum).Minimum
                    median = ($plain.openToFirstFrame1 | Sort-Object)[[int][math]::Floor($plain.Count / 2)]
                    max = ($plain.openToFirstFrame1 | Measure-Object -Maximum).Maximum
                }
            } else { $null }
            nextToFirstFrame2 = if ($nexts.Count) {
                [pscustomobject]@{
                    n = $nexts.Count; min = ($nexts.nextToFirstFrame2 | Measure-Object -Minimum).Minimum
                    median = ($nexts.nextToFirstFrame2 | Sort-Object)[[int][math]::Floor($nexts.Count / 2)]
                    max = ($nexts.nextToFirstFrame2 | Measure-Object -Maximum).Maximum
                }
            } else { $null }
            errors = @($k.Group | Where-Object { $_.error }).Count
            maxPrefetched = if ($mf.Count) { ($mf | Measure-Object -Property maxPrefetched -Maximum).Maximum } else { $null }
        })
    }
}
$condPath = Join-Path $OutDir 'summarize-conditions.json'
Write-BenchJson $condPath ([ordered]@{ schemaVersion = 1; matrix = $MatrixPath; conditions = @($conditions) })
Write-Host "trial rows: $csvPath"
Write-Host "condition aggregates: $condPath"
$conditions | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
