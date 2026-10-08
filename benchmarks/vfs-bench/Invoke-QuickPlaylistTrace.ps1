#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Folder,
    [Parameter(Mandatory)][string]$OutDir,
    [ValidateRange(1,60)][int]$HoldSeconds = 10,
    [switch]$TraceShutdown
)
$ErrorActionPreference = 'Stop'
if (Get-Process -Name mpv -ErrorAction SilentlyContinue) { throw 'Close existing mpv before testing.' }
if (Test-Path -LiteralPath $OutDir) { throw 'Use a new output directory for each trial.' }
$runDir = (New-Item -ItemType Directory -Path $OutDir).FullName
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class QuickNative {
 [StructLayout(LayoutKind.Sequential)] public struct IO { public ulong readOps,writeOps,otherOps,readBytes,writeBytes,otherBytes; }
 [DllImport("kernel32.dll",SetLastError=true)] public static extern bool GetProcessIoCounters(IntPtr h,out IO io);
 [DllImport("kernel32.dll",SetLastError=true)] public static extern bool GetProcessTimes(IntPtr h,out long created,out long ended,out long kernel,out long user);
}
"@
function Snapshot($proc) {
 try {
  $proc.Refresh()
  $h=$proc.Handle
  $io=[QuickNative+IO]::new()
  $ioOk=[QuickNative]::GetProcessIoCounters($h,[ref]$io)
  [long]$created=0; [long]$ended=0; [long]$kernel=0; [long]$user=0
  $cpuOk=[QuickNative]::GetProcessTimes($h,[ref]$created,[ref]$ended,[ref]$kernel,[ref]$user)
  [pscustomobject]@{pid=$proc.Id;name=$proc.ProcessName;utc=[DateTime]::UtcNow.ToString('o');cpuOk=$cpuOk;ioOk=$ioOk;kernelSec=$kernel/1e7;userSec=$user/1e7;cpuSec=($kernel+$user)/1e7;created=$created;ended=$ended;readBytes=$io.readBytes;writeBytes=$io.writeBytes;otherBytes=$io.otherBytes;readOps=$io.readOps;writeOps=$io.writeOps;otherOps=$io.otherOps;workingSet=$proc.WorkingSet64;privateBytes=$proc.PrivateMemorySize64;threads=$proc.Threads.Count;handles=$proc.HandleCount}
 } catch { [pscustomobject]@{pid=$proc.Id;error=$_.Exception.Message} }
}
function AllProcs { @(Get-Process | ForEach-Object { Snapshot $_ }) }
$counterJob=Start-Job -ScriptBlock {
 $paths=@('\Processor(_Total)\% Processor Time','\PhysicalDisk(_Total)\Disk Read Bytes/sec','\PhysicalDisk(_Total)\Disk Write Bytes/sec','\PhysicalDisk(_Total)\Avg. Disk sec/Read','\PhysicalDisk(_Total)\Current Disk Queue Length','\Memory\Available MBytes','\Memory\Pages/sec','\Network Interface(*)\Bytes Received/sec','\Network Interface(*)\Bytes Sent/sec')
 try { Get-Counter -Counter $paths -SampleInterval 1 -Continuous -ErrorAction Stop | ForEach-Object { foreach($s in $_.CounterSamples) { [pscustomobject]@{utc=$s.Timestamp.ToUniversalTime().ToString('o');path=$s.Path;value=$s.CookedValue;status=$s.Status} } } } catch { [pscustomobject]@{error=$_.Exception.Message} }
}

