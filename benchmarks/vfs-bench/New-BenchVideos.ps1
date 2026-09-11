#requires -Version 7.4
<#
.SYNOPSIS
Generates the synthetic benchmark videos (PB01..PBnn.mkv) and the local warm-up clip.

.DESCRIPTION
Each file: 1920x1080 30 fps CFR H.264 High (libx264, ABR 8 Mb/s, 2 s closed GOP),
quiet stereo AAC tone, testsrc2 motion + per-file temporal noise seed + burned-in
"PBnn frame N" label. Files are unique (noise seed, label, tone frequency), so no
layer can deduplicate them. Modification times are assigned strictly increasing
(2026-01-01T00:00Z + n minutes) so name order == mtime order == Explorer name order,
which keeps "next playlist entry" identical under mpv's natural sort and
playlist-sort.lua's mtime fallback. Never overwrites an existing output unless
-AdoptExisting is given, in which case an existing complete encode is recorded
instead of re-encoded.

.PARAMETER Only
Generate only these 1-based indices (testing).

.PARAMETER EncoderThreads
Pass -threads N to ffmpeg when > 0 (caps encoder CPU for stability).

.PARAMETER AdoptExisting
Accept an existing output file (non-zero length) and write its manifest without
re-encoding; adoption fails if the file does not match the expected duration.
#>
[CmdletBinding()]
param(
    [string] $OutDir = 'C:\PerfBench\videos',
    [int] $Count = 25,
    [int] $DurationSec = 300,
    [int[]] $Only = @(),
    [switch] $Warmup,
    [string] $WarmupPath = 'C:\PerfBench\warmup\PBWARM.mkv',
    [int] $WarmupDurationSec = 20,
    [string] $FfmpegPath = 'C:\Users\andre\Projects\FFmpeg\bin\ffmpeg.exe',
    [string] $FfprobePath = 'C:\Users\andre\Projects\FFmpeg\bin\ffprobe.exe',
    [string] $ManifestPath = '',
    [int] $EncoderThreads = 0,
    [switch] $AdoptExisting
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'VfsBench.psm1') -Force

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$font = Join-Path $OutDir 'consola.ttf'
if (-not (Test-Path -LiteralPath $font)) { Copy-Item -LiteralPath 'C:\Windows\Fonts\consola.ttf' -Destination $font }
$baseUtc = [DateTime]::new(2026, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)

function New-Video([int] $Index, [string] $Label, [string] $Path, [int] $Seconds, [string] $WorkDir) {
    $adopted = $false
    if (Test-Path -LiteralPath $Path) {
        if (-not $AdoptExisting) { throw "Refusing to overwrite $Path" }
        if ((Get-Item -LiteralPath $Path).Length -le 0) { Remove-Item -LiteralPath $Path -Force } else { $adopted = $true }
    }
    $freq = 200 + 20 * $Index
    $vf = "[0:v]noise=alls=10:allf=t+u:all_seed=$(1000 + $Index),drawtext=fontfile=consola.ttf:text='$Label frame %{frame_num}':x=40:y=40:fontsize=56:fontcolor=white:box=1:boxcolor=black@0.6[v];[1:a]volume=0.05,aformat=channel_layouts=stereo[a]"
    $encodeSec = 0.0
    if (-not $adopted) {
        $args = @('-hide_banner', '-nostdin', '-loglevel', 'error', '-stats',
            '-f', 'lavfi', '-i', "testsrc2=size=1920x1080:rate=30:duration=$Seconds",
            '-f', 'lavfi', '-i', "sine=frequency=${freq}:sample_rate=48000:duration=$Seconds",
            '-filter_complex', $vf, '-map', '[v]', '-map', '[a]',
            '-c:v', 'libx264', '-preset', 'veryfast', '-profile:v', 'high', '-pix_fmt', 'yuv420p',
            '-b:v', '8M', '-maxrate', '10M', '-bufsize', '16M', '-g', '60', '-keyint_min', '60', '-sc_threshold', '0',
            '-c:a', 'aac', '-b:a', '128k', '-metadata', "title=$Label", '-n', $Path)
        if ($EncoderThreads -gt 0) { $args += @('-threads', $EncoderThreads) }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Push-Location $WorkDir
        try { & $FfmpegPath @args 2>&1 | Out-Null; $code = $LASTEXITCODE } finally { Pop-Location }
        $sw.Stop()
        if ($code -ne 0 -or -not (Test-Path -LiteralPath $Path)) { throw "ffmpeg failed ($code) for $Path" }
        $encodeSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    }
    [pscustomobject]@{ index = $Index; label = $Label; toneHz = $freq; noiseSeed = 1000 + $Index; encodeSec = $encodeSec; adopted = $adopted }
}

