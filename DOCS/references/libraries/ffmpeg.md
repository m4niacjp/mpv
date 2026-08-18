---
library: FFmpeg
package_names: [libavformat, libavcodec, libavutil, libavfilter, libswscale, libswresample]
version_scope: "mpv subprojects/ffmpeg at bd98801f6cdd562ef3af9e60d31578facb8c6c0d (Meson wrap meson-8.1; libavformat 62.12.100/libavcodec 62.28.100); Context7 closest versioned Doxygen is 8.0"
context7_id: /websites/ffmpeg_doxygen_8_0
last_verified: 2026-08-18
---

# FFmpeg (libavformat / libavcodec)

mpv uses FFmpeg via Meson wrap `subprojects/ffmpeg.wrap`
(`revision = meson-8.1`, meson-ports clone). Context7 IDs:

- `/websites/ffmpeg_doxygen_8_0` — closest versioned API docs (used for this lookup)
- `/websites/ffmpeg_doxygen_trunk` — current trunk Doxygen (not mixed into claims below)
- `/websites/ffmpeg_documentation` — ffmpeg-all / format options

No Context7 library ID named FFmpeg 8.1. Do not treat 8.0 Doxygen as proof of 8.1
numeric defaults.

## avformat: probing vs format detection

From [AVFormatContext::probesize](https://ffmpeg.org/doxygen/8.0/structAVFormatContext.html)
(`avformat.h`):

- `probesize` is the **maximum number of bytes** read from input to determine
  **stream properties**.
- Used when reading the **global header** and in **`avformat_find_stream_info()`**.
- Demuxing only; caller sets it **before** `avformat_open_input()`.
- Explicitly **not** used to determine the input format.

`format_probesize` ([avformat.h](https://ffmpeg.org/doxygen/8.0/avformat_8h_source.html)):
maximum bytes to identify the **input format** when format is not set
explicitly; also set before `avformat_open_input()`.

User-facing format options ([ffmpeg-all Format Options > Probing](https://ffmpeg.org/ffmpeg-all.html)):
`probesize` and `analyzeduration` control how much data and time is spent
analyzing streams; higher values improve detection and increase latency.
`max_probe_packets` limits buffered packets during probing.

**Gap:** Context7 snippets did **not** include default numeric values for
`probesize` or `analyzeduration` on 8.0 or 8.1.

## avformat_open_input

Declared as `int avformat_open_input(AVFormatContext **ps, const char *url,
const AVInputFormat *fmt, AVDictionary **options)`; Doxygen points to
`demux.c` (line 217 in 8.0 sources). Custom I/O is done by attaching
`fmt_ctx->pb` before the call
([avio_read_callback example](https://ffmpeg.org/doxygen/8.0/avio_read_callback_8c-example.html)).

**Gap:** fetched docs do not describe Matroska- or MP4-specific reads inside
`avformat_open_input` (EBML header vs full cues, moov atom, etc.).

## Pinned mpv MKV open path (seekable custom AVIO)

For the lavf path in this checkout, `demux/demux_lavf.c` first performs mpv's
own start probe (`stream_read_peek`, up to its 10 MiB probe buffer), selects
`matroska`, then allocates a custom `AVIOContext` whose callbacks are
`mp_read`/`mp_seek`. It passes the selected format explicitly to
`avformat_open_input`, so FFmpeg's `format_probesize` format-identification
probe is not the operation deciding MKV here. The 1 MiB `probesize` option is
set on the context before open and is relevant to stream analysis/global-header
probing, not mpv's earlier format probe.

FFmpeg's `avformat_open_input` then calls the Matroska `read_header` callback.
In the pinned source, `matroska_read_header` parses EBML, Segment metadata,
tracks, and other level-1 header elements until the first Cluster. A seekable
`SeekHead` causes random `avio_seek` reads for non-Cues entries and restores the
previous position; Cues are deliberately deferred. Therefore normal MKV open
is primarily start/sequential I/O plus possible header-target random reads, not
an unconditional EOF/tail read.

mpv's default `probe-info=auto` is overridden by the lavf Matroska format hack
(`skipinfo=true`), so `avformat_find_stream_info` is skipped for ordinary MKV
with streams already created by `read_header`. If explicitly forced (or if the
mode requires it), FFmpeg reads packets from the current Cluster, stopping by
the stream-analysis conditions. With 1 MiB `probesize` and 0.1 seconds
`analyzeduration`, the raw callback bytes can exceed the packet-size limit due
to container overhead and buffering. Matroska's normal duration in the Info
header avoids FFmpeg's special end-of-file PTS duration scan (that scan is
selected for MPEG/MPEG-TS); `avio_size` is only a size query.

When stream info is forced, libavformat may temporarily open/probe codecs and
decode packets to fill missing parameters; this is separate from mpv's later
decoder and does not create mpv's D3D11VA device.

The first `av_read_frame` reads Cluster data sequentially (or consumes packets
buffered by `find_stream_info`). A later timestamp seek can lazily parse Cues,
which is a true random read to the Cues position and then a random read to the
selected Cluster; fallback/generic seeking may scan forward. `avio_size` calls
the custom `AVSEEK_SIZE` callback; mpv maps this to `stream_get_size`, so a
seekable file gets a metadata size query rather than a payload read.

Useful markers at trace/debug verbosity are mpv's `Found 'matroska' at
score=... size=...`, `mp_read(...), pos: ...`, `mp_seek(..., set/end/size)`,
and `avformat_find_stream_info() finished after ... bytes` (mpv's value is the
logical stream position, not a cumulative callback-byte counter); FFmpeg adds
`Before/After avformat_find_stream_info() ... bytes read ... seeks ...`,
`All info found`, and `Probe buffer size limit ...`. `--msg-level=all=trace`
is the reliable broad capture; filter the resulting `lavf`, `file`, and
`ffmpeg/*` lines. The callback's `mp_read` size is not necessarily the physical
WinFsp read size: mpv's stream buffer (default 128 KiB) and FFmpeg's AVIO buffer
(default 32 KiB in this source) add a buffering layer.

## First packet and D3D11VA

`avformat_open_input` does not open codecs. mpv later creates the selected
libavcodec decoder from Matroska `codecpar` and calls `avcodec_open2`. For a
direct D3D11VA method, device selection/creation and `AVHWDeviceContext`
initialization happen in mpv before codec open; `avcodec_open2` itself does not
read the file. On the first packet, mpv calls `avcodec_send_packet` and then
`avcodec_receive_frame`. When libavcodec selects `AV_PIX_FMT_D3D11`, mpv's
`get_format` callback calls `avcodec_get_hw_frames_parameters`, adjusts the
surface pool, initializes it with `av_hwframe_ctx_init`, and attaches
`AVCodecContext.hw_frames_ctx`. These operations are device/surface setup, not
additional file reads. The `d3d11va-copy` variant uses the device path without
mpv's generic `hw_frames_ctx` setup and may copy decoded surfaces afterward.

This source-level flow is more specific than the Context7 Doxygen snippets;
Context7 confirms the public contracts (open reads the header but not codecs,
find-stream-info reads packets, AVSEEK_SIZE returns a size, and the standard
hardware-decoder sequence) but does not describe mpv's Matroska seekhead policy.

## Skipping `avformat_find_stream_info`

Fetched docs do not state whether codec extradata is complete after
`avformat_open_input` alone for mkv/mp4. That is a container-header / mpv
`format_hack.skipinfo` behavior question, not covered by these Context7 hits.

## AVIO buffering

`avio_alloc_context()` takes a caller-supplied `buffer` and `buffer_size`
([aviobuf.c](https://ffmpeg.org/doxygen/8.0/aviobuf_8c_source.html)). The
official example uses `avio_ctx_buffer_size = 4096` as an **example**, not a
documented default for file/URL AVIO.

**Gap:** default internal AVIO buffer size and first-byte latency implications
were not in the fetched snippets.

## D3D11VA (libavcodec)

- `av_d3d11va_alloc_context()` — [d3d11va.h](https://ffmpeg.org/doxygen/8.0/d3d11va_8h.html)
- Hardware frames use `AV_PIX_FMT_D3D11`; `frame->data[0]` is an
  `ID3D11Texture2D *` ([hwcontext_d3d11va.c](https://ffmpeg.org/doxygen/8.0/hwcontext__d3d11va_8c_source.html)).
- `AVD3D11VAFramesContext::texture`: libavcodec D3D11VA hwaccel **requires a
  single array texture** and creates `ID3D11VideoDecoderOutputView` objects
  ([struct docs](https://ffmpeg.org/doxygen/8.0/structAVD3D11VAFramesContext.html)).
- `av_hwframe_transfer_data` copies to or from a hardware surface
  ([ffmpeg_dec.c](https://ffmpeg.org/doxygen/8.0/ffmpeg__dec_8c_source.html)).

**Gap:** no Context7 hit for a distinct `d3d11va_copy` hwaccel name, the
`hwdownload` filter’s cost, or whether D3D11 VideoProcessor requires GPU
textures vs system RAM.

## Known Context7 coverage gaps

- No `/websites/ffmpeg_doxygen_8_1`
- Default `probesize` / `analyzeduration` integers
- Per-format `read_header` I/O for matroska/mp4
- `hwdownload` / VideoProcessor / `d3d11va` vs copy
