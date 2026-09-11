# Option 2 verification plan — MinGW `d_type` fast path

Companion to `design-review.md`, `test-dirent-scan.c.draft`,
`meson-test-hunk.txt`, `measure-scan.ps1`. Nothing in this plan has been
applied or executed in this task; it is the ready-to-run recipe for the lane
that implements Option 2.

Preconditions understood by this plan:

- Working tree already contains **Option 1** (`demux/demux_playlist.c`,
  `is_include_path()` + the include-path shortcut at working-tree lines
  519-528). Option 2 must keep it.
- The active build is MinGW UCRT64 (`build/compile_commands.json` uses `cc`
  with `C:/msys64/ucrt64/include`). There is **no MSVC build directory** in
  this checkout; the MSVC lane is CI or a new build dir.
- Repo-level commands follow `AGENTS.md` (Meson; `python -m
  mesonbuild.mesonmain` if `meson` is not on PATH).
- Media names below are placeholders: `<media-root>` is a directory of
  `.mkv`-named files, `media-001.mkv` etc. are rank aliases only.

**Testability note.** `scan_dir()` is `static` and the only entry point,
`playlist_autocreate_siblings()` (`demux/demux_playlist.c:636`), needs a
constructed `mpv_global` plus config groups, so the scanner cannot be
unit-tested without exporting or refactoring production code. The least
invasive route is the existing libmpv integration pattern
(`test/libmpv_test_prefetch.c`), which drives the real
`loadfile -> autocreate worker -> scan_dir -> splice` path through the public
API; that is what `test-dirent-scan.c.draft` does. A direct `mp_readdir()`
unit test would be cheap but would not cover scan semantics (filters,
directory modes, ordering, splice). A test that only asserts "no error" is
explicitly avoided.

---

## 0. Baseline record (before touching Option 2)

```powershell
Set-Location C:\Users\andre\Projects\mpv
git status --short --branch                # record the concurrent Option 1 dirty state
git diff -- demux/demux_playlist.c osdep/io.c | Out-File C:\Temp\option2-baseline.diff
meson test -C build --print-errorlogs 2>&1 | Out-File C:\Temp\suite-baseline.txt
```

Store the baseline suite result; the post-change run must not add failures.

## 1. Preprocess gate (seconds, no full build)

Proves `_DIRENT_HAVE_D_TYPE` is active in the `demux_playlist.c` TU and the
`d_type` branch survives preprocessing. Run it **before** applying Option 2
(it must fail: only the stat fallback remains) and **after** (it must pass).

```powershell
$root  = 'C:\Users\andre\Projects\mpv'
$build = Join-Path $root 'build'
$entry = Get-Content (Join-Path $build 'compile_commands.json') -Raw |
         ConvertFrom-Json | Where-Object { $_.file -like '*demux_playlist.c' } |
         Select-Object -First 1
Push-Location $entry.directory
$cmd = $entry.command -replace '\s-MD\b.*$', '' -replace '^"cc"', '"C:\msys64\ucrt64\bin\cc.exe"'
if ($cmd -match '-MD' -or $cmd -notmatch '-std=c11') { throw "unexpected compile command" }
cmd.exe /d /s /c "$cmd -E -dD -o `"dirent-probe.i`" `"$($entry.file)`""
Pop-Location

