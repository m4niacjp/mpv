// SPDX-License-Identifier: LGPL-2.1-or-later

#include <stdatomic.h>
#include <string.h>

#include <libplacebo/config.h>

#include "config.h"
#include "common/common.h"
#include "common/msg.h"
#include "common/stats.h"
#include "demux/demux.h"
#include "demux/packet_pool.h"
#include "demux/stheader.h"
#include "filters/f_decoder_wrapper.h"
#include "filters/f_output_chain.h"
#include "filters/filter.h"
#include "misc/thread_tools.h"
#include "misc/path_utils.h"
#include "options/m_config_core.h"
#include "options/options.h"
#include "osdep/threads.h"
#include "osdep/timer.h"
#include "video/hwdec.h"
#include "video/mp_image.h"
#include "video/out/placebo/utils.h"

#include "warmup.h"

#ifdef _WIN32
#include <windows.h>
#endif

#if HAVE_D3D11 && defined(PL_HAVE_D3D11)
#include <d3d11.h>
#include <d3d10.h>
#include <dxgi.h>

#include <libplacebo/d3d11.h>

#include "video/d3d.h"
#endif

struct render_warmup {
    struct mp_log *log;
    pl_cache cache; // owner must keep callbacks/configuration alive until join
    mp_thread thread;
    bool started;
    mp_mutex lock;
    mp_cond wake;
    struct render_warmup_request *pending;
    struct mp_cancel *cancel;
    atomic_bool terminate;
    atomic_uint_fast64_t generation;
};

struct render_warmup_request *render_warmup_request_create(
    struct mpv_global *global, int64_t entry_id, const char *url, int flags)
{
    // The private global deliberately has no network/curl or client runtime.
    // Mounted filesystem paths are supported; protocol handlers are not.
    if (!url || strcmp(url, "-") == 0 || mp_is_url(bstr0(url)))
        return NULL;
    struct render_warmup_request *r = talloc_zero(NULL, struct render_warmup_request);
    r->entry_id = entry_id;
    r->url = talloc_strdup(r, url);
    r->stream_flags = flags;
    r->global = talloc_zero(r, struct mpv_global);
    r->global->log = mp_log_new(r->global, global->log, "render-warmup");
    r->global->configdir = talloc_strdup(r->global, global->configdir);
    r->global->config = talloc_steal(r->global, m_config_shadow_new(&mp_opt_root));

    struct m_config_cache *src = m_config_cache_alloc(NULL, global, &mp_opt_root);
    struct m_config_cache *dst = m_config_cache_from_shadow(
        NULL, r->global->config, &mp_opt_root);
    int32_t id = -1;
    while (m_config_cache_get_next_opt(src, &id)) {
        void *from = m_config_cache_get_opt_data(src, id);
        void *to = m_config_cache_get_opt_data(dst, id);
        if (!from || !to)
            continue;
        const struct m_option *opt = m_config_shadow_get_opt(global->config, id);
        m_option_copy(opt, to, from);
        char buf[M_CONFIG_MAX_OPT_NAME_LEN];
        const char *name = m_config_shadow_get_opt_name(global->config, id,
                                                        buf, sizeof(buf));
        // Speculation must not inherit the live multi-GiB packet budget.
        if (strcmp(name, "demuxer-max-bytes") == 0)
            *(int64_t *)to = 32 * 1024 * 1024;
        if (strcmp(name, "demuxer-max-back-bytes") == 0)
            *(int64_t *)to = 0;
        if (strcmp(name, "demuxer-readahead-secs") == 0)
            *(double *)to = 0;
        if (strcmp(name, "vd-queue-enable") == 0)
            *(bool *)to = false;
        if (strcmp(name, "vd-lavc-threads") == 0)
            *(int *)to = 1;
        m_config_cache_write_opt(dst, to);
    }
    talloc_free(dst);
    talloc_free(src);
    stats_global_init(r->global);
    demux_packet_pool_init(r->global);
    return r;
}

static bool obsolete(struct render_warmup *w, struct render_warmup_request *r)
{
    return atomic_load(&w->terminate) ||
           r->generation != atomic_load(&w->generation) ||
           mp_cancel_test(w->cancel);
}

struct sh_stream *render_warmup_select_video(struct sh_stream **streams,
                                             int num_streams, int vid)
{
    struct sh_stream *selected = NULL;
    int ordinal = 0, eligible = 0;
    for (int n = 0; n < num_streams; n++) {
        struct sh_stream *sh = streams[n];
        if (sh->type != STREAM_VIDEO)
            continue;
        ordinal++;
        bool supported = !sh->image && !sh->attached_picture && !sh->group && !sh->absent;
        if (vid == ordinal)
            selected = supported ? sh : NULL;
        if (vid == -1 && supported) {
            eligible++;
            selected = sh;
        }
    }
    return vid == -1 && eligible != 1 ? NULL : selected;
}

