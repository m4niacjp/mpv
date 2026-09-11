# Fix: keep the Explorer sort lookup off the file-open path

Scope: user scripts `%APPDATA%\mpv\scripts\playlist-sort.lua` and
`%APPDATA%\mpv\explorer-sort.ps1`, implemented 2026-09-11 after the
playlist-skip investigation in `report.md`. No mpv source, config, cache,
or rclone state was changed.

## Files, backups, hashes

| file | backup | SHA-256 (after) |
| --- | --- | --- |
| `%APPDATA%\mpv\scripts\playlist-sort.lua` | `%APPDATA%\mpv\backups\playlist-sort.lua-before-fix-20260911-170318` | `845471B3D70DEF6512A2598B74821893073C24113489A4F43E5156EE3484B414` |
| `%APPDATA%\mpv\explorer-sort.ps1` | `%APPDATA%\mpv\backups\explorer-sort.ps1-before-fix-20260911-170318` | `2E02228966A6148DE9BD5AD0CA82A8A7D14F73C4F99AF4FAE4E4C8782DFED025` |

Diffs and before/after copies: external run
`C:\Users\andre\PerfRuns\mpv-playlist-sort-fix-final-20260911T102310498Z-d23245f1363d415e9b0cecc80e0d1da1\measurements\`
(`diff-playlist-sort.diff`, `diff-explorer-sort.diff`,
`playlist-sort.lua.{before,after}-fix`, `explorer-sort.ps1.{before,after}-fix`).

## Root causes

1. **Synchronous subprocess blocked the hook.** `query_explorer_sort()` used
   `mp.command_native({name="subprocess", ...})`. Lua scripts run on their own
   thread; `on_before_start_file` is dispatched to that thread, so a subprocess
   running when the hook arrives delays the hook's reply and therefore the next
   file open. Baseline `mpv-real-t1.log`: hook at 7.944 s inside subprocess span
   7.901-8.648 s, next `Playing:` at 8.652 s (+708 ms, only 4 ms after the
   subprocess ended). Same in `mpv-real-t2.log` (+527 ms). This is the
   `report.md` finding #2 (0.5-0.8 s per gated open).
2. **One spawn per open, no durable cache for a directory.** The old
   single-entry cache was cleared whenever the directory changed, and a failed
   lookup was re-attempted from scratch per session/directory.
3. **Empty-stderr diagnostics gap.** `player/command.c:6985` always sets
   `error_string` (empty string on success). The old expression
   `result.error_string or result.stderr` returned `""` (truthy in Lua) and
   masked the helper's stderr line. Probe with the old helper reproduced:
   `status=1 error_string="" stderr="explorer-sort: no Explorer window for
   I:\XXX\new2\r\n"`, and the old expression yielded `""`. The helper also used
   exit 1 both for "folder not open" (common) and for real errors.

## Fix summary

`playlist-sort.lua`

- Explorer lookups run through `mp.command_native_async` only. A query is
  started as soon as the directory that is about to play is known: the
  `on_before_start_file` hook (synchronous prefetch-gate write stays as-is),
  a `user-data/playlist/sort-mode` change, or a manual request. `focus_dir`
  reads `playlist/<playlist-pos>/filename` because the hook runs before `path`
  switches to the new file.
- The in-memory cache is now a map keyed by normalized directory. One async
  query per directory per mpv session; success and failure are both memoized.
  No disk persistence: a stale on-disk order could keep shadowing a fresh
  query, and the async query costs the open path nothing. Policy documented in
  the file header.
- If the result is not in yet when a sort pass runs, the pass uses
  `fallback-mode`; when a success arrives later it triggers a silent re-sort.
  A bounded wait (`EXPLORER_WAIT_SEC = 1.5 s`) defers the auto pass while the
  query is pending so a fast autocreate does not pay a full fallback stat pass
  moments before the result lands.
- Failure logging uses stderr when non-blank, otherwise `error_string`, so the
  helper's one-line reason reaches the mpv log (status 2 = "folder not open").

`explorer-sort.ps1`

- Machine-readable outcomes: exit 0 found (stdout kept as `prop:...;`),
  exit 2 folder not open in Explorer, exit 1 real error; exactly one
  `explorer-sort: ...` stderr line on 1/2.
- Multiple windows are scanned, path match is case-insensitive after
  normalization; windows without a shell `Folder` (IE mode/busy) are skipped;
  COM errors while reading one window do not abort the scan; `Shell.Application`
  creation/enumeration failures and empty `SortColumns` are exit 1.
- Still ASCII, PowerShell 5.1, `-NoProfile -NonInteractive`.

## Preserved interfaces

