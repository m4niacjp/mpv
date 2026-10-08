// SPDX-License-Identifier: LGPL-2.1-or-later

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <mpv/client.h>

#include "config.h"
#include "common/common.h"
#include "common/global.h"
#include "common/msg_control.h"
#include "demux/packet.h"
#include "demux/stheader.h"
#include "options/m_config_frontend.h"
#include "options/options.h"
#include "video/mp_image.h"
#include "video/out/gpu_next/warmup.h"

#if HAVE_D3D11 && defined(PL_HAVE_D3D11)
#include <libavutil/hwcontext.h>
#include <libplacebo/d3d11.h>

#include "video/d3d.h"
#include "video/out/placebo/utils.h"
#endif

static void check_d3d11_cleanup(struct mpv_global *global)
{
#if HAVE_D3D11 && defined(PL_HAVE_D3D11)
    void *scope = talloc_new(NULL);
    pl_log log = mppl_log_create(scope, global->log);
    pl_log_level_update(log, PL_LOG_WARN);
    pl_d3d11 d3d = pl_d3d11_create(log, pl_d3d11_params(
        .allow_software = false,
        .flags = D3D11_CREATE_DEVICE_VIDEO_SUPPORT,
    ));
    mp_require(d3d);
    AVBufferRef *device = d3d11_wrap_device_ref(d3d->device);
    mp_require(device);
    AVBufferRef *frames = av_hwframe_ctx_alloc(device);
    mp_require(frames);
    AVHWFramesContext *hwframes = (AVHWFramesContext *)frames->data;
    hwframes->format = AV_PIX_FMT_D3D11;
    hwframes->sw_format = AV_PIX_FMT_NV12;
    hwframes->width = hwframes->height = 128;
    hwframes->initial_pool_size = 1;
    mp_require(av_hwframe_ctx_init(frames) >= 0);
    AVFrame *frame = av_frame_alloc();
    mp_require(frame && av_hwframe_get_buffer(frames, frame, 0) >= 0);
    struct mp_image *image = mp_image_from_av_frame(frame);
    mp_require(image);
    struct render_warmup_request *r = render_warmup_request_create(
        global, 456, "cleanup-fixture.mkv", 0);
    mp_require(r);
    r->target.format = "unsupported-render-warmup-test-format";
    r->target.width = 320;
    r->target.height = 180;
    r->target.monitor_par = 1;
    struct mp_log_buffer *buffer = mp_msg_log_buffer_new(
        global, 128, MSGL_INFO, NULL, NULL);
    for (int n = 0; n < 4; n++) {
        mp_require(!gpu_next_warmup_render(r, log, d3d->gpu, image));
        struct mp_log_buffer_entry *entry;
        bool imported_and_destroyed = false;
        while ((entry = mp_msg_log_buffer_read(buffer))) {
            imported_and_destroyed |=
                strstr(entry->text, "event=renderer-end rendered=0 reason=target-format") &&
                strstr(entry->text, "imported_planes=2 texture_ra=1");
            talloc_free(entry);
        }
        mp_require(imported_and_destroyed);
        printf("D3D11 error cleanup %d: imported 2 planes, destroyed private RA\n", n + 1);
    }
    mp_msg_log_buffer_destroy(buffer);
    pl_gpu_finish(d3d->gpu);
    talloc_free(image);
    av_frame_free(&frame);
    av_buffer_unref(&frames);
    av_buffer_unref(&device);
    talloc_free(r);
    pl_d3d11_destroy(&d3d);
    pl_log_destroy(&log);
    talloc_free(scope);
#else
    fprintf(stderr, "D3D11 cleanup check is unavailable in this build\n");
    abort();
#endif
}

static void set(struct m_config *config, const char *name, const char *value)
{
    mp_require(m_config_set_option_cli(config, bstr0(name), bstr0(value), 0) >= 0);
}

static int64_t integer_option(struct m_config_cache *cache, const char *name)
{
    int32_t id = -1;
    while (m_config_cache_get_next_opt(cache, &id)) {
        char buf[M_CONFIG_MAX_OPT_NAME_LEN];
        const char *opt = m_config_shadow_get_opt_name(cache->shadow, id, buf, sizeof(buf));
        if (strcmp(opt, name) == 0)
            return *(int64_t *)m_config_cache_get_opt_data(cache, id);
    }
    abort();
}