static void wake_worker(void *ctx)
{
    struct render_warmup *w = ctx;
    // Cancellation can call this while holding the mailbox lock. The graph
    // uses a short timed wait, so signaling without that lock is sufficient.
    mp_cond_signal(&w->wake);
}

#if HAVE_D3D11 && defined(PL_HAVE_D3D11)
static double display_fps(struct mp_stream_info *info)
{
    struct render_warmup_request *r = info->priv;
    return r->target.display_fps;
}

static void display_res(struct mp_stream_info *info, int *res)
{
    struct render_warmup_request *r = info->priv;
    memcpy(res, r->target.display_res, sizeof(r->target.display_res));
}

static struct mp_image *decode_frame(struct render_warmup *w,
                                     struct render_warmup_request *r,
                                     ID3D11Device *device,
                                     struct demuxer **demux)
{
    struct mp_image *image = NULL;
    struct mp_filter *root = NULL;
    void *config_scope = talloc_new(NULL);
    const char *failure = "hardware-device";
    struct mp_hwdec_devices *devices = hwdec_devices_create();
    struct mp_hwdec_ctx hwctx = {
        .driver_name = "render-warmup-d3d11",
        .hw_imgfmt = IMGFMT_D3D11,
        .av_device_ref = d3d11_wrap_device_ref(device),
    };
    if (!hwctx.av_device_ref)
        goto done;
    hwdec_devices_add(devices, &hwctx);
    struct MPOpts *opts = mp_get_config_group(config_scope, r->global, &mp_opt_root);
    failure = "unsupported-options";
    if (opts->stream_id[0][STREAM_VIDEO] == -2 ||
        opts->stream_id[1][STREAM_VIDEO] != -2 ||
        (opts->external_files && opts->external_files[0]) ||
        (opts->lavfi_complex && opts->lavfi_complex[0]))
        goto done;

    struct demuxer_params params = {.stream_flags = r->stream_flags};
    failure = "open-or-canceled";
    *demux = demux_open_url(r->url, &params, w->cancel, r->global);
    if (!*demux || obsolete(w, r))
        goto done;
    int num_streams = demux_get_num_stream(*demux);
    struct sh_stream **streams = talloc_array(config_scope, struct sh_stream *, num_streams);
    for (int n = 0; n < num_streams; n++)
        streams[n] = demux_get_stream(*demux, n);
    struct sh_stream *selected = render_warmup_select_video(
        streams, num_streams, opts->stream_id[0][STREAM_VIDEO]);
    // Automatic multi-track selection needs player policy, not a guessed track.
    failure = "ambiguous-or-unsupported-video";
    if (!selected)
        goto done;
    demuxer_select_track(*demux, selected, 0, true);
    demux_set_prefetch_limits(*demux, 0, 32 * 1024 * 1024);
    demux_start_thread(*demux);

    root = mp_filter_create_root(r->global);
    failure = "filter-or-decoder";
    struct mp_stream_info info = {
        .priv = r,
        .get_display_fps = display_fps,
        .get_display_res = display_res,
        .hwdec_devs = devices,
        .rotate90 = true,
        .vflip = true,
    };
    root->stream_info = &info;
    mp_filter_graph_set_wakeup_cb(root, wake_worker, w);
    mp_filter_graph_set_max_run_time(root, 0.010);
    struct mp_output_chain *out = mp_output_chain_create(root, MP_OUTPUT_CHAIN_VIDEO);
    if (!out)
        goto done;
    *out->f->stream_info = info;
    struct mp_decoder_wrapper *decoder = mp_decoder_wrapper_create(out->f, selected);
    failure = "decoder-init";
    if (!decoder || !mp_decoder_wrapper_reinit(decoder))
        goto done;
    failure = "filter-init";
    if (!mp_output_chain_update_filters(out, opts->vf_settings))
        goto done;
    mp_pin_connect(out->f->pins[0], decoder->f->pins[0]);
    mp_pin_set_manual_connection(out->f->pins[1], true);
    int64_t deadline = mp_time_ns() + MP_TIME_S_TO_NS(5);
    failure = "decode-timeout-or-canceled";
    while (!obsolete(w, r) && mp_time_ns() < deadline) {
        struct mp_frame frame = mp_pin_out_read(out->f->pins[1]);
        if (frame.type == MP_FRAME_VIDEO) {
            image = frame.data;
            break;
        }
        bool eof = frame.type == MP_FRAME_EOF;
        mp_frame_unref(&frame);
        if (eof || mp_filter_has_failed(root)) {
            failure = eof ? "decode-eof" : "filter-failed";
            break;
        }
        if (mp_filter_graph_run(root))
            continue;
        mp_mutex_lock(&w->lock);
        mp_cond_timedwait(&w->wake, &w->lock, MP_TIME_MS_TO_NS(10));
        mp_mutex_unlock(&w->lock);
    }
done:
    if (image) {
        MP_INFO(w, "render-warmup-trace: event=worker-frame tid=%lu time_ns=%lld "
                "entry=%lld pts=%.9f w=%d h=%d format=%s subformat=%s\n",
                GetCurrentThreadId(), (long long)mp_time_ns(), (long long)r->entry_id,
                image->pts, image->w, image->h, mp_imgfmt_to_name(image->imgfmt),
                mp_imgfmt_to_name(image->params.hw_subfmt));
    } else {
        MP_INFO(w, "render-warmup-trace: event=worker-skip tid=%lu time_ns=%lld "
                "entry=%lld reason=%s\n", GetCurrentThreadId(),
                (long long)mp_time_ns(), (long long)r->entry_id, failure);
    }
    // Stop packet speculation immediately; an outstanding OS read may finish later.
    mp_cancel_trigger(w->cancel);
    talloc_free(root);
    hwdec_devices_remove(devices, &hwctx);
    hwdec_devices_destroy(devices);
    av_buffer_unref(&hwctx.av_device_ref);
    talloc_free(config_scope); // unregister listeners before freeing the shadow
    return image;
}

