# Commands and outcomes

No complete shell transcript was retained. The workload argument lists below are
copied from MPV's own `Command line options` log records; paths shown as
`<log-file>` replace only the recorded output path. Helper outcomes are copied
from their error messages. Do not treat these as a statistically repeatable
benchmark script yet.

## Workloads

### Active configuration, direct directory

```text
dist\mpv.exe --player-operation-mode=pseudo-gui --idle=no --keep-open=no --msg-level=all=info --log-file=<log-file> I:\XXX
```

Outcome: MPV logged `Opening failed or was aborted: I:\XXX` at 0.224 s and
`Failed to recognize file format` at 0.226 s, then exited. The same log records
the active `directory-mode=ignore` option.

### Corrected directory, prefetch active

```text
dist\mpv.exe --player-operation-mode=pseudo-gui --directory-mode=recursive --idle=no --keep-open=no --msg-level=all=info --log-file=<log-file> I:\XXX
```

Outcome: folder open 2.178 s, current file open 2.193 s, first AO 2.569 s,
first VO 2.578 s. The external harness stopped only PID 52464 after the
30-second sample window.

### Corrected directory, prefetch disabled

```text
dist\mpv.exe --player-operation-mode=pseudo-gui --directory-mode=recursive --prefetch-playlist=no --prefetch-playlist-on-cache=no --prefetch-playlist-realtime=no --idle=no --keep-open=no --msg-level=all=info --log-file=<log-file> I:\XXX
```

Outcome: folder open 2.126 s, current file open 2.133 s, first AO 2.592 s,
first VO 2.594 s. The external harness stopped only PID 55580 after the
30-second sample window.

### Single-file control, sibling discovery disabled

```text
dist\mpv.exe --player-operation-mode=pseudo-gui --autocreate-playlist=no --idle=no --keep-open=no --msg-level=all=info --log-file=<log-file> I:\XXX\3p\683d17803fd90.mkv
```

Outcome: file open 0.201 s, first AO 0.577 s, first VO 0.578 s. The external
harness stopped only PID 30556 after the 30-second sample window.

## WPR preparation and blocked capture

The saved plan selected `CPU.Light,GPU.Light,FileIO.Light` in memory mode.
`Invoke-WprCapture.ps1 -Executable` first rejected `mpv.com` because it requires
a native `.exe`. A retry using `pwsh.exe` reached the capture prerequisite and
failed with `WPR capture needs an elevated session.` No recording started, so
there was no ETL to stop or recover and no UAC bypass was attempted.

## Read-only repository checks

```powershell
git status --short --branch
git rev-parse HEAD
& .\dist\mpv.com --no-config --version
```

Outcomes: branch `master` tracked `origin/master`; commit
`d37b8c1a79c422208bde4050154dab7dbcd32846`; MPV
`v0.41.0-947-gd37b8c1a7-dirty`. The pre-existing dirty files are outside this
report package and were not modified by the playback investigation.
