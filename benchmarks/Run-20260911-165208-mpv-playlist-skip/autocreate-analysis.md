# Autocreated-playlist readiness: root cause

Scope: why opening a video from `I:\XXX\new2` (257 `.mkv`, rclone WinFsp mount
`wcrypt:` -> Wasabi S3) takes seconds before the sibling playlist exists, and why
`playlist-next` errors during that window. Read-only source + retained-log
investigation, 2026-09-11. Companion to `report.md` and `fix-playlist-sort.md`.

## Symptom (VERIFIED)

Real config (`autocreate-playlist=filter`): the playlist contains exactly one
entry until the worker splices the siblings, which the log records as
`Autocreate playlist: 257 siblings.` Delays measured from the first
`starting video playback` line:

| run | trial | play (s) | autocreate (s) | after play (s) | next cmds |
| --- | --- | ---: | ---: | ---: | ---: |
| playlist-skip (baseline) | real-t0 | 1.07 | 3.84 | 2.77 | 2 |
| playlist-skip (baseline) | real-t1 | 1.12 | 7.74 | 6.62 | 10 |
| playlist-skip (baseline) | real-t2 | 1.10 | 8.36 | 7.26 | 14 |
| playlist-sort-fix-final | real-t0 | 0.21 | 11.64 | 11.42 | 34 |
| playlist-sort-fix-final | real-t1 | 0.79 | 10.65 | 9.86 | 26 |
| playlist-sort-fix-final | real-t2 | 1.08 | 2.74 | 1.65 | 2 |
| playlist-sort-fix-found | real-t0/t1 | 0.26/1.18 | 3.41/12.40 | 3.16/11.22 | 2/32 |
| playlist-sort-fix-open | real-t0/t1 | 1.83/0.22 | 6.73/11.69 | 4.90/11.47 | 2/34 |
| playlist-skip (control) | control-t3/t4/t5 | 0.37/1.19/0.37 | 0.17/1.00/0.17 | before first frame | 2 |

Unmarked smoke trials ranged from ~0.2 s to a 46.3 s outlier, so readiness is
highly variable; the Lua sort change did not alter this (post-Fix-1 values span
the same range as baseline). While the list is incomplete, a weak
`playlist-next` returns `error running command` -- the user-visible "5 s then
next" action is a no-op.

## Root cause (VERIFIED)

1. **The deployed binary is MinGW-w64 GCC 16.2 UCRT64, not MSVC**:
   `build/meson-logs/meson-log.txt:37`, `build/compile_commands.json:268`
   (msys64 ucrt64 includes). `dist/mpv.exe` and `build/mpv.exe` are byte
   identical (SHA-256 `777FB944...B36E7`).
2. **`osdep/dirent-win.h` is not compiled on MinGW**: `osdep/io.h:102-108`
   includes it only for `defined(_WIN32) && !defined(__MINGW32__)`; MinGW uses
   `<dirent.h>`, whose `struct dirent` has no `d_type` and which never defines
   `_DIRENT_HAVE_D_TYPE` (`C:\msys64\ucrt64\include\dirent.h:21-27`). The only
   in-repo definition is `osdep/dirent-win.h:42`, inactive here.
3. **Therefore the `d_type` fast path in `demux/demux_playlist.c:480-509` is
   preprocessed away.** Every entry takes the fallback at `:511-529`:
   `stat(file, &st)` per entry, even with `directory-mode=ignore` (the
   DIR_IGNORE shortcut exists only inside the `#ifdef`, `:488-490`). On Windows
   `stat` = `mp_stat` (`osdep/io.h:216-218`) -> `CreateFileW(FILE_READ_ATTRIBUTES)`
   plus up to 3 `GetFileInformationByHandleEx` (`osdep/io.c:274-362`), then
   close -- through `\\server\RcloneWcrypt\...`.
