# mpv agent guide

mpv is a C11 command-line media player and libmpv library, built with Meson.
Read the code and nearby tests before changing behavior; this guide is an
onboarding map, not a substitute for source verification.

## Start here

1. Read [README.md](README.md) for project scope, prerequisites, and the
   baseline Meson workflow.
2. Read [DOCS/tech-overview.txt](DOCS/tech-overview.txt) for the broad
   playback/data-flow model. It includes historical material (and an old commit
   reference), so verify all implementation details against current code.
3. Read [DOCS/contribute.md](DOCS/contribute.md) before preparing a patch.
4. Read [DOCS/local-workflow.md](DOCS/local-workflow.md) for this checkout's
   coding-AI, Windows build/deployment, and remote-maintenance notes.
5. Use the manuals for the affected interface:
   [player/options/input](DOCS/man/mpv.rst), [commands](DOCS/man/commands.rst),
   [options](DOCS/man/options.rst), [Lua](DOCS/man/lua.rst), and
   [libmpv](DOCS/man/libmpv.rst) with its public headers in `include/mpv/`.
6. Remaining checkout docs: [DOCS/references/README.md](DOCS/references/README.md)
   indexes library/subsystem summaries,
   [DOCS/optimization_implementation.md](DOCS/optimization_implementation.md)
   holds the local RTX/playlist notes and the `user-data` interface table,
   [DOCS/compile-windows.md](DOCS/compile-windows.md) covers Windows builds, and
   [DOCS/interface-changes/](DOCS/interface-changes/) holds interface notes.

## First successful change

### Portable Meson workflow

Run these from the repository root on a supported development environment:

```sh
meson setup build -Dtests=true
meson compile -C build
meson test -C build json
./build/mpv --no-config --version
```

- Reconfigure an existing build with `meson configure build -D<option>=<value>`.
- Use `meson test -C build <test-name>` for a focused test; discover names with
  `meson test -C build --list`. Run the affected suite, then
  `meson test -C build`, when practical.
- If `meson` is unavailable as a command, use
  `python -m mesonbuild.mesonmain` in the commands above.

### This Windows checkout: targeted build and deployment

This is local runtime guidance, not the portable upstream build path. From a
Visual Studio x64 environment, build only the player targets and refresh the
packaged binaries used by this checkout:

```powershell
& $env:ComSpec /d /s /c '"C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat" && set "PATH=C:\Users\andre\AppData\Roaming\Python\Python314\Scripts;C:\Users\andre\AppData\Local\bin\NASM;C:\Program Files\Microsoft Visual Studio\18\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja;C:\Program Files\Microsoft Visual Studio\18\Community\VC\Tools\Llvm\x64\bin;C:\Program Files\Git\usr\bin;%PATH%" && set "RC=C:\Program Files\Microsoft Visual Studio\18\Community\VC\Tools\Llvm\x64\bin\llvm-rc.exe" && ninja -C build mpv.exe mpv.com'
Copy-Item -LiteralPath build\mpv.exe -Destination dist\mpv.exe -Force
& .\dist\mpv.exe --no-config --version
```

