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

This checkout keeps two Meson trees. `build/` is the normal `-Dtests=true`
tree. `build-static/` additionally links statically (for a self-contained
`libmpv`); recreate it with:

```powershell
meson setup build-static -Dtests=true -Ddefault_library=static -Dprefer_static=true -Dc_link_args=-static -Dcpp_link_args=-static
```

Both are untracked build output, so either can be deleted and recreated; the
`build-static` configure line above is the only record of it.

## Repository identity and remotes

The canonical clone and publication repository for this checkout is the
personal fork:

```text
https://github.com/m4niacjp/mpv.git
```

Use conventional remote names: `origin` is that fork and `upstream` is the
official mpv repository. Local `master` tracks `origin/master`; it must not
track `upstream/master`.

```powershell
git remote set-url origin https://github.com/m4niacjp/mpv.git
git remote set-url upstream https://github.com/mpv-player/mpv.git
git branch --set-upstream-to=origin/master master
git remote -v
git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}'
```

For a new checkout, clone the fork first and then add the official source:

```powershell
git clone https://github.com/m4niacjp/mpv.git
Set-Location mpv
git remote add upstream https://github.com/mpv-player/mpv.git
```

For the older `origin` = official, `fork` = personal layout, migrate once with:

```powershell
git remote rename origin upstream
git remote rename fork origin
git branch --set-upstream-to=origin/master master
```

Keep editor comparison metadata pointed at `upstream/master` when it is used:

```powershell
git config branch.master.vscode-merge-base upstream/master
```

## Reviewing and importing upstream changes

Do not use a blind `git pull`, merge upstream directly into `master`, or assume
a conflict-free merge preserves local behavior. Fetch explicitly, review both
commit ranges and changed paths, integrate on a temporary branch, and verify
before publishing.

### 1. Establish a recoverable baseline

Inspection fetches are safe, but do not start integration with uncommitted
changes. Preserve unrelated work instead of resetting it. Commit and push the
intended baseline, or deliberately park unfinished work in a named stash, then
create a backup ref:

```powershell
git status --short
git diff --name-only
git switch master
git fetch --prune origin
git fetch --prune upstream
git merge --ff-only origin/master
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
git branch "backup/pre-upstream-$stamp" master
```

The `git merge --ff-only origin/master` above only synchronizes the already
fetched canonical fork branch; it does not import official upstream changes.
Stop if the worktree is dirty, the fast-forward fails, or local `master`
differs unexpectedly from `origin/master`.

### 2. Review the incoming and local ranges

Compute the merge base and inspect the two sides independently:

```powershell
$base = git merge-base origin/master upstream/master
git log --oneline --decorate "$base..upstream/master"
git diff --stat "$base..upstream/master"
git diff --name-status "$base..upstream/master"
git log --oneline --decorate "$base..origin/master"
git diff --name-status "$base..origin/master"
$incoming = git diff --name-only "$base..upstream/master"
$local = git diff --name-only "$base..origin/master"
Compare-Object $incoming $local -IncludeEqual -ExcludeDifferent
```

An empty overlap report lowers merge risk but is not proof of behavioral
compatibility. Review upstream commits that affect playback, playlists,
directory scanning, demux/cache ownership, threading, Windows I/O, or option
lifecycle even when the changed files differ. Local behavior is concentrated
in `player/loadfile_async.c`, `player/autocreate_playlist.c`, other
`player/loadfile*` files, `common/playlist.*`, `misc/path_utils.*`, and the
Windows I/O layer; use the current diff rather than treating this list as
exhaustive.

### 3. Integrate in a staging branch

For a routine upstream refresh, preserve both histories with a merge. This
avoids rewriting already-published local commits:

```powershell
git switch -c "integrate/upstream-$stamp" master
git merge --no-ff upstream/master
```

Resolve conflicts one subsystem at a time and compare each resolution against
both parents. For a deliberately selected isolated fix, use `git cherry-pick
-x <commit>` instead; do not cherry-pick a large upstream range as a substitute
for reviewing it. Rebase is not the default because it rewrites the fork's
published local history.

After integration, repeat the path-overlap review and inspect the effective
result:

```powershell
git diff --check
git log --oneline master..HEAD
git diff --stat master...HEAD
```

### 4. Verify behavior before promotion

Run the tests for every affected subsystem, then the practical full mpv suite.
Playlist/autocreate/prefetch changes must include the focused libmpv test when
that target is configured:

```powershell
meson compile -C build
meson test -C build libmpv-test-prefetch --print-errorlogs
meson test -C build --print-errorlogs
```

Apply the known local environment caveats below only after verifying that a
failure matches the documented signature. Do not weaken or skip a newly failing
check merely because the merge was conflict-free.

