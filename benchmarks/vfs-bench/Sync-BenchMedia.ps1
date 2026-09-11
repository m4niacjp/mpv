#requires -Version 7.4
<#
.SYNOPSIS
Uploads the verified benchmark corpus to wcrypt:PerformanceBench/{Cold,Warm}
out-of-band, then refreshes the mount's directory cache.

.DESCRIPTION
Uses the verified RC method: operations/copyfile with dstFs='wcrypt:' (the mount
shares this root Fs; a sub-path Fs object fails with S3 CreateBucket) and
dstRemote='PerformanceBench/<Folder>/<name>'. Remote files whose size already
matches are skipped. Pending copies run concurrently (-Parallel, default 6)
because this is a one-time seed before any measurement; every remote size is then
verified via operations/stat and one vfs/refresh -dir makes the files visible
through I:.

Writes an upload manifest JSON under -OutDir. Safe to rerun (size-skip).
#>
[CmdletBinding()]
param(
    [ValidateSet('Cold', 'Warm', 'Both')][string] $Folder = 'Both',
    [string] $StagingDir = 'C:\PerfBench\videos',
    [int] $Count = 25,
    [string] $Prefix = 'PB',
    [string] $OutDir = 'C:\PerfBench\upload',
    [int] $TimeoutSec = 900,
    [int] $Parallel = 6
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'VfsBench.psm1') -Force
$cfg = Get-BenchConfig

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$folders = if ($Folder -eq 'Both') { @('Cold', 'Warm') } else { @($Folder) }

$auth = Get-Content -LiteralPath $cfg.RcAuthPath -Raw | ConvertFrom-Json
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($auth.user):$($auth.pass)"))
$rcHeader = @{ Authorization = "Basic $b64" }

function Get-RemoteSize([string] $FolderName, [string] $Name) {
    try {
        $body = @{ fs = $cfg.RemoteFs; remote = "$($cfg.RemoteRoot)/$FolderName/$Name" } | ConvertTo-Json -Compress
        $r = Invoke-RestMethod -Uri "$($cfg.RcUrl)/operations/stat" -Headers $rcHeader -Method Post `
            -ContentType 'application/json' -Body $body -TimeoutSec 60
        if ($r.item) { return [long]$r.item.Size }
        return -1
    } catch {
        return -1
    }
}

$results = [Collections.Generic.List[object]]::new()
$pending = [Collections.Generic.List[object]]::new()

# Phase 1: size-skip already uploaded files.
foreach ($f in $folders) {
    foreach ($i in 1..$Count) {
        $name = '{0}{1:D2}.mkv' -f $Prefix, $i
        $local = Join-Path $StagingDir $name
        if (-not (Test-Path -LiteralPath $local)) { throw "missing local file: $local" }
        $size = (Get-Item -LiteralPath $local).Length
        $before = Get-RemoteSize $f $name
        if ($before -eq $size) {
            $results.Add([pscustomobject]@{
                folder = $f; name = $name; localSize = $size; remoteSizeBefore = $before
                remoteSizeAfter = $before; skipped = $true; uploaded = $false
                seconds = 0; error = $null; ok = $true
            })
            Write-Host ("{0}/{1}  OK  skip (size match)" -f $f, $name)
        } else {
            $pending.Add([pscustomobject]@{ folder = $f; name = $name; local = $local; size = $size })
        }
    }
}

# Phase 2: concurrent uploads of the pending files.
Write-Host ("uploading {0} pending files with -Parallel {1}" -f $pending.Count, $Parallel)
$parResults = @()
if ($pending.Count -gt 0) {
    $parResults = @($pending | ForEach-Object -Parallel {
        $job = $_
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $rec = [ordered]@{
            folder = $job.folder; name = $job.name; localSize = $job.size; remoteSizeBefore = $null
            remoteSizeAfter = $null; skipped = $false; uploaded = $true; seconds = $null
            error = $null; ok = $false
        }
        try {
            $body = @{
                srcFs = $using:StagingDir; srcRemote = $job.name
                dstFs = $using:cfg.RemoteFs; dstRemote = "$($using:cfg.RemoteRoot)/$($job.folder)/$($job.name)"
            } | ConvertTo-Json -Compress
            $null = Invoke-RestMethod -Uri "$($using:cfg.RcUrl)/operations/copyfile" -Headers $using:rcHeader `
                -Method Post -ContentType 'application/json' -Body $body -TimeoutSec $using:TimeoutSec
            $st = Invoke-RestMethod -Uri "$($using:cfg.RcUrl)/operations/stat" -Headers $using:rcHeader `
                -Method Post -ContentType 'application/json' `
                -Body (@{ fs = $using:cfg.RemoteFs; remote = "$($using:cfg.RemoteRoot)/$($job.folder)/$($job.name)" } | ConvertTo-Json -Compress) `
                -TimeoutSec 60
            $after = [long]$st.item.Size
            $rec.remoteSizeAfter = $after
            if ($after -ne $job.size) { throw "remote size $after != local $($job.size)" }
            $rec.ok = $true
        } catch {
            $rec.error = "$_"
        }
        $sw.Stop()
        $rec.seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        [pscustomobject]$rec
    } -ThrottleLimit $Parallel)
}
foreach ($r in $parResults) {
    $results.Add($r)
    Write-Host ("{0}/{1}  {2}  {3}s  {4}" -f $r.folder, $r.name, $(if ($r.ok) { 'OK  uploaded' } else { 'FAIL' }), $r.seconds, $r.error)
}

$failed = @($results | Where-Object { -not $_.ok }).Count
if ($failed -eq 0) {
    # Refresh the VFS root first: with --dir-cache-time 72h, a direct subdir
    # refresh fails with "file does not exist" until the root listing is re-read.
    $null = Invoke-BenchRc 'vfs/refresh' @{} -TimeoutSec 300
    $null = Invoke-BenchRc 'vfs/refresh' @{ dir = $cfg.RemoteRoot; recursive = 'true' } -TimeoutSec 600
    Write-Host "vfs/refresh $($cfg.RemoteRoot) done"
}

$summary = [ordered]@{
    schemaVersion = 2
    completedUtc = [DateTimeOffset]::UtcNow.ToString('o')
    folders = $folders
    count = $Count
    parallel = $Parallel
    pendingAtStart = $pending.Count
    failed = $failed
    files = @($results | Sort-Object folder, name)
}
Write-BenchJson (Join-Path $OutDir 'upload-manifest.json') $summary
Write-Host ("upload finished: failed {0}; summary {1}" -f $failed, (Join-Path $OutDir 'upload-manifest.json'))
if ($failed -gt 0) { exit 1 }
