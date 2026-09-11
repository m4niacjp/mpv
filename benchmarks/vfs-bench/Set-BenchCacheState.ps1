#requires -Version 7.4
<#
.SYNOPSIS
Reports or controls the rclone VFS cache state of the benchmark folders.

.DESCRIPTION
mode status: per-file vfsMeta Rs coverage for the chosen folder(s).
mode cold:   deletes the vfs data+metadata files of every entry in the folder
             under the live rclone mount (rclone detects the external removal on
             the next open; requires the 60 s handle grace to have expired) and
             verifies both files are gone.
mode warm:   reads every file in the folder through the mount so the VFS cache
             holds it, then verifies vfsMeta Rs coverage is 100%.

Warm mode is idempotent: files whose flushed Rs coverage is already 100% are
skipped. Pending files are read concurrently (-Parallel), because rclone runs one
sequential chunk stream per file with this mount's --vfs-read-chunk-streams=0.
The on-disk vfsMeta lags the in-memory item until rclone saves it (at latest when
the 60 s handle grace ends), so verification waits -SettleSeconds after the last
handle closes and then polls up to -VerifyTimeoutSeconds. Checking coverage
immediately after the read is a false negative.

Cold and warm are the only cache states used by the benchmark. Reads never purge
other clients' entries. Writes a JSON report under -OutDir.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('status', 'cold', 'warm')][string] $Mode,
    [ValidateSet('Cold', 'Warm')][string] $Folder = 'Cold',
    [int] $Count = 25,
    [string] $Prefix = 'PB',
    [string[]] $Names = @(),
    [string] $OutDir = 'C:\PerfBench\cache-state',
    [string] $Label = '',
    [int] $CoolDownSeconds = 0,
    [int] $ReadBufferMiB = 4,
    [int] $Parallel = 4,
    [int] $SettleSeconds = 75,
    [int] $VerifyTimeoutSeconds = 180
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'VfsBench.psm1') -Force
$cfg = Get-BenchConfig

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$names = if ($Names.Count) { $Names } else { @(Get-BenchNames $Count $Prefix) }
$report = [ordered]@{
    schemaVersion = 1
    mode = $Mode; folder = $Folder; startedUtc = [DateTimeOffset]::UtcNow.ToString('o')
    files = @(); failures = @()
}
$failures = [Collections.Generic.List[string]]::new()

if ($Mode -eq 'cold' -and $CoolDownSeconds -gt 0) {
    Write-Host "cool-down $CoolDownSeconds s (handle grace)"
    Start-Sleep -Seconds $CoolDownSeconds
}