On this Windows checkout, finish with the targeted `mpv.exe` / `mpv.com` build,
copy both files to `dist/`, and run the `--no-config --version` smoke check from
[AGENTS.md](../AGENTS.md#this-windows-checkout-targeted-build-and-deployment).

When upstream touches playlist, autocreate, prefetch, stream/demux/cache, or
Windows filesystem behavior, also exercise the deployed binary against
`X:\XXX\Best`. Verify initial open and playlist-next latency, demuxer adoption,
unexpected stale/wrong-prefetch cancellation, and CPU/disk activity. Compare an
uncached file and a warm repeat when practical. Do not delete the entire rclone
VFS cache merely to manufacture a cold run; choose an uncached file or obtain
explicit approval for isolated cache eviction.

### 5. Promote and prove the published result

Only after review and verification pass, fast-forward `master` to the staging
branch and push the canonical repository:

```powershell
$integration = git branch --show-current
git switch master
git merge --ff-only $integration
git push origin master
git fetch origin
$localSha = git rev-parse master
$remoteSha = (git ls-remote origin refs/heads/master).Split()[0]
if ($localSha -ne $remoteSha) { throw 'origin/master does not match local master' }
git rev-list --left-right --count master...origin/master
```

Record the upstream range, overlapping paths, conflict decisions, tests, real
mount checks when applicable, and matching local/remote SHA in the integration
report or commit notes.

## Personal runtime configuration

`C:\Users\andre\AppData\Roaming\mpv\` is outside this repository. Files such
as `mpv.conf`, `input.conf`, and `scripts\playlist-sort.lua` are active local
runtime configuration, but cloning, committing, or pushing
`https://github.com/m4niacjp/mpv.git` does not preserve them. Back them up or
version them separately, and include them in compatibility testing when an
upstream import changes options, Lua events, playlist commands, or prefetch
behavior.

### Roaming workstream

Treat that tree as a second workstream, not as incidental configuration. It
holds `mpv.conf`, `input.conf`, `scripts\*.lua`, `script-opts\` /
`scripts-opts\`, `Docs\INTERNAL.md` and `Docs\Reference\*.md`,
`tests\*-regression.lua`, `backups\`, and `.agent-memory\<role>\`, and it carries
its own `AGENTS.md`.

- **Which tree changes?** Decide by where the edit lands, not by vocabulary: a
  claim about `RTX HDR`, `prefetch-playlist-*`, or a `user-data` property is a
  Roaming task when the Lua, `mpv.conf`, or menu is what must change, and a
  checkout task when mpv's C, Meson, or `DOCS/man/` is.
- **File sandbox:** Roaming is outside the session workspace, so writes there are
  denied. Retry the exact operation once with `danger-full-access` and a
  justification — that retry raises the approval prompt. If the escalation is
  unavailable, stage the reviewed change inside the checkout and hand it back;
  never report a Roaming edit as landed when it is only staged.
- **Backups:** copy each file to be changed into Roaming `backups\` first, as
  `<name>-before-<short-reason>-<YYYYMMDD-HHMMSS>`.
- **Reload:** Roaming Lua is not hot-reloaded; mpv must restart to pick up a
  script change.
- Finish with a harness run (below), or state explicitly what could not be
  verified — real playback, display, and GPU behavior usually needs the user.

### Precedence and ground truth

When a checkout document and a Roaming document disagree, neither guide is
authoritative: the live `%APPDATA%\mpv\mpv.conf` and the current source win, and
the reconciliation belongs in the same change. Worked example: the checkout
guide, `mpv.conf`, `DOCS/man/vf.rst`, and Roaming
`Docs\Reference\RTX_VIDEO.md` use `hwdec=d3d11va`, while older Roaming prose
said `hwdec=d3d11va-copy`.

The tracked onboarding set is `AGENTS.md` and `DOCS/local-workflow.md`. Keep
unrelated local tooling and build artifacts out of scope unless the task
explicitly includes them; inspect the current worktree rather than relying on a
clean-tree snapshot.

### Mock-mpv Lua harness

Roaming scripts are covered by standalone harnesses that stub the `mp` API
(`tests\playlist-sort-regression.lua`, `tests\quick-menu-rtx-hdr-regression.lua`,
`tests\render-detail-regression.lua`; the last one also loads the live
`mpv.conf` through the real API to check the `detail-*` profiles, with an
`MPV_CONF` override):

- Load the target with `package.preload["mp"]` (plus `mp.msg` and `mp.assdraw`),
  `_G.mp = <mock>`, then `dofile(target)`; allow an env override for the target
  path (for example `MPV_QUICK_MENU_SCRIPT`) so a staged copy can be tested
  before it is installed.
- Drive the script only through the entry points it registers
  (`mp.add_hook`, `mp.register_event`, `mp.observe_property`, forced key
  bindings, `register_script_message`). No sleeps, no real media, no network.
- End with `os.exit(failures == 0 and 0 or 1)` and print one
  `PASS:`/`FAILURES:` line.
- Run it without the real config:
  `mpv --no-config --load-scripts=no --vo=null --ao=null --idle=yes --script=<harness>`.
  Use the console wrapper for visible output; with only the GUI-subsystem
  `mpv.exe`, redirect stdout/stderr to files and read the exit code from the
  process object, because the status line arrives on stderr.
- A harness must fail loudly: never weaken or delete an assertion to make a run
  pass. Assert on observable effects (property writes, `vf` commands, overlay
  text), and note any layout or geometry constants the assertions depend on.
- A new Roaming script change also needs the existing harnesses re-run, so a
  regression in an unrelated script is still caught.

### Local agent conventions

- `.agent-memory\<role>\MEMORY.md` (tracked) is per-role durable memory for
  `codebase-explorer`, `doc-keeper`, `doc-search`, `web-search`, and
  `windows-performance-debugging`. Read the relevant role's memory before docs
  or analysis work.
- `doc-keeper` owns `DOCS/references/libraries/**` bodies; user-visible behavior
  belongs in `DOCS/man/`, interface notes in `DOCS/interface-changes/`. Keep the
  existing `README.md` / `AGENTS.md` / `DOCS/` layout and never create a
  lowercase `docs/` tree.
- `tasks\*.md` (untracked) holds per-run worker/verifier reports; keep them out
  of commits.

## VFS cold/warm benchmark harness

`benchmarks\vfs-bench\` is the checkout-local harness for the rclone/WinFsp VFS
cold/warm first-frame and `playlist-next` measurements (completed report
package: `benchmarks\Run-20260912-041416-mpv-vfs-cold-warm\`; session handoff:
`benchmarks\vfs-bench\handoff.md`). Corpus and reports are under
`C:\PerfBench`; run directories (trial JSON, logs, ETL/PML) are created under
`C:\Users\andre\PerfRuns\mpv-vfs-*`.

| Script | Role |
| --- | --- |
| `New-BenchVideos.ps1`, `Resume-BenchVideos.ps1`, `Verify-BenchMedia.ps1` | Generate `PB01`–`PB25` plus the warm-up clip, resume an interrupted generation, and full-decode verify before upload |
| `Sync-BenchMedia.ps1` | Seed `wcrypt:PerformanceBench/{Cold,Warm}` with parallel RC `copyfile`, verify sizes, then refresh the mount root-first (`vfs/refresh`, then recursive) |
| `Set-BenchCacheState.ps1` | Report `status` or enforce `cold` (delete the span's vfs data + vfsMeta) / `warm` (verify flushed `Rs` coverage is 100 %) |
| `Invoke-BenchTrials.ps1` | Matrix driver (conditions including the `config-*-no-playlist-sort` A/B) with `-PlainRepeats`; toggles `playlist-sort.lua` with a hash-guarded restore |
| `Summarize-BenchTrials.ps1`, `Analyze-ProcmonSwitch.ps1` | Per-trial CSV + per-condition JSON; playlist-next switch window from a Procmon CSV |
| `bench-probe.lua`, `Measure-Load.ps1`, `VfsBench.psm1` | In-process driver/recorder, preflight load sampling, and shared helpers |

Protocol invariants:

- Run one mpv process at a time, and purge the system standby list before each
  trial (authorized for this benchmark only).
- A cold trial deletes the span's vfs data + metadata under the live rclone;
  the 60 s `--vfs-handle-caching` grace must have expired (reused spans wait
  another 15 s).
- A warm trial is only valid with flushed `vfsMeta` `Rs` coverage of 100 %; the
  on-disk metadata lags the in-memory item until the 60 s grace ends, so warm
  verification settles and polls instead of checking immediately.
- The rclone log is raised to DEBUG only during traced (WPR/Procmon) trials and
  restored right after (filtered slice beside the trial JSON).
- WPA exports use `-Marks workload-start,workload-end` (comma, no space; pass it
  from PowerShell, not as a `pwsh -File` argument).
- Keep raw ETL/PML and large Procmon CSVs outside Git; only the report package
  belongs in the repository.

The real-config arm reads `%APPDATA%\mpv`; the A/B conditions disable
`playlist-sort.lua` by moving it out of `%APPDATA%\mpv\scripts` for the run
(mpv probes every entry under `scripts\`, so renaming it in place would log
"Can't load unknown script"); the move is hash-guarded and restored afterwards.

## Test suite caveat on this checkout

`meson test -C build` reports 230 passing with three known environment failures
that are unrelated to local source changes:

- `ffmpeg - mpv:img-format` and `ffmpeg - mpv:scale-sws` fail because
  `core.autocrlf=true` checks out `test/ref/**/*.txt` with CRLF while the test
  binaries write LF. The byte delta equals the CR count exactly, and the
  reference files are unmodified in the index.
- `libuv:libuv_run_tests` times out at 300s; it belongs to the libuv subproject,
  not mpv.