function Get-VideoFacts([string] $Path) {
    $j = & $FfprobePath -v error -show_entries 'format=duration,size,bit_rate:stream=index,codec_name,profile,width,height,r_frame_rate,nb_frames,pix_fmt,sample_rate,channels' -of json $Path | ConvertFrom-Json
    $v = @($j.streams | Where-Object { $_.codec_name -eq 'h264' })[0]
    $a = @($j.streams | Where-Object { $_.codec_name -eq 'aac' })[0]
    if (-not $v -or -not $a -or -not $j.format.duration) { throw "ffprobe did not find the expected video/audio streams or duration: $Path" }
    [pscustomobject]@{ durationSec = [double]$j.format.duration; bitRate = [long]$j.format.bit_rate
        video = "$($v.codec_name) $($v.profile) $($v.width)x$($v.height) $($v.r_frame_rate) $($v.pix_fmt)"
        audio = "$($a.codec_name) $($a.sample_rate) Hz $($a.channels) ch" }
}

$ffv = (& $FfmpegPath -hide_banner -version | Select-Object -First 1)
$records = [Collections.Generic.List[object]]::new()
$targets = if ($Warmup) { @(0) } elseif ($Only.Count) { $Only } else { 1..$Count }
foreach ($i in $targets) {
    if ($Warmup) { $label = 'PBWARM'; $path = $WarmupPath; $secs = $WarmupDurationSec; $work = $OutDir }
    else { $label = '{0}{1:D2}' -f 'PB', $i; $path = Join-Path $OutDir "$label.mkv"; $secs = $DurationSec; $work = $OutDir }
    $gen = New-Video $i $label $path $secs $work
    $mtime = if ($Warmup) { $baseUtc } else { $baseUtc.AddMinutes($i) }
    [IO.File]::SetLastWriteTimeUtc($path, $mtime)
    $facts = Get-VideoFacts $path
    if ($AdoptExisting -and [math]::Abs($facts.durationSec - $secs) -gt 2) {
        throw "existing file does not match the expected duration ($($facts.durationSec)s vs ${secs}s): $Path"
    }
    $layout = Get-MkvLayout $path
    $rec = [ordered]@{ name = [IO.Path]::GetFileName($path); path = $path; size = (Get-Item -LiteralPath $path).Length
        sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash; mtimeUtc = $mtime.ToString('o')
        durationSec = $facts.durationSec; bitRate = $facts.bitRate; video = $facts.video; audio = $facts.audio
        frames = [int]($secs * 30); toneHz = $gen.toneHz; noiseSeed = $gen.noiseSeed; encodeSec = $gen.encodeSec; adopted = $gen.adopted
        mkvTopLevel = @($layout.elements | ForEach-Object { '{0}@{1}' -f $_.element, $_.pos }); mkvTrailing = $layout.trailingElements; clusters = $layout.clusters }
    $records.Add([pscustomobject]$rec)
    Write-Host ("{0}  {1:N1} MB  {2:N2} Mb/s  enc {3}s  adopted {4}  trailing: {5}" -f $rec.name, ($rec.size / 1MB), ($rec.bitRate / 1e6), $rec.encodeSec, $rec.adopted, ($rec.mkvTrailing -join ','))
}

$manifest = [ordered]@{ schemaVersion = 1; createdUtc = [DateTimeOffset]::UtcNow.ToString('o'); ffmpeg = $ffv
    spec = [ordered]@{ video = 'libx264 veryfast high yuv420p 1920x1080 30fps ABR 8M maxrate 10M bufsize 16M g=60 sc_threshold=0'; audio = 'aac 128k stereo 48 kHz, sine at -26 dBFS'
        content = 'testsrc2 + noise(alls=10, t+u, per-file seed) + drawtext label/frame counter'; mtimeRule = '2026-01-01T00:00Z + index minutes' }
    files = @($records) }
if (-not $ManifestPath) { $ManifestPath = if ($Warmup) { [IO.Path]::ChangeExtension($WarmupPath, '.manifest.json') } else { Join-Path $OutDir 'manifest.json' } }
if (Test-Path -LiteralPath $ManifestPath) {
    $old = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    $merged = @($old.files | Where-Object { $_.name -notin $records.name }) + @($records) | Sort-Object name
    $manifest.files = @($merged)
}
Write-BenchJson $ManifestPath $manifest
$ManifestPath
