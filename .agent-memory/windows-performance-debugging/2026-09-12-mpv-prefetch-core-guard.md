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

- This checkout's `build/` is MSYS2 UCRT64 GCC 16.2
  (`C:\msys64\ucrt64\bin`), not MSVC; ninja targets are path-prefixed
  (`test/libmpv-test-prefetch.exe`). The AGENTS.md VS/vcvars command does not
  match this build tree (`cc` is not on that PATH).
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
