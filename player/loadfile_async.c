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

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include "mpv_talloc.h"

#include "common/common.h"
#include "common/msg.h"
#include "common/playlist.h"
#include "demux/demux.h"
#include "misc/thread_tools.h"
#include "options/options.h"
#include "osdep/threads.h"

#include "client.h"
#include "core.h"

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
    bool for_prefetch;
    bool start_prefetch;
    double prefetch_secs;
    int64_t prefetch_bytes;

    struct demuxer *demuxer;
    int error;
};

struct prefetched_file {
    uint64_t playlist_entry_id;
    char *url;
    struct demuxer *demuxer;
    int error;
};

static void wakeup_demux(void *pctx)
{
    struct MPContext *mpctx = pctx;
    mp_wakeup_core(mpctx);
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
        .allow_playlist_create = mpctx->playlist->num_entries <= 1 &&
                                 !mpctx->playlist->playlist_dir,
    };
    open->demuxer =
        demux_open_url(open->url, &p, open->cancel, mpctx->global);

    if (open->demuxer) {
        MP_VERBOSE(mpctx, "Opening done: %s\n", open->url);

        if (open->start_prefetch && !open->demuxer->fully_read) {
            int num_streams = demux_get_num_stream(open->demuxer);
            for (int n = 0; n < num_streams; n++) {
                struct sh_stream *sh = demux_get_stream(open->demuxer, n);
                demuxer_select_track(open->demuxer, sh, MP_NOPTS_VALUE, true);
            }

            demux_set_prefetch_limits(open->demuxer, open->prefetch_secs,
                                      open->prefetch_bytes);
            demux_set_wakeup_cb(open->demuxer, wakeup_demux, mpctx);
            demux_start_thread(open->demuxer);
            demux_start_prefetch(open->demuxer);
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

    mp_cancel_trigger(open->cancel);
    if (open->active)
        mp_thread_join(open->thread);
    if (open->demuxer)
        demux_cancel_and_free(open->demuxer);

    mpctx->open = NULL;
    talloc_free(open);
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

    struct async_open *open = talloc_zero(mpctx, struct async_open);
    open->mpctx = mpctx;
    open->cancel = mp_cancel_new(open);
    open->url = talloc_strdup(open, url);
    open->format = talloc_strdup(open, mpctx->opts->demuxer_name);
    open->url_flags = url_flags;
    open->playlist_entry_id = entry ? entry->id : 0;
    open->for_prefetch = for_prefetch;
    open->start_prefetch = for_prefetch && mpctx->opts->demuxer_thread;
    open->prefetch_secs = mpctx->opts->prefetch_open_secs;
    open->prefetch_bytes = mpctx->opts->prefetch_open_bytes;
    atomic_init(&open->done, false);

    mpctx->open = open;
    if (mp_thread_create(&open->thread, open_demux_thread, open)) {
        destroy_open(mpctx);
        return false;
    }

    open->active = true;
    return true;
}

static void clear_prefetched_files(struct MPContext *mpctx)
{
    for (int n = 0; n < mpctx->num_prefetched_files; n++) {
        struct prefetched_file *file = &mpctx->prefetched_files[n];
        if (file->demuxer)
            demux_cancel_and_free(file->demuxer);
        talloc_free(file->url);
    }

    talloc_free(mpctx->prefetched_files);
    mpctx->prefetched_files = NULL;
    mpctx->num_prefetched_files = 0;
}

void cancel_open(struct MPContext *mpctx)
{
    destroy_open(mpctx);
    clear_prefetched_files(mpctx);
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
        .error = open->error,
    };
    if (file.demuxer)
        mp_cancel_set_parent(file.demuxer->cancel, NULL);
    open->url = NULL;
    open->demuxer = NULL;
    MP_TARRAY_APPEND(mpctx, mpctx->prefetched_files,
                     mpctx->num_prefetched_files, file);
    talloc_free(open);
}

