#requires -Version 7.4
<#
.SYNOPSIS
Short system-load observation for benchmark preflight / contamination checks.

.DESCRIPTION
Samples system CPU, memory, disk, network, GPU, per-process CPU and I/O deltas,
and rclone wcrypt RC backend deltas over a short representative interval.
Writes structured JSON and prints a concise summary. Read-only; never changes
process state.

.PARAMETER Seconds
Total observation window. Counter sampling uses 2 s samples for the first ~10 s.

.PARAMETER OutJson
Path for the JSON result file.

.PARAMETER SkipNvidia
Skip nvidia-smi spot check.

.PARAMETER RcPort
rclone RC port for the wcrypt mount (default 5574).
#>
[CmdletBinding()]
param(
    [int] $Seconds = 20,
    [string] $OutJson = '',
    [string] $Label = 'load',
    [switch] $SkipNvidia,
    [int] $RcPort = 5574
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class LoadProbeNative
{
    [StructLayout(LayoutKind.Sequential)]
    public struct IO_COUNTERS { public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes; }
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetProcessIoCounters(IntPtr processHandle, out IO_COUNTERS ioCounters);
}
'@

function Get-ProcSnapshot {
    $map = @{}
    foreach ($p in Get-Process -ErrorAction SilentlyContinue) {
        try {
            $io = [LoadProbeNative+IO_COUNTERS]::new()
            if (-not [LoadProbeNative]::GetProcessIoCounters($p.Handle, [ref] $io)) { continue }
            $map[$p.Id] = [pscustomobject]@{
                pid = $p.Id; name = $p.ProcessName
                cpu = $p.TotalProcessorTime.TotalSeconds
                readBytes = $io.ReadBytes; writeBytes = $io.WriteBytes
                ws = $p.WorkingSet64
            }
        } catch { }
    }
    $map
}

function Get-NicSnapshot {
    $out = @{}
    foreach ($a in Get-NetAdapterStatistics -ErrorAction SilentlyContinue) {
        try {
            $name = (Get-NetAdapter -InterfaceIndex $a.InterfaceIndex -ErrorAction SilentlyContinue).Name
            if (-not $name) { $name = "ifindex-$($a.InterfaceIndex)" }
            $out[$name] = [pscustomobject]@{ received = [double]$a.ReceivedBytes; sent = [double]$a.SentBytes }
        } catch { }
    }
    $out
}

function Get-RcStats([int] $Port) {
    try {
        $auth = Get-Content -LiteralPath (Join-Path $env:APPDATA 'rclone\rc-auth.json') -Raw | ConvertFrom-Json
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($auth.user):$($auth.pass)"))
        $h = @{ Authorization = "Basic $b64" }
        $core = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/core/stats" -Headers $h -Method Post -TimeoutSec 5
        $vfs = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/vfs/stats" -Headers $h -Method Post -TimeoutSec 5
        $prop = { param($obj, $name) $p = $obj.PSObject.Properties[$name]; if ($null -ne $p) { $p.Value } else { $null } }
        return [pscustomobject]@{
            ok = $true
            bytes = [double]$core.bytes; transfers = [double]$core.transfers
            errors = $core.errors; retryError = $core.retryError; fatalError = $core.fatalError
            elapsedTime = $core.elapsedTime
            cacheBytes = [double]$vfs.diskCache.bytesUsed; cacheFiles = [double]$vfs.diskCache.files
            inUse = & $prop $vfs 'inUse'
            outOfSpace = & $prop $vfs.diskCache 'outOfSpace'
            erroredFiles = & $prop $vfs.diskCache 'erroredFiles'
        }
    } catch {
        return [pscustomobject]@{ ok = $false; error = $_.Exception.Message }
    }
}

function Get-GpuSample {
    $smi = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
    if (-not $smi) { return $null }
    try {
        $raw = & $smi.Source --query-gpu=timestamp,index,utilization.gpu,utilization.memory,utilization.encoder,utilization.decoder,memory.used,power.draw,clocks.sm --format=csv,noheader,nounits 2>$null
        return [string]$raw
    } catch { return $null }
}

$procExclude = @('Idle', 'System', 'Registry', 'Memory Compression', 'Secure System')

# --- t0 ---
$t0 = Get-Date
$s0 = Get-ProcSnapshot
$nic0 = Get-NicSnapshot
$rc0 = Get-RcStats $RcPort
$gpu0 = if ($SkipNvidia) { $null } else { Get-GpuSample }

# --- system counters (approx 10 s) ---
$counters = [ordered]@{}
$cpaths = @(
    '\Processor(_Total)\% Processor Time'
    '\Memory\Available MBytes'
    '\Memory\Pages/sec'
    '\PhysicalDisk(_Total)\% Disk Time'
    '\PhysicalDisk(_Total)\Disk Bytes/sec'
)
$samples = @()
try {
    $samples = @(Get-Counter -Counter $cpaths -SampleInterval 2 -MaxSamples 5 -ErrorAction Stop | Select-Object -ExpandProperty CounterSamples)
} catch {
    $counters['counterError'] = $_.Exception.Message
}
if ($samples.Count -gt 0) {
    $byPath = @{}
    foreach ($s in $samples) {
        $key = $s.Path
        if (-not $byPath.ContainsKey($key)) { $byPath[$key] = [Collections.Generic.List[double]]::new() }
        $byPath[$key].Add($s.CookedValue)
    }
    foreach ($k in $byPath.Keys) {
        $vals = @($byPath[$k])
        $counters[$k] = [pscustomobject]@{
            avg = [math]::Round(($vals | Measure-Object -Average).Average, 2)
            max = [math]::Round(($vals | Measure-Object -Maximum).Maximum, 2)
            n = $vals.Count
        }
    }
}

# per-volume disk counters (best effort, separate call)
$volCounters = [ordered]@{}
try {
    $vpaths = @('\LogicalDisk(C:)\Disk Bytes/sec', '\LogicalDisk(D:)\Disk Bytes/sec', '\LogicalDisk(D:)\% Disk Time')
    $vs = @(Get-Counter -Counter $vpaths -SampleInterval 2 -MaxSamples 3 -ErrorAction Stop | Select-Object -ExpandProperty CounterSamples)
    $vby = @{}
    foreach ($s in $vs) {
        if (-not $vby.ContainsKey($s.Path)) { $vby[$s.Path] = [Collections.Generic.List[double]]::new() }
        $vby[$s.Path].Add($s.CookedValue)
    }
    foreach ($k in $vby.Keys) {
        $vals = @($vby[$k])
        $volCounters[$k] = [math]::Round(($vals | Measure-Object -Average).Average, 2)
    }
} catch { $volCounters['counterError'] = $_.Exception.Message }

# --- fill remaining window ---
$elapsed = ((Get-Date) - $t0).TotalSeconds
if ($elapsed -lt $Seconds) { Start-Sleep -Milliseconds ([int](($Seconds - $elapsed) * 1000)) }

# --- t1 ---
$t1 = Get-Date
$s1 = Get-ProcSnapshot
$nic1 = Get-NicSnapshot
$rc1 = Get-RcStats $RcPort
$gpu1 = if ($SkipNvidia) { $null } else { Get-GpuSample }
$interval = [math]::Round(($t1 - $t0).TotalSeconds, 2)

# --- deltas ---
$procs = foreach ($k in $s1.Keys) {
    if (-not $s0.ContainsKey($k)) { continue }
    $a = $s0[$k]; $b = $s1[$k]
    $cpu = [math]::Round($b.cpu - $a.cpu, 3)
    $rb = $b.readBytes - $a.readBytes; $wb = $b.writeBytes - $a.writeBytes
    if ($cpu -gt 0.1 -or $rb -gt 262144 -or $wb -gt 262144) {
        [pscustomobject]@{
            pid = $k; name = $b.name; cpuSeconds = $cpu
            readMB = [math]::Round($rb / 1MB, 2); writeMB = [math]::Round($wb / 1MB, 2)
            wsMB = [math]::Round($b.ws / 1MB, 1)
        }
    }
}
$procs = @($procs | Sort-Object { $_.cpuSeconds } -Descending)

$nics = foreach ($k in $nic1.Keys) {
    if (-not $nic0.ContainsKey($k)) { continue }
    $rx = ($nic1[$k].received - $nic0[$k].received) / $interval
    $tx = ($nic1[$k].sent - $nic0[$k].sent) / $interval
    if ($rx -gt 1024 -or $tx -gt 1024) {
        [pscustomobject]@{ name = $k; rxBytesPerSec = [math]::Round($rx); txBytesPerSec = [math]::Round($tx) }
    }
}
$nics = @($nics)

$rc = $null
if ($rc0.ok -and $rc1.ok) {
    $rc = [pscustomobject]@{
        port = $RcPort
        intervalSec = $interval
        deltaBytes = $rc1.bytes - $rc0.bytes
        deltaTransfers = $rc1.transfers - $rc0.transfers
        bytesPerSec = [math]::Round(($rc1.bytes - $rc0.bytes) / $interval)
        cacheBytesUsedDelta = $rc1.cacheBytes - $rc0.cacheBytes
        cacheFilesStart = $rc0.cacheFiles; cacheFilesEnd = $rc1.cacheFiles
        errorsTotal = $rc1.errors; retryError = $rc1.retryError; fatalError = $rc1.fatalError
        elapsedTime = $rc1.elapsedTime
    }
} else {
    $rc = [pscustomobject]@{ port = $RcPort; ok0 = $rc0.ok; ok1 = $rc1.ok; error = "$($rc0.error) | $($rc1.error)" }
}

$gateProcs = @(Get-Process -Name wpaexporter, wpa, xperf -ErrorAction SilentlyContinue | Select-Object Name, Id)

$result = [ordered]@{
    schemaVersion = 1
    label = $Label
    startedAtUtc = $t0.ToUniversalTime().ToString('o')
    endedAtUtc = $t1.ToUniversalTime().ToString('o')
    intervalSec = $interval
    systemCounters = $counters
    volumeCounters = $volCounters
    network = $nics
    rclone = $rc
    gpuStart = $gpu0
    gpuEnd = $gpu1
    processes = $procs
    offlineToolProcesses = $gateProcs
    machine = [pscustomobject]@{
        logicalProcessors = [Environment]::ProcessorCount
        availableMemoryMB = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1KB
        committedMemoryMB = [math]::Round(((Get-CimInstance Win32_OperatingSystem).TotalVirtualMemorySize - (Get-CimInstance Win32_OperatingSystem).FreeVirtualMemory) / 1KB, 1)
    }
}

if ($OutJson) {
    $dir = Split-Path -Parent $OutJson
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [IO.File]::WriteAllText($OutJson, ($result | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
}

# --- summary ---
Write-Output ("[{0}] interval={1}s" -f $Label, $interval)
foreach ($k in $counters.Keys) {
    $v = $counters[$k]
    if ($v -is [pscustomobject] -and $null -ne $v.avg) { Write-Output ("  sys {0}: avg={1} max={2} (n={3})" -f $k, $v.avg, $v.max, $v.n) }
}
foreach ($k in $volCounters.Keys) { Write-Output ("  vol {0}: {1}" -f $k, $volCounters[$k]) }
foreach ($n in $nics) { Write-Output ("  nic {0}: rx={1:N0} B/s tx={2:N0} B/s" -f $n.name, $n.rxBytesPerSec, $n.txBytesPerSec) }
$rcInUse = if ($null -ne $rc.PSObject.Properties['inUse']) { $rc.inUse } else { 'n/a' }
if ($null -ne $rc.PSObject.Properties['deltaBytes']) { Write-Output ("  rclone:{0} dbytes={1:N0} dtransfers={2} ({3:N0} B/s) cacheFilesEnd={4:N0} cacheUsedDelta={5:N0} inUse={6}" -f $rc.port, $rc.deltaBytes, $rc.deltaTransfers, $rc.bytesPerSec, $rc.cacheFilesEnd, $rc.cacheBytesUsedDelta, $rcInUse) }
if ($gpu0 -or $gpu1) { Write-Output ("  gpu start: {0}" -f $gpu0); Write-Output ("  gpu end:   {0}" -f $gpu1) }
Write-Output '  top processes (cpu s / read MB / write MB):'
foreach ($p in ($procs | Select-Object -First 12)) {
    Write-Output ("    {0,-20} pid={1,-7} cpu={2,8:N3} read={3,10:N2} write={4,10:N2} ws={5,9:N1}" -f $p.name, $p.pid, $p.cpuSeconds, $p.readMB, $p.writeMB, $p.wsMB)
}
Write-Output ("  offline tools running: {0}" -f $(if ($gateProcs.Count) { ($gateProcs | ForEach-Object { "$($_.Name):$($_.Id)" }) -join ', ' } else { 'none' }))
