# Real-arm wait/stack analysis (retained deep ETL)

Scope: stack-level answers for the **real arm only**, from the retained deep capture
`capture-27b08a25da7f4e81b77092c46603bff6.etl` (3.43 GB, CPU.Verbose + FileIO.Verbose,
41.275 s, 0 lost buffers / 0 lost events, `Sequential Relogged`). mpv PID **39720**
(exit code 0, 3 first-presented frames), rclone mount PID **55588** (second rclone
process 44512 also present). No re-capture, no repo change; raw exports live outside Git.

This file modifies nothing else in `benchmarks\Run-20260911-165208-mpv-playlist-skip\`.

## 1. Window mapping (wall clock ↔ ETL)

ETL t0 = **2026-09-11 09:04:08.4997 UTC = 16:04:08.4997 local** (tracestats).
Supervisor events (`scenario-events-173fae25…jsonl`) and mpv log (`--msg-time`,
process-relative log seconds) map as:

| Event | mpv log s | ETL t (s) | source |
| --- | ---: | ---: | --- |
| mpv process start | — | ~0.4345 | thread 59912 lifetime start; `mpv-started` UTC 09:04:08.9372 |
| first frame (frame 1) | 1.846 | 2.377 | supervisor UTC |
| next-1 accepted | 6.963 | 7.4257 | supervisor UTC 09:04:15.9255 |
| "Aborting ongoing prefetch of wrong URL" | 7.005 | ~7.465 | log + ~0.46 s offset |
| frame 2 | 9.460 | 9.9717 | supervisor UTC 09:04:18.4714 |
| next-2 accepted | 9.617 | 10.0763 | supervisor UTC 09:04:18.5761 |
| "Done terminating demuxers" (2nd end-file) | 12.774 | 13.234 | log +0.46 |
| `playlist_sort/on_before_start_file` hook start | 12.781 | 13.241 | log +0.46 |
| "Playing:" third file (prefetched URL) | 16.205 | 16.665 | log +0.46 |
| frame 3 | 16.620 | 17.0898 | supervisor UTC 09:04:25.5896 |
| `quit` issued | 16.635 | 17.0945 | supervisor UTC 09:04:25.5942 |
| mpv exit | — | 19.1196 | supervisor UTC 09:04:27.6193 |

- **Transition window A** = accepted next-1 → frame 3 = **7.4257 → 17.0898 s (9.664 s)**.
  Decomposition: A1 = first transition/open 7.4257 → 9.9717 (2.546 s);
  A2 = second next → frame 3 = 10.0763 → 17.0898 (7.014 s), itself
  10.076→13.234 teardown (3.16 s) + 13.239→16.659 gated open (3.420 s) + 16.665→17.090 open/frame (0.425 s).
- **Quit window B** = `quit` → exit = **17.0945 → 19.1196 s (2.0251 s)** (this ETL's own number;
  the 0.69–1.10 s quoted in the parent report is the 165208 harness trials, a different batch).
- Uncertainty: supervisor UTC phases ±20 ms; log-derived phases ±60 ms (frame-detection
  latency varies 0.47–0.53 s). CSwitch timestamps below are exact to the µs in the ETL.

Commands actually used (all read-only):
`Export-WpaTables.ps1` (WPAExporter 11.7.395.48728, `-symbols`) for range probes and
`xperf -i <etl> -tle -symbols -o <out> -a dumper -range <us> <us>` for 9 slices, then
custom PowerShell parsers (`…\real\filter-slices.ps1`, `analyzer.ps1`).

## 2. Symbol coverage

`_NT_SYMBOL_PATH=srv*C:\symbols*https://msdl.microsoft.com/download/symbols` (shared cache, 983 entries).

- **Resolved**: `ntdll`, `KernelBase`, `kernel32`, `ucrtbase`, `ntoskrnl`, `win32k*`, `dxgkrnl`,
  `Npfs.SYS`, `FLTMGR.SYS`, `fileinfo.sys`, `d3d11`, `win32u`, `user32`, `apphelp` (`SeUtilsIsSystem`),
  `crypt32` (`ILS_WaitForThreadProc`), plus module-relative frames in `winfsp-x64.dll`,
  `libcurl-4.dll`, `nvwgf2umx.dll`, `nvspcap64.dll`.
