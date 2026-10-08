/*
 * This file is part of mpv.
 *
 * mpv is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * mpv is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with mpv.  If not, see <http://www.gnu.org/licenses/>.
 */

#include <inttypes.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "mpv_talloc.h"

#include "common/common.h"
#include "common/msg.h"
#include "common/playlist.h"
#include "demux/demux.h"
#include "misc/path_utils.h"
#include "misc/thread_tools.h"
#include "options/m_config_core.h"
#include "options/options.h"
#include "osdep/threads.h"
#include "osdep/timer.h"
#include "video/out/gpu_next/warmup.h"
#include "video/out/vo.h"

#include "client.h"
#include "command.h"
#include "core.h"
#include "external_files.h"

struct async_open {
    struct MPContext *mpctx;
    mp_thread thread;
    bool active;
    atomic_bool done;

    struct mp_cancel *cancel;
    char *url;
    char *format;
    int url_flags;
    uint64_t playlist_entry_id;
    int stream_flags;
    bool for_prefetch;
    bool start_prefetch;
    bool start_window;
    double prefetch_secs;
    int64_t prefetch_bytes;

    struct demuxer *demuxer;
    struct subfn *external_files;
    int error;
};

struct prefetched_file {
    uint64_t playlist_entry_id;
    char *url;
    struct demuxer *demuxer;
    struct subfn *external_files;
    int error;
    bool start_window;
    int stream_flags;
};

// A stuck driver operation can keep a full playback cache alive. Keep only
// two such cleanups outstanding; speculative opens stop before this limit.
#define MAX_RETIRED_DEMUXERS 2

struct retired_demux {
    struct demux_free_async_state *state;
    struct async_open *open;
    double deadline;
    bool forced;
};

static void wakeup_demux(void *pctx)
{
    struct MPContext *mpctx = pctx;
    mp_wakeup_core(mpctx);
}

void reap_demuxers(struct MPContext *mpctx)
{
    for (int n = 0; n < mpctx->num_retired_demuxers; n++) {
        struct retired_demux *item = &mpctx->retired_demuxers[n];
        if (item->open) {
            struct async_open *open = item->open;
            if (open->active && !atomic_load(&open->done))
                continue;
            if (open->active)
                mp_thread_join(open->thread);
            if (open->demuxer) {
                mp_cancel_set_parent(open->demuxer->cancel, NULL);
                demux_set_wakeup_cb(open->demuxer, wakeup_demux, mpctx);
                item->state = demux_free_async(open->demuxer);
                if (!item->state)
                    demux_cancel_and_free(open->demuxer);
            }
            talloc_free(open->external_files);
            talloc_free(open);
            item->open = NULL;
        }
        if (item->state && !demux_free_async_finish(item->state)) {
            double wait = item->deadline - mp_time_sec();
            if (!item->forced && wait <= 0) {
                demux_free_async_force(item->state);
                item->forced = true;
            } else if (!item->forced) {
                mp_set_timeout(mpctx, wait);
            }
            continue;
        }
        MP_TARRAY_REMOVE_AT(mpctx->retired_demuxers,
                            mpctx->num_retired_demuxers, n);
        MP_VERBOSE(mpctx, "Demux cleanup finished (%d pending).\n",
                   mpctx->num_retired_demuxers);
        n--;
    }
}

static void wait_retirement_room(struct MPContext *mpctx)
{
    reap_demuxers(mpctx);
    if (mpctx->num_retired_demuxers >= MAX_RETIRED_DEMUXERS) {
        MP_VERBOSE(mpctx, "Demux cleanup limit reached; waiting for a slot.\n");
        while (mpctx->num_retired_demuxers >= MAX_RETIRED_DEMUXERS)
            mp_idle(mpctx);
    }
}

void retire_demuxer(struct MPContext *mpctx, struct demuxer *demuxer)
{
    if (!demuxer)
        return;
    wait_retirement_room(mpctx);
    mp_cancel_set_parent(demuxer->cancel, NULL);
    demux_set_wakeup_cb(demuxer, wakeup_demux, mpctx);
    struct demux_free_async_state *state = demux_free_async(demuxer);
    if (!state) {
        demux_cancel_and_free(demuxer);
        return;
    }
    struct retired_demux item = {
        .state = state,
        .deadline = mp_time_sec() + mpctx->opts->demux_termination_timeout,
    };
    MP_TARRAY_APPEND(mpctx, mpctx->retired_demuxers,
                     mpctx->num_retired_demuxers, item);
    MP_VERBOSE(mpctx, "Demux cleanup queued (%d pending).\n",
               mpctx->num_retired_demuxers);
    reap_demuxers(mpctx);
}

void drain_demuxers(struct MPContext *mpctx)
{
    reap_demuxers(mpctx);
    while (mpctx->num_retired_demuxers)
        mp_idle(mpctx);
    TA_FREEP(&mpctx->retired_demuxers);
    MP_VERBOSE(mpctx, "All demux cleanup drained.\n");
}

