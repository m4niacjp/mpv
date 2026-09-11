# Control-arm (`--no-config --autocreate-playlist=filter`) wait/stack analysis

Deep control ETL only. Source trace (read-only):
`C:\Users\andre\PerfRuns\mpv-wpd-20260911\mpv-no-config-20260911T090139772Z-b8f2b28a653045a5a3b02a254fce3aa2\traces\capture-a091ae2dc1e04322825042b4a27aec4d.etl`
(3.35 GB, CPU.Verbose+FileIO.Verbose, 28.746 s, 0 lost buffers / 0 lost events,
`logs\tracestats-control.txt`). No re-capture was performed; the concurrent
real-arm exporter shares the machine, so export wall-time is not evidence.

This file is an additive analysis artifact for the existing package
`benchmarks\Run-20260911-165208-mpv-playlist-skip\`; no other package file was
modified.

## 0. Wall-clock → ETL mapping

All ETL times below are trace-relative microseconds. Anchors: WPR markers
(`workload-start` = 434,898 µs, `workload-end` = 6,422,654 µs) and supervisor
event UTC timestamps from `measurements\scenario-events-527974e648ee4ad08f54a5ffc432003f.jsonl`
(ETL start 2026-09-11T09:06:46.9455874Z; mpv PID 57788, launched +457 ms).

| Boundary | ETL-relative | Source |
| --- | ---: | --- |
| mpv started (PID 57788) | +457 ms | supervisor |
| T1 first frame (`playback-restart`) | +846 ms | supervisor + log 0.364 s |
| next-1 accepted (v2) | +5,880 ms | supervisor IPC reply |
| v2 "Playing:" / stream open / Opening done | ~+5,892 / +5,897 / +5,899 | mpv log 5.416/5.421/5.423 s + ~476 ms offset; opener T-Start 5.8990 s |
| frame-2 | +5,957 ms | supervisor (count 2) |
| next-2 accepted (v3) | +5,959 ms | supervisor IPC reply |
| v3 "Playing:" / stream open / Opening done | ~+5,985 / +5,991 / +5,993 | mpv log 5.509/5.513/5.515 s + ~476 ms offset; opener T-Start 5.9917 s |
| v3 first frame (T4) | +6,139 ms | supervisor (count 3) |
| `quit` accepted | +6,146 ms | supervisor IPC reply |
| main thread T-End | +6,313 ms | ETW T-End tid 55432 |
| process P-End | +6,318 ms | ETW P-End mpv (57788) |
| supervisor observes exit | +6,332 ms | supervisor |
| `workload-end` marker | +6,423 ms | WPR marker |

Uncertainty: the supervisor/log clock domain and the ETW timebase agree to
within about ±5 ms at phase boundaries; mpv log-file line times run ~30 ms
before the supervisor observes them (polling), so log-based phase splits carry
that offset. Relative ordering inside the trace is exact (QPC).

Decision windows used for the dumps: **transition** 5,850,000–6,160,000 µs
(310 ms) and **quit** 6,140,000–6,350,000 µs (210 ms).

## 1. Symbol and identity coverage

- **Thread identity is good.** ETW thread-name events are present and used
  (`demux`, `opener`, `av:h264:df0..df15`, `vo`, `window`, `log`, `curl`,
  `worker`, `pool-0`, `ao/wasapi`, `ipc/ipc-0..2`, `ipc/named-pipe`, `lua/*`,
  `dnd`, `osc`).
- **mpv.exe has no PDBs** (`build\` and `dist\` contain none), so mpv frames are
  module+offset only. **rclone.exe is Go** and has no PDB. The hot exit-phase PC
  `mpv.exe!0x00007ff74aec1460` cannot be attributed to a function from this
  environment.
- System/kernel symbols are available (`_NT_SYMBOL_PATH=srv*C:\symbols*https://msdl.microsoft.com/download/symbols`;
  the two WPAExporter table exports ran with `-symbols`). The xperf dumper
  dumps were deliberately collected **without** `-symbols` (module-level stacks
  only) to fit the time budget and to keep rclone/mpv attribution realistic.
- WPAExporter CSV drops stack columns for the CPU Usage (Precise) and Sampled
  presets and rolls mpv/rclone up to one process row (both stack-visible
  profiles tried: `control-delays.wpaProfile`, `control-precise-stacks.wpaProfile`).
  Per-wait/per-sample stacks therefore required the xperf dumper path, and
  wait-stack *leaf* attribution remains INCONCLUSIVE (see §6).

## 2. Q1 — are control threads waiting, and in what? (transition)

**VERIFIED: the control transition is not wait-bound; it is a warm-cache read +
decode/VO pipeline.** In the 310 ms window:

| quantity (5.850–6.160 s) | value |
| --- | --- |
| mpv ReadFile on the mount (`\\;WinFsp.Mup+…\server\RcloneWcrypt\…`), matched IRP start→OpEnd | 864 ops, 68.79 MB, 144.9 ms total latency, **max 15.3 ms** (≈0.17 ms/op) |
| System paging reads on the mount | 386 ops, 68.46 MB, 189.9 ms total, max 15.4 ms |
| rclone reads from `D:\rclone-wasabi-cache\vfs\wcrypt\…` | 786 ops, 137.93 MB, 153.5 ms total, max 15.3 ms |
| rclone writes into the VFS cache | 2 ops, ≈0 B (one 257 B write at 5.9016 s) |
| System paging write into the VFS cache | 2 ops, 2.00 MB (lazy-writer flush of the v1 cache file) |

Slowest mount op in the window is 15.4 ms (System, aborted v2 file); the slowest
mpv op is 15.3 ms. There is no 0.4–0.76 s read in the window.

Wait reasons from CSwitch (pair switch-out → next switch-in of the same TID):

| thread | total wait in window | top reasons |
| --- | ---: | --- |
| main (tid 55432) | 272.8 ms sum / 275 events | `WrAlertByThreadId` 250.7 ms / 218 (max 66.3 ms), `UserRequest` 21.5 ms / 54 (max 7.8), `WrLpcReply` 0.6 ms / 3 |
| demux v1 (44340) | 24.5 ms | `WrPageIn` 18.2 / 21 (max 15.3), `WrAlertByThreadId` 6.2 |
| opener v2 (46668) | 2.5 ms | `WrPageIn` 1.4, `Executive` 1.1 |
| opener v3 (33492) | 2.1 ms | `WrPageIn` 1.1, `Executive` 1.0 |
| v2/v3 decoder `av:h264:df*` | ~55–155 ms each | `WrAlertByThreadId` (idle-between-frames), plus one 20–140 ms wait during their own teardown |

- The only single wait >50 ms on an mpv thread is a 66 ms `WrAlertByThreadId`
  on the main thread — the normal alertable event-loop wait while worker
  threads run. No mpv/rclone thread is blocked on I/O completion for a
  material interval in this window.
- READY time is negligible (WPA precise, 650 ms window 5.75–6.40 s):
  mpv ready sum 49.4 ms, max 1.29 ms; rclone ready sum 24.6 ms, max 0.77 ms.
  No scheduler contention.
- Sampled running time (same window, module level): mpv ≈679 samples, mostly
  `ucrtbase` (memcpy-like) with callers `avcodec-63` (94), `libplacebo-360`
  (86), `ntdll` (72), `D3DCompiler_47` (30), `libshaderc` (11), plus
  `nvwgf2umx` (20); rclone 113 samples, **92 inside `winfsp-x64.dll`** (+11
  winfsp+rclone) and 21 in `rclone.exe` — i.e. rclone CPU is WinFsp service
  work, not TLS/network. mpv ≈3.91 % of 32 CPUs (~0.81 s CPU) and rclone
  ≈0.59 % (~0.12 s) in the 650 ms window.

Phase shape (I/O read count per 10 ms bin, mount paths):

```
5.90–5.95  small reads (v2 open + abort, 3–58 ops / 0.2–4.8 MB per bin)
5.97–5.99  quiet (playlist switch / teardown of v2)
6.00–6.15  70–91 reads / 8–10 MB per 10 ms — v3 decoder read-ahead loop
```

So next-2→frame-3 (~180 ms) is ≈30 ms playlist switch + open/demux/header
(v3 opener T-Start 5.9917 s → decoders 5.9997–6.0001 s) and ≈140 ms read-ahead
decode + shader/VO init before the first frame at +6,139 ms — with file reads
served from cache at sub-millisecond average latency. **INCONCLUSIVE only for
the exact leaf stack of each wait** (module-level stacks; see §6).

## 3. Q2 — does warm VFS cache explain the gap?

**VERIFIED (this run): the control's reads were served by the rclone VFS cache,
not by the backend.** All 786 rclone media reads in the window are reads of
`D:\rclone-wasabi-cache\vfs\wcrypt\XXX\new2\<file>.mkv`; there is no large
cache-data write that would accompany an S3 download (rclone write ops in the
window: 2, ≤257 B; System paging flush 2.0 MB can reflect earlier writes). No
rclone sample lands in Go network/TLS code, and the sibling deep report already
recorded rclone RC stats of 0–2 backend transfers per 5 s window for the control
arm. Cross-process handoff is visible and sub-millisecond: the v2 opener
(46668) is readied **by rclone.exe 32664** at 5.899411 s and repeatedly through
5.9001 s (WinFsp open/read responses), and rclone 32664 is readied by
`System (4)` on its cache-read completions.

**CONTRADICTED: "the control open path is structurally faster, therefore cache
warmth is irrelevant."** The transition still moves 68.8 MB through the mount
(plus 137.9 MB of rclone cache reads) in 310 ms; sustaining that requires the
0.1–2 ms per-read service that only a warm cache provides. A cold backend read
measured in the same investigation costs 0.38–0.76 s (Procmon observer passes;
playlist-skip report §6.1 and finding 3), which cannot support this read rate.
The control's *non-I/O* terms are also structurally smaller (no `playlist-sort`
PowerShell hook, no prefetch, no RTX VPP, software decode), which explains why
the control needs no more than a warm cache to finish in ≤484 ms.

Corollary evidence for the aborted-open cost: the skipped v2 file's reads in
this window cost at most 15.4 ms, versus the real arm's multi-second
CreateFile/CloseFile on the aborted entry (report §7 item 4).

## 4. Q3 — control `quit` → exit

**VERIFIED: ~186 ms, almost entirely CPU teardown, with no rclone/WinFsp/TCP
wait and no file I/O after +6.153 s.** Trace-relative thread-exit sequence
(first T-End per phase):

| phase | interval | ending threads |
| --- | --- | --- |
| quit → pipeline teardown | 6.146–6.178 | v3 decoders 6.157–6.160, demux 6.171, built-in Lua (`osc/stats/console/select/positioning/commands/ytdl_hook`), `dnd`, `ipc/named-pipe`, `ao/wasapi` 6.177 |
| VO/window + GPU/shader workers | 6.176–6.231 | `window` 6.216; ~30 libplacebo/shader/GPU-pool threads 6.218–6.231 |
| pool joins | 6.231–6.258 | `vo` 6.2485, `log` 6.2493, `curl` 6.2499, `worker`×2 + `pool-0` + batch 6.2574–6.2583 |
| **main thread alone** | **6.258–6.313** | sampled continuously (~1 ms cadence) at `mpv.exe!0x00007ff74aec1460` with varying `ntoskrnl` kernel frames; no other mpv thread alive |
| process teardown | 6.313–6.318 | T-End(55432) 6.3130, P-End 6.3182; supervisor exit 6.3321 |

File I/O after the quit command: last mount OpEnd 6.1524 s, last mpv
`FileIoCleanup` 6.1707 s, then nothing. The final ~74 ms is a single-threaded
process-exit phase (thread-pool/CRT teardown class of work). No `WrLpcReply` /
`WrQueue` / `WrIoCompletion` blocking and no cross-process wakeups on the
critical path; the largest waits in the window are event-loop slices on the
main thread (max 71 ms `UserRequest`, one 52 ms `DelayExecution`) while the
other threads drain. Ready-time outliers (e.g. tid 47196 102 ms) appear to be
termination readies and are not treated as scheduler contention.

Comparison to published real-arm numbers only (real ETL is another lane's
scope): playlist-skip real `quit→exit` was 695/1104/924 ms, deep real run
2.025 s, versus control 60–352 ms (playlist-skip) and 186 ms here. The control
teardown contains none of the real arm's extra teardown objects (`vf remove
@rtxvideo`, user Lua scripts, prefetch/cache workers, in-flight aborted opens).
The control ETL cannot itself prove what blocks the real arm; its role is to
bound the core teardown at ~186 ms and to show that mpv's own exit path does
not wait on rclone/WinFsp in the clean configuration. VERIFIED for control;
INCONCLUSIVE for the real-arm blocking chain.

## 5. Q4 — waits that would remain cold

| wait | present in control transition? | cold behavior |
| --- | --- | --- |
| rclone VFS-cache media read | yes, 0.1–2 ms/op | replaced by S3 GET + cache write (0.38–0.76 s/op measured on the real arm; plus TLS/TCP and D: writes) |
| WinFsp user↔kernel round trip, mpv↔rclone handoff | yes, sub-ms (ready handoffs at 5.8994–5.9001 s) | unchanged; structural but small |
| rclone Go scheduling / WinFsp service | `winfsp-x64.dll` samples | unchanged; grows with real request latency |
| mpv pipeline (open→demux→decode→VO) | yes, ~170 ms of the 180 ms transition | unchanged (same work; decode may wait longer for data) |
| process/thread teardown at quit | yes, ~186 ms CPU | unchanged unless streams are mid-flight cold I/O |

Implication for the arm comparison: the control's 86–484 ms transitions are
**warm-cache numbers and must not be transferred to cold inputs**. A cold
control run would still avoid the real arm's script hook (~0.5–0.8 s/open) and
prefetch/RTX terms, so it should stay faster than the real arm, but its open
phase would be dominated by S3 latency exactly like the real arm's cold reads.

## 6. Trimmed stacks (module level) and their limits

- Transition, rclone: `winfsp-x64.dll` (92) and `rclone.exe` (21) top frames,
  kernel side `ntoskrnl`; consistent with WinFsp request servicing.
- Transition, mpv: `ucrtbase` ← `avcodec-63` / `libplacebo-360` / `ntdll` /
  `D3DCompiler_47` / `libshaderc` / `mpv.exe`; `nvwgf2umx` ← `dxgmms2.sys`
  (GPU submit). Read/FileIo completion stacks on the mount are kernel-only
  (`ntoskrnl` ← `fileinfo.sys` ← `FLTMGR.SYS`), i.e. the paging path; the
  WinFsp user-side frames are not present on those stack records.
- Quit tail: samples of the surviving main thread repeatedly show
  `mpv.exe!0x00007ff74aec1460` + `ntoskrnl.exe!0x…` while no other thread runs.
- Wait-stack leaves are **not resolvable** with the current artifacts: switch-out
  stacks attach to the incoming thread and are kernel-only; the dumper dumps
  are unsymbolized for mpv/rclone; WPAExporter omitted stack columns. Exact
  blocking primitive per wait remains INCONCLUSIVE.

## 7. Gaps / next discriminating measurements

1. Re-dump 5.99–6.16 s and 6.25–6.34 s with `xperf … -symbols` to resolve the
   kernel wait paths and the exit-phase loop (`mpv.exe!0x7ff74aec1460`).
2. Open the control ETL in the WPA UI and expand CPU Usage (Precise) mpv rows
   to read per-wait stack + `New Wait Reason` (CSV export limitation).
3. One cold control trial on an input with verified absent VFS cache (check
   `vfs/stats`/rclone RC before the run) — the decisive structure-vs-warmth test.
4. Build mpv with PDBs (debug/`/DEBUG`) to attribute the exit-phase PC.
5. Repeat the deep control capture ≥3× for variability (this analysis is one run).

## 8. Artifacts (external, not in Git)

Base: `C:\Users\andre\PerfRuns\mpv-stack-analysis-20260911\control\`

- Dumps: `dump-all-transition-5850-6160.txt` (344 MB),
  `dump-all-quit-6140-6350.txt` (241 MB); probes `probe-all-5950-6000.txt`,
  `rawdata-5950050-5950080.txt`.
- Parsed events: `ev-transition-events.csv` (20 MB), `ev-quit-events.csv`,
  `ev-transition-waits.csv`, `ev-quit-waits.csv`, `*-summary.json`.
- Analyses: `analysis-transition.txt`, `analysis-quit.txt`,
  `query-transition.txt`, `query-quit2.txt`, `ready-transition.txt`,
  `stacks-transition.txt`, `stacks-quit.txt`.
- WPAExporter runs (with `-symbols`): `export-delay-window-5750-6400\`
  (precise Thread-Delays + sampled, 650 ms window),
  `export-precise-stacks-5750-6400\`, `val-threaddelays\`.
- Profiles: `control-delays.wpaProfile`, `control-precise-stacks.wpaProfile`
  (built from the prior lane's `_ref-*.xml` presets; WPAExporter 11.7.395.48728).
- Scripts: `parse_dump.py`, `analyze_events.py`, `query_events.py`,
  `readycheck.py`, `stackcheck.py`, `tailcheck.py`, `writecheck.py`.
- Source trace and deep-run logs/measurements remain at
  `C:\Users\andre\PerfRuns\mpv-wpd-20260911\mpv-no-config-20260911T090139772Z-b8f2b28a653045a5a3b02a254fce3aa2\`
  (ETL, mpv log `measurements\mpv-527974e648ee4ad08f54a5ffc432003f.log`,
  scenario events, separate-reproduction Procmon CSV at
  `exports\procmon-0e5e8ae400c24093a64baf0ebecb2af0.csv`).