- **Not resolved**: **`mpv.exe` has no PDB** – every mpv frame is `mpv.exe!0x00007ff74a…`;
  **`rclone.exe` is Go** – `rclone.exe!0x0000000140…` (module/address only). Frame offsets are
  retained so the source lane can map them with a matching-PDB build.
- The prior partial work (`exports\symtest-real-10-11\`) contained no stack evidence and was
  not reused as evidence; its `profiles\_ref-*.xml` presets were used only as WPA schema
  references to build `real\real-stacks.wpaProfile`. **WPAExporter's precise-table export
  produced no per-thread stacks** (all `[Root]`/empty, full-trace aggregates even with
  `-range`), so all wait evidence below comes from `xperf` dump parsing.

## 3. Q1 — transition (accepted `playlist-next` → third-file playback)

**VERIFIED — the critical path is a 3.42 s `NtCreateFile` on mpv worker TID 31520
(`…\new2\Brazilian Tattooed Babe … [xhH7GW2].mkv`), while the main thread waits 3.41 s on a
condition variable.**

- mpv TID **31520** (`ucrtbase thread_start`, alive 0.470–18.866 s):
  `FileIoCreate` at ETL **13.239044**, path
  `\\;WinFsp.Mup+20260910T094317Z\server\RcloneWcrypt\XXX\new2\Brazilian Tattooed Babe With Perfect Ass Wants Cum In Her Mouth [xhH7GW2].mkv`,
  `FILE_SYNCHRONOUS_IO_NONALERT`. It entered the kernel at **13.239086** and the thread was
  switched in again only at **16.659304** → **3.4202 s blocked inside `NtCreateFile`**.
  Stack at switch-out/in (frames from the wait entry outward):
  `ntoskrnl!IopParseDevice ← ObpLookupObjectName ← ObOpenObjectByNameEx ← IopCreateFile ← NtCreateFile ← KiSystemServiceCopyEnd`
- mpv main thread **TID 59912** (`mpv.exe` main): last ran 13.245786 (then Old, `Waiting`,
  reason `WrAlertByThreadId`); switched in **16.659523** after **3.4137 s** in
  `ntdll!ZwWaitForAlertByThreadId ← RtlSleepConditionVariableSRW ← KernelBase!SleepConditionVariableSRW
  ← mpv.exe!0x7ff74af21744 ← 0x…af62626 ← 0x…af6558a ← 0x…af5aff8 ← 0x…af5d089 ← 0x…af5f288`.
- **Wake edge (ReadyThread, VERIFIED)**: at **16.659516** TID 31520 readied main thread 59912
  (`ReadyThread, 16659516, mpv.exe (39720), 31520, mpv.exe (39720), 59912, Unwait`), 7 µs before
  it resumed. `Playing:` at 16.665, first frame 17.0898 using the prefetched URL (log
  `Using prefetched URL.`), i.e. the actual open is not the cost once the gate clears.
- **No mpv I/O while gated (VERIFIED)**: in slice 14.90–15.20 s mpv had exactly **40 CSwitch
  events, all on TID 7920** (an NVIDIA `nvwgf2umx.dll` thread); **0** mpv `FileIoCreate` in that
  slice (only the single outstanding create from 13.239). The mount was not being read by mpv.
- **rclone side (VERIFIED activity, INCONCLUSIVE attribution)**: during the same window rclone
  WinFsp worker TIDs 30820/10376/55892/47716 are in tight `NtDeviceIoControlFile` loops
  (13 610 / 10 704 / 10 210 / 4 946 waits in 0.3 s, caller `winfsp-x64.dll!0x…3ba98`), and at
  16.65 rclone TIDs 32664↔55892 ping-pong `ReadyThread … Unwait` every ~20 µs. Consistent with
  serving the mount, but the ETL does not tie that specific IRP to PID 31520's CreateFile; no
  rclone `NtCreateFile`/`NtReadFile` appears in the window.
- **INCONCLUSIVE**: mpv source names for the condvar wait/`0x…af21744` chain and the identity of
  worker 31520 (script vs autocreate worker) – needs a PDB-equipped build or source instrumentation.

## 4. Q2 — aborted second open vs target open (first transition, 7.4257 → 9.9717 s)

**VERIFIED — the aborted prefetch and the replacement open were serialized, not concurrent; the
abort path delayed the target open by ~1.29 s.**

- **Aborted prefetch thread TID 14516** (7.460345 → 8.747245), open of the third entry:
  - 7.460841 `CreateFile …\Brazilian Tattooed Babe …\MovieObject.bdmv` → 110 µs,
    `0xC0000034` (not found);
  - 7.460979 `CreateFile …\BDMV\MovieObject.bdmv` → 61 µs, not found;
  - 7.461087 `CreateFile …\Brazilian Tattooed Babe … [xhH7GW2].mkv` → 106 µs, `STATUS_SUCCESS`;
  - 7.462464 switched out with reason **`WrPageIn`**, resurfaced only at **8.746842**
    (**1.2865 s**), terminated `WrTerminated` at **8.747245**.
  - Log `Aborting ongoing prefetch of wrong URL` (~7.465) did **not** interrupt the block.
- **Replacement open thread TID 59036** (8.747309 → 9.445934), second entry:
  - 8.747660/8.747798 bluray probes → 108 µs / 80 µs, not found;
  - 8.747934 `CreateFile …\Blonde with a Big Ass … [xhSjwCe-1].mkv` → **208 µs**, success;
  - then blocked in **`NtReadFile` for 697 253 µs (0.697 s)** (switch-in at 9.444547, stack
    `IofCallDriver ← IopCallDriverReference ← IopSynchronousServiceTail ← IopReadFile ← NtReadFile`),
    ended 9.445934; log `Opening done` 9.447.
- **Overlap verdict**: TID 59036's lifetime starts at 8.747309, i.e. **64 µs after TID 14516
  terminated at 8.747245** – the replacement open could not start while the aborted one was
  stuck. So the aborted open and the target open **compete by serialization** (the aborted
  page-in wait gates the replacement), not by concurrent I/O.
- **CONTRADICTED (this trace)**: the Procmon t6 magnitudes (CreateFile 3.09 s, CloseFile 2.13 s)
  are not reproduced here – all creates in this run complete in 61–208 µs. The long item here is
  the **1.286 s `WrPageIn` wait** on the aborted thread. t6 is an observer-inflated separate trial.
- **INCONCLUSIVE**: what address/file the `WrPageIn` fault belonged to (no mpv `HardFault` events
  with paths in that window in this capture).

## 5. Q3 — `quit` → exit (17.0945 → 19.1196 s, 2.0251 s)

**VERIFIED — teardown is parallel; no single large blocking wait on the main thread. The top
stack-count activities are GPU resource destruction, a local shader-cache scan, and AppCompat
shim checks, while rclone keeps serving WinFsp requests until ~18.65 s.**

Per-thread WAIT top reasons (from CSwitch wait-call classification; counts per slice):

| TID | process | wait call | slice (s) | count |
| --- | --- | --- | --- | ---: |
| 22948 | mpv (nvwgf2umx thread) | `dxgkrnl.sys!DxgkDestroyAllocation2` (+82 `d3d11!CallAndLogImpl<D3DKMT_DESTROYALLOCATION2>`) | 17.04–17.60 | 2578 (+82) |
| 49848 | mpv | `ZwWriteFile` ← `mpv.exe!0x…d8526` | 17.04–17.60 | 1463 |
| 59912 | mpv main | `NtAlertThreadByThreadId` / `ZwWaitForAlertByThreadId` (`mpv.exe!0x…3d924`, `0x…216c3`) | 17.04–17.60 | 81 / 60 |
| 30532 | mpv | shader-cache `FileIoCreate/QueryInfo/Close` (local `C:\Users\andre\AppData\Roaming\mpv\shader_cache\shader_*`) | 18.88–19.12 | 2059 / 3587 / 1954 |
| 50072, 59036 | mpv | `ZwOpenFile/ZwQuerySecurityObject/ZwClose` ← `apphelp.dll!SeUtilsIsSystem` | 18.20–18.65 | ~130 each |
| 59912 | mpv main | `NtTerminateProcess` | 18.88–19.12 | 294 |
| 32664/31056/10376/55892 | rclone (winfsp) | `NtDeviceIoControlFile` ← `winfsp-x64.dll!0x…3ba98` | 18.20–18.65 | 3703/3034/1083/804 |
| 55888/53828/56772 | rclone (Go) | `ZwWaitForSingleObject`, `NtRemoveIoCompletionEx`, `NtSetEvent` | 17.04–17.60 | few hundred |

- No mpv wait in the quit window exceeds milliseconds individually in the sampled slices;
  the 2.03 s is spread over parallel cleanup: `vf remove @rtxvideo` at 18.487, ytdl
  `on_after_end_file` at 18.862, thread terminations 18.86–19.03, shader-cache scan ending
  19.0035, main `NtTerminateProcess` until 19.1196.
- **INCONCLUSIVE**: the exact wall-clock share of each component. First-event-in-slice
  CSwitch wait fields carry thread-start artifacts and cannot be used as durations; a
  per-thread WAIT/RUNNING accounting for window B is not derivable from these tables alone.

## 6. Q4 — READY/WAIT per-thread summary

**WAIT** (top reasons with stack evidence; see tables above):

- Transition A: TID 31520 `NtCreateFile` 3.4202 s; TID 14516 `WrPageIn` 1.2865 s;
  TID 59036 `NtReadFile` 0.6973 s; TID 59912 `ZwWaitForAlertByThreadId`/condvar 3.4137 s;
  rclone/wsp `NtDeviceIoControlFile` loops throughout.
- Quit B: TID 22948 `DxgkDestroyAllocation2` (GPU); TID 30532 local shader-cache file ops;
  TID 59912 alert/condvar + `NtTerminateProcess`; TIDs 50072/59036 `apphelp` security I/O;
  rclone `DeviceIoControl` + Go IOCP waits.
- **READY** edges captured: `31520 → 59912` at 16.659516 (main-thread wake, `Unwait`);
  rclone `32664 ↔ 55892` `Unwait` handoff storm at 16.65; main thread 59912 alerting workers
  (`NtAlertThreadByThreadId`) during quit.

## 7. Gaps / limits

1. mpv and rclone frames are **unsymbolized** (no PDBs): all mpv attribution is at
   TID + absolute-offset level; source-level mapping needs a matching-PDB build or the
   source lane's instrumentation.
2. WPAExporter precise/sampled tables were unusable for stacks (`[Root]`/empty) and its
   `-range` was not consistently honored for aggregated values; the exporter artifacts under
   `real\export-A-transition\` are retained but were not used for verdicts.
3. CSwitch `TmSinceLast`/`WaitTime` columns equal `(event − thread start)` for the first event
   of a thread inside a dump slice; durations above use event pairs/lifetime boundaries, not
   those fields.
4. Stack-walk events can be throttled under the very high winfsp switch rate; only captured
   stacks were analyzed.
5. The second ETL `capture-1c0b020256a0494594d0931b875ad9aa.etl` (1.95 GB) in the same run is
   a **failed** configured attempt with `GPU.Verbose` added (outcome `error`, mpv exit 1,
   `firstPresentedCount=0`, "Timed out before the third first-presented marker"); it was not
   used and is not a valid real-arm comparison.
6. Q1's rclone-side causality (which server thread served the 3.42 s CreateFile) is not
   provable from stacks alone; a FileIO-detail table with IRP/path correlation would close it.

## 8. Artifacts

ETL (read-only):
`C:\Users\andre\PerfRuns\mpv-wpd-20260911\mpv-configured-20260911T090138445Z-bca58da8047c49b68d50c15821b2d9f8\traces\capture-27b08a25da7f4e81b77092c46603bff6.etl`

Analysis outputs (external, not in Git): `C:\Users\andre\PerfRuns\mpv-stack-analysis-20260911\real\`
- `slices\s01…s09-<range>.txt` — raw `xperf -a dumper` ranges (7.40–7.75, 8.60–9.00, 9.30–9.50,
  13.18–13.70, 14.90–15.20, 16.58–16.80, 17.04–17.60, 18.20–18.65, 18.88–19.12 s; ~3.3 GB)
- `filtered\*.filtered.txt` — mpv/rclone CSwitch/ReadyThread/SampledProfile + stack lines
- `analyzer.ps1`, `filter-slices.ps1`, `show-stacks.ps1` — parsers used for the tables above
- `real-stacks.wpaProfile`, `pilot2-7.30-7.60\`, `pilot3-20-25\`, `export-A-transition\` —
  WPAExporter probes (stack-less; retained to document the dead end)
- Prior partial work untouched: `exports\symtest-real-10-11\`, `logs\tracestats-real.txt`,
  `profiles\_ref-*.xml`
