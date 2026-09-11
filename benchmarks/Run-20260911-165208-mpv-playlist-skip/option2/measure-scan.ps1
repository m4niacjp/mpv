#requires -Version 7.4
<#
.SYNOPSIS
Quantifies the autocreate-playlist directory scan from a Process Monitor CSV.

.DESCRIPTION
Streams a Procmon CSV (raw export or pre-filtered) and reports, for the
autocreate worker thread:

  * entryAttributeOpens - CreateFile rows with "Desired Access: Read
    Attributes" for entries under the media root (mp_stat()'s
    CreateFileW(FILE_READ_ATTRIBUTES) on Windows). This is the metric
    Option 2 must drive to 0.
  * dirAttributeOpens  - the same for the directory path itself
    (normally <= 1).
  * queryOps           - Query* rows under the root (~5 per stat'd entry:
    QueryBasic/Standard/Id/All/Volume/DeviceInformation).
  * listOpen           - CreateFile "Read Data/List Directory" of the root,
    i.e. the opendir of the scan.
  * scanWindow         - first..last row time on the worker TID, and its
    duration.
  * log                - when -MpvLog is given, the mpv log interval
    "Opening done:" -> "Autocreate playlist: N siblings." plus N.

The scan thread is discovered structurally: among CreateFile
"Read Data/List Directory" opens of a marker directory, the TID with the most
child attribute opens inside -MaxScanWindowSec wins. -ScanTid overrides this.

The toolchain for the capture is the windows-performance-debugging skill:
  Invoke-ProcmonCapture.ps1 -RunDirectory <run> -Executable pwsh.exe `
      -ArgumentList @(...loadfile the media file...) -TimeoutSeconds 120 `
      -ConfigPath <skill>\assets\procmon-duration-tid.pmc -SettleSeconds 3
It needs an elevated session, an accepted Procmon EULA, and exports the PML
with Duration and TID columns. Raw exports are 10x smaller after applying
Filter-ProcmonCsv.ps1, but this script streams either form.

.PARAMETER FilteredCsv
Path to the exported Procmon CSV (columns: Time of Day, Process Name, PID,
Operation, Path, Result, Detail, Duration, TID).

.PARAMETER PathMarkers
Media root directories exactly as they appear in the CSV (on rclone WinFsp
mounts this is usually the resolved UNC path, not the drive letter), for
example '\\server\RcloneWcrypt\<share>\<dir>'. Repeat for multiple roots.

.PARAMETER MpvLog
Optional mpv log written with --log-file and --msg-time=yes. Enables the
"Opening done" -> "Autocreate playlist" cross-check and the scanned-entry
count from the verbose sibling log line.

.PARAMETER Baseline
Record a pre-Option-2 capture: metrics are reported but the post-fix
thresholds are not applied (only the structural capture checks must pass).
Exit code is 0 unless the capture could not be interpreted.

