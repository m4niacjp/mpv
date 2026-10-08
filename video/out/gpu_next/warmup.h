// SPDX-License-Identifier: LGPL-2.1-or-later
#pragma once

#include <stdint.h>

#include <libplacebo/renderer.h>

#include "common/global.h"

struct mp_image;
struct mp_log;
struct sh_stream;
struct render_warmup;

struct render_warmup_target {
    struct pl_frame frame;
    const char *format;
    int width, height;
    double monitor_par, display_fps;
    float ref_luma;
    int display_res[2];
    uint64_t adapter_luid;
    unsigned int feature_level;
};

// Metadata and an independent, immutable configuration; no graph or device.
struct render_warmup_request {
    int64_t entry_id;
    char *url;
    int stream_flags;
    struct mpv_global *global;
    struct render_warmup_target target;
    uint64_t generation;
};

struct render_warmup_request *render_warmup_request_create(
    struct mpv_global *global, int64_t entry_id, const char *url, int flags);

// Numeric IDs include all video streams; automatic selection supports one
// unambiguous moving-video stream and ignores artwork/unsupported groups.
struct sh_stream *render_warmup_select_video(struct sh_stream **streams,
                                             int num_streams, int vid);

struct render_warmup *render_warmup_create(struct mp_log *log, pl_cache cache);
// Takes ownership. NULL cancels obsolete work without waiting.
void render_warmup_submit(struct render_warmup *w,
                          struct render_warmup_request *request);
void render_warmup_destroy(struct render_warmup **w);

// Called only on the isolated worker with its private GPU and filtered frame.
bool gpu_next_warmup_render(struct render_warmup_request *request, pl_log log,
                            pl_gpu gpu, struct mp_image *image);