$probe   = Join-Path $build 'dirent-probe.i'
$defines = Select-String -LiteralPath $probe -Pattern '^#define _DIRENT_HAVE_D_TYPE'
$sites   = Select-String -LiteralPath $probe -Pattern 'ep->d_type == DT_REG', 'ep->d_type == DT_DIR'
if (-not $defines -or $sites.Count -lt 2) {
    throw 'PRECHECK FAIL: d_type fast path not active in demux_playlist.c'
}
"PRECHECK OK: $($defines.Line) + $($sites.Count) branch sites"
Remove-Item -LiteralPath $probe
```

- A1 (drop the gate): the pattern above is exact.
- A2 (`mp_dirent_type()`): adjust to
  `Select-String -Pattern 'mp_dirent_type\(ep\) == DT_REG'` and verify
  `osdep/io.h` defines `_DIRENT_HAVE_D_TYPE` for MinGW in that preprocess.
- This gate is TU-local and cannot catch an unexpected `<dirent.h>` /
  `dirent-win.h` collision in another file; step 2's build is the backstop.

## 2. Apply Option 2 and build (MinGW)

Apply the chosen approach from `design-review.md` §A.2. A1 is one edit in
`osdep/io.h:102-108` (keep `<unistd.h>` for `__MINGW32__`); no call-site
change. Then:

```powershell
Set-Location C:\Users\andre\Projects\mpv
meson compile -C build 2>&1 | Tee-Object C:\Temp\option2-build.txt
if ($LASTEXITCODE -ne 0) { throw 'build failed' }
# no new warnings: compare against C:\Temp\option2-baseline-build.txt (if captured)
```

Only after this passes, add the test registration
(`meson-test-hunk.txt`) and the draft as
`test/libmpv_test_dirent_scan.c`, then:

```powershell
meson test -C build libmpv-test-dirent-scan --print-errorlogs
meson test -C build --suite libmpv --print-errorlogs
meson test -C build --print-errorlogs
```

Acceptance:

| Gate | Pass | Fail |
| --- | --- | --- |
| Preprocess | `_DIRENT_HAVE_D_TYPE` defined + 2 branch sites | fallback only |
| New test (MinGW) | all four fixture cases pass, exact playlist order | any count/order mismatch |
| `--suite libmpv` | no failures, including `libmpv-test-prefetch` external-files case | any failure |
| Full suite | no failure absent from the step-0 baseline | new failure |

## 3. MSVC lane (must stay green)

`dirent-win.h` remains the MSVC provider and `osdep/io.c:621-623` must stay
active. No MSVC build dir exists here, so this lane needs CI or:

```powershell
cmd /d /s /c '"C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat" && meson setup build-msvc -Dtests=true -Dlibmpv=true'
cmd /d /s /c '"...vcvars64.bat" && meson test -C build-msvc libmpv-test-dirent-scan --print-errorlogs'
```

Pass: same fixture outputs as MinGW. Any edit inside `osdep/dirent-win.h` must
be `__MINGW32__`-guarded. If this lane cannot run locally, record it as an
unclosed gate in the parent report; do not claim COMPLETE without it.

## 4. Procmon acceptance (the decisive measurement)

Quantifies the scan on the autocreate worker: `measure-scan.ps1` counts
`CreateFile` rows with `Desired Access: Read Attributes` plus the `Query*`
rows under the media root, discovers the worker TID from the directory
`Read Data/List Directory` open, and (with `-MpvLog`) cross-checks the
`Opening done` → `Autocreate playlist` interval.

### 4a. Fast deterministic lane (local directory, any machine)

Create a local fixture directory with ~500 empty `media-###.mkv` files and
run one bounded mpv load of one file with the user's config minus prefetch
(`--autocreate-playlist=filter --directory-filter-types=video
--directory-mode=ignore`). Capture once before applying Option 2
(`-Baseline`) and once after. Pass: `entryAttributeOpens == 0`,
`dirAttributeOpens <= 1`, `maxAttributeOpenSec <= 0.05`, `queryOps <= 5`.

```powershell
& <skill>\Invoke-ProcmonCapture.ps1 -RunDirectory <PerfRun> `
    -Executable pwsh.exe -ArgumentList @('-NoProfile','-File',`
        'C:\Users\andre\PerfRuns\<old-run>\measurements\Invoke-MpvSkipBatch.ps1',`
        '-RunDirectory','<PerfRun>','-MpvPath','C:\Users\andre\Projects\mpv\dist\mpv.exe',`
        '-MediaRoot','<local-fixture-dir>','-Arm','real','-TrialCount','1',`
        '-FirstTrialIndex','0','-MarkerMode','none') `
    -TimeoutSeconds 60 -ConfigPath <skill>\assets\procmon-duration-tid.pmc -SettleSeconds 3

pwsh -File .\measure-scan.ps1 `
    -FilteredCsv <PerfRun>\exports\procmon-<id>.csv `
    -PathMarkers '<resolved media path as Procmon shows it>' `
    -MpvLog <PerfRun>\measurements\mpv-<trial>.log `
    -MaxEntryAttributeOpens 0 -MaxAttributeOpenSec 0.05 -MaxQueryOps 5 `
    -OutJson <PerfRun>\measurements\scan-local-after.json
