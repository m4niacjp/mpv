#requires -Version 7.4
<#
.SYNOPSIS
Resumes the PB01..PB25 synthetic-video generation after an interruption.

.DESCRIPTION
Generation is per-file and crash-resumable:
  - a file counts as complete only when its output and its per-file manifest exist;
  - an existing non-empty output without a manifest is adopted (facts recorded
    from the file itself, no re-encode) when it matches the expected duration;
  - a zero-length or mismatched leftover is deleted and regenerated;
  - every invocation is one New-BenchVideos.ps1 -Only <n> process, so a hard
    reset loses at most the file being encoded;
  - when all Count manifests exist, they are merged into <OutDir>\manifest.json
    (facts only; sha256/size were recorded per file at creation time).

Encoder CPU is capped via -EncoderThreads (default 6) per the all-core-load
stability note. Not part of the benchmark harness itself; safe to rerun.
#>
[CmdletBinding()]
param(
    [int[]] $Only = @(),
    [int] $Count = 25,
    [string] $OutDir = 'C:\PerfBench\videos',
    [string] $ManifestDir = 'C:\PerfBench\manifests',
    [string] $LogPath = 'C:\PerfBench\gen-resume.log',
    [int] $EncoderThreads = 6
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$harness = $PSScriptRoot
$generator = Join-Path $harness 'New-BenchVideos.ps1'
if (-not (Test-Path -LiteralPath $generator)) { throw "missing $generator" }

function Write-Log([string] $Line) {
    $stamp = [DateTime]::Now.ToString('yyyy-MM-ddTHH:mm:ss')
    $text = "[$stamp] $Line"
    Write-Host $text
    [IO.File]::AppendAllText($LogPath, $text + [Environment]::NewLine)
}

New-Item -ItemType Directory -Force -Path $ManifestDir | Out-Null
$targets = if ($Only.Count) { $Only } else { 1..$Count }
$failures = [Collections.Generic.List[string]]::new()

foreach ($i in $targets) {
    $name = 'PB{0:D2}.mkv' -f $i
    $path = Join-Path $OutDir $name
    $manifest = Join-Path $ManifestDir ("PB{0:D2}.json" -f $i)
    $file = if (Test-Path -LiteralPath $path) { Get-Item -LiteralPath $path } else { $null }
    if ($file -and $file.Length -gt 0 -and (Test-Path -LiteralPath $manifest)) {
        Write-Log "skip $name (complete, $($file.Length) bytes)"
        continue
    }
    if ($file -and $file.Length -gt 0 -and -not (Test-Path -LiteralPath $manifest)) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            & $generator -OutDir $OutDir -Only $i -ManifestPath $manifest -AdoptExisting *>> $LogPath
            if ($LASTEXITCODE -ne 0) { throw "generator exit code $LASTEXITCODE" }
            Write-Log ("adopt {0} in {1:N1}s" -f $name, $sw.Elapsed.TotalSeconds)
            continue
        } catch {
            $sw.Stop()
            Write-Log ("adopt failed for {0} after {1:N1}s : {2}; regenerating" -f $name, $sw.Elapsed.TotalSeconds, $_)
        }
    }
    if (Test-Path -LiteralPath $path) {
        Write-Log "remove incomplete $name ($((Get-Item -LiteralPath $path).Length) bytes)"
        Remove-Item -LiteralPath $path -Force
    }
    if (Test-Path -LiteralPath $manifest) { Remove-Item -LiteralPath $manifest -Force }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        & $generator -OutDir $OutDir -Only $i -ManifestPath $manifest -EncoderThreads $EncoderThreads *>> $LogPath
        if ($LASTEXITCODE -ne 0) { throw "generator exit code $LASTEXITCODE" }
        Write-Log ("done {0} in {1:N1}s (threads {2})" -f $name, $sw.Elapsed.TotalSeconds, $EncoderThreads)
    } catch {
        $sw.Stop()
        $failures.Add("$name : $_")
        Write-Log ("FAIL {0} after {1:N1}s : {2}" -f $name, $sw.Elapsed.TotalSeconds, $_)
    }
}

if ($failures.Count) {
    Write-Log ("FAILURES: " + ($failures -join ' | '))
    exit 1
}

# Merge per-file manifests once every target file is complete.
$missing = @(foreach ($i in 1..$Count) {
    $m = Join-Path $ManifestDir ("PB{0:D2}.json" -f $i)
    if (-not (Test-Path -LiteralPath $m)) { "PB{0:D2}" -f $i }
})
if ($missing.Count) {
    Write-Log ("no merge yet; missing manifests: " + ($missing -join ', '))
    exit 0
}
$recs = @(foreach ($i in 1..$Count) {
    $m = Get-Content -LiteralPath (Join-Path $ManifestDir ("PB{0:D2}.json" -f $i)) -Raw | ConvertFrom-Json
    @($m.files)[0]
})
$first = Get-Content -LiteralPath (Join-Path $ManifestDir 'PB01.json') -Raw | ConvertFrom-Json
$merged = [ordered]@{
    schemaVersion = 1
    createdUtc = [DateTimeOffset]::UtcNow.ToString('o')
    ffmpeg = $first.ffmpeg
    spec = $first.spec
    files = @($recs | Sort-Object name)
}
$out = Join-Path $OutDir 'manifest.json'
[IO.File]::WriteAllText($out, ($merged | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
Write-Log "merged $($recs.Count) manifests -> $out"
