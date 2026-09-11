# Option 2 design review — re-enable the `d_type` fast path on MinGW

Scope: **review only**. No repository file, build tree, or package file was
modified. All evidence was read from the working tree on 2026-09-11 ~18:05
(local checkout, MinGW UCRT64 build). Media names are anonymized; where a real
media root appears it is written `<media-root>`.

Companion input: `../autocreate-analysis.md` (verified root cause). Companion
outputs: `test-dirent-scan.c.draft`, `meson-test-hunk.txt`, `measure-scan.ps1`,
`test-plan.md`.

> **Checkout is concurrently modified.** At review time another lane had
> already applied "Option 1" (skip the `stat()` for the include/playing path)
> to `demux/demux_playlist.c` (`is_include_path()` and the shortcut at
> working-tree lines 519-528; file mtime 2026-09-11 18:00:06). `osdep/io.c` and
> `test/libmpv_test_prefetch.c` are dirty too. Option 2 must be rebased on that
> state and must keep Option 1. Working-tree line numbers below were exact at
> read time and will drift.

---

## Verdict summary

| # | Claim | Verdict | Evidence |
| --- | --- | --- | --- |
| V1 | MinGW builds use the CRT `<dirent.h>`; `osdep/dirent-win.h` is compiled out by `!defined(__MINGW32__)` | **VERIFIED** | `osdep/io.h:102-108`; `C:\msys64\ucrt64\include\dirent.h:9-27` (no `d_type`, no `_DIRENT_HAVE_D_TYPE`); MinGW compile command `build/compile_commands.json` (`cc`, `C:/msys64/ucrt64/include`) |
| V2 | The `d_type` fast path is the only thing that can remove per-entry `stat()`s; today every entry except the include path takes the fallback | **VERIFIED** (and now Option 1 changes only the include path) | `demux/demux_playlist.c:486-515` (fast path), `:519-528` (Option 1 shortcut), `:530-546` (fallback) |
| V3 | No caller depends on `struct dirent` cross-TU layout; only `d_name` is read everywhere except two `d_type` sites | **VERIFIED** | consumer inventory A.1; grep for `d_(namlen\|ino\|reclen\|off\|type)` outside `osdep/` returns only the 6 `d_type` comparisons; `include/mpv/` exposes no dirent types |
| V4 | Only `osdep/io.h` includes `<dirent.h>`/`dirent-win.h` in-tree, and no reachable MinGW system header pulls `<dirent.h>` into the same TU | **VERIFIED** (in-tree) | `osdep/io.h:102-108` only includes; glib `gdir.h:33-35` includes `<dirent.h>` only under `G_OS_UNIX`; `HAVE_GLOB_POSIX=0` (`build/config.h`) so `<glob.h>` is not included |
| V5 | `dirent-win.h` compiles on MinGW UCRT64: `FindFirstFileExW`/`FindExInfoBasic`/`FIND_FIRST_EX_LARGE_FETCH` and `WINAPI_FAMILY_PARTITION` exist and are enabled | **VERIFIED** (API presence) | `fileapi.h:197` (`FindFirstFileExW`), included via `windows.h`; `minwinbase.h:103-109` under `_WIN32_WINNT >= 0x0400`; build defines `_WIN32_WINNT=0x0A00` (`build/compile_commands.json`, `meson.build:335`); `winapifamily.h:21-22,47`; `dirent-win.h:633-635` |
| V6 | `S_IFLNK` is not defined by MinGW `sys/stat.h`; `dirent-win.h` supplies `DT_LNK = _S_IFDIR\|_S_IFREG` (0xC000), used only in `DT_LNK` self-comparisons | **VERIFIED** | recursive grep of `C:\msys64\ucrt64\include` finds `S_IFLNK` only in python/tcl private headers; `dirent-win.h:106-108,194` |
| V7 | A MinGW `dirent-win.h` build is conflict-free and warning-clean | **INCONCLUSIVE** | no compiler run in this task (constraint: source reading only). First gate of `test-plan.md` compiles/preprocesses the affected TU before any behavioral run |
| V8 | `mp_readdir()`'s name-conversion buffer loses ~20 bytes under `dirent-win.h`; the unchecked `WideCharToMultiByte` return + `strlen` is a pre-existing latent over-read | **VERIFIED** (code) / defect not executed | `osdep/io.c:615-620`; `dirent-win.h:284-302` (offsetof `d_name` = 28 on x64, buffer 781-28=753 vs 781-8=773 today); `MP_FILENAME_MAX` at `osdep/io.c:578` |
| V9 | MSVC behavior is the reference and must not change | **VERIFIED** (by construction) | `osdep/io.c:621-623` is active on MSVC today; `dirent-win.h` untouched except guarded edits; no MSVC build dir exists in this checkout (`build` and `build-static` are both `cc`/MinGW) |