- `script-message-to playlist_sort sort <mode>` with
  `random|name|mtime|ctime|size|duration|explorer` (verified over IPC).
- `user-data/playlist/{sort-mode,sort-descending,fallback-mode,
  fallback-descending,sort-restored}` semantics: Explorer publishes only the
  logical mode, concrete modes refresh the fallback pair, default fallback
  stays `mtime`; `remember-rtx.state` still round-trips.
- Prefetch gate write is synchronous in the hook; gate/restore state machine
  and its reasons (`end-file`, `shutdown`, `playlist order finalization`,
  "the next file load") unchanged.
- One-shot `playlist-reorder` (no per-entry moves), idle-sliced key filling,
  fingerprint/job generation guards, OSD text unchanged.
- Lua 5.1/LuaJIT only, ASCII, 4-space indent, no new dependencies.

## Before/after evidence

### Standalone helper

| state | before | after |
| --- | --- | --- |
| `I:\XXX\new2` not open | exit 1, `explorer-sort: no Explorer window for I:\XXX\new2`, 717.4 ms | exit 2, `explorer-sort: folder not open in Explorer: I:\XXX\new2`, 645.9/614.8/608.1 ms (3 runs) |
| `new2` open (target was window 1 of 4) | exit 0, `prop:System.ItemNameDisplay;`, 687.6 ms | exit 0, `prop:System.ItemNameDisplay;`, 765.4/649.1/656.7 ms (3 runs) |
| real error | indistinguishable from "not open" | exit 1, `explorer-sort: empty folder path` (wrapper invocation) |

### Regression harness and syntax

- `%APPDATA%\mpv\tests\playlist-sort-regression.lua` (mock mpv, loaded with
  `dist\mpv.exe --no-config --load-scripts=no`): PASS before and after the
  change; non-Explorer modes do not touch the async path.
- Both files are pure ASCII with no tab characters; `playlist-sort.lua` has no
  remaining reference to the old cache fields or the synchronous query.

### Real-config harness trials

`Invoke-MpvSkipBatch.ps1 -Arm real` on random `I:\XXX\new2` files,
`dist\mpv.exe`, warm VFS cache (not purged). Baseline numbers are the
`report.md` table; after numbers are deltas recomputed from the batch events
(`accepted next→T4` uses the accepted attempt, not the first rejected one).
T1 is launch→first `playback-restart`.

| run / trial | input | T1 | next attempts | accepted next→T4 | quit→exit | Explorer |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| baseline t0 | rank-101/257 | 1106.9 ms | 1 | 812.5 ms | 1103.0 ms | exit 1 |
| baseline t1 | rank-63/257 | 1146.9 ms | 5 | 4170.6 ms | 694.7 ms | exit 1 |
| baseline t2 | rank-44/257 | 1123.0 ms | 7 | 3236.5 ms | 923.8 ms | exit 1 |
| fix-final t0 | rank-240 (147 MB) | 231.2 ms | 17 | 396.7 ms | 119.3 ms | found |
| fix-final t1 | rank-29 (466 MB) | 811.1 ms | 13 | 1623.0 ms | 1290.0 ms | found |
| fix-final t2 | rank-137 (37 MB) | 1103.0 ms | 1 | 1475.0 ms | 1105.1 ms | exit 2 |
| fix-found t0 | rank-245 (102 MB) | 273.6 ms | 1 | 1663.1 ms | 1046.2 ms | found |
| fix-found t1 | rank-127 (201 MB) | 1201.9 ms | 16 | 3329.1 ms | 997.9 ms | found |
| fix-open t0 | rank-24 (762 MB) | 1843.0 ms | 1 | 1769.7 ms | 1053.4 ms | exit 2 |
| fix-open t1 | rank-220 (402 MB) | 238.8 ms | 17 | 907.7 ms | 1665.9 ms | exit 2 |

Structural result, per log (the decisive one):

- Baseline: a `playlist_sort/on_before_start_file` hook sits **inside** the
  subprocess span in t1 (7.944 in 7.901-8.648, next `Playing:` +708 ms) and t2
  (+527 ms); t0/t6 have the same per-open cost by the report's correlation.
- After (all 5 trials): **zero** hooks inside a subprocess span. The query
  starts with/just after the first hook and completes 0.7-0.9 s later while the
  core proceeds. `fix-final t0`: hook 0.149 s → first `Opening done` 0.156 s
  (+7 ms) with the subprocess finishing at 0.870 s; `fix-found t0`: +16 ms,
  subprocess finish 1.080 s. `fix-final t0` also shows the gate
  (`gated prefetch ...`) and the restore (`restored prefetch-playlist after
  playlist order finalization`) with a successful `explorer sort for
  I:\XXX\new2: name asc`.