static MP_THREAD_VOID open_demux_thread(void *ctx)
{
    struct async_open *open = ctx;
    struct MPContext *mpctx = open->mpctx;

    mp_thread_set_name("opener");

    struct demuxer_params p = {
        .force_format = open->format,
        .stream_flags = open->url_flags,
        .stream_record = true,
        .is_top_level = true,
        .allow_playlist_create = false,
    };
    open->demuxer =
        demux_open_url(open->url, &p, open->cancel, mpctx->global);

    if (open->demuxer) {
        MP_VERBOSE(mpctx, "Opening done: %s\n", open->url);

        if (open->start_prefetch && !open->demuxer->fully_read) {
            int num_streams = demux_get_num_stream(open->demuxer);
            for (int n = 0; n < num_streams; n++) {
                struct sh_stream *sh = demux_get_stream(open->demuxer, n);
                if (sh->type != STREAM_VIDEO && sh->type != STREAM_AUDIO)
                    continue;
                if (sh->image)
                    continue;
                demuxer_select_track(open->demuxer, sh, MP_NOPTS_VALUE, true);
            }

            demux_set_prefetch_limits(open->demuxer, open->prefetch_secs,
                                      open->prefetch_bytes);
            demux_set_wakeup_cb(open->demuxer, wakeup_demux, mpctx);
            demux_start_thread(open->demuxer);
            demux_start_prefetch(open->demuxer);
        } else {
            open->start_window = false;
        }

        if (open->for_prefetch) {
            struct MPOpts *opts = mpctx->opts;
            if ((opts->sub_auto >= 0 || opts->audiofile_auto >= 0 || opts->coverart_auto >= 0) &&
                opts->autoload_files && strcmp(open->url, "-") != 0 &&
                !mp_is_url(bstr0(open->url)) && !mp_cancel_test(open->cancel))
            {
                open->external_files = find_external_files(mpctx->global, open->url, opts);
                if (open->external_files)
                    talloc_steal(open, open->external_files);
            }
        }
    } else {
        MP_VERBOSE(mpctx, "Opening failed or was aborted: %s\n", open->url);
        open->error = p.demuxer_failed ? MPV_ERROR_UNKNOWN_FORMAT
                                       : MPV_ERROR_LOADING_FAILED;
    }

    atomic_store(&open->done, true);
    mp_wakeup_core(mpctx);
    MP_THREAD_RETURN();
}

static void destroy_open(struct MPContext *mpctx)
{
    struct async_open *open = mpctx->open;
    if (!open)
        return;

    bool was_prefetch = open->for_prefetch;
    mpctx->open = NULL;
    mp_cancel_set_parent(open->cancel, NULL);
    mp_cancel_trigger(open->cancel);
    if (!open->active) {
        // Failed thread creation has no worker that could ever signal done.
        mp_assert(!open->demuxer);
        talloc_free(open->external_files);
        talloc_free(open);
    } else {
        wait_retirement_room(mpctx);
        struct retired_demux item = {
            .open = open,
            .deadline = mp_time_sec() + mpctx->opts->demux_termination_timeout,
        };
        MP_TARRAY_APPEND(mpctx, mpctx->retired_demuxers,
                         mpctx->num_retired_demuxers, item);
        reap_demuxers(mpctx);
    }
    if (was_prefetch) {
        mp_notify_property(mpctx, "prefetch-active");
        mp_notify_property(mpctx, "playlist");
    }
}

static struct async_open *take_finished_open(struct MPContext *mpctx)
{
    struct async_open *open = mpctx->open;
    mp_assert(open && atomic_load(&open->done));

    if (open->active)
        mp_thread_join(open->thread);
    open->active = false;
    mpctx->open = NULL;
    return open;
}

static bool start_open(struct MPContext *mpctx, struct playlist_entry *entry,
                       char *url, int url_flags, bool for_prefetch)
{
    mp_assert(!mpctx->open);

    struct async_open *open = talloc_zero(NULL, struct async_open);
    open->mpctx = mpctx;
    open->cancel = mp_cancel_new(open);
    open->url = talloc_strdup(open, url);
    open->format = talloc_strdup(open, mpctx->opts->demuxer_name);
    open->url_flags = url_flags;
    open->playlist_entry_id = entry ? entry->id : 0;
    open->stream_flags = entry ? entry->stream_flags : 0;
    open->for_prefetch = for_prefetch;
    open->start_prefetch = for_prefetch && mpctx->opts->demuxer_thread;
    bool use_start = for_prefetch &&
                     (mpctx->opts->prefetch_open_start_secs > 0 ||
                      mpctx->opts->prefetch_open_start_bytes > 0);
    if (use_start) {
        open->prefetch_secs = mpctx->opts->prefetch_open_start_secs;
        open->prefetch_bytes = mpctx->opts->prefetch_open_start_bytes;
        open->start_window = true;
    } else {
        open->prefetch_secs = mpctx->opts->prefetch_open_secs;
        open->prefetch_bytes = mpctx->opts->prefetch_open_bytes;
        open->start_window = false;
    }
    atomic_init(&open->done, false);

    mpctx->open = open;
    if (mp_thread_create(&open->thread, open_demux_thread, open)) {
        destroy_open(mpctx);
        return false;
    }

    open->active = true;
    if (for_prefetch) {
        mp_notify_property(mpctx, "prefetch-active");
        mp_notify_property(mpctx, "playlist");
    }
    return true;
}

