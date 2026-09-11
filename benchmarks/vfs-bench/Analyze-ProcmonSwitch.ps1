#requires -Version 7.4
<#
.SYNOPSIS
Extracts the playlist-next switch window from one Procmon trial into a small JSON.

.DESCRIPTION
Streams the trial's exported Procmon CSV once to locate the probe markers
(`<trial>-NN-cmd-playlist-next.mark`, `<trial>-NN-playback-restart.mark`), then
again for the rows of interest in the window [cmd-playlist-next, last
playback-restart] for the mpv PID (and optional extra PIDs such as the rclone
mount). TextFieldParser from PowerShell was too slow for 1.5-2.7 M rows, so the
scan is a compiled CSV reader.

Outputs per-PID aggregates (operations, total/max duration), the top rows by
duration, and a per-file (PB*.mkv) first/last access summary including parsed
ReadFile lengths. Writes `<id>-procmon-switch.json` under -OutDir.

This is analysis-only: input files are read, nothing else is touched.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $TrialJson,
    [string] $OutDir = 'C:\PerfBench\analysis\procmon',
    [int[]] $ExtraPids = @(),
    [int] $TopN = 40,
    [double] $SlowSeconds = 0.05
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not ('ProcmonSwitch.Scan' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;

namespace ProcmonSwitch {
    public class Row {
        public DateTime Time;
        public string Pid = "";
        public string Op = "";
        public string Path = "";
        public string Result = "";
        public string Detail = "";
        public string Tid = "";
        public double Dur;
    }

    public static class Scan {
        static string[] Line(string s) {
            var fields = new List<string>();
            var sb = new StringBuilder();
            bool quoted = false;
            for (int i = 0; i < s.Length; i++) {
                char c = s[i];
                if (quoted) {
                    if (c == '"') {
                        if (i + 1 < s.Length && s[i + 1] == '"') { sb.Append('"'); i++; }
                        else quoted = false;
                    } else sb.Append(c);
                } else if (c == '"') quoted = true;
                else if (c == ',') { fields.Add(sb.ToString()); sb.Clear(); }
                else sb.Append(c);
            }
            fields.Add(sb.ToString());
            return fields.ToArray();
        }

        static DateTime ParseTime(string s) {
            DateTime dt;
            if (DateTime.TryParse(s, CultureInfo.CurrentCulture, DateTimeStyles.None, out dt)) return dt;
            if (DateTime.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.None, out dt)) return dt;
            return DateTime.MinValue;
        }

        static double ParseDur(string s) {
            if (string.IsNullOrWhiteSpace(s)) return 0;
            double d;
            if (double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out d)) return d;
            if (double.TryParse(s, NumberStyles.Float, CultureInfo.CurrentCulture, out d)) return d;
            return 0;
        }

        /// <summary>markersOnly: Path contains trialId and ends with .mark.
        /// Otherwise: Pid in pids and Time in [from,to].</summary>
        public static List<Row> Run(string csv, string trialId, string[] pids, DateTime from, DateTime to, bool markersOnly) {
            var result = new List<Row>();
            using (var reader = new StreamReader(csv, Encoding.UTF8, true))
            {
                string header = reader.ReadLine();
                if (header == null) return result;
                var h = Line(header);
                int iTime = Array.IndexOf(h, "Time of Day");
                int iPid = Array.IndexOf(h, "PID");
                int iOp = Array.IndexOf(h, "Operation");
                int iPath = Array.IndexOf(h, "Path");
                int iRes = Array.IndexOf(h, "Result");
                int iDet = Array.IndexOf(h, "Detail");
                int iDur = Array.IndexOf(h, "Duration");
                int iTid = Array.IndexOf(h, "TID");
                if (iTime < 0 || iPid < 0 || iPath < 0) throw new Exception("CSV lacks Time of Day/PID/Path columns");

                string line;
                while ((line = reader.ReadLine()) != null) {
                    var f = Line(line);
                    if (iPath >= f.Length) continue;
                    string path = f[iPath];
                    if (markersOnly) {
                        if (trialId.Length == 0 || !path.Contains(trialId)) continue;
                        if (!path.EndsWith(".mark", StringComparison.OrdinalIgnoreCase)) continue;
                    } else {
                        if (iPid >= f.Length) continue;
                        string pid = f[iPid];
                        bool wanted = false;
                        foreach (var p in pids) if (p == pid) { wanted = true; break; }
                        if (!wanted) continue;
                        var t = ParseTime(f[iTime]);
                        if (t < from || t > to) continue;
                    }
                    var r = new Row();
                    r.Time = ParseTime(f[iTime]);
                    r.Pid = iPid < f.Length ? f[iPid] : "";
                    r.Op = iOp >= 0 && iOp < f.Length ? f[iOp] : "";
                    r.Path = path;
                    r.Result = iRes >= 0 && iRes < f.Length ? f[iRes] : "";
                    r.Detail = iDet >= 0 && iDet < f.Length ? f[iDet] : "";
                    r.Dur = iDur >= 0 && iDur < f.Length ? ParseDur(f[iDur]) : 0;
                    r.Tid = iTid >= 0 && iTid < f.Length ? f[iTid] : "";
                    result.Add(r);
                }
            }
            return result;
        }
    }
}
'@
}

$trial = Get-Content -LiteralPath $TrialJson -Raw | ConvertFrom-Json
$recordPath = $trial.result.capture.recordPath
$record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
$csvPath = $record.csvPath
$mpvPid = [string]$record.workload.processId
$trialId = [string]$trial.id
if (-not (Test-Path -LiteralPath $csvPath)) { throw "CSV not found: $csvPath" }

