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

#include <string.h>

#include "mpv_talloc.h"

#include "common/common.h"
#include "common/msg.h"
#include "common/playlist.h"
#include "demux/demux.h"
#include "misc/dispatch.h"
#include "misc/path_utils.h"
#include "misc/thread_pool.h"
#include "misc/thread_tools.h"
#include "options/m_config.h"
#include "options/options.h"

#include "client.h"
#include "command.h"
#include "core.h"

struct autocreate_job {
    struct MPContext *mpctx;
    char *filename;
    uint64_t playing_id;
    struct mp_cancel *cancel;
    struct playlist *pl;
};

static void autocreate_finish(void *p)
{
    struct autocreate_job *job = p;
    struct MPContext *mpctx = job->mpctx;
    bool drop = mpctx->autocreate != job ||
                !mpctx->playing ||
                mpctx->playing->id != job->playing_id ||
                mp_cancel_test(job->cancel) ||
                !job->pl ||
                mpctx->playlist->num_entries != 1;

    if (mpctx->autocreate == job)
        mpctx->autocreate = NULL;

    if (!drop) {
        struct playlist_entry *current = mpctx->playing;
        struct playlist *pl = mpctx->playlist;
        struct playlist_entry *after = playlist_entry_get_rel(current, 1);
        int cur_in_scan = -1;

        for (int n = 0; n < job->pl->num_entries; n++) {
            if (strcmp(job->pl->entries[n]->filename, current->filename) == 0) {
                cur_in_scan = n;
                break;
            }
        }

        int before = cur_in_scan >= 0 ? cur_in_scan : 0;
        int first_after = cur_in_scan >= 0 ? cur_in_scan + 1 : 0;
        for (int n = 0; n < before; n++) {
            struct playlist_entry *e =
                playlist_entry_new(job->pl->entries[n]->filename);
            e->stream_flags = current->stream_flags;
            if (mpctx->opts->playlist_inherit_options == 1) {
                playlist_entry_add_params(e, current->params,
                                          current->num_params);
            }
            playlist_insert_at(pl, e, current);
        }
        for (int n = first_after; n < job->pl->num_entries; n++) {
            struct playlist_entry *e =
                playlist_entry_new(job->pl->entries[n]->filename);
            e->stream_flags = current->stream_flags;
            if (mpctx->opts->playlist_inherit_options == 1) {
                playlist_entry_add_params(e, current->params,
                                          current->num_params);
            }
            playlist_insert_at(pl, e, after);
        }

        if (job->pl->playlist_dir && !pl->playlist_dir) {
            pl->playlist_dir =
                talloc_strdup(pl, job->pl->playlist_dir);
        }
        playlist_populate_playlist_path(pl, mpctx->filename);
        pl->current = current;

        if (mpctx->opts->shuffle)
            playlist_shuffle(pl);

        MP_VERBOSE(mpctx, "Autocreate playlist: %d siblings.\n",
                   pl->num_entries);
        mp_notify(mpctx, MP_EVENT_CHANGE_PLAYLIST, NULL);
        mp_notify_property(mpctx, "playlist");
        prefetch_next(mpctx);
    }

    talloc_free(job->pl);
    talloc_free(job);
    mpctx->outstanding_async -= 1;
    if (!mpctx->outstanding_async && mp_is_shutting_down(mpctx))
        mp_wakeup_core(mpctx);
}

static void autocreate_thread(void *p)
{
    struct autocreate_job *job = p;

    job->pl = playlist_autocreate_siblings(job->filename, job->cancel,
                                           job->mpctx->global);
    mp_dispatch_enqueue(job->mpctx->dispatch, autocreate_finish, job);
}

void mp_cancel_autocreate_playlist(struct MPContext *mpctx)
{
    if (!mpctx->autocreate)
        return;
    mp_cancel_trigger(mpctx->autocreate->cancel);
}

void mp_start_autocreate_playlist(struct MPContext *mpctx)
{
    mp_cancel_autocreate_playlist(mpctx);

    if (!mpctx->playing || !mpctx->filename)
        return;
    if (mpctx->playlist->num_entries > 1 || mpctx->playlist->playlist_dir)
        return;
    if (mp_is_url(bstr0(mpctx->filename)) || strcmp(mpctx->filename, "-") == 0)
        return;

    struct demux_opts *dopts =
        mp_get_config_group(NULL, mpctx->global, &demux_conf);
    int mode = dopts->autocreate_playlist;
    talloc_free(dopts);
    if (mode == 0)
        return;

    struct autocreate_job *job = talloc_zero(NULL, struct autocreate_job);
    job->mpctx = mpctx;
    job->filename = talloc_strdup(job, mpctx->filename);
    job->playing_id = mpctx->playing->id;
    job->cancel = mp_cancel_new(job);

    mpctx->autocreate = job;
    mpctx->outstanding_async += 1;
    if (!mp_thread_pool_queue(mpctx->thread_pool, autocreate_thread, job)) {
        mpctx->autocreate = NULL;
        mpctx->outstanding_async -= 1;
        talloc_free(job);
    }
}