static void clear_prefetched_files(struct MPContext *mpctx)
{
    bool had_files = mpctx->num_prefetched_files > 0;
    while (mpctx->num_prefetched_files) {
        struct prefetched_file file =
            mpctx->prefetched_files[--mpctx->num_prefetched_files];
        talloc_free(file.external_files);
        talloc_free(file.url);
        retire_demuxer(mpctx, file.demuxer);
    }

    talloc_free(mpctx->prefetched_files);
    mpctx->prefetched_files = NULL;
    mpctx->num_prefetched_files = 0;
    if (had_files) {
        mp_notify_property(mpctx, "prefetched-count");
        mp_notify_property(mpctx, "playlist");
    }
}

void cancel_open(struct MPContext *mpctx)
{
    if (mpctx->prefetch_canceling)
        return;
    mpctx->prefetch_canceling = true;
    destroy_open(mpctx);
    clear_prefetched_files(mpctx);
    bool had_history = mpctx->num_history_files > 0;
    while (mpctx->num_history_files) {
        struct prefetched_file file =
            mpctx->history_files[--mpctx->num_history_files];
        talloc_free(file.external_files);
        talloc_free(file.url);
        retire_demuxer(mpctx, file.demuxer);
    }
    TA_FREEP(&mpctx->history_files);
    mpctx->num_history_files = 0;
    if (had_history)
        mp_notify_property(mpctx, "playlist");
    talloc_free(mpctx->prefetched_external_files);
    mpctx->prefetched_external_files = NULL;
    mpctx->prefetch_canceling = false;
}

static void store_finished_prefetch(struct MPContext *mpctx)
{
    struct async_open *open = mpctx->open;
    if (!open || !open->for_prefetch || !atomic_load(&open->done))
        return;

    open = take_finished_open(mpctx);
    struct prefetched_file file = {
        .playlist_entry_id = open->playlist_entry_id,
        .url = talloc_steal(mpctx, open->url),
        .demuxer = open->demuxer,
        .external_files = talloc_steal(mpctx, open->external_files),
        .error = open->error,
        .start_window = open->start_window,
        .stream_flags = open->stream_flags,
    };
    if (file.demuxer)
        mp_cancel_set_parent(file.demuxer->cancel, NULL);
    open->url = NULL;
    open->demuxer = NULL;
    open->external_files = NULL;
    MP_TARRAY_APPEND(mpctx, mpctx->prefetched_files,
                     mpctx->num_prefetched_files, file);
    talloc_free(open);
    mp_notify_property(mpctx, "prefetched-count");
    mp_notify_property(mpctx, "prefetch-active");
    mp_notify_property(mpctx, "playlist");
}

static int find_prefetched_file(struct MPContext *mpctx,
                                struct playlist_entry *entry, char *url)
{
    for (int n = 0; n < mpctx->num_prefetched_files; n++) {
        struct prefetched_file *file = &mpctx->prefetched_files[n];
        if (file->playlist_entry_id == entry->id &&
            file->stream_flags == entry->stream_flags &&
            strcmp(file->url, url) == 0)
        {
            return n;
        }
    }
    return -1;
}

static struct prefetched_file take_prefetched_file(struct MPContext *mpctx,
                                                   int index)
{
    struct prefetched_file file = mpctx->prefetched_files[index];
    MP_TARRAY_REMOVE_AT(mpctx->prefetched_files,
                        mpctx->num_prefetched_files, index);
    mp_notify_property(mpctx, "prefetched-count");
    mp_notify_property(mpctx, "playlist");
    return file;
}

static bool open_matches(struct async_open *open,
                         struct playlist_entry *entry, char *url)
{
    return open->playlist_entry_id == entry->id &&
           open->stream_flags == entry->stream_flags &&
           strcmp(open->url, url) == 0;
}

static void adopt_demuxer(struct MPContext *mpctx, struct demuxer *demuxer)
{
    mpctx->demuxer = demuxer;
    mpctx->demuxer_reusable = true;
    demux_set_prefetch_limits(demuxer, 0, 0);
    mp_cancel_set_parent(demuxer->cancel, mpctx->playback_abort);
    MP_VERBOSE(mpctx, "Adopted demuxer %p for entry %" PRIu64 ".\n",
               (void *)demuxer, mpctx->playing->id);
}

static bool file_matches(struct prefetched_file *file,
                          struct playlist_entry *entry, const char *url)
{
    return entry && file->playlist_entry_id == entry->id &&
           file->stream_flags == entry->stream_flags &&
           strcmp(file->url, url) == 0;
}

static struct playlist_entry *entry_by_id(struct MPContext *mpctx, uint64_t id)
{
    for (int n = 0; n < mpctx->playlist->num_entries; n++) {
        struct playlist_entry *entry = mpctx->playlist->entries[n];
        if (entry->id == id)
            return entry;
    }
    return NULL;
}

static struct playlist_entry *previous_entry(struct MPContext *mpctx,
                                              struct playlist_entry *entry)
{
    struct playlist_entry *prev = playlist_entry_get_rel(entry, -1);
    if (!prev && mpctx->opts->loop_times != 1)
        prev = playlist_get_last(mpctx->playlist);
    return prev;
}