Write-Host "scanning markers in $([IO.Path]::GetFileName($csvPath)) ($([math]::Round((Get-Item $csvPath).Length / 1MB, 1)) MB)"
$markers = [ProcmonSwitch.Scan]::Run($csvPath, $trialId, @(), [DateTime]::MinValue, [DateTime]::MaxValue, $true) |
    Sort-Object Time
$next = @($markers | Where-Object { $_.Path -like '*-cmd-playlist-next.mark' })
$restarts = @($markers | Where-Object { $_.Path -like '*-playback-restart.mark' })
if ($next.Count -eq 0) { throw "no cmd-playlist-next marker for $trialId" }
if ($restarts.Count -lt 2) { throw "expected 2 playback-restart markers, found $($restarts.Count)" }
$from = $next[0].Time
$to = $restarts[-1].Time

# main and prefetch files from the probe playlist snapshot before next
$probe = Get-Content -LiteralPath $trial.probeJson -Raw | ConvertFrom-Json
$snap = $probe.playlists | Where-Object { $_.tag -eq 'before-next' } | Select-Object -First 1
$mainName = $null; $prefName = $null
if ($snap) {
    $entries = @($snap.entries); $pos = [int]$snap.pos
    if ($entries.Count -gt $pos + 1) { $mainName = [string]$entries[$pos + 1].name }
    if ($entries.Count -gt $pos + 2) { $prefName = [string]$entries[$pos + 2].name }
}

$pids = @($mpvPid) + @($ExtraPids | ForEach-Object { [string]$_ })
Write-Host "window $($from.ToString('HH:mm:ss.fff')) .. $($to.ToString('HH:mm:ss.fff')) ($([math]::Round(($to - $from).TotalSeconds, 2)) s), mpv PID $mpvPid, main=$mainName prefetch=$prefName"
$rows = [ProcmonSwitch.Scan]::Run($csvPath, '', $pids, $from, $to, $false)

function Summarize([object[]] $set) {
    $byOp = [ordered]@{}
    foreach ($g in ($set | Group-Object Op | Sort-Object { ($_.Group | Measure-Object Dur -Sum).Sum } -Descending)) {
        $sum = ($g.Group | Measure-Object Dur -Sum).Sum
        $max = ($g.Group | Measure-Object Dur -Maximum).Maximum
        $byOp[$g.Name] = [pscustomobject]@{ count = $g.Count; totalSec = [math]::Round($sum, 4); maxSec = [math]::Round($max, 4) }
    }
    [pscustomobject]@{ rows = $set.Count; byOperation = $byOp }
}

$out = [ordered]@{
    schemaVersion = 1
    trial = $trialId; csvPath = $csvPath; pmlPath = $record.pmlPath
    window = [pscustomobject]@{ next = $from.ToString('o'); restart2 = $to.ToString('o'); seconds = [math]::Round(($to - $from).TotalSeconds, 3) }
    main = $mainName; prefetch = $prefName
    pids = [pscustomobject]@{ mpv = $mpvPid; extra = @($ExtraPids) }
    perPid = [ordered]@{}
    topByDuration = @($rows | Sort-Object Dur -Descending | Select-Object -First $TopN | ForEach-Object {
        [pscustomobject]@{ t = $_.Time.ToString('HH:mm:ss.fff'); pid = $_.Pid; tid = $_.Tid; op = $_.Op; path = $_.Path; result = $_.Result; sec = [math]::Round($_.Dur, 4) }
    })
    files = [ordered]@{}
}
foreach ($g in ($rows | Group-Object Pid)) { $out.perPid[$g.Name] = Summarize @($g.Group) }
foreach ($name in @($mainName, $prefName) | Where-Object { $_ }) {
    $fr = @($rows | Where-Object { $_.Path -like "*\$name" })
    if ($fr.Count -eq 0) { continue }
    $reads = @($fr | Where-Object { $_.Op -eq 'ReadFile' })
    $bytes = 0L
    foreach ($r in $reads) {
        if ($r.Detail -match 'Length:\s*([0-9,]+)') { $bytes += [long]($Matches[1] -replace ',', '') }
    }
    $out.files[$name] = [pscustomobject]@{
        first = ($fr | Sort-Object Time | Select-Object -First 1).Time.ToString('HH:mm:ss.fff')
        last = ($fr | Sort-Object Time | Select-Object -Last 1).Time.ToString('HH:mm:ss.fff')
        rows = $fr.Count; readRows = $reads.Count; readMiB = [math]::Round($bytes / 1MB, 2)
        ops = @($fr | Group-Object Op | ForEach-Object { [pscustomobject]@{ op = $_.Name; count = $_.Count } })
    }
}
$out.slowest = @($rows | Where-Object { $_.Dur -ge $SlowSeconds } | Sort-Object Dur -Descending | ForEach-Object {
    [pscustomobject]@{ t = $_.Time.ToString('HH:mm:ss.fff'); pid = $_.Pid; tid = $_.Tid; op = $_.Op; path = $_.Path; result = $_.Result; sec = [math]::Round($_.Dur, 4) }
})

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$path = Join-Path $OutDir "$trialId-procmon-switch.json"
[IO.File]::WriteAllText($path, ($out | ConvertTo-Json -Depth 8))
Write-Host "wrote $path ($($rows.Count) rows for the window)"
$out.perPid.GetEnumerator() | ForEach-Object { "pid $($_.Key): $($_.Value.rows) rows" }
if ($out.files.Contains($mainName)) { "main $mainName reads: $($out.files[$mainName].readRows) rows, $($out.files[$mainName].readMiB) MiB" }
if ($prefName -and $out.files.Contains($prefName)) { "prefetch $prefName reads: $($out.files[$prefName].readRows) rows, $($out.files[$prefName].readMiB) MiB" }