static int find_prefetched_file(struct MPContext *mpctx,
                                struct playlist_entry *entry, char *url)
{
    for (int n = 0; n < mpctx->num_prefetched_files; n++) {
        struct prefetched_file *file = &mpctx->prefetched_files[n];
        if (file->playlist_entry_id == entry->id &&
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
    return file;
}

static bool open_matches(struct async_open *open,
                         struct playlist_entry *entry, char *url)
{
    return open->playlist_entry_id == entry->id &&
           strcmp(open->url, url) == 0;
}

static void adopt_demuxer(struct MPContext *mpctx, struct demuxer *demuxer)
{
    mpctx->demuxer = demuxer;
    demux_set_prefetch_limits(demuxer, 0, 0);
    mp_cancel_set_parent(demuxer->cancel, mpctx->playback_abort);
}

void open_demux_reentrant(struct MPContext *mpctx)
{
    char *url = mpctx->stream_open_filename;
    struct playlist_entry *entry = mpctx->playing;

    if (mpctx->demuxer_changed) {
        bool done = mpctx->open && atomic_load(&mpctx->open->done);
        if (mpctx->open || mpctx->num_prefetched_files) {
            MP_VERBOSE(mpctx, "%s prefetch because demuxer options changed.\n",
                       done ? "Dropping finished" : "Aborting ongoing");
        }
        cancel_open(mpctx);
        mpctx->demuxer_changed = false;
    }

    store_finished_prefetch(mpctx);

    int index = find_prefetched_file(mpctx, entry, url);
    if (index >= 0) {
        bool out_of_order = index > 0;
        struct prefetched_file file = take_prefetched_file(mpctx, index);

        if (out_of_order) {
            destroy_open(mpctx);
            clear_prefetched_files(mpctx);
        }

        if (file.demuxer) {
            MP_VERBOSE(mpctx, "Using prefetched URL.\n");
            adopt_demuxer(mpctx, file.demuxer);
            talloc_free(file.url);
            return;
        }

        MP_VERBOSE(mpctx, "Prefetched URL failed, retrying.\n");
        talloc_free(file.url);
        destroy_open(mpctx);
    }

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
            clear_prefetched_files(mpctx);
        }
    }

    if (!mpctx->open)
        start_open(mpctx, entry, url, entry->stream_flags, false);

    if (mpctx->open)
        mp_cancel_set_parent(mpctx->open->cancel, mpctx->playback_abort);

    // If the thread failed to start, cancel the playback.
    if (!mpctx->open)
        return;

    while (!atomic_load(&mpctx->open->done)) {
        mp_idle(mpctx);

        if (mpctx->stop_play)
            mp_abort_playback_async(mpctx);
    }

    struct async_open *open = take_finished_open(mpctx);
    if (open->demuxer) {
        adopt_demuxer(mpctx, open->demuxer);
        open->demuxer = NULL;
    } else {
        mpctx->error_playing = open->error;
    }
    talloc_free(open);
}

static bool is_prefetched(struct MPContext *mpctx,
                          struct playlist_entry *entry)
{
    if (mpctx->open && mpctx->open->playlist_entry_id == entry->id)
        return true;

    for (int n = 0; n < mpctx->num_prefetched_files; n++) {
        if (mpctx->prefetched_files[n].playlist_entry_id == entry->id)
            return true;
    }
    return false;
}

static bool id_in_prefetch_window(struct MPContext *mpctx, uint64_t id)
{
    int max = mpctx->opts->prefetch_open_max;
    struct playlist_entry *entry = mp_next_file(mpctx, +1, false, false);
    for (int n = 0; entry && n < max; n++) {
        if (entry == mpctx->playing)
            break;
        if (entry->id == id)
            return true;
        entry = playlist_entry_get_rel(entry, 1);
    }
    return false;
}

static void free_prefetched_at(struct MPContext *mpctx, int index)
{
    struct prefetched_file *file = &mpctx->prefetched_files[index];
    if (file->demuxer)
        demux_cancel_and_free(file->demuxer);
    talloc_free(file->url);
    MP_TARRAY_REMOVE_AT(mpctx->prefetched_files,
                        mpctx->num_prefetched_files, index);
}

static void drop_stale_prefetches(struct MPContext *mpctx)
{
    if (mpctx->open && mpctx->open->for_prefetch &&
        !id_in_prefetch_window(mpctx, mpctx->open->playlist_entry_id))
    {
        MP_VERBOSE(mpctx, "Aborting prefetch outside playlist next.\n");
        destroy_open(mpctx);
    }

    for (int n = mpctx->num_prefetched_files - 1; n >= 0; n--) {
        uint64_t id = mpctx->prefetched_files[n].playlist_entry_id;
        if (id_in_prefetch_window(mpctx, id))
            continue;
        MP_VERBOSE(mpctx, "Dropping stale prefetched URL.\n");
        free_prefetched_at(mpctx, n);
    }
}

void prefetch_next(struct MPContext *mpctx)
{
    if (mpctx->demuxer_changed) {
        cancel_open(mpctx);
        mpctx->demuxer_changed = false;
    }

    if (!mpctx->opts->prefetch_open) {
        cancel_open(mpctx);
        return;
    }

    store_finished_prefetch(mpctx);
    drop_stale_prefetches(mpctx);
    if (mpctx->open)
        return;

    int max = mpctx->opts->prefetch_open_max;
    if (mpctx->num_prefetched_files >= max)
        return;

    struct playlist_entry *entry = mp_next_file(mpctx, +1, false, false);
    for (int n = 0; entry && n < max; n++) {
        if (entry == mpctx->playing)
            break;
        if (entry->filename && !is_prefetched(mpctx, entry)) {
            MP_VERBOSE(mpctx, "Prefetching: %s\n", entry->filename);
            start_open(mpctx, entry, entry->filename, entry->stream_flags, true);
            return;
        }
        entry = playlist_entry_get_rel(entry, 1);
    }
}