static int pool_position(struct MPContext *mpctx, uint64_t current_id,
                         struct prefetched_file *file, bool previous)
{
    struct playlist_entry *current = entry_by_id(mpctx, current_id);
    if (!current)
        return 0;
    int max = previous ? mpctx->opts->prefetch_open_history
                       : mpctx->opts->prefetch_open_max;
    struct playlist_entry *entry = current;
    bool loop = mpctx->opts->loop_times != 1;
    for (int n = 0; n < max; n++) {
        entry = previous ? previous_entry(mpctx, entry)
                         : playlist_entry_get_next_cyclic(mpctx->playlist,
                                                           entry, loop);
        if (!entry || entry == current)
            break;
        if (file_matches(file, entry, entry->filename))
            return n + 1;
    }
    return 0;
}

static void discard_file(struct MPContext *mpctx, struct prefetched_file file)
{
    talloc_free(file.url);
    talloc_free(file.external_files);
    retire_demuxer(mpctx, file.demuxer);
}

static void trim_retained_files(struct MPContext *mpctx, uint64_t current_id)
{
    bool changed = false;
    for (int n = mpctx->num_history_files - 1; n >= 0; n--) {
        struct prefetched_file file = mpctx->history_files[n];
        if (file.demuxer && demux_prefetch_prepare_state(file.demuxer) < 0) {
            MP_TARRAY_REMOVE_AT(mpctx->history_files, mpctx->num_history_files, n);
            changed = true;
            discard_file(mpctx, file);
            n = mpctx->num_history_files;
            continue;
        }
        struct playlist_entry *current = entry_by_id(mpctx, current_id);
        if (current && file_matches(&file, current, current->filename))
            continue; // protect the requested target until it is adopted
        if (pool_position(mpctx, current_id, &file, true))
            continue;
        MP_TARRAY_REMOVE_AT(mpctx->history_files, mpctx->num_history_files, n);
        changed = true;
        int pos = pool_position(mpctx, current_id, &file, false);
        if (pos) {
            bool start = pos > 1 &&
                         (mpctx->opts->prefetch_open_start_secs > 0 ||
                          mpctx->opts->prefetch_open_start_bytes > 0);
            double secs = start ? mpctx->opts->prefetch_open_start_secs
                                : mpctx->opts->prefetch_open_secs;
            int64_t bytes = start ? mpctx->opts->prefetch_open_start_bytes
                                  : mpctx->opts->prefetch_open_bytes;
            if (demux_prepare_prefetch(file.demuxer, secs, bytes)) {
                file.start_window = start;
                MP_TARRAY_APPEND(mpctx, mpctx->prefetched_files,
                                 mpctx->num_prefetched_files, file);
            } else {
                discard_file(mpctx, file);
            }
        } else {
            discard_file(mpctx, file);
        }
        n = mpctx->num_history_files;
    }
    for (int n = mpctx->num_prefetched_files - 1; n >= 0; n--) {
        struct prefetched_file file = mpctx->prefetched_files[n];
        if (file.demuxer && demux_prefetch_prepare_state(file.demuxer) < 0) {
            MP_TARRAY_REMOVE_AT(mpctx->prefetched_files,
                                mpctx->num_prefetched_files, n);
            changed = true;
            discard_file(mpctx, file);
            n = mpctx->num_prefetched_files;
            continue;
        }
        struct playlist_entry *current = entry_by_id(mpctx, current_id);
        if (current && file_matches(&file, current, current->filename))
            continue;
        if (pool_position(mpctx, current_id, &file, false))
            continue;
        MP_TARRAY_REMOVE_AT(mpctx->prefetched_files,
                            mpctx->num_prefetched_files, n);
        changed = true;
        if (file.demuxer && pool_position(mpctx, current_id, &file, true) &&
            demux_prepare_prefetch(file.demuxer,
                                   mpctx->opts->prefetch_open_secs,
                                   mpctx->opts->prefetch_open_bytes))
        {
            file.start_window = false;
            MP_TARRAY_APPEND(mpctx, mpctx->history_files,
                             mpctx->num_history_files, file);
        } else {
            discard_file(mpctx, file);
        }
        n = mpctx->num_prefetched_files;
    }
    // The immediate next file drives start-window expansion, irrespective
    // of the order in which retained files and openers entered the pool.
    for (int n = 0; n < mpctx->num_prefetched_files; n++) {
        for (int m = n + 1; m < mpctx->num_prefetched_files; m++) {
            int a = pool_position(mpctx, current_id,
                                  &mpctx->prefetched_files[n], false);
            int b = pool_position(mpctx, current_id,
                                  &mpctx->prefetched_files[m], false);
            if (b < a) {
                MPSWAP(struct prefetched_file, mpctx->prefetched_files[n],
                       mpctx->prefetched_files[m]);
                changed = true;
            }
        }
    }
    if (changed) {
        mp_notify_property(mpctx, "prefetched-count");
        mp_notify_property(mpctx, "playlist");
    }
}