int main(int argc, char **argv)
{
    struct demux_packet cover = {0};
    struct sh_stream moving = {.type = STREAM_VIDEO};
    struct sh_stream art = {.type = STREAM_VIDEO, .attached_picture = &cover};
    struct sh_stream audio = {.type = STREAM_AUDIO};
    struct sh_stream other = {.type = STREAM_VIDEO};
    struct sh_stream *streams[] = {&art, &audio, &moving, &other};
    mp_require(render_warmup_select_video(streams, 3, -1) == &moving);
    mp_require(!render_warmup_select_video(streams, 3, 1));
    mp_require(render_warmup_select_video(streams, 3, 2) == &moving);
    mp_require(!render_warmup_select_video(streams, 4, -1));
    mp_require(render_warmup_select_video(streams, 4, 3) == &other);
    mp_require(!render_warmup_select_video(streams, 3, -2));
    struct mpv_global *global = talloc_zero(NULL, struct mpv_global);
    mp_msg_init(global);
    struct m_config *config = m_config_new(NULL, global->log, &mp_opt_root);
    global->config = config->shadow;
    set(config, "force-media-title", "original title");
    set(config, "vf", "format=fmt=yuv420p");
    set(config, "demuxer-max-bytes", "4GiB");
    set(config, "demuxer-max-back-bytes", "4GiB");
    struct mpv_node value = {.format = MPV_FORMAT_STRING, .u.string = "original value"};
    char *key = "warmup-fixture";
    struct mpv_node_list list = {.num = 1, .keys = &key, .values = &value};
    struct mpv_node node = {.format = MPV_FORMAT_NODE_MAP, .u.list = &list};
    mp_require(m_config_set_option_node(config, bstr0("script-opts"), &node, 0) >= 0);

    struct render_warmup_request *request = render_warmup_request_create(
        global, 123, "snapshot-fixture.mkv", 0);
    mp_require(request);
    struct m_config_cache *cache = m_config_cache_alloc(NULL, request->global, &mp_opt_root);
    struct MPOpts *snapshot = cache->opts;
    set(config, "force-media-title", "changed title");
    set(config, "vf", "format=fmt=yuv444p");
    set(config, "script-opts", "warmup-fixture=changed value");
    struct MPOpts *current = config->optstruct;
    mp_require(strcmp(snapshot->media_title, "original title") == 0);
    mp_require(snapshot->media_title != current->media_title);
    mp_require(snapshot->vf_settings != current->vf_settings);
    mp_require(strcmp(snapshot->vf_settings[0].name, "format") == 0);
    mp_require(strcmp(snapshot->vf_settings[0].attribs[1], "yuv420p") == 0);
    mp_require(strcmp(snapshot->script_opts[0], "warmup-fixture") == 0);
    mp_require(strcmp(snapshot->script_opts[1], "original value") == 0);
    mp_require(snapshot->script_opts[1] != current->script_opts[1]);
    // Private budget overrides must not modify the source player's options.
    struct m_config_cache *live = m_config_cache_alloc(NULL, global, &mp_opt_root);
    mp_require(integer_option(cache, "demuxer-max-bytes") == 32 * 1024 * 1024);
    mp_require(integer_option(cache, "demuxer-max-back-bytes") == 0);
    mp_require(integer_option(live, "demuxer-max-bytes") == INT64_C(4) * 1024 * 1024 * 1024);
    mp_require(integer_option(live, "demuxer-max-back-bytes") == INT64_C(4) * 1024 * 1024 * 1024);
    talloc_free(live);
    mp_require(request->entry_id == 123);
    mp_require(strcmp(request->url, "snapshot-fixture.mkv") == 0);
    talloc_free(cache);
    talloc_free(request); // listener/shadow/statistics destructors assert order
    mp_require(!render_warmup_request_create(global, 1, "https://example.com/a", 0));
    mp_require(!render_warmup_request_create(global, 1, "-", 0));
    struct render_warmup *worker = render_warmup_create(global->log, NULL);
    for (int n = 0; n < 256; n++)
        render_warmup_submit(worker, NULL);
    render_warmup_destroy(&worker); // idle cancellation never creates a device/thread
    mp_require(!worker);
    if (argc == 2 && strcmp(argv[1], "--d3d11-cleanup") == 0)
        check_d3d11_cleanup(global);
    mp_msg_uninit(global);
    talloc_free(config);
    talloc_free(global);
    return 0;
}
