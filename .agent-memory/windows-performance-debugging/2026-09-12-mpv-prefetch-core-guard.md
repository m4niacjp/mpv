# 2026-09-12 — prefetch core guard (#3) + win32-shell tie-break note (#4)

Follow-up to `2026-09-12-mpv-playlist-sort-fix-applied.md` (script-side stall
fix). Same day, later session.

## Core guard (#3) — implemented

`player/loadfile_async.c` `prefetch_next()`: the handover guard now checks
`playlist->current != mpctx->playing` for the whole file-start handover
instead of only `stop_play == PT_CURRENT_ENTRY`. Root cause of the bypass:
`play_current_file()` zeroes `stop_play` before
`process_hooks("on_before_start_file")`; playlist commands issued by hooks in
that window called `prefetch_next`, which opened the entry after `current`;
the main open then aborted it as a wrong-URL prefetch and joined the opener
(cooperative cancel; seconds on WinFsp). `id_in_prefetch_window` keeps its
narrower condition but is unreachable during the handover now that
`prefetch_next` returns first.

Regression test: `test_prefetch_hook_command` in
`test/libmpv_test_prefetch.c`. It registers an `on_before_start_file` hook via
`mpv_hook_add`, issues an identity `playlist-reorder` while the hook is
pending, fails if any `Prefetching:` log appears before continuing the hook,
then asserts the post-start prefetch still runs and no wrong-URL abort was
logged. Before/after proof (same test binary, only the guard reverted):
old guard -> `prefetch started while the file start was pending` (exit 1);
fixed -> exit 0.

Packaged-binary smoke (`%TEMP%\opencode\prefetch-hook-smoke.lua`, 3 lavfi
entries, hook reorder): old `dist\mpv_bck.exe` logs `Prefetching:` before the
first `Opening done:` and then `Aborting ongoing prefetch of wrong URL.`;
new `dist\mpv.exe` logs neither and prefetches only after the file start
(0 pre-open prefetches, 0 aborts).

## Environment notes (avoid re-discovery)

- ~~This checkout's `build/` is MSYS2 UCRT64 GCC 16.2
  (`C:\msys64\ucrt64\bin`), not MSVC; ninja targets are path-prefixed
  (`test/libmpv-test-prefetch.exe`).~~ Superseded 2026-10-02 — see below.
- **2026-10-02: MSYS2 was gone, then reinstalled.** `C:\msys64` did not exist on
  any drive, so the UCRT64 tree that built `dist\mpv.exe` was unreproducible; it
  was reinstalled the same day (unattended Inno CLI:
  `msys2-x86_64-latest.exe in --confirm-command --accept-licenses
  --accept-messages --root C:/msys64`; `--accept-messages` and
  `--default-answer` are mutually exclusive) and now sits at `C:\msys64`. The
  clang 22.1.3 (VS 18 LLVM) + tracked `subprojects/` wraps tree (FFmpeg
  `meson-8.1`, libplacebo, luajit, shaderc, d3d11) remains the fallback when
  MSYS2 is absent; its exact option list is the `CONFIGURATION` string in
  `build/config.h`. See `DOCS/local-workflow.md` for the pacman mirror and
  `XferCommand` quirks found while installing the UCRT64 dependency set.
- The clang tree needs `RC` pinned to
  `...\VC\Tools\Llvm\x64\bin\llvm-rc.exe` (documented in AGENTS.md). Meson
  1.12.1 pairs clang with `link.exe`, so it selects the Windows SDK `rc.exe`
  for `osdep/mpv.rc`, which rejects the `--codepage=65001` that `meson.build`
  passes; the resource step then fails with `fatal error RC1106` and nothing
  relinks, even when every object is already built.