bool retain_demuxer(struct MPContext *mpctx, struct demuxer *demuxer)
{
    struct playlist_entry *playing = mpctx->playing;
    if (!mpctx->opts->prefetch_open || !mpctx->opts->prefetch_open_history ||
        !playing || playing->removed || playing->num_params ||
        mpctx->demuxer_changed || !mpctx->demuxer_reusable ||
        mpctx->playlist->current_was_replaced ||
        mpctx->encode_lavc_ctx || mpctx->stop_play == PT_QUIT ||
        mpctx->stop_play == PT_STOP || mpctx->stop_play == PT_ERROR)
    {
        return false;
    }
    struct playlist_entry *target = mpctx->stop_play == PT_CURRENT_ENTRY
        ? mpctx->playlist->current : mp_next_file(mpctx, +1, false, false);
    if (!target || target == playing || target->reloading)
        return false;

    struct prefetched_file file = {
        .playlist_entry_id = playing->id,
        .url = mpctx->stream_open_filename,
        .demuxer = demuxer,
        .stream_flags = playing->stream_flags,
    };
    uint64_t target_id = target->id;
    bool history = pool_position(mpctx, target_id, &file, true) > 0;
    int forward_pos = pool_position(mpctx, target_id, &file, false);
    if (!history && !forward_pos)
        return false;
    bool start = !history && forward_pos > 1 &&
                 (mpctx->opts->prefetch_open_start_secs > 0 ||
                  mpctx->opts->prefetch_open_start_bytes > 0);
    double secs = start ? mpctx->opts->prefetch_open_start_secs
                        : mpctx->opts->prefetch_open_secs;
    int64_t bytes = start ? mpctx->opts->prefetch_open_start_bytes
                         : mpctx->opts->prefetch_open_bytes;
    if (!demux_prepare_prefetch(demuxer, secs, bytes))
        return false;

    mp_cancel_set_parent(demuxer->cancel, NULL);
    demux_set_wakeup_cb(demuxer, wakeup_demux, mpctx);
    file.url = talloc_strdup(mpctx, file.url);
    file.start_window = start;
    if (history) {
        MP_TARRAY_APPEND(mpctx, mpctx->history_files, mpctx->num_history_files, file);
    } else {
        MP_TARRAY_APPEND(mpctx, mpctx->prefetched_files,
                         mpctx->num_prefetched_files, file);
    }
    MP_VERBOSE(mpctx, "Retained demuxer %p for entry %" PRIu64 " (%s).\n",
               (void *)demuxer, playing->id, history ? "history" : "forward");
    mp_notify_property(mpctx, "prefetched-count");
    mp_notify_property(mpctx, "playlist");
    trim_retained_files(mpctx, target_id);
    return true;
}

static bool use_retained_file(struct MPContext *mpctx, struct prefetched_file file)
{
    int state;
    while (!(state = demux_prefetch_prepare_state(file.demuxer)) &&
           !mpctx->stop_play && !mpctx->demuxer_changed &&
           !mpctx->prefetch_changed)
    {
        mp_idle(mpctx);
    }
    if (state < 0 || mpctx->stop_play || mpctx->demuxer_changed ||
        mpctx->prefetch_changed ||
        mpctx->playing->num_params ||
        !file_matches(&file, mpctx->playing, mpctx->stream_open_filename))
    {
        MP_VERBOSE(mpctx, "Retained URL requires a fresh open.\n");
        discard_file(mpctx, file);
        return false;
    }

    adopt_demuxer(mpctx, file.demuxer);
    talloc_free(mpctx->prefetched_external_files);
    mpctx->prefetched_external_files = file.external_files;
    talloc_free(file.url);
    return true;
}