Honest timing statement: the end-to-end phase numbers do **not** show a clean
improvement. T1 and quit→exit are in the baseline range or better, and
accepted next→T4 is mostly mount-bound (396-3329 ms vs 813-4171 ms baseline)
with a different random file per trial and warm-cache asymmetry. The
controller is the target file's open on rclone/WinFsp, not the removed
subprocess; the fix's guarantee is structural (no hook waits on PowerShell;
at most one async lookup per directory per session), which the log analysis
demonstrates. The autocreate-splice latency (2.7-11.6 s here, out of scope)
still caused 13-17 rejected `playlist-next` attempts in 4 of 7 after trials.

### IPC message test (final code)

Second IPC client in `mpv-playlist-sort-fix-msg3-...\measurements\
watch-sort-message.ps1` during a real-config trial with a 25 s pre-next
window:

- `ok = true`; playlist-count reached 257.
- `script-message-to playlist_sort sort random` changed the 257-entry order in
  1233.5 ms; then `script-message-to playlist_sort sort explorer` changed it
  again in 807.3 ms.
- Trial log: `Run command: script-message-to ... args="explorer"` at 1.958 s,
  fresh async query 1.959 s, `explorer sort for I:\XXX\new2: name asc` at
  2.750 s, 2 `playlist-reorder` commands total.

### Diagnostics and health

- `fix-final t2` (window closed by the user): the failure now reads
  `playlist-sort: explorer sort lookup failed for I:\XXX\new2 (status 2):
  explorer-sort: folder not open in Explorer: I:\XXX\new2` - the reason is no
  longer empty.
- Every after log: `gated prefetch` = 1 and at least one
  `restored prefetch-playlist`; zero `[e]`/`[w]` lines from `playlist_sort`.
  The only `[e]` is the pre-existing `scripts\__pycache__` note.
- No Explorer sort lookup is repeated within a session; each after trial
  spawns exactly one PowerShell process.

## Design choice worth noting

Run C of the message test exposed a race: with hot directory metadata the
autocreate list can arrive (~0.24 s) before the async lookup (~0.9 s). The
first auto sort then used the `mtime` fallback and its 257 per-file stat calls
held the script thread in idle slices for ~14.5 s while the mount stalled. The
old synchronous code effectively waited for the lookup first, so this was a
new exposure, not a new fallback cost (the same stat pass runs whenever the
lookup fails). The bounded 1.5 s wait was added for this; after it, the final
batch trials sorted directly from the lookup (or the exit-2 fallback) without
long script-thread stalls. Superseded run-C artifacts are retained:
`C:\Users\andre\PerfRuns\mpv-playlist-sort-fix-msg-20260911T101606884Z-...`.

## Deviations and side effects

- Harness and mpv ran elevated (High IL), as in the baseline report; not
  re-measured at medium IL.
- The user had 1-4 concurrent mpv/Explorer activities on `I:` during the
  batches; autocreate varied 2.7-11.6 s. Explorer windows appeared/disappeared
  mid-batch (found and exit-2 trials are marked above); the final desktop state
  is the user's, not controlled by this work.
- The functional `sort random` test message updated
  `user-data/playlist/fallback-mode` via the documented "concrete manual sorts
  refresh fallback" behavior, and `remember-rtx.lua` persisted it. The original
  `fallback_mode = "mtime"` was restored in
  `%APPDATA%\mpv\remember-rtx.state`; backup of the pre-restore file:
  `%APPDATA%\mpv\backups\remember-rtx.state-before-restore-20260911-*`.
  `mode = explorer` / `descending = false` were unchanged.
- Three regression-test mpv processes left idling by the temporary test
  wrapper (its `os.exit` override errored instead of quitting) were killed;
  the user's own mpv session was left alone.

## Remaining gaps and risks

- `duration` sorting still uses the synchronous `ffprobe` subprocess in idle
  slices; unchanged and out of scope. Under a stalled mount it can hold the
  script thread the same way.
- Roaming docs and memory still describe the lookup as synchronous/per-session:
  `%APPDATA%\mpv\AGENTS.md`, `Docs\INTERNAL.md`, `Docs\Reference\QUICK_MENU.md`,
  `.agent-memory\`. A doc-keeper follow-up is needed; they were not edited here
  per the task's file-ownership constraints.
- No persistence by design: if Explorer is opened at the folder after mpv
  started, that session keeps the fallback (same as before the fix, which also
  memoized failures).
- If the helper hangs longer than the 1.5 s wait, the fallback pass proceeds;
  a later success silently re-sorts.
- The core autocreate splice (7-12 s in this environment) and the resulting
  rejected `playlist-next` calls are out of scope and unchanged.
