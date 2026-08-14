---
library: FFmpeg
package_names: [libavformat, libavcodec, libavutil, libavfilter, libswscale, libswresample]
version_scope: "this checkout pins subprojects/ffmpeg.wrap revision meson-8.1; Context7 has no 8.1 ID — closest versioned Doxygen is 8.0; user docs from ffmpeg.org documentation"
context7_id: /websites/ffmpeg_doxygen_8_0
last_verified: 2026-08-14
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