.EXAMPLE
# After the fix (must pass):
pwsh -File measure-scan.ps1 -FilteredCsv $run\exports\procmon-<id>.csv `
    -PathMarkers '\\server\RcloneWcrypt\<share>\<dir>' `
    -MpvLog $run\measurements\mpv-t0.log `
    -OutJson $run\measurements\scan-after.json

.EXAMPLE
# Before the fix (record only):
pwsh -File measure-scan.ps1 -FilteredCsv $run\exports\procmon-<id>.csv `
    -PathMarkers '\\server\RcloneWcrypt\<share>\<dir>' -Baseline `
    -OutJson $run\measurements\scan-before.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $FilteredCsv,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]] $PathMarkers,
    [ValidateNotNullOrEmpty()][string] $ProcessName = 'mpv.exe',
    [ValidateRange(0, [int]::MaxValue)][int] $MpvPid = 0,
    [ValidateNotNullOrEmpty()][string] $MpvLog,
    [ValidateRange(0, [int]::MaxValue)][int] $ScanTid = 0,
    [ValidateNotNullOrEmpty()][string] $OutJson,
    [ValidateRange(1, 100000)][int] $MinScannedEntries = 10,
    [ValidateRange(0, 100000)][int] $MaxEntryAttributeOpens = 0,
    [ValidateRange(0.0, 600.0)][double] $MaxAttributeOpenSec = 0.05,
    [ValidateRange(0, 100000)][int] $MaxQueryOps = 5,
    [ValidateRange(1.0, 600.0)][double] $MaxScanWindowSec = 60.0,
    [ValidateRange(1, 100)][int] $TopLongest = 10,
    [switch] $Baseline
)
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$csvPath = (Resolve-Path -LiteralPath $FilteredCsv).ProviderPath
if (-not [IO.File]::Exists($csvPath))
    { throw "FilteredCsv does not exist: $FilteredCsv" }
$markers = @($PathMarkers | ForEach-Object { $_.TrimEnd('\', '/') } | Where-Object { $_ })
if ($markers.Count -eq 0)
    { throw 'PathMarkers must contain at least one non-empty directory path.' }
if ($MpvLog -and -not [IO.File]::Exists($MpvLog))
    { throw "MpvLog does not exist: $MpvLog" }

function Test-PathRelation([string] $Path, [string] $Marker) {
    if ($Path.Equals($Marker, [StringComparison]::OrdinalIgnoreCase)) { return 'self' }
    if ($Path.StartsWith($Marker + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $Path.StartsWith($Marker + '/', [StringComparison]::OrdinalIgnoreCase)) { return 'child' }
    return 'none'
}

$invariant = [Globalization.CultureInfo]::InvariantCulture
function ConvertFrom-ProcmonTime([string] $Text) {
    $value = $Text.Trim()
    try { return [datetime]::ParseExact($value, 'h:mm:ss.fffffff tt', $invariant) }
    catch { return [datetime]::Parse($value, $invariant) }
}

# ---------------------------------------------------------------- CSV stream
$rows = [Collections.Generic.List[object]]::new()
$scanned = 0
$headerChecked = $false
$sr = [IO.StreamReader]::new($csvPath, [Text.Encoding]::UTF8, $true, 1MB)
try {
    $header = $sr.ReadLine()
    if ($null -eq $header -or $header -notmatch '"Duration"' -or $header -notmatch '"TID"') {
        throw 'CSV lacks Duration/TID columns. Export with a .pmc that enables them (procmon-duration-tid.pmc).'
    }
    $headerChecked = $true
    while (-not $sr.EndOfStream) {
        $line = $sr.ReadLine()
        $scanned++
        # Detail may contain quotes/commas; anchor Duration/TID to the tail.
        $parts = $line.Split('","')
        if ($parts.Count -lt 9) { continue }
        if ($parts[1] -ne $ProcessName) { continue }
        $pidValue = [int]$parts[2]
        if ($MpvPid -gt 0 -and $pidValue -ne $MpvPid) { continue }
        $op = $parts[3]
        if ($op -ne 'CreateFile' -and $op -notlike 'Query*') { continue }

        $path = $parts[4]
        $relation = 'none'
        foreach ($marker in $markers) {
            $candidate = Test-PathRelation $path $marker
            if ($candidate -ne 'none') { $relation = $candidate; break }
        }
        if ($relation -eq 'none') { continue }

        $detail = ($parts[6..($parts.Count - 3)] -join '","')
        $durationSec = [double]::Parse($parts[$parts.Count - 2], $invariant)
        $tidValue = [int]$parts[$parts.Count - 1].TrimEnd('"')

        $kind = 'other-open'
        if ($op -eq 'CreateFile') {
            if ($detail -match 'Desired Access:\s*Read Attributes') { $kind = 'attr' }
            elseif ($detail -match 'Read Data/List Directory') { $kind = 'list' }
        } else {
            $kind = 'query'
        }
        $rows.Add([pscustomobject]@{
                tod      = ConvertFrom-ProcmonTime $parts[0].TrimStart('"')
                pid      = $pidValue
                tid      = $tidValue
                op       = $op
                kind     = $kind
                relation = $relation
                path     = $path
                durationSec = $durationSec
            })
    }
} finally { $sr.Dispose() }

# ------------------------------------------------------- worker-TID discovery
$listOpens = @($rows | Where-Object { $_.kind -eq 'list' -and $_.relation -eq 'self' })
if ($ScanTid -gt 0) {
    $scanTid = $ScanTid
    $start = @($rows | Where-Object { $_.tid -eq $scanTid -and $_.kind -eq 'list' -and $_.relation -eq 'self' } |
        Sort-Object tod | Select-Object -First 1).tod
    if (-not $start) {
        $start = @($rows | Where-Object { $_.tid -eq $scanTid -and $_.kind -eq 'attr' -and $_.relation -eq 'child' } |
            Sort-Object tod | Select-Object -First 1).tod
    }
    if (-not $start) { throw "No scan rows found for -ScanTid $scanTid." }
} elseif ($listOpens.Count -gt 0) {
    $candidates = foreach ($open in $listOpens) {
        $end = $open.tod.AddSeconds($MaxScanWindowSec)
        $childAttr = @($rows | Where-Object {
                $_.tid -eq $open.tid -and $_.kind -eq 'attr' -and $_.relation -eq 'child' -and
                $_.tod -ge $open.tod -and $_.tod -le $end })
        [pscustomobject]@{ open = $open; childAttr = $childAttr.Count }
    }
    $best = $candidates | Sort-Object childAttr -Descending | Select-Object -First 1
    $scanTid = $best.open.tid
    $start = $best.open.tod
} else {
    throw 'No directory "Read Data/List Directory" open found under PathMarkers; check the markers (rclone WinFsp scans appear as the resolved UNC path).'
}

# The directory attribute open (mp_opendir / FindFirstFileExW) can precede the
# visible list-directory open by a fraction of a millisecond; keep a small
# pre-roll so dirAttributeOpens is counted.
$start = $start.AddSeconds(-1.0)

$windowEnd = $start.AddSeconds($MaxScanWindowSec)
$windowRows = @($rows | Where-Object {
        $_.tid -eq $scanTid -and $_.tod -ge $start -and $_.tod -le $windowEnd })
$entryAttr = @($windowRows | Where-Object { $_.kind -eq 'attr' -and $_.relation -eq 'child' })
$dirAttr = @($windowRows | Where-Object { $_.kind -eq 'attr' -and $_.relation -eq 'self' })
$queryOps = @($windowRows | Where-Object { $_.kind -eq 'query' })
$allAttr = @($entryAttr + $dirAttr)
$maxAttrSec = if ($allAttr.Count) { ($allAttr | Measure-Object durationSec -Maximum).Maximum } else { 0.0 }

# ------------------------------------------------------------------ mpv log
$logInfo = $null
if ($MpvLog) {
    $openingDone = $null
    $autocreateAt = $null
    $siblings = $null
    foreach ($line in [IO.File]::ReadLines($MpvLog)) {
        if ($line -match '^\[\s*([0-9.]+)\].*Opening done:') {
            $openingDone = [double]$Matches[1]
        } elseif ($line -match '^\[\s*([0-9.]+)\].*Autocreate playlist:\s*(\d+)\s+siblings') {
            $siblings = [int]$Matches[2]
            $autocreateAt = [double]$Matches[1]
            break
        }
    }
    if ($null -ne $openingDone -and $null -ne $autocreateAt) {
        $logInfo = [pscustomobject]@{
            openingDoneSec = $openingDone
            autocreateSec  = $autocreateAt
            siblings       = $siblings
            deltaSec       = [math]::Round($autocreateAt - $openingDone, 3)
        }
    }
}

# ---------------------------------------------------------------- thresholds
$warnings = [Collections.Generic.List[string]]::new()
$observedEntries = if ($logInfo) { $logInfo.siblings } else { $entryAttr.Count + $queryOps.Count }
if (-not $logInfo) {
    $warnings.Add('No mpv log: scanned-entry count falls back to per-entry Procmon rows, which is 0 after the fix; pass -MpvLog to verify >= MinScannedEntries.')
} elseif ($observedEntries -lt $MinScannedEntries) {
    $warnings.Add("Only $observedEntries scanned entries (< MinScannedEntries $MinScannedEntries); is the fixture the expected one?")
}

$scanWindowSec = if ($windowRows.Count) {
    [math]::Round((($windowRows | Measure-Object tod -Maximum).Maximum -
                   ($windowRows | Measure-Object tod -Minimum).Minimum).TotalSeconds, 3)
} else { 0.0 }

$checks = [ordered]@{
    captureInterpreted     = ($listOpens.Count -ge 1 -and $scanTid -gt 0)
    scanEntriesObserved    = $observedEntries
    entryAttributeOpens    = $entryAttr.Count
    dirAttributeOpens      = $dirAttr.Count
    queryOps               = $queryOps.Count
    maxAttributeOpenSec    = [math]::Round([double]$maxAttrSec, 4)
    scanWindowSec          = $scanWindowSec
}

$success = $checks.captureInterpreted
if (-not $Baseline) {
    $success = $success -and
        ($checks.entryAttributeOpens -le $MaxEntryAttributeOpens) -and
        ($checks.maxAttributeOpenSec -le $MaxAttributeOpenSec) -and
        ($checks.queryOps -le $MaxQueryOps) -and
        ($checks.scanWindowSec -le $MaxScanWindowSec)
}

$summary = [ordered]@{
    schemaVersion      = 1
    filteredCsv        = $csvPath
    scannedCsvRows     = $scanned
    processName        = $ProcessName
    mpvPid             = if ($rows.Count) { $rows[0].pid } else { $null }
    pathMarkers        = $markers
    scanTid            = $scanTid
    scanWindow         = [ordered]@{
        start = $start.ToString('HH:mm:ss.fffffff')
        end   = if ($windowRows.Count) { ($windowRows | Measure-Object tod -Maximum).Maximum.ToString('HH:mm:ss.fffffff') } else { $null }
    }
    metrics            = $checks
    log                = $logInfo
    longestAttributeOpens = @($allAttr | Sort-Object durationSec -Descending |
        Select-Object -First $TopLongest |
        ForEach-Object { [pscustomobject]@{ tod = $_.tod.ToString('HH:mm:ss.fffffff'); tid = $_.tid; durationMs = [math]::Round($_.durationSec * 1000, 3); path = $_.path } })
    thresholds         = [ordered]@{
        baseline                 = [bool]$Baseline
        maxEntryAttributeOpens   = $MaxEntryAttributeOpens
        maxAttributeOpenSec      = $MaxAttributeOpenSec
        maxQueryOps              = $MaxQueryOps
        maxScanWindowSec         = $MaxScanWindowSec
    }
    warnings           = $warnings.ToArray()
    success            = $success
}
if ($OutJson) {
    $summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutJson -Encoding utf8NoBOM
}
$summary | ConvertTo-Json -Depth 4
if (-not $success) {
    throw ("Scan thresholds failed: entryAttr=$($checks.entryAttributeOpens) " +
           "maxAttrSec=$($checks.maxAttributeOpenSec) queryOps=$($checks.queryOps) " +
           "windowSec=$($checks.scanWindowSec)")
}