```

### 4b. Slow-mount lane (the original regression)

Same capture with `-MediaRoot <media-root>` on the rclone WinFsp mount. The
Procmon path is the resolved UNC (`\\server\RcloneWcrypt\...`), not the drive
letter; pass that as `-PathMarkers`. Record the pre-fix capture with
`-Baseline` first.

Measured reference from the existing t6 capture (anonymized, reused by the
plan): 258 attribute opens on the worker TID (257 entries + the directory),
max 5.2492 s; that fixture is the acceptance target. After Option 1 the
expected pre-Option-2 count is ~256 entries + 1 directory.

| Metric | Pre-Option-2 (`-Baseline`) | Post-Option-2 pass |
| --- | --- | --- |
| `entryAttributeOpens` | ~256 (0 if every entry is a reparse point) | **0** |
| `dirAttributeOpens` | 1 | <= 1 |
| `queryOps` | ~5 per stat'd entry (~1280) | <= 5 |
| `maxAttributeOpenSec` | can be seconds | <= 0.05 |
| `scanWindowSec` | seconds | <= `MaxScanWindowSec` (60 default; tighten for local) |
| `log.deltaSec` (Opening done → Autocreate) | variable, 0.1-47 s observed | secondary; must not regress; cold-cache runs stay noisy |

Note: plain entries only. A directory consisting solely of reparse points
(junctions/symlinks) legitimately keeps one `stat()` per entry
(`DT_LNK` fallback) and would show a constant, small count — treat that as a
different fixture, not a failure.

`measure-scan.ps1` was exercised against a synthetic capture plus a
post-fix simulation in `selftest/` (baseline: entryAttr=2, dirAttr=1,
query=1, max=5.2492 s, exit 0 with `-Baseline`; post-fix: entryAttr=0,
dirAttr=1, query=0, max=0.0001 s, exit 0; threshold mode on baseline data
exits 1). Re-run that self-test after editing the script.

## 5. Optional sanitizer lane

The change is Windows-only; the closest lane is MinGW ASan/UBSan for the new
test:

```powershell
meson setup build-asan -Dtests=true -Dlibmpv=true -Db_sanitize=address,undefined -Dbuildtype=debug
meson test -C build-asan libmpv-test-dirent-scan --print-errorlogs
```

If UCRT64 lacks ASan support, record it as not run and cover the new
enumeration code with the MSVC lane plus the fixture tests; do not claim
sanitizer coverage.

## 6. Rollback

Prefer a reverse patch over file-level restore: other lanes have edits in
`demux/demux_playlist.c`, `osdep/io.c`, `test/libmpv_test_prefetch.c` and
deleted `DOCS/man/mpv.rst`, so `git restore <file>` would destroy their work.

```powershell
Set-Location C:\Users\andre\Projects\mpv
git diff -- osdep/io.h osdep/io.c demux/demux_playlist.c player/external_files.c test/meson.build |
    Out-File C:\Temp\option2.patch          # capture ONLY the Option 2 hunks
# (review C:\Temp\option2.patch: no foreign hunks)
git apply -R C:\Temp\option2.patch
Remove-Item test\libmpv_test_dirent_scan.c
meson compile -C build
meson test -C build libmpv-test-prefetch --print-errorlogs
```

Do not revert `dist\` unless the runtime lane refreshed it; if it did,
rebuild the pre-change binaries before publishing measurements.

## 7. Known gaps / constraints

- No MSVC build directory exists locally (verified: `build` and `build-static`
  both use MinGW `cc`). Step 3 is a real gate and is currently unclosed.
- The concurrent Option 1 edit landed while this review was being written;
  re-check `git diff demux/demux_playlist.c` immediately before applying
  Option 2 and rebase the patch if the function moved.
- The pre-existing latent issue in `mp_readdir()` (unchecked
  `WideCharToMultiByte` + `strlen`, see `design-review.md` V8) is out of scope
  for this plan; it should be filed separately.
- Cold-cache rclone runs vary by tens of seconds; the pass/fail gate is the
  Procmon count, not wall-clock log deltas.
