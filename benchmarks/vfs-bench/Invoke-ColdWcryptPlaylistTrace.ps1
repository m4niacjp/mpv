#requires -Version 7.4
#requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutDir)

$ErrorActionPreference = 'Stop'
$stopScript = 'C:\ProgramData\Rclone\stop-rclone-wcrypt-mount.ps1'
$restartScript = 'C:\ProgramData\Rclone\restart-rclone-wcrypt-mount.ps1'
$cacheRoot = 'D:\rclone-wasabi-cache'
$targets = @("$cacheRoot\vfs\wcrypt", "$cacheRoot\vfsMeta\wcrypt")
if (Get-Process -Name mpv -ErrorAction SilentlyContinue) {
    throw 'Close existing mpv before resetting the mount.'
}
if (Test-Path -LiteralPath $OutDir) { throw 'Use a new output directory.' }
$out = (New-Item -ItemType Directory -Path $OutDir).FullName

# Prove that the registered task can be restarted before stopping its mount.
& $restartScript -ValidateOnly | Out-File (Join-Path $out 'restart-preflight.txt')
Import-Module 'C:\ProgramData\Rclone\rclone-rc-auth.psm1'
function Rc([string]$Endpoint) {
    Invoke-RcloneRcRequest -RcAddr '127.0.0.1:5574' -Path $Endpoint -TimeoutSec 5
}
function Save-Rc([string]$Tag) {
    $state = @{ vfs = Rc 'vfs/stats'; core = Rc 'core/stats'; queue = Rc 'vfs/queue' }
    $state | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $out "$Tag.json")
    return $state
}
$before = Save-Rc 'cache-before'
if ($before.vfs.fs -ne 'wcrypt:' -or
    $before.vfs.diskCache.path -ne '\\?\D:\rclone-wasabi-cache\vfs\wcrypt' -or
    $before.vfs.diskCache.pathMeta -ne '\\?\D:\rclone-wasabi-cache\vfsMeta\wcrypt') {
    throw 'Live RC cache paths do not match the explicitly selected cache.'
}
if ($before.vfs.diskCache.uploadsQueued -or $before.vfs.diskCache.uploadsInProgress -or
    @($before.queue.queue).Count) {
    throw 'Pending uploads: refusing to remove potentially unwritten data.'
}
$mountPid = (Rc 'core/pid').pid
$stopped = $false
try {
    $stopped = $true
    & $stopScript | Out-File (Join-Path $out 'stop.txt')
    if (Get-Process -Id $mountPid -ErrorAction SilentlyContinue) {
        throw 'Original mount process still exists; cache was not removed.'
    }
    $reachable = $false
    try { $null = Rc 'core/pid'; $reachable = $true } catch { }
    if ($reachable) { throw 'RC is still reachable; cache was not removed.' }

    # Check every ancestor and descendant for reparse points before deletion.
    foreach ($target in $targets) {
        $full = [IO.Path]::GetFullPath($target)
        if (-not $full.StartsWith($cacheRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Deletion target escaped cache root: $full"
        }
        $ancestor = $full
        while ($ancestor) {
            if (Test-Path -LiteralPath $ancestor) {
                if ((Get-Item -LiteralPath $ancestor -Force).Attributes -band
                    [IO.FileAttributes]::ReparsePoint) { throw "Reparse point: $ancestor" }
            }
            $ancestor = Split-Path -Parent $ancestor
        }
        if (Test-Path -LiteralPath $full) {
            $links = @(Get-ChildItem -LiteralPath $full -Force -Recurse |
                Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
            if ($links.Count) { throw 'Reparse point inside cache; refusing recursive deletion.' }
        }
    }
    $meta = @()
    if (Test-Path -LiteralPath $targets[1]) {
        $meta = @(Get-ChildItem -LiteralPath $targets[1] -File -Recurse -ErrorAction Stop)
    }
    foreach ($file in $meta) {
        $entry = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
        if ($entry.Dirty) { throw "Dirty cache entry retained: $($file.FullName)" }
    }
    foreach ($target in $targets) {
        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Recurse -Force
        }
        if (Test-Path -LiteralPath $target) { throw "Cache removal incomplete: $target" }
    }
    [pscustomobject]@{ utc = [DateTime]::UtcNow; removed = $targets;
        cleanMetadataEntries = $meta.Count; oldMountPid = $mountPid } |
        ConvertTo-Json | Set-Content (Join-Path $out 'cache-cleared.json')
} finally {
    if ($stopped) {
        & $restartScript | Out-File (Join-Path $out 'restart.txt')
    }
}
$cold = Save-Rc 'cache-after-restart'
if ($cold.vfs.diskCache.bytesUsed -ne 0 -or $cold.vfs.diskCache.files -ne 0) {
    throw 'Cache is already populated after restart; cold condition not established.'
}
& (Join-Path $PSScriptRoot 'Invoke-QuickPlaylistTrace.ps1') `
    -Folder 'I:\XXX\Short Sexy' -OutDir (Join-Path $out 'trial') `
    -HoldSeconds 10 -TraceShutdown
$null = Save-Rc 'cache-after-test'
