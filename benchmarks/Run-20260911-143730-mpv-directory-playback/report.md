# MPV recursive-directory playback investigation

## Scenario and result

The requested workload was playback of the videos below `I:\XXX` with the
deployed local MPV build. The primary boundary was process launch to first video
output; a 30-second externally bounded window supplied process-level resource
samples.

The active configuration rejected the directory because it set
`directory-mode=ignore`. A command-line `--directory-mode=recursive` override
made the workload playable without changing user configuration. In single trials,
recursive-folder playback reached first VO at 2.578-2.594 s, while the same first
file with sibling discovery disabled reached first VO at 0.578 s. The roughly
2.0-second gap is measured scenario overhead, but its CPU, scheduling, and storage
breakdown is not known because WPR capture required elevation.

No product source, binary, or user configuration was changed by this
investigation.

## Reproduction boundary and controls

- Input tree: `I:\XXX`, 9,797 video files when enumerated during the session.
- Representative first file: `I:\XXX\3p\683d17803fd90.mkv`.
- Start boundary: creation of the MPV process by the PowerShell sampler.
- First-output boundary: first MPV `VO:` log record on its monotonic timebase.
- Sampling boundary: about 30 seconds, then stop only the PID created by the
  harness. `--length` and `--frames` were not trusted to stop the whole playlist.
- Cache state: unknown. Runs were sequential and no cache purge was performed.
- Background-load preflight: not recorded. Contamination by unrelated system
  activity is `INCONCLUSIVE` for all four trials.
- Observer: verbose MPV file logging plus one process sample per second.
- Process tree: one MPV process was observed; no child process was identified.
- Trials: one failed directory attempt and one trial for each successful variant.
  The results are descriptive and have no median or variance estimate.

## Build, configuration, and environment

- Git commit: `d37b8c1a79c422208bde4050154dab7dbcd32846`; working tree already dirty.
- Binary: `dist\mpv.exe`, MPV `v0.41.0-947-gd37b8c1a7-dirty`, x64, built
  2026-09-11 03:34:59.
- Relevant active options: `autocreate-playlist=filter`,
  `directory-mode=ignore`, `prefetch-playlist=yes`,
  `prefetch-playlist-max=10`, `prefetch-playlist-on-cache=yes`,
  `prefetch-playlist-realtime=yes`, 60 s/1 GiB start window, 300 s/2 GiB
  expanded limit, `vo=gpu-next`, D3D11, and `hwdec=d3d11va`.
- Host: Windows 11 Pro Insider Preview build 26220; Ryzen 9 9950X3D,
  16 cores/32 logical processors; 102,741,454,848 bytes RAM.
- Tools: WPR 10.0.26100.9306; WPA/WPAExporter 11.7.395.48728;
  PowerShell 7.6.6; host was not elevated.

See `environment.json` for the structured environment and `commands.md` for
command provenance and outcomes.

## Measurements

| Scenario | Folder/file open | First AO | First VO | Last startup VO reconfiguration | Sampled CPU delta | Peak WS | Peak private | Peak threads |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Folder, prefetch active | folder 2.178 s; file 2.193 s | 2.569 s | 2.578 s | 2.799 s | 14.891 s | 466.5 MiB | 1046.5 MiB | 147 |
| Folder, prefetch disabled | folder 2.126 s; file 2.133 s | 2.592 s | 2.594 s | 2.799 s | 14.485 s | 360.7 MiB | 949.2 MiB | 137 |
| Single file, no autocreate | file 0.201 s | 0.577 s | 0.578 s | 0.807 s | 13.891 s | 311.0 MiB | 877.7 MiB | 137 |

CPU delta is the last cumulative CPU sample minus the first, not total process
CPU from launch. The sampler's zero-valued `ReadMB`/`WriteMB` columns were
unavailable placeholders and are excluded; they do not demonstrate zero I/O.

## Critical-path accounting

| Interval | Duration | State evidence | PID/TID | Dependency | Evidence |
| --- | ---: | --- | --- | --- | --- |
| Launch to folder open, prefetch variant | 2.178 s | RUNNING/READY/WAIT unknown | 52464 / TID unavailable | Recursive directory and playlist setup | `mpv-corrected-20260911-144340.log` |
| Launch to folder open, no-prefetch variant | 2.126 s | RUNNING/READY/WAIT unknown | 55580 / TID unavailable | Recursive directory and playlist setup | `mpv-20260911-144505.log` |
| Folder open to current-file open | 0.007-0.015 s | RUNNING/READY/WAIT unknown | same PIDs / TID unavailable | Current entry handoff/open | Both folder logs |
| Current-file open to first VO | 0.385-0.461 s | RUNNING/READY/WAIT unknown | same PIDs / TID unavailable | Demux/decode/output initialization | Both folder logs |
| Single-file launch to first VO | 0.578 s | RUNNING/READY/WAIT unknown | 30556 / TID unavailable | File open plus output initialization | `mpv-20260911-144612.log` |

The intervals are mutually ordered within each run, but the two folder trials are
separate observations and must not be summed or averaged as one critical path.
Sibling prefetches after folder open overlap each other and playback. About two
seconds of folder-scenario wall time remains unattributed to thread state, source
stacks, or logical versus physical I/O.