The PATH entries supply `meson` (user-site Scripts, used when ninja
regenerates), `ninja` (Visual Studio's CMake bundle) and `clang` (Visual
Studio's LLVM); `vcvars64.bat` provides none of them. `RC` must point at
`llvm-rc.exe`. Meson 1.12.1 sees clang linked with `link.exe`
and therefore picks the Windows SDK `rc.exe` for `osdep/mpv.rc`, which rejects
the `--codepage=65001` that `meson.build` passes (`fatal error RC1106`);
`llvm-rc` accepts it. Without the pin the resource step fails and nothing
relinks. `dist\` intentionally has no `mpv.com` (the console stub sits there as
`mpv.bat.com`), so a bare `mpv` resolves to the GUI binary; refresh only
`mpv.exe` and read redirected output instead of relying on a console wrapper.

The explicit targets avoid unrelated optional tools in the default build. See
[DOCS/compile-windows.md](DOCS/compile-windows.md) for supported Windows build
setups. Player behavior that affects the local runtime should finish with this
targeted build and `dist\` refresh.

`dist\` can be partially refreshed, so `Test-Path dist\mpv.exe` before relying
on it. The deployed `mpv.exe` is GUI-subsystem: redirect stdout/stderr and read
the exit code (or run the freshly built `build\mpv.com`) for visible console
output.

## Subsystem map

| Area | Current source | Focused tests to inspect | Primary docs |
| --- | --- | --- | --- |
| Playback, commands, scripting | `player/` (incl. `player/loadfile_async.c`, `player/autocreate_playlist.c`), `input/`, `options/` | `test/libmpv_test_*.c`, `test/paths.c` | `DOCS/man/{commands,input,lua,options}.rst` |
| Audio, video, subtitles, filters | `audio/`, `video/`, `sub/`, `filters/` | `test/{chmap,format,gl_video,img_format,scale_*}.c` | `DOCS/man/{af,ao,vf,vo}.rst` |
| Demuxing, streams, cache | `demux/`, `stream/` | `test/avio_crypto.c`; inspect `test/` for related coverage | `DOCS/man/options.rst`, `DOCS/man/commands.rst` |
| Public embedding API | `include/mpv/`, `player/client.c` | `test/libmpv_*.c` | `DOCS/man/libmpv.rst`, header Doxygen |
| Platform/common infrastructure | `common/`, `misc/`, `osdep/`, `ta/` | `test/{json,language,timer,linked_list,codepoint_width}.c` | nearby source comments and relevant manual page |

This is a navigation map, not a coverage claim: inspect `test/meson.build` and
nearby tests to establish what is actually exercised.

## Working rules

- C11, K&R style; four spaces, no tabs; soft 80-column and hard 100-column
  limits. Brace multi-line `if`/`for`/`while` bodies and both `if`/`else`
  branches. Follow `.editorconfig` and `TOOLS/uncrustify.cfg`.
- Order includes as standard, library, then internal headers; separate and
  alphabetize each group. Avoid GNU-only extensions and VLAs to preserve
  Windows/MinGW compatibility. New Apple Cocoa code must be Swift.
- Run `pre-commit run --all-files` for whitespace and spelling hooks when
  practical. Do not weaken tests or checks to make a failure disappear.
- Treat `https://github.com/m4niacjp/mpv.git` as canonical `origin` and
  `https://github.com/mpv-player/mpv.git` as comparison-only `upstream`.
  Never import upstream with a blind pull or direct merge into `master`; follow
  the staged review, verification, and remote-SHA proof in
  [DOCS/local-workflow.md](DOCS/local-workflow.md#reviewing-and-importing-upstream-changes).
- Unit tests are normally named after their subject; libmpv integration tests
  use `libmpv_test_*.c`, and expected output belongs in `test/ref/`. Roaming
  Lua changes are covered by mock harnesses under `%APPDATA%\mpv\tests\`, not by
  meson (see [DOCS/local-workflow.md](DOCS/local-workflow.md#mock-mpv-lua-harness)).
- User-visible behavior belongs in `DOCS/man/`; incompatible interfaces require
  a note in `DOCS/interface-changes/`. Keep documentation in the same logical
  change.
- Commit subjects use `subsystem: short description`, lowercase after the
  colon, no period, and at most 72 characters. Explain why in a 72-column body.
- Open a pull request (or send `git format-patch`), mark unfinished work
  `[RFC]`, and state the testing performed. Split independent work into logical
  commits.
- New code is LGPLv2.1+. Disclose AI/LLM assistance in a PR description.

## Workstreams and routing

Two trees are in play; decide which one the task changes before reading code.

- **This checkout** is mpv itself: C, Meson, `DOCS/man/`, `test/`. Use the build
  and test paths above.
- **Roaming** (`C:\Users\andre\AppData\Roaming\mpv\`) is the personal runtime:
  `mpv.conf`, `input.conf`, `script-opts/`, `scripts/*.lua`, its own `AGENTS.md`
  and `Docs/`, and mock harnesses in `tests/`. A behavior claim that names an
  mpv option or filter is still a Roaming task when the file that must change
  lives there.

- Roaming is outside the file sandbox, so its writes need the documented
  escalation or a staged handback; back up each file before changing it.
- Roaming `*.lua` client names replace non-alphanumeric characters with `_`
  (`playlist-sort.lua` is `playlist_sort` for `script-message-to`).
- When documents disagree, the live `%APPDATA%\mpv\mpv.conf` and the current
  source win over any guide; reconcile in the same change.

The Roaming `AGENTS.md` and `Docs/` cover the personal configuration, and
[DOCS/local-workflow.md](DOCS/local-workflow.md#roaming-workstream) covers the
sandbox, backup, and harness procedure. Prefetch and reorder semantics are
the manual's (`--prefetch-playlist` in
[DOCS/man/options.rst](DOCS/man/options.rst), `playlist-reorder` in
[DOCS/man/input.rst](DOCS/man/input.rst)); for VFS cold/warm measurements see
the [harness notes](DOCS/local-workflow.md#vfs-coldwarm-benchmark-harness) and
`benchmarks\vfs-bench\handoff.md`.