void open_demux_reentrant(struct MPContext *mpctx)
{
retry:;
    char *url = mpctx->stream_open_filename;
    struct playlist_entry *entry = mpctx->playing;

    if (mpctx->demuxer_changed || mpctx->prefetch_changed) {
        bool done = mpctx->open && atomic_load(&mpctx->open->done);
        if (mpctx->open || mpctx->num_prefetched_files || mpctx->num_history_files) {
            MP_VERBOSE(mpctx, "%s prefetch because options changed.\n",
                       done ? "Dropping finished" : "Aborting ongoing");
        }
        // Cleanup can process commands while waiting for a retirement slot.
        // Consume this notification before it yields, preserving new changes.
        mpctx->demuxer_changed = false;
        mpctx->prefetch_changed = false;
        cancel_open(mpctx);
        if (mpctx->demuxer_changed || mpctx->prefetch_changed)
            goto retry;
    }

    store_finished_prefetch(mpctx);

    if (mpctx->playlist->current_was_replaced || entry->reloading || entry->num_params)
        cancel_open(mpctx);
    if (mpctx->stop_play)
        return;
    url = mpctx->stream_open_filename;

    for (int n = 0; n < mpctx->num_history_files; n++) {
        struct prefetched_file file = mpctx->history_files[n];
        if (!file_matches(&file, entry, url))
            continue;
        MP_TARRAY_REMOVE_AT(mpctx->history_files, mpctx->num_history_files, n);
        mp_notify_property(mpctx, "playlist");
        MP_VERBOSE(mpctx, "Using retained previous URL.\n");
        if (use_retained_file(mpctx, file)) {
            trim_retained_files(mpctx, entry->id);
            return;
        }
        break;
    }

    if (mpctx->stop_play)
        return;
    if (mpctx->demuxer_changed || mpctx->prefetch_changed)
        goto retry;
    url = mpctx->stream_open_filename;

    int index = find_prefetched_file(mpctx, entry, url);
    if (index >= 0) {
        struct prefetched_file file = take_prefetched_file(mpctx, index);

        if (file.demuxer) {
            MP_VERBOSE(mpctx, "Using prefetched URL.\n");
            if (use_retained_file(mpctx, file)) {
                trim_retained_files(mpctx, entry->id);
                return;
            }
            file.external_files = NULL;
            file.url = NULL;
        }

        MP_VERBOSE(mpctx, "Prefetched URL failed, retrying.\n");
        talloc_free(file.external_files);
        talloc_free(file.url);
        destroy_open(mpctx);
    }

    if (mpctx->stop_play)
        return;
    if (mpctx->demuxer_changed || mpctx->prefetch_changed)
        goto retry;
    url = mpctx->stream_open_filename;

    if (mpctx->open) {
        bool done = atomic_load(&mpctx->open->done);
        bool failed = done && !mpctx->open->demuxer;
        bool correct_url = open_matches(mpctx->open, entry, url);

        if (correct_url && !failed) {
            MP_VERBOSE(mpctx, "Using prefetched/prefetching URL.\n");
        } else {
            if (correct_url && failed) {
                MP_VERBOSE(mpctx, "Prefetched URL failed, retrying.\n");
            } else if (done) {
                MP_VERBOSE(mpctx, "Dropping finished prefetch of wrong URL.\n");
            } else {
                MP_VERBOSE(mpctx, "Aborting ongoing prefetch of wrong URL.\n");
            }
            destroy_open(mpctx);
        }
    }

    if (mpctx->stop_play)
        return;
    url = mpctx->stream_open_filename;
    if (!mpctx->open && !mpctx->stop_play)
        start_open(mpctx, entry, url, entry->stream_flags, false);

    if (mpctx->open)
        mp_cancel_set_parent(mpctx->open->cancel, mpctx->playback_abort);

    // If the thread failed to start, cancel the playback.
    if (!mpctx->open)
        return;

    while (mpctx->open && !atomic_load(&mpctx->open->done)) {
        mp_idle(mpctx);

        if (mpctx->stop_play)
            mp_abort_playback_async(mpctx);
    }

    if (!mpctx->open)
        return;

    struct async_open *open = take_finished_open(mpctx);
    if (mpctx->demuxer_changed && !mpctx->stop_play) {
        struct prefetched_file file = {
            .demuxer = open->demuxer,
            .url = talloc_steal(mpctx, open->url),
            .external_files = talloc_steal(mpctx, open->external_files),
        };
        if (file.demuxer)
            mp_cancel_set_parent(file.demuxer->cancel, NULL);
        talloc_free(open);
        discard_file(mpctx, file);
        goto retry;
    }
    if (open->demuxer) {
        adopt_demuxer(mpctx, open->demuxer);
        open->demuxer = NULL;
        talloc_free(mpctx->prefetched_external_files);
        mpctx->prefetched_external_files = talloc_steal(mpctx, open->external_files);
        open->external_files = NULL;
    } else {
        mpctx->error_playing = open->error;
    }
    talloc_free(open);
}

bool is_prefetch_active(struct MPContext *mpctx)
{
    return mpctx->open && mpctx->open->for_prefetch;
}

bool is_entry_prefetched(struct MPContext *mpctx,
                         struct playlist_entry *entry)
{
    if (!entry)
        return false;

    if (mpctx->open && mpctx->open->for_prefetch &&
        mpctx->open->playlist_entry_id == entry->id)
    {
        return true;
    }

    for (int n = 0; n < mpctx->num_prefetched_files; n++) {
        if (file_matches(&mpctx->prefetched_files[n], entry, entry->filename))
            return true;
    }
    for (int n = 0; n < mpctx->num_history_files; n++) {
        if (file_matches(&mpctx->history_files[n], entry, entry->filename))
            return true;
    }
    return false;
}

static bool id_in_prefetch_window(struct MPContext *mpctx, uint64_t id)
{
    struct playlist_entry *current = mpctx->playlist->current;
    if (mpctx->stop_play == PT_CURRENT_ENTRY && current &&
        current != mpctx->playing &&
        !mpctx->playlist->current_was_replaced && current->id == id)
    {
        return true;
    }

    int max = mpctx->opts->prefetch_open_max;
    bool loop = mpctx->opts->loop_times != 1;
    struct playlist_entry *entry = mp_next_file(mpctx, +1, false, false);
    for (int n = 0; entry && n < max; n++) {
        if (entry == mpctx->playing)
            break;
        if (entry->id == id)
            return true;
        entry = playlist_entry_get_next_cyclic(mpctx->playlist, entry, loop);
    }
    return false;
}

static void drop_stale_prefetches(struct MPContext *mpctx)
{
    struct playlist_entry *current = mpctx->playlist->current;
    uint64_t current_id = current ? current->id : 0;
    if (mpctx->open && mpctx->open->for_prefetch &&
        !id_in_prefetch_window(mpctx, mpctx->open->playlist_entry_id))
    {
        MP_VERBOSE(mpctx, "Aborting prefetch outside playlist next.\n");
        destroy_open(mpctx);
    }

    trim_retained_files(mpctx, current_id);
}

