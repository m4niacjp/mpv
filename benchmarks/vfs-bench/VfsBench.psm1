#requires -Version 7.4
# Shared helpers for the mpv rclone-VFS cold/warm benchmark (benchmarks\vfs-bench).
# Every function is read-only unless its name says otherwise (Invoke-StandbyPurge,
# Remove-BenchColdCache, Set-RcloneLogLevel, Restore-BenchUserState).
Set-StrictMode -Version Latest

$script:Utf8NoBom = [Text.UTF8Encoding]::new($false)

function Get-BenchConfig {
    [pscustomobject]@{
        MpvPath       = 'C:\Users\andre\Projects\mpv\dist\mpv.exe'
        MountRoot     = 'I:\PerformanceBench'
        RemoteFs      = 'wcrypt:'                 # root Fs shared with the mount (bucket already verified)
        RemoteRoot    = 'PerformanceBench'
        CacheRoot     = 'D:\rclone-wasabi-cache\vfs\wcrypt'
        MetaRoot      = 'D:\rclone-wasabi-cache\vfsMeta\wcrypt'
        RcloneLog     = 'D:\rclone-wasabi-cache\logs\rclone-mount-http.log'
        RcUrl         = 'http://127.0.0.1:5574'
        RcAuthPath    = Join-Path $env:APPDATA 'rclone\rc-auth.json'
        Folders       = @('Cold', 'Warm')
        Count         = 25
        Prefix        = 'PB'
        StagingDir    = 'C:\PerfBench\videos'
        WarmupClip    = 'C:\PerfBench\warmup\PBWARM.mkv'
        MarkerDir     = 'C:\PerfBench\markers'
        UserConfigDir = Join-Path $env:APPDATA 'mpv'
        UserStateFiles = @('remember-volume.state', 'remember-rtx.state', 'remember-rtx.state.bak')
        SkillDir      = 'C:\Users\andre\.claude\skills\windows-performance-debugging'
        HarnessDir    = $PSScriptRoot
        GraceSeconds  = 60                        # --vfs-handle-caching on the wcrypt mount
        CoolDownSeconds = 75                      # grace + WinFsp cache-manager retention (<10 s) + margin
    }
}

function Get-BenchNames([int] $Count = 25, [string] $Prefix = 'PB') {
    1..$Count | ForEach-Object { '{0}{1:D2}.mkv' -f $Prefix, $_ }
}

function Write-BenchJson([string] $Path, $Object, [int] $Depth = 12) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [IO.File]::WriteAllText($Path, ($Object | ConvertTo-Json -Depth $Depth), $script:Utf8NoBom)
}

# ---------------------------------------------------------------- rclone RC
$script:RcHeaders = $null
function Get-RcHeaders {
    if (-not $script:RcHeaders) {
        $cfg = Get-BenchConfig
        $auth = Get-Content -LiteralPath $cfg.RcAuthPath -Raw | ConvertFrom-Json
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($auth.user):$($auth.pass)"))
        $script:RcHeaders = @{ Authorization = "Basic $b64" }   # never logged
    }
    $script:RcHeaders
}

