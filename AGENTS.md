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
& $env:ComSpec /d /s /c '"C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat" && set "PATH=C:\Users\andre\AppData\Local\Python\pythoncore-3.14-64\Scripts;C:\Users\andre\AppData\Local\bin\NASM;C:\Program Files\Git\usr\bin;%PATH%" && ninja -C build mpv.exe mpv.com'
Copy-Item -LiteralPath build\mpv.exe -Destination dist\mpv.exe -Force
Copy-Item -LiteralPath build\mpv.com -Destination dist\mpv.com -Force
& .\build\mpv.com --no-config --version
```

The explicit targets avoid unrelated optional tools in the default build. See
[DOCS/compile-windows.md](DOCS/compile-windows.md) for supported Windows build
setups. Player behavior that affects the local runtime should finish with this
targeted build and `dist\` refresh.

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
  use `libmpv_test_*.c`, and expected output belongs in `test/ref/`.
- User-visible behavior belongs in `DOCS/man/`; incompatible interfaces require
  a note in `DOCS/interface-changes/`. Keep documentation in the same logical
  change.
- Commit subjects use `subsystem: short description`, lowercase after the
  colon, no period, and at most 72 characters. Explain why in a 72-column body.
- Open a pull request (or send `git format-patch`), mark unfinished work
  `[RFC]`, and state the testing performed. Split independent work into logical
  commits.
- New code is LGPLv2.1+. Disclose AI/LLM assistance in a PR description.

## Local user-script routing

This checkout also has a personal runtime configuration at
`C:\Users\andre\AppData\Roaming\mpv\`; packaged binaries are in `dist/`.
For a user Lua script there, or `mpv.conf`, `input.conf`, or `script-opts/`
glue that supports it, route the work to the designated `mpv-lua-scripter`
agent/role using the active environment's delegation mechanism. Do not edit
that Roaming Lua or Lua-wired configuration inline in the parent task.

This routing does not apply to built-in `player/lua/` or normal upstream C/Meson
work. Roaming `*.lua` client names replace non-alphanumeric characters with `_`
(`playlist-sort.lua` is `playlist_sort` for `script-message-to`).

For local playlist-prefetch testing, the Roaming `mpv.conf` may set
`prefetch-playlist-on-cache=yes`, `prefetch-playlist-cache-secs=<seconds>`,
`prefetch-playlist-cache-bytes=<bytesize>`, `prefetch-playlist-max`,
`prefetch-playlist-realtime=yes`, `prefetch-playlist-start-secs`, and
`prefetch-playlist-start-bytes`. Next-1 fills the start window first; extra
`prefetch-playlist-max` entries wait until that window is full (both start
options 0 = immediate full-cache fill). Playlist-move, playlist-reorder,
shuffle, unshuffle, remove, and clear retarget prefetch to the new next
entries instead of keeping a stale previous next. `playlist-reorder` is a
one-shot permutation by current 0-based indexes (does not restart the current
file; one prefetch retarget). Use it instead of many `playlist-move` calls
when sorting a large autocreate playlist. `--autocreate-playlist=filter|same`
opens a local regular file first and scans siblings on a worker; the core splices
remaining entries in bulk (reuses the worker playlist). The playlist may
grow after `file-loaded`.
