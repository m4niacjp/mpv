# Local workflow notes

This is part of the local coding-AI onboarding path. Start with the concise
[repository guide](../AGENTS.md), then use this page for checkout-specific
Windows build/deployment and remote maintenance. It is not part of the
user-facing mpv manual.

## First local success

Use the portable workflow in [AGENTS.md](../AGENTS.md#first-successful-change)
first: configure with `meson setup build -Dtests=true`, compile, run a focused
test such as `meson test -C build json`, and smoke-test with
`./build/mpv --no-config --version` (or `./build/mpv.com --no-config --version`
on this Windows checkout so console output is visible).

For this checkout's Windows runtime, use the targeted build and `dist/`
deployment command in [AGENTS.md](../AGENTS.md#this-windows-checkout-targeted-build-and-deployment).
It builds `mpv.exe` and `mpv.com` only, then refreshes the packaged binaries.
Do not treat that machine-specific command as the general upstream build path.

## Remotes

Keep `origin` pointed at upstream mpv for fetches:

```powershell
git remote set-url origin https://github.com/mpv-player/mpv
```

Keep `fork` pointed at the personal fork for pushes:

```powershell
git remote add fork https://github.com/m4niacjp/mpv.git
```

If the fork repository does not exist yet, create it from this checkout and add
the remote in one step:

```powershell
gh repo fork --remote --remote-name fork
```

If `fork` already exists, confirm or repair it:

```powershell
git remote -v
git remote set-url fork https://github.com/m4niacjp/mpv.git
```

## Updating the fork

Fetch both remotes, then compare the upstream and fork branches before making
local history changes:

```powershell
git fetch origin
git fetch fork
git rev-parse origin/master fork/master
```

Upstream `origin/master` was last verified at:

```text
7b8915bc1d04c7e1b61184e00c7fbfaab1911e75
```

`fork/master` tracks local `master`, which is `origin/master` plus local
prefetch commits. Committed prefetch work currently ends at:

```text
496f5920bdab10e5ee2a93e0b4b09e072e07f7a3
```

That includes on-cache start, `--prefetch-playlist-max` /
`--prefetch-playlist-realtime`, playlist-edit retarget (drop retained
demuxers that left the next window after `playlist-move`, `playlist-reorder`,
shuffle, unshuffle, remove, or clear, then prefetch the new next files),
two-phase prefetch start-window options (`--prefetch-playlist-start-secs`
default 10, `--prefetch-playlist-start-bytes` default 32MiB; both 0 =
immediate full-cache fill), and async `--autocreate-playlist` for local
regular files (open the media file first; sibling scan on a worker; core
bulk-splices remaining entries). Refresh this hash
from `git rev-parse` after further prefetch commits land.

If the fork falls behind upstream and the local worktree is clean, fast-forward
the fork from upstream and push it:

```powershell
git switch master
git merge --ff-only origin/master
git push fork master
```

If local committed `HEAD` is already included in `origin/master`, the fork can
also be updated directly from the fetched upstream ref without changing the
local branch or touching a dirty worktree:

```powershell
git merge-base --is-ancestor HEAD origin/master
git push fork origin/master:master
```

If the worktree is dirty, especially when local source changes overlap upstream
updates, do not merge, rebase, reset, or stash automatically. First inspect the
dirty files and decide whether to commit the local work, split it, or park it in
a named stash:

```powershell
git status --short
git diff --name-only
```

The tracked onboarding set is `AGENTS.md` and `DOCS/local-workflow.md`. Keep
unrelated local tooling and build artifacts out of scope unless the task
explicitly includes them; inspect the current worktree rather than relying on a
clean-tree snapshot.

## Test suite caveat on this checkout

`meson test -C build` reports 230 passing with three known environment failures
that are unrelated to local source changes:

- `ffmpeg - mpv:img-format` and `ffmpeg - mpv:scale-sws` fail because
  `core.autocrlf=true` checks out `test/ref/**/*.txt` with CRLF while the test
  binaries write LF. The byte delta equals the CR count exactly, and the
  reference files are unmodified in the index.
- `libuv:libuv_run_tests` times out at 300s; it belongs to the libuv subproject,
  not mpv.