4. **The scan is serial and hostage to one stall, not 257 slow calls.** Procmon
   t6 (`exports/procmon-filtered.csv`): 258 attribute-open `CreateFile` calls on
   autocreate worker TID 47792 span 4:37:41.3748 -> 4:37:46.7303 (5.356 s),
   matching the log interval (`Opening done` 0.293 s -> `Autocreate` 5.657 s =
   5.36 s). One call took **5.249 s** on the file being streamed at that moment;
   the other 257 sum to ~0.05 s (~0.2 ms each). Control-arm full scans took
   0.16/1.00/0.16 s with the same code path.
5. **Splice behavior** (`player/autocreate_playlist.c`): the worker builds a
   private playlist, then `autocreate_finish` (called on the core via dispatch)
   moves the entries in, logs the sibling count (`:98`) and notifies `playlist`.
   The real playlist genuinely has 1 entry until then; no lock gates
   `playlist-next`, and rejected weak attempts do not cancel the scan.

## `playlist-next` error semantics (VERIFIED)

`playlist-next` defaults to weak (the logged `args=[flags="weak"]` is the
materialized default, `input/cmd.c:128-151`). With one entry,
`playlist_get_next` returns NULL and the handler sets `cmd->success = false`
(`player/command.c:6204-6220`, `common/playlist.c:256-271`) -> "error running
command". `force` is not a workaround: it stops playback
(`player/loadfile.c:2129-2138`). There is no queue/future-advance mechanism.

## Why the control arm was ready sooner (partially verified)

Same compiled-out `d_type` path; control scans were 0.16-1.0 s. Supported:
control ran after the real trials with warm rclone VFS/Windows metadata caches
(`Opening done` 0.009 s vs ~1.0 s), no `playlist-sort` PowerShell enumeration,
and much lighter real-config load. The precise WinFsp/rclone mechanism that
turns a same-file attribute open into a multi-second stall is not proven.

## Narrow fix options

1. **Skip the `stat()` for the include (playing) path** in the no-`d_type`
   fallback (`demux/demux_playlist.c:511-529`): the include path is known to be
   a regular file and already matches `test_path` (`:431-437`). Removes the
   measured 5.25 s stall; low risk. Verify with Procmon worker-TID max
   `Read Attributes` duration and `Opening done` -> `Autocreate` delta.
2. **Activate the `d_type` fast path on MinGW** by using attribute-derived
   `d_type` from `osdep/dirent-win.h` (`:545-553`, `:633-635`) in `mp_readdir`,
   e.g. dropping the `!defined(__MINGW32__)` gate at `osdep/io.h:102` or porting
   the attribute derivation into MinGW's dirent shim. Removes the per-entry
   stats entirely; medium risk (`struct dirent` ABI/layout differences).
3. **No-stat fallback when `dir_mode == DIR_IGNORE`** (`mpv.conf` setting):
   append non-dot entries directly. Simple, but a directory named like a media
   file would be added instead of skipped (behavior change).
4. **Caller-side wait (no C change)**: gate scripts/harness `playlist-next` on
   the `playlist` notification or `playlist-count > 1`; removes the rejected
   command but not the wait.

## Documentation discrepancies

`DOCS/optimization_implementation.md` marks the `d_type` fast path COMPLETED
with a "~5.0 s -> ~20 ms" claim (`:11,22,58-59`) and `FindExInfoBasic +
FIND_FIRST_EX_LARGE_FETCH` completed (`:15,217-239,598`). For this MinGW build
both are inert: the header is not compiled, the fallback `stat()` runs for every
entry regardless of `dir_mode` (`demux_playlist.c:511-529`), and measured scans
are 2.9-7.3 s. The doc needs correction.

## Gaps

- t1/t2 lack per-op traces; whether their 6.7/7.3 s scans were dominated by one
  stall is inferred from t6, not proven (INCONCLUSIVE).
- The WinFsp/rclone cause of the multi-second attribute-open stall is unproven;
  a Procmon/WPR run with Duration/TID during a real stall would settle it.
