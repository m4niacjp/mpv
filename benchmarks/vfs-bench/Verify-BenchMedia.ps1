#requires -Version 7.4
<#
.SYNOPSIS
Full-decode verification of the staged benchmark corpus before upload.

.DESCRIPTION
For each PB01..PB25 in -StagingDir:
  - full ffmpeg decode (video+audio) to null, collecting error lines and exit code;
  - ffprobe stream/duration facts;
  - manifest comparison (size, sha256, duration).
Writes a JSON and CSV summary under -OutDir and exits non-zero if any file fails.
Read-only otherwise. Decode threads are capped for machine stability.

.PARAMETER Count
Number of files (default 25).

.PARAMETER DecodeThreads
ffmpeg decode threads (default 8; this is far lighter than the encoder).
#>
[CmdletBinding()]
param(
    [string] $StagingDir = 'C:\PerfBench\videos',
    [int] $Count = 25,
    [string] $Prefix = 'PB',
    [string] $ManifestDir = 'C:\PerfBench\manifests',
    [string] $OutDir = 'C:\PerfBench\verify',
    [int] $DecodeThreads = 8,
    [string] $FfmpegPath = 'C:\Users\andre\Projects\FFmpeg\bin\ffmpeg.exe',
    [string] $FfprobePath = 'C:\Users\andre\Projects\FFmpeg\bin\ffprobe.exe'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'VfsBench.psm1') -Force

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$results = [Collections.Generic.List[object]]::new()
$failed = 0

for ($i = 1; $i -le $Count; $i++) {
    $name = '{0}{1:D2}.mkv' -f $Prefix, $i
    $path = Join-Path $StagingDir $name
    $manifestPath = Join-Path $ManifestDir ("{0}{1:D2}.json" -f $Prefix, $i)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $rec = [ordered]@{
        name = $name; path = $path; exists = (Test-Path -LiteralPath $path)
        size = $null; sha256 = $null; durationSec = $null
        decodeExit = $null; decodeErrorLines = 0; decodeErrors = @()
        manifestFound = (Test-Path -LiteralPath $manifestPath)
        manifestSizeMatch = $null; manifestHashMatch = $null; manifestDurationDeltaSec = $null
        decodeSec = $null; ok = $false; error = $null
    }
    try {
        if (-not $rec.exists) { throw "missing file" }
        $file = Get-Item -LiteralPath $path
        if ($file.Length -le 0) { throw "zero-length file" }
        $rec.size = $file.Length
        $rec.sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash

        $factsRaw = & $FfprobePath -v error -show_entries 'format=duration:stream=codec_type' -of json $path 2>$null
        $facts = $factsRaw | ConvertFrom-Json
        if (-not $facts.format.duration) { throw "ffprobe returned no duration" }
        $rec.durationSec = [double]$facts.format.duration

        if ($rec.manifestFound) {
            $m = @((Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json).files)[0]
            $rec.manifestSizeMatch = ([long]$m.size -eq $rec.size)
            $rec.manifestHashMatch = ($m.sha256 -eq $rec.sha256)
            $rec.manifestDurationDeltaSec = [math]::Round($rec.durationSec - [double]$m.durationSec, 3)
        }

        $errLines = [Collections.Generic.List[string]]::new()
        $out = & $FfmpegPath -hide_banner -nostdin -v error -threads $DecodeThreads `
            -i $path -map 0:v:0 -map '0:a:0?' -f null - 2>&1 |
            ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { "$_" } }
        $rec.decodeExit = $LASTEXITCODE
        foreach ($line in @($out)) {
            if ($null -ne $line -and "$line".Trim().Length -gt 0) { $errLines.Add("$line") }
        }
        $rec.decodeErrorLines = $errLines.Count
        $rec.decodeErrors = @($errLines | Select-Object -First 8)

        if ($rec.decodeExit -ne 0) { throw "decode exit $($rec.decodeExit)" }
        if ($rec.decodeErrorLines -gt 0) { throw "decode reported $($rec.decodeErrorLines) error lines" }
        if ($rec.size -le 0) { throw "empty size" }
        if (-not $rec.manifestFound) { throw "missing per-file manifest" }
        if (-not $rec.manifestSizeMatch) { throw "manifest size mismatch" }
        if (-not $rec.manifestHashMatch) { throw "manifest sha256 mismatch" }
        if ([math]::Abs($rec.manifestDurationDeltaSec) -gt 0.5) { throw "manifest duration mismatch" }
        $rec.ok = $true
    } catch {
        $rec.ok = $false
        $rec.error = "$_"
        $failed++
    }
    $sw.Stop()
    $rec.decodeSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    $results.Add([pscustomobject]$rec)
    Write-Host ("{0}  {1}  size={2}  decode={3}s errs={4}  {5}" -f $name,
        $(if ($rec.ok) { 'OK' } else { 'FAIL' }), $rec.size, $rec.decodeSec,
        $rec.decodeErrorLines, $(if ($rec.error) { $rec.error } else { '' }))
}

$summary = [ordered]@{
    schemaVersion = 1
    checkedUtc = [DateTimeOffset]::UtcNow.ToString('o')
    stagingDir = $StagingDir
    count = $Count
    failed = $failed
    decodeThreads = $DecodeThreads
    files = @($results)
}
Write-BenchJson (Join-Path $OutDir 'verify-media.json') $summary
$csv = @($results | ForEach-Object {
    [pscustomobject]@{ name = $_.name; ok = $_.ok; size = $_.size; durationSec = $_.durationSec
        decodeSec = $_.decodeSec; decodeErrorLines = $_.decodeErrorLines
        manifestSizeMatch = $_.manifestSizeMatch; manifestHashMatch = $_.manifestHashMatch
        manifestDurationDeltaSec = $_.manifestDurationDeltaSec; error = $_.error }
})
$csv | Export-Csv -LiteralPath (Join-Path $OutDir 'verify-media.csv') -NoTypeInformation -Encoding utf8
Write-Host ("verified {0}/{1}; failed {2}; summary {3}" -f ($Count - $failed), $Count, $failed, (Join-Path $OutDir 'verify-media.json'))
if ($failed -gt 0) { exit 1 }