if ($Mode -eq 'warm') {
    # --------------------------------------------------------------- warm mode
    # If a pending file already has cache data, its Rs spans are probably still
    # in memory (flush pending): wait once so the initial census is trustworthy.
    $needSettle = $false
    foreach ($name in $names) {
        $e = Get-BenchCacheEntry $Folder $name
        if ($e.dataExists -and ($null -eq $e.coveragePct -or $e.coveragePct -lt 99.999)) { $needSettle = $true; break }
    }
    if ($needSettle -and $SettleSeconds -gt 0) {
        Write-Host "settle $SettleSeconds s so pending vfsMeta Rs spans flush"
        Start-Sleep -Seconds $SettleSeconds
    }

    $before = @{}
    $pending = [Collections.Generic.List[string]]::new()
    foreach ($name in $names) {
        $e = Get-BenchCacheEntry $Folder $name
        $before[$name] = $e
        if ($null -ne $e.coveragePct -and $e.coveragePct -ge 99.999) { continue }
        $pending.Add($name)
    }
    Write-Host ("warm {0}: {1} covered, {2} to read (-Parallel {3})" -f $Folder, ($names.Count - $pending.Count), $pending.Count, $Parallel)

    $reads = @{}
    if ($pending.Count -gt 0) {
        $mountRoot = Join-Path $cfg.MountRoot $Folder
        $bufBytes = $ReadBufferMiB * 1MB
        $parResults = @($pending | ForEach-Object -Parallel {
            $name = $_
            $path = Join-Path $using:mountRoot $name
            $rec = [ordered]@{ name = $name; readMs = $null; error = $null; ok = $false }
            $sw = [Diagnostics.Stopwatch]::StartNew()
            try {
                if (-not (Test-Path -LiteralPath $path)) { throw "not visible through mount: $path" }
                $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                try {
                    $buf = [byte[]]::new($using:bufBytes)
                    while ($fs.Read($buf, 0, $buf.Length) -gt 0) { }
                } finally { $fs.Dispose() }
                $rec.ok = $true
            } catch {
                $rec.error = "$_"
            }
            $sw.Stop()
            $rec.readMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
            [pscustomobject]$rec
        } -ThrottleLimit $Parallel)
        foreach ($r in $parResults) { $reads[$r.name] = $r }
        foreach ($r in $parResults) {
            if (-not $r.ok) { Write-Host ("  read FAIL {0}: {1}" -f $r.name, $r.error) }
        }
        if ($SettleSeconds -gt 0) {
            Write-Host "settle $SettleSeconds s for vfsMeta flush after reads"
            Start-Sleep -Seconds $SettleSeconds
        }
    }

    # Poll until every name reaches full flushed coverage or the budget expires.
    $deadline = (Get-Date).AddSeconds($VerifyTimeoutSeconds)
    while ($true) {
        $bad = [Collections.Generic.List[string]]::new()
        foreach ($name in $names) {
            $e = Get-BenchCacheEntry $Folder $name
            if ($null -eq $e.coveragePct -or $e.coveragePct -lt 99.999) { $bad.Add($name) }
        }
        if ($bad.Count -eq 0) { break }
        if ((Get-Date) -ge $deadline) { break }
        Start-Sleep -Seconds 10
    }

    foreach ($name in $names) {
        $b = $before[$name]
        $a = Get-BenchCacheEntry $Folder $name
        $read = if ($reads.ContainsKey($name)) { $reads[$name] } else { $null }
        $errorText = $null
        if ($read -and $read.error) {
            $errorText = $read.error
        } elseif ($null -eq $a.coveragePct -or $a.coveragePct -lt 99.999) {
            $errorText = "cache coverage after read is $($a.coveragePct)% (expected 100%)"
        }
        $result = [ordered]@{
            name = $name; action = $(if ($read) { 'read' } else { 'skip' })
            dataExistsBefore = $b.dataExists; metaExistsBefore = $b.metaExists
            coveragePctBefore = $b.coveragePct; dataExistsAfter = $a.dataExists; metaExistsAfter = $a.metaExists
            coveragePctAfter = $a.coveragePct; readMs = $(if ($read) { $read.readMs } else { 0 }); error = $errorText
        }
        if ($errorText) { $failures.Add("$name : $errorText") }
        $report.files += [pscustomobject]$result
        Write-Host ("{0}  {1}  coverage={2}%  {3}  {4}" -f $Folder, $name, $a.coveragePct,
            $(if ($read) { "$($read.readMs) ms" } else { 'skipped' }), $(if ($errorText) { "FAIL $errorText" } else { 'OK' }))
    }
} else {
    # ------------------------------------------------------- cold / status mode
    foreach ($name in $names) {
        $entry = Get-BenchCacheEntry $Folder $name
        $result = [ordered]@{
            name = $name; action = $Mode; dataExistsBefore = $entry.dataExists; metaExistsBefore = $entry.metaExists
            coveragePctBefore = $entry.coveragePct; dataExistsAfter = $null; metaExistsAfter = $null
            coveragePctAfter = $null; readMs = $null; error = $null
        }
        try {
            if ($Mode -eq 'cold') {
                $rel = Join-Path (Join-Path $cfg.RemoteRoot $Folder) $name
                foreach ($p in @((Join-Path $cfg.CacheRoot $rel), (Join-Path $cfg.MetaRoot $rel))) {
                    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
                }
                $after = Get-BenchCacheEntry $Folder $name
                $result.dataExistsAfter = $after.dataExists
                $result.metaExistsAfter = $after.metaExists
                if ($after.dataExists -or $after.metaExists) { throw "cache files still present after reset" }
            } else {
                $result.coveragePctAfter = $entry.coveragePct
            }
        } catch {
            $result.error = "$_"
            $failures.Add("$name : $_")
        }
        $report.files += [pscustomobject]$result
        $state = if ($Mode -eq 'cold') { "data=$($result.dataExistsAfter) meta=$($result.metaExistsAfter)" } else { "coverage=$($result.coveragePctAfter)%" }
        Write-Host ("{0}  {1}  {2}  {3}" -f $Folder, $name, $state, $(if ($result.error) { "FAIL $($result.error)" } else { 'OK' }))
    }
}

$report.completedUtc = [DateTimeOffset]::UtcNow.ToString('o')
$report.failures = @($failures)
$suffix = if ($Label) { "-$Label" } else { '' }
Write-BenchJson (Join-Path $OutDir ("cache-$($Folder.ToLower())-$Mode$suffix.json")) $report
Write-Host ("cache $Mode $Folder done: failures {0}" -f $failures.Count)
if ($failures.Count -gt 0) { exit 1 }