- `dist\mpv.exe` refreshed 2026-10-02 to the clang build
  (`2A7B822D05CF58452E182A9AD8AFF4363C052E551FBD94D5FEA633284918C612`,
  `v0.41.0-1122-gf923fc56f`, which supports `backstep-cache` and satisfies the
  live `mpv.conf`). The MSYS2 binary (`7C30234D…`, FFmpeg 9.0.1) is kept at
  `dist\mpv_msys2_20260912.exe`; `dist\mpv_bck.exe` (`58702733…`) is untouched.
  The clang binary is static, so `dist\`'s 121 DLLs are unused by it. Feature
  delta vs the MSYS2 build: no libbluray, libcurl, libcaca, libva/libvpl,
  vulkan, subrandr, and FFmpeg 8.1 instead of 9.0.1 — none of which the live
  config or Roaming scripts reference (`vo=gpu-next`, `gpu-api=d3d11`,
  `hwdec=d3d11va`, no `bd://`/vulkan/curl options).
- **2026-10-02 later: UCRT64 parity rebuild supersedes that clang deployment.**
  With MSYS2 reinstalled, `build/` was recreated as the UCRT64 tree
  (`meson setup build -Dtests=true --wrap-mode=nofallback`; the pacman
  `windres` handles `osdep/mpv.rc`, so the `RC` pin is only needed for the
  clang tree) and compiled to
  `B0420E867CFF6DF20873105A738A2AAEB0B7006FFF05CB95FBA68219739D9D1A`
  (`v0.41.0-1125-g1ee8a6663`, built 2026-10-02 01:49:37, FFmpeg 9.0.2,
  libplacebo 7.360.1), whose enabled-features string is byte-identical to the
  Sep-12 baseline. `dist\mpv.exe` now holds it, and its `ldd` closure was copied
  into `dist\` — required, not optional, because `dist\` is on `PATH`: with the
  stale 9.0.1 `avcodec-63.dll` still in place, startup aborted with
  `libavcodec: build version 63.1.102 incompatible with runtime version
  63.1.101`. Verified after deploy: live `mpv.conf` parses (no `backstep-cache`
  error), `--bluray-device`/`--curl-enabled`/`--vulkan-device`/`--vaapi-device`
  are back, `d3d11vpp` present, null-output playback of an h264/aac clip runs to
  `End of file`.
- `dist\mpv.exe` refreshed to
  `7C30234D1D33419B111975302279D9489E5D150A18FA7D1F3C792363A0A7889F`
  (`v0.41.0-948-g2b0f9f46c-dirty`, built 2026-09-12 06:09:49); the previously
  validated benchmark binary `58702733…` is kept at `dist\mpv_bck.exe`.
- Do not let `meson test` inherit `PWD` from an MSYS2 bash: `mp_getcwd()`
  (`misc/path_utils.c:170`) trusts `$PWD`, so tests that create relative paths
  fail with source-root-relative opens (`test_autocreate_playlist` then logs
  `Invalid argument`). With `PWD` unset, `meson test -C build --suite libmpv`
  is 26/27; the only failure is the pre-existing ggml assert in
  `libmpv-lifetime` (`ggml.cpp:22`, unrelated code).
- `dist\mpv.exe` refreshed to
  `7C30234D1D33419B111975302279D9489E5D150A18FA7D1F3C792363A0A7889F`
  (`v0.41.0-948-g2b0f9f46c-dirty`, built 2026-09-12 06:09:49); the previously
  validated benchmark binary `58702733…` is kept at `dist\mpv_bck.exe`.

## Win32-shell tie-break note (#4) — done

`DOCS/references/libraries/win32-shell/docs/sortcolumns.md` gained an
"Equal-key tie-break (verified live, 2026-09-11/12)" section: Explorer falls
back to later `SortColumns` tokens (unflagged = ascending); a live
`System.DateModified` descending folder resolved a second-resolution mtime tie
by `System.ItemNameDisplay` ascending; the helper's natural-name tie-break
reproduced all 36 Explorer positions (34 unchanged, tied pair swapped). Front
matter and `index.md` dates updated. Caveats recorded: the live SortColumns
string exposed only the primary column, and sub-second Explorer comparisons
are not observable through the helper.