static uint64_t cpu_time(void)
{
    FILETIME creation, exit, kernel, user;
    if (!GetThreadTimes(GetCurrentThread(), &creation, &exit, &kernel, &user))
        return 0;
    ULARGE_INTEGER k = {.LowPart = kernel.dwLowDateTime, .HighPart = kernel.dwHighDateTime};
    ULARGE_INTEGER u = {.LowPart = user.dwLowDateTime, .HighPart = user.dwHighDateTime};
    return k.QuadPart + u.QuadPart;
}

static void run_request(struct render_warmup *w, struct render_warmup_request *r)
{
    int64_t start = mp_time_ns();
    uint64_t cpu_start = cpu_time();
    int64_t device_done = start, decode_done = start, render_done = start;
    pl_log log = mppl_log_create(r, w->log);
    pl_log_level_update(log, PL_LOG_INFO); // avoid shader-source dumps during playback
    LUID luid;
    memcpy(&luid, &r->target.adapter_luid, sizeof(luid));
    pl_d3d11 d3d = pl_d3d11_create(log, pl_d3d11_params(
        .adapter_luid = luid,
        .allow_software = false,
        .min_feature_level = r->target.feature_level,
        .max_feature_level = r->target.feature_level,
        .flags = D3D11_CREATE_DEVICE_VIDEO_SUPPORT,
    ));
    struct demuxer *demux = NULL;
    struct mp_image *image = NULL;
    bool rendered = false;
    double pts = MP_NOPTS_VALUE;
    device_done = mp_time_ns();
    if (!d3d || obsolete(w, r))
        goto done;
    IDXGIDevice *dxgi = NULL;
    IDXGIAdapter *adapter = NULL;
    DXGI_ADAPTER_DESC desc;
    bool matches = false;
    if (SUCCEEDED(ID3D11Device_QueryInterface(d3d->device, &IID_IDXGIDevice,
                                               (void **)&dxgi)) &&
        SUCCEEDED(IDXGIDevice_GetAdapter(dxgi, &adapter)) &&
        SUCCEEDED(IDXGIAdapter_GetDesc(adapter, &desc)))
    {
        matches = memcmp(&desc.AdapterLuid, &luid, sizeof(luid)) == 0 &&
                  ID3D11Device_GetFeatureLevel(d3d->device) == r->target.feature_level;
    }
    if (adapter)
        IDXGIAdapter_Release(adapter);
    if (dxgi)
        IDXGIDevice_Release(dxgi);
    if (!matches)
        goto done;
    ID3D10Multithread *multithread = NULL;
    if (FAILED(ID3D11Device_QueryInterface(d3d->device, &IID_ID3D10Multithread,
                                             (void **)&multithread)))
        goto done;
    ID3D10Multithread_SetMultithreadProtected(multithread, TRUE);
    ID3D10Multithread_Release(multithread);
    pl_gpu_set_cache(d3d->gpu, w->cache);
    MP_INFO(w, "render-warmup-trace: event=worker-begin tid=%lu time_ns=%lld entry=%lld "
            "adapter=%016llx feature=%x url=%s\n", GetCurrentThreadId(),
            (long long)start,
            (long long)r->entry_id, (unsigned long long)r->target.adapter_luid,
            r->target.feature_level, r->url);
    image = decode_frame(w, r, d3d->device, &demux);
    decode_done = mp_time_ns();
    // decode_frame cancels IO after obtaining one frame. Generation determines
    // whether that frame is still useful; no live decoder or reader is touched.
    if (image && !atomic_load(&w->terminate) &&
        r->generation == atomic_load(&w->generation))
    {
        rendered = gpu_next_warmup_render(r, log, d3d->gpu, image);
    }
    render_done = mp_time_ns();
done:
    pts = image ? image->pts : MP_NOPTS_VALUE;
    if (decode_done < device_done)
        decode_done = device_done;
    if (render_done < decode_done)
        render_done = decode_done;
    if (d3d)
        pl_gpu_finish(d3d->gpu); // private-device teardown, never the live GPU
    talloc_free(image);
    if (demux)
        demux_cancel_and_free(demux);
    demux_packet_pool_clear(r->global->packet_pool);
    if (d3d)
        pl_d3d11_destroy(&d3d);
    pl_log_destroy(&log);
    MP_INFO(w, "render-warmup-trace: event=worker-end tid=%lu entry=%lld "
            "rendered=%d stale=%d pts=%.9f time_ns=%lld device_ms=%.3f "
            "decode_ms=%.3f render_ms=%.3f cleanup_ms=%.3f wall_ms=%.3f cpu_ms=%.3f\n",
            GetCurrentThreadId(), (long long)r->entry_id, rendered,
            r->generation != atomic_load(&w->generation),
            pts, (long long)mp_time_ns(),
            MP_TIME_NS_TO_MS(device_done - start),
            MP_TIME_NS_TO_MS(decode_done - device_done),
            MP_TIME_NS_TO_MS(render_done - decode_done),
            MP_TIME_NS_TO_MS(mp_time_ns() - render_done),
            MP_TIME_NS_TO_MS(mp_time_ns() - start), (cpu_time() - cpu_start) / 10000.0);
}
#endif