## Findings ranked by critical-path relevance

1. **VERIFIED — active configuration prevents direct directory playback.**
   The failed log records `directory-mode=ignore`, then `Opening failed or was
   aborted: I:\XXX` at 0.224 s and `Failed to recognize file format` at 0.226 s.
   The recursive command-line override succeeds. This is a configuration/workload
   mismatch, not a demonstrated MPV defect.

2. **VERIFIED — the recursive-folder scenario adds about 2.0 s before video
   output versus the single-file control.** The no-prefetch folder opens the
   current file at 2.133 s versus 0.201 s for the single-file control; first VO
   occurs at 2.594 s versus 0.578 s. These logs localize most of the scenario gap
   before the current file is opened, consistent with directory/playlist setup,
   but do not identify the responsible calls or physical I/O.

3. **VERIFIED — active prefetch increases process memory and thread pressure in
   these samples.** Relative to the no-prefetch folder control, peak working set
   is 105.8 MiB higher, peak private memory 97.3 MiB higher, and peak thread count
   10 higher. The sampled CPU delta differs by only 0.406 s. One trial per variant
   cannot establish repeatability, and the first-VO timestamps differ by only
   16 ms in favor of the prefetch run.

4. **INCONCLUSIVE — the causal CPU/READY/WAIT, storage, and GPU costs.** No ETL,
   WPA tables, Procmon PML, TIDs, stacks, disk service times, or GPU packet timing
   were collected. The MPV logs show overlapping sibling prefetch opens after the
   folder becomes playable, but overlapping operations cannot be added as elapsed
   time.

5. **INCONCLUSIVE — cause and impact of the WASAPI underrun.** One underrun was
   logged in each successful variant (3.588 s prefetch, 3.551 s no-prefetch,
   1.355 s single-file). Logs alone cannot distinguish startup settling, decoder
   delay, scheduling, or device behavior.

6. **INCONCLUSIVE — background-load contamination.** No preflight counters or
   top-consumer snapshot was retained, so unrelated CPU, memory, disk, network,
   or GPU work cannot be excluded as a source of trial-to-trial bias.

## Source-level follow-up map

- `demux/demux_playlist.c`: `scan_dir()` performs recursive directory enumeration,
  file/directory classification, cycle checks, and playlist population. This is
  the primary source area to correlate with the measured pre-open interval.
- `player/autocreate_playlist.c`: `mp_start_autocreate_playlist()` queues sibling
  discovery for a regular-file workload; verify whether it applies to the exact
  folder path after directory expansion.
- `player/loadfile.c`: starts autocreate after the demuxer is opened.
- `player/loadfile_async.c`: `start_open()`, `prefetch_next()`,
  `update_prefetch_state()`, and stale-prefetch handling control asynchronous
  opens, start-window expansion, and the configured next-entry window.
- `player/playloop.c`: `handle_update_cache()` triggers real-time, cache-full,
  and EOF prefetch transitions.
- `options/options.c` and `options/options.h`: definitions/defaults for the
  `prefetch-playlist*` options.
- `DOCS/man/options.rst`: user-visible directory, autocreate, and prefetch
  contracts.

The active local `playlist-sort` client also logged that it gated prefetch while
autocreate sorting finished. Treat that script/configuration interaction as a
potential scenario confounder and time it independently before attributing the
full folder-open interval to core directory scanning.

This map identifies inspection targets, not proven optimization sites. The next
trace must distinguish recursive directory expansion from sorting scripts,
filesystem metadata/data access, demux open, decoder/output startup, and
prefetch work before any source change is justified.

## Proposed next experiments

1. Run the system-load preflight. If heavy unrelated activity is found, wait once
   for 60 seconds and recheck; if it remains, stop and ask the user to close the
   identified processes or abort the benchmark.
2. From one elevated PowerShell process, repeat the corrected folder run using
   the saved `CPU.Light,GPU.Light,FileIO.Light` WPR plan and a native `.exe` as
   the capture helper target. Export CPU sampled/precise, File I/O, Disk I/O,
   GPU/DxgKrnl, process/thread lifetime, and marker-range tables.
3. Repeat at least five lightweight trials per variant with an explicit cache
   label and fixed order or counterbalanced order. Report median, range, and all
   failures.
4. Add phase markers around directory expansion, playlist insertion/sorting,
   current-file demux open, and first presented frame if ETW stacks cannot
   separate the phases.
5. Capture Procmon separately only if ETW leaves pathname/operation attribution
   unresolved.
6. Re-test smaller directory cardinalities to determine whether pre-open latency
   scales with file count and whether the relationship is linear.

## Validation and remaining risk

The corrected folder command played the representative AV1 file with D3D11VA,
WASAPI, and `gpu-next`; the no-prefetch and single-file controls also played for
the bounded window. WPR was not run because the host was not elevated. Therefore
no optimization or performance improvement is claimed, and scheduler, physical
disk, GPU, and source-stack conclusions remain unresolved.

Raw evidence and SHA-256 hashes are listed in `artifacts.md`; structured results
are in `measurements\summary.csv`.