static bool prefetch_current_healthy(struct MPContext *mpctx)
{
    if (!mpctx->demuxer)
        return false;

    struct demux_reader_state s;
    demux_get_reader_state(mpctx->demuxer, &s);
    return !s.underrun;
}

void update_prefetch_state(struct MPContext *mpctx)
{
    store_finished_prefetch(mpctx);
    if (!mpctx->num_prefetched_files)
        return;

    bool healthy = prefetch_current_healthy(mpctx);
    struct prefetched_file *first = &mpctx->prefetched_files[0];
    if (first->demuxer && first->start_window) {
        int state = demux_prefetch_prepare_state(first->demuxer);
        if (state < 0) {
            struct prefetched_file file = *first;
            MP_TARRAY_REMOVE_AT(mpctx->prefetched_files,
                                mpctx->num_prefetched_files, 0);
            discard_file(mpctx, file);
            mp_notify_property(mpctx, "prefetched-count");
            mp_notify_property(mpctx, "playlist");
            return;
        }
        if (!state)
            return;
        struct demux_reader_state ps;
        demux_get_reader_state(first->demuxer, &ps);
        if (ps.cache_full || ps.eof) {
            MP_VERBOSE(mpctx, "Prefetch start window ready.\n");
            if (healthy) {
                demux_set_prefetch_limits(first->demuxer,
                                          mpctx->opts->prefetch_open_secs,
                                          mpctx->opts->prefetch_open_bytes);
                demux_start_prefetch(first->demuxer);
                first->start_window = false;
                MP_VERBOSE(mpctx, "Prefetch expanding cache.\n");
            }
        }
    }
}

void cancel_render_prefetch(struct MPContext *mpctx)
{
    if (mpctx->render_prefetch_id && getenv("MPV_RENDER_WARMUP_TRACE")) {
        MP_INFO(mpctx, "render-warmup-trace: event=eligibility-cancel time_ns=%lld "
                "entry=%lld submitted=%d\n", (long long)mp_time_ns(),
                (long long)mpctx->render_prefetch_id, mpctx->render_prefetch_submitted);
    }
    if (mpctx->render_prefetch_submitted && mpctx->video_out)
        vo_control_async(mpctx->video_out, VOCTRL_RENDER_WARMUP, NULL);
    mpctx->render_prefetch_id = 0;
    mpctx->render_prefetch_deadline_ns = 0;
    mpctx->render_prefetch_submitted = false;
    TA_FREEP(&mpctx->render_prefetch_url);
}

static void prefetch_render(struct MPContext *mpctx)
{
    if (!mpctx->opts->prefetch_render || !mpctx->opts->prefetch_open ||
        !mpctx->video_out || !mpctx->vo_chain || !mpctx->playback_initialized ||
        mpctx->video_status < STATUS_PLAYING || mpctx->video_status >= STATUS_EOF ||
        !mpctx->restart_complete || !mpctx->vo_chain->track ||
        !vo_has_frame(mpctx->video_out) ||
        mpctx->stop_play)
    {
        cancel_render_prefetch(mpctx);
        return;
    }
    if (!mpctx->render_prefetch_options) {
        mpctx->render_prefetch_options = m_config_cache_alloc(
            mpctx, mpctx->global, &mp_opt_root);
    }
    struct m_config_cache *cache = mpctx->render_prefetch_options;
    void *changed;
    bool filter_changed = false;
    while (m_config_cache_get_next_changed(cache, &changed)) {
        struct MPOpts *cached = cache->opts;
        filter_changed |= changed == &cached->vf_settings;
    }
    if (filter_changed || cache->change_flags) {
        uint64_t relevant = UPDATE_IMGPAR | UPDATE_VIDEO | UPDATE_VO |
                            UPDATE_DEMUXER | UPDATE_VD | UPDATE_HWDEC |
                            UPDATE_PREFETCH | UPDATE_LAVFI_COMPLEX;
        if (filter_changed || (cache->change_flags & relevant))
            cancel_render_prefetch(mpctx);
        cache->change_flags = 0;
    }
    struct playlist_entry *entry = mp_next_file(mpctx, +1, false, false);
    if (!entry || !entry->filename || entry == mpctx->playing ||
        entry->num_params || mpctx->playlist->current_was_replaced)
    {
        cancel_render_prefetch(mpctx);
        return;
    }
    if (mpctx->render_prefetch_id != entry->id || !mpctx->render_prefetch_url ||
        strcmp(mpctx->render_prefetch_url, entry->filename) != 0 ||
        mpctx->render_prefetch_stream_flags != entry->stream_flags)
    {
        cancel_render_prefetch(mpctx);
        mpctx->render_prefetch_id = entry->id;
        mpctx->render_prefetch_url = talloc_strdup(mpctx, entry->filename);
        mpctx->render_prefetch_stream_flags = entry->stream_flags;
        int64_t now = mp_time_ns();
        mpctx->render_prefetch_deadline_ns = now + MP_TIME_MS_TO_NS(250);
        if (getenv("MPV_RENDER_WARMUP_TRACE")) {
            MP_INFO(mpctx, "render-warmup-trace: event=eligibility time_ns=%lld "
                    "source=%lld entry=%lld deadline_ns=%lld\n", (long long)now,
                    (long long)mpctx->playing->id, (long long)entry->id,
                    (long long)mpctx->render_prefetch_deadline_ns);
        }
    }
    if (mpctx->render_prefetch_submitted)
        return;
    int64_t remaining = mpctx->render_prefetch_deadline_ns - mp_time_ns();
    if (remaining > 0) {
        // Keep ordinary packet prefetch immediate. Only private render work
        // needs a stable current frame, rather than each rapid navigation stop.
        mp_set_timeout(mpctx, MP_TIME_NS_TO_S(remaining));
        return;
    }
    // Begin only once normal nearest-next packet prefetch has completed opening.
    if (find_prefetched_file(mpctx, entry, entry->filename) < 0)
        return;
    struct render_warmup_request *r = render_warmup_request_create(
        mpctx->global, entry->id, entry->filename, entry->stream_flags);
    if (!r)
        return;
    mpctx->render_prefetch_submitted = true;
    if (getenv("MPV_RENDER_WARMUP_TRACE")) {
        MP_INFO(mpctx, "render-warmup-trace: event=submit time_ns=%lld source=%lld "
                "entry=%lld\n", (long long)mp_time_ns(),
                (long long)mpctx->playing->id, (long long)entry->id);
    }
    vo_control_async(mpctx->video_out, VOCTRL_RENDER_WARMUP, r);
}