function Invoke-BenchRc {
    param([Parameter(Mandatory)][string] $Path, [hashtable] $Body = @{}, [int] $TimeoutSec = 60)
    $cfg = Get-BenchConfig
    Invoke-RestMethod -Uri "$($cfg.RcUrl)/$Path" -Headers (Get-RcHeaders) -Method Post `
        -ContentType 'application/json' -Body ($Body | ConvertTo-Json -Compress -Depth 8) -TimeoutSec $TimeoutSec
}

function Set-RcloneLogLevel([ValidateSet('DEBUG', 'INFO', 'NOTICE')][string] $Level) {
    $null = Invoke-BenchRc 'options/set' @{ main = @{ LogLevel = $Level } }
    (Invoke-BenchRc 'options/get' @{ blocks = 'main' }).main.LogLevel
}

function Get-RcloneLogLength {
    $cfg = Get-BenchConfig
    (Get-Item -LiteralPath $cfg.RcloneLog).Length
}

# Returns only the log lines that mention the benchmark root, so unrelated
# client file names never leave the rclone log.
function Get-RcloneLogSlice([long] $FromOffset, [string] $Filter = 'PerformanceBench/') {
    $cfg = Get-BenchConfig
    $fs = [IO.FileStream]::new($cfg.RcloneLog, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try {
        if ($FromOffset -gt $fs.Length) { $FromOffset = 0 }   # rotated
        [void]$fs.Seek($FromOffset, [IO.SeekOrigin]::Begin)
        $text = [IO.StreamReader]::new($fs).ReadToEnd()
    } finally { $fs.Dispose() }
    @($text -split "`r?`n" | Where-Object { $_.Contains($Filter) })
}

# ---------------------------------------------------------------- VFS cache state
# vfsMeta Rs spans are the only coverage signal; the data file is pre-allocated
# to full size. The on-disk meta lags the in-memory item until rclone saves it
# (at latest when the item's handle grace period ends).
function Get-BenchCacheEntry([string] $Folder, [string] $Name) {
    $cfg = Get-BenchConfig
    $rel = Join-Path (Join-Path $cfg.RemoteRoot $Folder) $Name
    $data = Join-Path $cfg.CacheRoot $rel
    $meta = Join-Path $cfg.MetaRoot $rel
    $rec = [ordered]@{ folder = $Folder; name = $Name; dataExists = (Test-Path -LiteralPath $data); metaExists = (Test-Path -LiteralPath $meta)
        size = $null; rsBytes = 0; rsRanges = @(); coveragePct = 0.0; fingerprint = $null; dirty = $null; metaMtimeUtc = $null }
    if ($rec.metaExists) {
        $m = Get-Content -LiteralPath $meta -Raw | ConvertFrom-Json
        $rec.size = [long]$m.Size; $rec.fingerprint = $m.Fingerprint; $rec.dirty = $m.Dirty
        $rec.metaMtimeUtc = (Get-Item -LiteralPath $meta).LastWriteTimeUtc.ToString('o')
        $sum = 0L
        $rec.rsRanges = @(foreach ($r in @($m.Rs)) { if ($null -ne $r) { $sum += [long]$r.Size; [pscustomobject]@{ pos = [long]$r.Pos; size = [long]$r.Size } } })
        $rec.rsBytes = $sum
        if ($rec.size -gt 0) { $rec.coveragePct = [math]::Round(100.0 * $sum / $rec.size, 3) }
    }
    [pscustomobject]$rec
}

function Get-BenchCacheCensus([string] $Folder, [string[]] $Names) {
    @(foreach ($n in $Names) { Get-BenchCacheEntry $Folder $n })
}

# ---------------------------------------------------------------- standby purge
if (-not ('VfsBench.Mem' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace VfsBench {
public static class Mem {
    [StructLayout(LayoutKind.Sequential)]
    public struct SYSTEM_MEMORY_LIST_INFORMATION {
        public UIntPtr ZeroPageCount, FreePageCount, ModifiedPageCount, ModifiedNoWritePageCount, BadPageCount;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 8)] public UIntPtr[] PageCountByPriority;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 8)] public UIntPtr[] RepurposedPagesByPriority;
        public UIntPtr ModifiedPageCountPageFile;
    }
    [StructLayout(LayoutKind.Sequential)] struct LUID { public uint Low; public int High; }
    [StructLayout(LayoutKind.Sequential)] struct TOKEN_PRIVILEGES { public uint Count; public LUID Luid; public uint Attributes; }
    [DllImport("ntdll.dll")] static extern int NtSetSystemInformation(int cls, ref int info, int len);
    [DllImport("ntdll.dll")] static extern int NtQuerySystemInformation(int cls, out SYSTEM_MEMORY_LIST_INFORMATION info, int len, out int ret);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr h, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool LookupPrivilegeValue(string sys, string name, out LUID luid);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TOKEN_PRIVILEGES tp, int len, IntPtr prev, IntPtr ret);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    const int SystemMemoryListInformation = 80;
    public static int EnablePrivilege(string name) {
        IntPtr tok;
        if (!OpenProcessToken(GetCurrentProcess(), 0x28, out tok)) return Marshal.GetLastWin32Error();
        try {
            LUID luid;
            if (!LookupPrivilegeValue(null, name, out luid)) return Marshal.GetLastWin32Error();
            TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES { Count = 1, Luid = luid, Attributes = 2 };
            if (!AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero)) return Marshal.GetLastWin32Error();
            return Marshal.GetLastWin32Error(); // 0 or ERROR_NOT_ALL_ASSIGNED (1300)
        } finally { CloseHandle(tok); }
    }
    // 3 = MemoryFlushModifiedList, 4 = MemoryPurgeStandbyList
    public static int Command(int command) { return NtSetSystemInformation(SystemMemoryListInformation, ref command, 4); }
    public static SYSTEM_MEMORY_LIST_INFORMATION Query() {
        SYSTEM_MEMORY_LIST_INFORMATION i; int ret;
        int st = NtQuerySystemInformation(SystemMemoryListInformation, out i, Marshal.SizeOf(typeof(SYSTEM_MEMORY_LIST_INFORMATION)), out ret);
        if (st != 0) throw new InvalidOperationException("NtQuerySystemInformation status 0x" + st.ToString("X8"));
        return i;
    }
}
}
'@
}

function Get-StandbyMiB {
    $i = [VfsBench.Mem]::Query()
    $pages = 0UL; foreach ($p in $i.PageCountByPriority) { $pages += $p.ToUInt64() }
    [pscustomobject]@{ standbyMiB = [math]::Round($pages * 4096 / 1MB, 1); modifiedMiB = [math]::Round($i.ModifiedPageCount.ToUInt64() * 4096 / 1MB, 1); freeZeroMiB = [math]::Round(($i.FreePageCount.ToUInt64() + $i.ZeroPageCount.ToUInt64()) * 4096 / 1MB, 1) }
}

# System-wide: flushes the modified list, then empties the standby list
# (RAMMap "Empty Standby List"). Authorized by the user for this benchmark only.
function Invoke-StandbyPurge {
    $before = Get-StandbyMiB
    $priv = [VfsBench.Mem]::EnablePrivilege('SeProfileSingleProcessPrivilege')
    $flush = [VfsBench.Mem]::Command(3)
    $purge = [VfsBench.Mem]::Command(4)
    $after = Get-StandbyMiB
    [pscustomobject]@{ privilegeWin32 = $priv; flushStatus = ('0x{0:X8}' -f $flush); purgeStatus = ('0x{0:X8}' -f $purge); before = $before; after = $after; ok = ($flush -eq 0 -and $purge -eq 0) }
}

# ---------------------------------------------------------------- user state (real-config arm)
function Save-BenchUserState([string] $Destination) {
    $cfg = Get-BenchConfig
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    @(foreach ($f in $cfg.UserStateFiles) {
        $p = Join-Path $cfg.UserConfigDir $f
        if (Test-Path -LiteralPath $p) {
            Copy-Item -LiteralPath $p -Destination (Join-Path $Destination $f)
            [pscustomobject]@{ file = $f; exists = $true; sha256 = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash }
        } else { [pscustomobject]@{ file = $f; exists = $false; sha256 = $null } }
    })
}

function Restore-BenchUserState([string] $Source, $Snapshot) {
    $cfg = Get-BenchConfig
    @(foreach ($s in $Snapshot) {
        $p = Join-Path $cfg.UserConfigDir $s.file
        $now = if (Test-Path -LiteralPath $p) { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash } else { $null }
        $changed = $now -ne $s.sha256
        if ($changed -and $s.exists) { Copy-Item -LiteralPath (Join-Path $Source $s.file) -Destination $p -Force }
        [pscustomobject]@{ file = $s.file; changedByTrial = $changed; restored = ($changed -and $s.exists); createdByTrial = ($changed -and -not $s.exists) }
    })
}

# ---------------------------------------------------------------- MKV layout (top-level Segment children)
function Get-MkvLayout([string] $Path) {
    $names = @{ 0x114D9B74 = 'SeekHead'; 0x1549A966 = 'Info'; 0x1654AE6B = 'Tracks'; 0x1254C367 = 'Tags'; 0x1C53BB6B = 'Cues'
        0x1043A770 = 'Chapters'; 0x1941A469 = 'Attachments'; 0x1F43B675 = 'Cluster'; 0xEC = 'Void' }
    $fs = [IO.File]::OpenRead($Path)
    try {
        function Read-Vint([IO.Stream] $s, [bool] $keepMarker) {
            $b = $s.ReadByte(); if ($b -lt 0) { return $null }
            $len = 1; $mask = 0x80
            while ($len -le 8 -and -not ($b -band $mask)) { $len++; $mask = $mask -shr 1 }
            $v = [uint64]($(if ($keepMarker) { $b } else { $b -band ($mask - 1) }))
            for ($i = 1; $i -lt $len; $i++) { $v = ($v -shl 8) -bor [uint64]$s.ReadByte() }
            [pscustomobject]@{ value = $v; length = $len }
        }
        $id = Read-Vint $fs $true; $sz = Read-Vint $fs $false; [void]$fs.Seek([long]$sz.value, 'Current')   # EBML header
        $segId = Read-Vint $fs $true; $segSz = Read-Vint $fs $false
        $segStart = $fs.Position
        $items = [Collections.Generic.List[object]]::new(); $clusters = 0; $firstCluster = $null; $lastCluster = $null; $malformed = $false
        while ($fs.Position -lt $fs.Length) {
            $pos = $fs.Position
            $eid = Read-Vint $fs $true; if ($null -eq $eid) { break }
            $esz = Read-Vint $fs $false; if ($null -eq $esz) { break }
            $name = $names[[int]$eid.value]; if (-not $name) { $name = ('0x{0:X}' -f $eid.value) }
            if ($name -eq 'Cluster') { $clusters++; if ($null -eq $firstCluster) { $firstCluster = $pos }; $lastCluster = $pos }
            else { $items.Add([pscustomobject]@{ element = $name; pos = $pos; size = [long]$esz.value }) }
            [void]$fs.Seek([long]$esz.value, 'Current')
            # A zero-size or non-advancing element otherwise loops forever on a
            # malformed or zero-filled file (e.g. data lost in a hard reset).
            if ($fs.Position -le $pos) { $malformed = $true; break }
        }
        [pscustomobject]@{ fileSize = $fs.Length; segmentDataStart = $segStart; clusters = $clusters; firstClusterPos = $firstCluster; lastClusterPos = $lastCluster; malformed = $malformed
            elements = @($items); trailingElements = @($items | Where-Object { $_.pos -gt $lastCluster } | ForEach-Object element) }
    } finally { $fs.Dispose() }
}

Export-ModuleMember -Function *