Re-measured Procmon counters from
`C:\Users\andre\PerfRuns\mpv-playlist-skip-20260911T090749482Z-...\exports\procmon-filtered.csv`
(TID 47792, the autocreate worker; confirms the analysis):

- 259 `CreateFile` on the worker TID = **1 directory list open + 258 attribute
  opens** (`Read Attributes`), 258/257/257/257/257/257 of
  `QueryBasicInformationFile` / `QueryIdInformation` /
  `QueryStandardInformationFile` / `QueryInformationVolume` /
  `QueryAllInformationFile` / `QueryDeviceInformationVolume`, 19
  `QueryDirectory`, 1 `QueryOpen`.
- Max attribute-open duration **5.2492 s** (the streamed file); 257 entry opens
  plus the directory open span 4:37:41.3748 → 4:37:46.7303.

---

## A.1 Consumers of `DIR` / `struct dirent` / `readdir`

All are the same pattern: `opendir`/`readdir`/`closedir` return an opaque
`DIR*` and a borrowed `struct dirent*` that is never copied, freed, or stored
beyond the loop.

| Location | Fields used | Notes |
| --- | --- | --- |
| `demux/demux_playlist.c:461-568` (`scan_dir`) | `d_name`; `d_type` at `:487,:494` | The target. Both `d_type` uses are inside `#ifdef _DIRENT_HAVE_D_TYPE` (`:486-515`) |
| `player/external_files.c:93-211` | `d_name`; `d_type` at `:103-105,:186` | Second and only other `d_type` consumer; both sites are `_DIRENT_HAVE_D_TYPE`-gated |
| `demux/demux_cue.c:113-130` | `d_name` | stat by joined path |
| `demux/demux_mkv_timeline.c:105-139` | `d_name` | stat by joined path |
| `player/scripting.c:218-238` | `d_name` | stat by joined path |
| `player/lua.c:165-175,1074-1111,1271` | `d_name` | `DIR*` kept in a talloc destructor (`closedir`); script-facing `utils.readdir` returns names only |
| `player/javascript.c:233-256,865-903,1210` | `d_name` | same pattern |
| `video/out/vo_gpu_next.c:2268-2296` | `d_name` | stat by joined path |
| `osdep/als-linux.c:46-121` | `d_name` | Linux only, not compiled on Windows |
| `osdep/io.c:580-633` | owns the wrapper | `struct mp_dir {DIR crap; _WDIR *wdir; union {struct dirent; char space[...]}}`; writes `d_name/d_ino/d_reclen/d_namlen` (`:618-620`) and `d_type` when available (`:621-623`) |

What switching MinGW to `dirent-win.h` changes:

- `struct dirent` layout (per TU, not per ABI): CRT
  `{long d_ino; ushort d_reclen; ushort d_namlen; char d_name[260]}` vs
  dirent-win `{long d_ino; long d_off; ushort d_reclen; size_t d_namlen; int
  d_type; char d_name[261]}` (`dirent.h:21-27`; `dirent-win.h:284-302`).
  No consumer reads `d_off`; `d_ino/d_reclen/d_namlen` are write-only in
  `mp_readdir`. The struct never crosses the DLL boundary — `include/mpv/` has
  no dirent types. Layout divergence is therefore invisible to callers.
- `DIR` identity changes inside `io.c` only; `mp_opendir` already tallocs its
  own wrapper and callers treat `DIR` as opaque (`osdep/io.c:602-604`).
- `_DIRENT_HAVE_D_TYPE` becomes defined for every MinGW TU → the two fast
  paths activate; that is the intent, and the only behavior delta.
- `<windows.h>` is pulled into every TU that includes `osdep/io.h` (dirent-win
  includes it). MSVC already lives with this; GCC/MinGW compiles more code
  paths but the same mpv sources, so the risk is compiler-specific warnings
  and macro collisions, not API conflicts.
- One preservation detail: today MinGW gets `<io.h>` through `<dirent.h>`
  (`dirent.h:15`) and `<unistd.h>` through the `#else` branch. The edited
  include block should keep `<unistd.h>` for `__MINGW32__` (see A1) so no TU
  loses transitive declarations.

## A.2 Implementation approaches

Acceptance measurement shared by all approaches (decisive, quantitative):

1. Preprocess gate: `_DIRENT_HAVE_D_TYPE` is defined in the
   `demux/demux_playlist.c` TU and the `ep->d_type` branches survive `-E`.
2. Procmon gate: on the autocreate worker TID, `CreateFile` rows with
   `Desired Access: Read Attributes` **under the media root, excluding the
   directory itself, drop to 0**, max duration < 50 ms (baseline after
   Option 1: ~256 opens, max can still be seconds on a reparse entry or a
   second stall). Directory enumeration (`Read Data/List Directory` +
   `QueryDirectory`) stays constant.