static MP_THREAD_VOID warmup_thread(void *arg)
{
    struct render_warmup *w = arg;
    mp_thread_set_name("render-warmup");
    bool priority_ok = false;
#ifdef _WIN32
    priority_ok = SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_BELOW_NORMAL) &&
                  GetThreadPriority(GetCurrentThread()) == THREAD_PRIORITY_BELOW_NORMAL;
    MP_INFO(w, "render-warmup-trace: event=worker-thread tid=%lu priority=%d "
            "verified=%d\n", GetCurrentThreadId(),
            GetThreadPriority(GetCurrentThread()), priority_ok);
#endif
    mp_mutex_lock(&w->lock);
    while (!atomic_load(&w->terminate)) {
        struct render_warmup_request *r = w->pending;
        w->pending = NULL;
        if (!r) {
            mp_cond_wait(&w->wake, &w->lock);
            continue;
        }
        mp_cancel_reset(w->cancel);
        mp_mutex_unlock(&w->lock);
#if HAVE_D3D11 && defined(PL_HAVE_D3D11)
        if (priority_ok)
            run_request(w, r);
#endif
        talloc_free(r);
        mp_mutex_lock(&w->lock);
    }
    mp_mutex_unlock(&w->lock);
    MP_THREAD_RETURN();
}

struct render_warmup *render_warmup_create(struct mp_log *log, pl_cache cache)
{
    struct render_warmup *w = talloc_zero(NULL, struct render_warmup);
    w->log = mp_log_new(w, log, "render-warmup");
    w->cache = cache;
    w->cancel = mp_cancel_new(w);
    mp_mutex_init(&w->lock);
    mp_cond_init(&w->wake);
    atomic_init(&w->terminate, false);
    atomic_init(&w->generation, 0);
    return w;
}

void render_warmup_submit(struct render_warmup *w,
                          struct render_warmup_request *request)
{
    mp_mutex_lock(&w->lock);
    // Serialize publication and cancellation with the worker's reset/pickup.
    // No cancellation callback takes the mailbox lock (wake_worker only signals).
    mp_cancel_trigger(w->cancel);
    uint64_t generation = atomic_fetch_add(&w->generation, 1) + 1;
    talloc_free(w->pending);
    w->pending = request;
    if (request)
        request->generation = generation;
    if (!w->started && request) {
        if (mp_thread_create(&w->thread, warmup_thread, w)) {
            talloc_free(w->pending);
            w->pending = NULL;
        } else {
            w->started = true;
        }
    }
    mp_cond_signal(&w->wake);
    mp_mutex_unlock(&w->lock);
}

void render_warmup_destroy(struct render_warmup **wp)
{
    struct render_warmup *w = *wp;
    if (!w)
        return;
    atomic_store(&w->terminate, true);
    render_warmup_submit(w, NULL);
    if (w->started)
        mp_thread_join(w->thread);
    mp_cond_destroy(&w->wake);
    mp_mutex_destroy(&w->lock);
    talloc_free(w);
    *wp = NULL;
}