void request_prefetch_next(struct MPContext *mpctx)
{
    // Retirement can wait via mp_idle(), which must not run from a dispatch
    // callback or a client holding the core lock. Let the playloop do it.
    mpctx->prefetch_requested = true;
    mp_wakeup_core(mpctx);
}

static void do_prefetch_next(struct MPContext *mpctx)
{
    if (mpctx->prefetch_canceling)
        return;
    // The current opener/adoption owns pending option invalidation. In
    // particular, a preparing retained target is outside both pools.
    if (!mpctx->demuxer || (mpctx->open && !mpctx->open->for_prefetch))
        return;
    if (mpctx->demuxer_changed || mpctx->prefetch_changed) {
        cancel_render_prefetch(mpctx);
        if (mpctx->demuxer_changed)
            mpctx->demuxer_reusable = false;
        mpctx->demuxer_changed = false;
        mpctx->prefetch_changed = false;
        cancel_open(mpctx);
        if (mpctx->demuxer_changed || mpctx->prefetch_changed)
            return;
    }

    if (!mpctx->opts->prefetch_open) {
        cancel_render_prefetch(mpctx);
        cancel_open(mpctx);
        return;
    }

    if (mpctx->playlist->current_was_replaced) {
        cancel_render_prefetch(mpctx);
        cancel_open(mpctx);
        return;
    }

    // The playloop and mp_set_playlist_entry() select playlist->current
    // before the old file finishes teardown; play_current_file() then zeroes
    // stop_play before it makes that entry mpctx->playing. Hooks and events
    // run in between and may call back into playlist commands, so keep the
    // selected entry adoptable for the whole handover.
    struct playlist_entry *current = mpctx->playlist->current;
    if (current && current != mpctx->playing &&
        !mpctx->playlist->current_was_replaced)
    {
        return;
    }
    update_prefetch_state(mpctx);
    drop_stale_prefetches(mpctx);
    // Retirement can yield to commands which invalidate the options or stop
    // playback. Reconcile again before submitting work from this old pass.
    if (mpctx->demuxer_changed || mpctx->prefetch_changed ||
        !mpctx->opts->prefetch_open || mpctx->stop_play)
    {
        mpctx->prefetch_requested = true;
        return;
    }
    prefetch_render(mpctx);
    reap_demuxers(mpctx);
    if (mpctx->num_retired_demuxers >= MAX_RETIRED_DEMUXERS - 1) {
        // Completion wakes the core. Keep the request until an opener can
        // be admitted, including when realtime prefetch is disabled.
        mpctx->prefetch_requested = true;
        return;
    }
    if (mpctx->open)
        return;

    int max = mpctx->opts->prefetch_open_max;
    if (mpctx->num_prefetched_files >= max)
        return;

    if (mpctx->num_prefetched_files >= 1) {
        if (mpctx->prefetched_files[0].start_window)
            return;
        if (!prefetch_current_healthy(mpctx))
            return;
    }

    bool loop = mpctx->opts->loop_times != 1;
    struct playlist_entry *entry = mp_next_file(mpctx, +1, false, false);
    for (int n = 0; entry && n < max; n++) {
        if (entry == mpctx->playing)
            break;
        if (entry->filename && !is_entry_prefetched(mpctx, entry)) {
            MP_VERBOSE(mpctx, "Prefetching: %s\n", entry->filename);
            start_open(mpctx, entry, entry->filename, entry->stream_flags, true);
            return;
        }
        entry = playlist_entry_get_next_cyclic(mpctx->playlist, entry, loop);
    }
}

void prefetch_next(struct MPContext *mpctx)
{
    if (mpctx->prefetch_running || mpctx->prefetch_canceling)
        return;
    mpctx->prefetch_running = true;
    do_prefetch_next(mpctx);
    mpctx->prefetch_running = false;
    if (mpctx->prefetch_requested &&
        mpctx->num_retired_demuxers < MAX_RETIRED_DEMUXERS - 1)
    {
        mp_wakeup_core(mpctx);
    }
}