$p=$null
try {
 Write-Output '@@agent phase=baseline'
 $background0=AllProcs
 Start-Sleep -Seconds 3
 $background1=AllProcs
 @($background0,$background1) | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $runDir 'baseline-processes.json')
 $before=AllProcs
 $media=Get-ChildItem -LiteralPath $Folder -File | Where-Object Extension -in '.mkv','.mp4','.webm','.avi','.mov' | Sort-Object Name | Select-Object -First 1
 if (-not $media) { throw "No supported video in $Folder" }
 $exe=Join-Path $PSScriptRoot '..\..\dist\mpv.exe'
 $info=[Diagnostics.ProcessStartInfo]::new($exe)
 $info.UseShellExecute=$false
 if ($TraceShutdown) { $info.Environment['MPV_DEMUX_SHUTDOWN_TRACE']='1' }
 $info.RedirectStandardOutput=$true
 $info.RedirectStandardError=$true
 $argsList=@(
  ('--log-file='+(Join-Path $runDir 'mpv.log'))
  '--msg-level=all=warn,cplayer=v,demux=v'
  ('--script='+(Join-Path $PSScriptRoot 'quick-playlist-probe.lua'))
  ('--script-opts-append=quickperf-out='+(Join-Path $runDir 'events.jsonl'))
  ('--script-opts-append=quickperf-hold='+$HoldSeconds)
  $media.FullName
 )
 foreach($a in $argsList){$info.ArgumentList.Add($a)}
 $startUtc=[DateTime]::UtcNow
 $watch=[Diagnostics.Stopwatch]::StartNew()
 $p=[Diagnostics.Process]::Start($info)
 $processHandle=$p.Handle
 $stdoutTask=$p.StandardOutput.ReadToEndAsync()
 $stderrTask=$p.StandardError.ReadToEndAsync()
 Write-Output ('@@agent phase=playback pid='+$p.Id)
 $samples=[Collections.Generic.List[object]]::new()
 $deadlineHit=$false
 while (-not $p.HasExited) {
  $s=Snapshot $p
  $s | Add-Member -NotePropertyName elapsed -NotePropertyValue $watch.Elapsed.TotalSeconds
  $samples.Add($s)
  if ($watch.Elapsed.TotalSeconds -gt 105) { $deadlineHit=$true; $p.Kill(); break }
  Start-Sleep -Milliseconds 50
 }
 $p.WaitForExit(5000) | Out-Null
 $elapsed=$watch.Elapsed.TotalSeconds
 $final=Snapshot $p
 $stdoutTask.GetAwaiter().GetResult() | Set-Content (Join-Path $runDir 'stdout.txt')
 $stderrTask.GetAwaiter().GetResult() | Set-Content (Join-Path $runDir 'stderr.txt')
 $after=AllProcs
 @($before,$after) | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $runDir 'process-boundaries.json')
 $samples | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $runDir 'process-samples.json')
 [pscustomobject]@{startUtc=$startUtc.ToString('o');elapsedSec=$elapsed;exitCode=$p.ExitCode;deadlineHit=$deadlineHit;pid=$p.Id;final=$final;args=$argsList;executable=$exe;exeSha256=(Get-FileHash $exe).Hash;logicalProcessors=[Environment]::ProcessorCount;traceShutdown=[bool]$TraceShutdown;holdSeconds=$HoldSeconds;media=$media.Name;mediaBytes=$media.Length} | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $runDir 'run.json')
 Write-Output ('@@agent phase=stopped elapsed='+$elapsed+' exit='+$p.ExitCode)
 $events = @(Get-Content (Join-Path $runDir 'events.jsonl') |
     ForEach-Object { $_ | ConvertFrom-Json })
 $protocol = [ordered]@{
     starts = @($events | Where-Object name -eq 'start-file').Count
     firstFrames = @($events | Where-Object name -eq 'first-frame').Count
     nextCommands = @($events | Where-Object name -eq 'next-command').Count
     successfulCommands = @($events | Where-Object {
         $_.name -eq 'next-return' -and $_.detail.ok -eq $true
     }).Count
     quitReason = ($events | Where-Object name -eq 'quit-command').detail.reason
 }
 $protocol | ConvertTo-Json | Set-Content (Join-Path $runDir 'protocol.json')
 if ($protocol.starts -ne 7 -or $protocol.firstFrames -ne 7 -or
     $protocol.nextCommands -ne 6 -or $protocol.successfulCommands -ne 6 -or
     $protocol.quitReason -ne 'complete' -or $p.ExitCode -ne 0 -or $deadlineHit) {
     throw 'Playback protocol failed; inspect the retained events and log.'
 }
} finally {
 if ($p -and -not $p.HasExited) { $p.Kill(); $p.WaitForExit(5000) | Out-Null }
 Stop-Job $counterJob
 Receive-Job $counterJob | Select-Object * -ExcludeProperty RunspaceId,PSComputerName,PSShowComputerName | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $runDir 'system-counters.json')
 Remove-Job $counterJob
 Write-Output ('@@agent artifact='+$runDir)
}