3. Behavioral equivalence: the new `libmpv-test-dirent-scan` passes with the
   same expected playlist contents on MinGW and MSVC (and Linux CI, where
   `d_type` is native).

### A1 — drop the `!defined(__MINGW32__)` gate (recommended first attempt)

- Files/functions: `osdep/io.h:102-108` only for the switch, e.g.
  ```c
  #if defined(_WIN32)
  #include <io.h>
  #include "dirent-win.h"
  #ifdef __MINGW32__
  #include <unistd.h>   /* was provided by the MinGW <dirent.h> branch */
  #endif
  #else
  #include <dirent.h>
  #include <unistd.h>
  #endif
  ```
  `osdep/io.c:621-623` then becomes active for MinGW with no further change:
  `dirent-win.h`'s `_wreaddir` already fills `d_type` from
  `WIN32_FIND_DATAW.dwFileAttributes` (`dirent-win.h:805-815`).
- Behavior: minimal diff; MSVC path untouched (`_MSC_VER` still satisfies the
  `_WIN32` condition).
- Effort: low (one edit plus build fixups). Risk: medium — the 1200-line
  third-party header and `<windows.h>` now reach every MinGW TU; the
  compile/link gate is the real risk, not semantics.
- Decisive acceptance: `-fsyntax-only`/preprocess of `demux_playlist.c` and a
  full MinGW build with no new errors/warnings, then gates 2 and 3.
- If A1 fails to compile cleanly, fall back to A2 without changing the
  acceptance criteria.

### A2 — MinGW-native enumeration + `mp_dirent_type()` accessor

- Files/functions:
  - `osdep/io.h`: for `_WIN32`, declare
    `int mp_dirent_type(const struct dirent *de);`; for POSIX, define
    `#define mp_dirent_type(de) ((de)->d_type)` under `_DIRENT_HAVE_D_TYPE`
    (or `DT_UNKNOWN`).
  - `osdep/io.c`: under `#ifdef __MINGW32__`, implement
    `mp_opendir/mp_readdir/mp_closedir` on `FindFirstFileExW`/
    `FindNextFileW` (port of `dirent-win.h:629-692` + `:769-852`), keeping the
    CRT `struct dirent` as the public record and a private tail field for
    `d_type`. `DIR` stays opaque-by-convention, so the first-member cast can
    be replaced by an mpv-owned struct.
  - Call sites: `demux/demux_playlist.c:486-515` and
    `player/external_files.c:102-107,185-190` switch from `#ifdef
    _DIRENT_HAVE_D_TYPE`+`ep->d_type` to `mp_dirent_type(ep)`; MSVC and POSIX
    keep working through the accessor.
- Behavior: avoids injecting `<windows.h>` into every TU and avoids sharing a
  struct definition with the CRT; keeps one enumeration implementation per
  toolchain, so MSVC is untouched.
- Effort: medium (~100-150 LOC plus 3 call-site edits). Risk: medium — new
  Win32 code on the script/directory hot path, but each piece has a direct
  unit-observable (`d_type` of reg/lnk/dir fixtures) and the integration test.
- Decisive acceptance: same as A1, plus a direct assertion that
  `mp_dirent_type()` returns `DT_REG`/`DT_DIR`/`DT_LNK` for plain file,
  directory, and junction fixtures without any per-entry `stat()`
  (Procmon count 0).

### A3 — read `_WDIR.dd_dta.attrib` from the MinGW CRT struct (rejected)

`_WDIR`/`struct _wdirent` and `dd_dta` are declared in MinGW's public
`<dirent.h>` (`dirent.h:73-112`), and the CRT's find data carries the
attribute mask. Reading `wdir->dd_dta.attrib` would avoid new enumeration
code, but it depends on undocumented CRT internals whose concrete find-data
type varies by arch/CRT flavor, and `struct dirent` still has no `d_type`, so
the A2 accessor refactor is needed anyway. Not worth the fragility; no
reasonable decisive test. **Rejected.**

(A further variant — keeping `dirent-win.h` for MSVC and adding a copy under
an mpv-owned name for MinGW — is A1 with extra maintenance and no functional
gain.)

## A.3 Behavior risks of activating `d_type` on MinGW

Decision table for `scan_dir` (`demux/demux_playlist.c:461-568`), current
working tree:

| `d_type` | Current code path | Post-Option-2 path | Delta |
| --- | --- | --- | --- |
| `DT_REG` | fallback `stat()` (`:530-546`) | append without stat (`:487-491`); still filtered at `:562` by `test_path()`/include path | intended; extension/include filtering unchanged |
| `DT_DIR`, `DIR_IGNORE` | fallback `stat()` then skip | skip without stat (`:494-495`) | intended |
| `DT_DIR`, lazy/recursive | `stat()` for loop detection (`:498-511`) | unchanged (`stat()` still runs; needed for `st_dev`/`st_ino`) | none |
| `DT_LNK` (symlink/junction/reparse) | fallback `stat()` follows the target | unchanged (falls through `:515` to `:530`) | none; junctions under `DIR_IGNORE` still cost one stat |
| `DT_UNKNOWN`, devices (`DT_CHR`) | fallback `stat()` | unchanged | none |
| include path (Option 1) | shortcut `:519-528` | still hit before `d_type` | none |

- `DT_UNKNOWN` is effectively unreachable on Windows: `dirent-win.h` emits it
  only when the UTF-8 name conversion fails (`:841-847`), and that entry is
  reported as `?`; the fallback `stat()` then fails harmlessly.
- Reparse-point coverage matters on Windows: OneDrive placeholders, junctions,
  and symlinks all set `FILE_ATTRIBUTE_REPARSE_POINT`; `dirent-win.h` maps
  them to `DT_LNK` *before* checking `FILE_ATTRIBUTE_DIRECTORY`
  (`:808-815`), so they always take the `stat()` path. Consequence: the
  "zero attribute opens" acceptance criterion must be stated for plain
  entries; reparse entries keep today's cost and semantics (links to
  directories are recursed in recursive mode with `same_st` loop detection,
  links to files are included — exactly as today, because `mp_stat` follows
  reparse points).
- Second behavior surface: `player/external_files.c:102-107` will start
  skipping directory/special entries before name matching, and `:185-190`
  will skip `mp_path_exists()` for `DT_REG`. Results are equivalent (directory
  and FIFO/CHR/SOCK/BLK entries could never become external tracks), but this
  should be covered by the existing `libmpv-test-prefetch`
  external-files case plus the MSVC lane.
- Scope creep is contained: grep shows only these two files read `d_type`.
- Latent defect (pre-existing, not introduced): `mp_readdir()` ignores the
  `WideCharToMultiByte` result (`osdep/io.c:616-617`) and then calls
  `strlen()` on the union buffer (`:620`). A 260-wchar name near the UTF-8
  worst case (780 bytes) already exceeds today's 773-byte buffer, and A1
  shrinks it to 753. This is not caused by Option 2, but the margin narrows;
  a cheap hardening (check the return, clamp, or make the buffer
  `offsetof + MP_FILENAME_MAX`) belongs in the same change or in a tracked
  follow-up — report to the parent as a production gap.

## A.4 Cross-toolchain check — what must stay green

- MSVC keeps `dirent-win.h` via the unchanged condition; do not edit
  `dirent-win.h` except behind `__MINGW32__` guards (A1 makes that header
  shared by both toolchains).
- `osdep/io.c:621-623` (d_type propagation) must remain; MSVC is the
  reference implementation for `mp_readdir` attributes.
- Regression lanes that already exercise `_DIRENT_HAVE_D_TYPE` behavior on
  MSVC: `libmpv-test-prefetch` (`test/libmpv_test_prefetch.c`, includes the
  `test_autocreate_playlist` and external-files cases) and
  `libmpv-test-file-loading`; run the whole `meson test -C build` suite.
- The new `libmpv-test-dirent-scan` must produce identical playlist contents
  on MSVC and MinGW; that is the cross-toolchain semantic gate.
- This checkout has no MSVC build directory (`build` and `build-static` are
  both MinGW `cc`), so the MSVC lane must be a separate build dir or CI run —
  see `test-plan.md` gap list.

## A.5 Interaction with the concurrently applied Option 1

Option 1 removed exactly the include-path `stat()` (the 5.25 s stall in the
t6 capture). Option 2 removes the remaining per-entry stats (256 of 257 in
that fixture). They are complementary, and the acceptance baseline for
Option 2 is therefore "0 attribute opens for child entries" rather than
"~258". Keep both; if only one can land, Option 1 is the smaller change, but
it leaves every non-playing sibling stat'd (still one `CreateFile` +
~5 `Query*` per entry, and any one of them can stall on WinFsp/rclone).

## A.6 Gaps / INCONCLUSIVE items

- V7 (MinGW build of `dirent-win.h`) is unproven by execution here by
  assignment constraint; it is the first gate of `test-plan.md`.
- The WinFsp/rclone mechanism that turns one attribute open into a
  multi-second stall is outside this scope (see `../autocreate-analysis.md`).
- A1's `<windows.h>`-in-every-TU compile cost and any GCC-specific warning
  noise were not measured; the plan's build gate covers it.
- Whether any out-of-tree/optional MinGW dependency header pulls
  `<dirent.h>` into an `osdep/io.h` TU is unverified beyond the in-tree
  include graph; the preprocess/compile gate covers it.
