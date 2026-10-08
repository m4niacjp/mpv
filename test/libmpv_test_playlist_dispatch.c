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
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with mpv. If not, see <http://www.gnu.org/licenses/>.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <mpv/stream_cb.h>

#include "osdep/threads.h"
#include "osdep/timer.h"

#include "libmpv_common.h"

#define NUM_STREAMS 11
#define NUM_SLOW 5

static struct {
    mp_mutex lock;
    mp_cond cond;
    bool release;
    bool stop_events;
    int opened[NUM_STREAMS];
    int blocked;
    int closed_slow;
    int closed_total;
    int loaded;
    int replies;
    int retirement_waits;
    int max_retired;
    int adopted;
} state;

struct stream_cookie {
    int id;
    int64_t pos;
};

static int64_t read_stream(void *p, char *buf, uint64_t size)
{
    struct stream_cookie *cookie = p;
    if (cookie->id > 0 && cookie->id <= NUM_SLOW) {
        mp_mutex_lock(&state.lock);
        state.blocked++;
        mp_cond_broadcast(&state.cond);
        while (!state.release)
            mp_cond_wait(&state.cond, &state.lock);
        mp_mutex_unlock(&state.lock);
        return 0;
    }
    size = size < 65536 ? size : 65536;
    memset(buf, 0, size);
    cookie->pos += size;
    return size;
}

static int64_t seek_stream(void *p, int64_t pos)
{
    struct stream_cookie *cookie = p;
    cookie->pos = pos;
    return pos;
}

static int64_t size_stream(void *p)
{
    return 1024 * 1024 * 1024;
}

static void close_stream(void *p)
{
    struct stream_cookie *cookie = p;
    mp_mutex_lock(&state.lock);
    state.closed_total++;
    if (cookie->id > 0 && cookie->id <= NUM_SLOW)
        state.closed_slow++;
    mp_cond_broadcast(&state.cond);
    mp_mutex_unlock(&state.lock);
    free(cookie);
}

static int open_stream(void *p, char *uri, mpv_stream_cb_info *info)
{
    int id = -1;
    if (sscanf(uri, "slowraw://%d", &id) != 1 ||
        id < 0 || id >= NUM_STREAMS)
    {
        return MPV_ERROR_LOADING_FAILED;
    }
    struct stream_cookie *cookie = calloc(1, sizeof(*cookie));
    if (!cookie)
        return MPV_ERROR_NOMEM;
    cookie->id = id;
    *info = (mpv_stream_cb_info) {
        .cookie = cookie,
        .read_fn = read_stream,
        .seek_fn = seek_stream,
        .size_fn = size_stream,
        .close_fn = close_stream,
        // Optional cancel_fn is deliberately absent: the pending read models
        // filesystem I/O which cancellation cannot immediately interrupt.
    };
    mp_mutex_lock(&state.lock);
    state.opened[id]++;
    mp_cond_broadcast(&state.cond);
    mp_mutex_unlock(&state.lock);
    return 0;
}

static MP_THREAD_VOID collect_events(void *p)
{
    for (;;) {
        mpv_event *event = mpv_wait_event(ctx, 0.1);
        mp_mutex_lock(&state.lock);
        if (event->event_id == MPV_EVENT_FILE_LOADED)
            state.loaded++;
        if (event->event_id == MPV_EVENT_COMMAND_REPLY) {
            if (event->error < 0)
                fail("asynchronous playlist command failed\n");
            state.replies++;
        }
        if (event->event_id == MPV_EVENT_LOG_MESSAGE) {
            mpv_event_log_message *msg = event->data;
            printf("[%s:%s] %s", msg->prefix, msg->level, msg->text);
            if (msg->log_level <= MPV_LOG_LEVEL_ERROR)
                fail("error was logged\n");
            state.retirement_waits +=
                strstr(msg->text, "Demux cleanup limit reached;") != NULL;
            state.adopted += strstr(msg->text, "Using prefetched URL.") != NULL ||
                             strstr(msg->text, "Using prefetched/prefetching URL.") != NULL;
            int retired = 0;
            if (sscanf(msg->text, "Demux cleanup queued (%d pending)", &retired) == 1) {
                if (retired > 2)
                    fail("retirement pool exceeded its two-slot bound\n");
                state.max_retired = MPMAX(state.max_retired, retired);
            }
        }
        mp_cond_broadcast(&state.cond);
        bool stop = state.stop_events;
        mp_mutex_unlock(&state.lock);
        if (stop)
            MP_THREAD_RETURN();
    }
}

static void wait_count(int *value, int minimum, const char *description)
{
    int64_t deadline = mp_time_ns() + MP_TIME_S_TO_NS(10);
    mp_mutex_lock(&state.lock);
    while (*value < minimum) {
        if (mp_cond_timedwait_until(&state.cond, &state.lock, deadline))
            fail("timed out waiting for %s (%d/%d)\n", description, *value, minimum);
    }
    mp_mutex_unlock(&state.lock);
}

int main(int argc, char **argv)
{
    if (argc != 2 || (strcmp(argv[1], "sync") &&
                     strcmp(argv[1], "async") && strcmp(argv[1], "disable")))
    {
        fail("expected sync, async, or disable\n");
    }
    bool async = strcmp(argv[1], "sync") != 0;
    bool disable = strcmp(argv[1], "disable") == 0;
    mp_time_init();
#ifdef _WIN32
    // A regression should fail at the original assertion without a modal UI.
    _set_error_mode(_OUT_TO_STDERR);
    _set_abort_behavior(0, _WRITE_ABORT_MSG | _CALL_REPORTFAULT);
#endif
    mp_mutex_init(&state.lock);
    mp_cond_init(&state.cond);
    ctx = mpv_create();
    if (!ctx)
        fail("could not create mpv\n");
    set_property_string("config", "no");
    set_property_string("load-scripts", "no");
    set_property_string("autocreate-playlist", "no");
    set_property_string("demuxer", "+rawaudio");
    set_property_string("pause", "yes");
    set_property_string("cache-pause", "no");
    set_property_string("demuxer-readahead-secs", "30");
    set_property_string("demuxer-max-bytes", "4MiB");
    set_property_string("demuxer-max-back-bytes", "0");
    set_property_string("prefetch-playlist", "yes");
    set_property_string("prefetch-playlist-render", "no");
    set_property_string("prefetch-playlist-max", "5");
    set_property_string("prefetch-playlist-history", "0");
    set_property_string("prefetch-playlist-realtime", "yes");
    set_property_string("prefetch-playlist-on-cache", "no");
    set_property_string("prefetch-playlist-start-secs", "0");
    set_property_string("prefetch-playlist-start-bytes", "0");
    set_property_string("prefetch-playlist-cache-secs", "30");
    set_property_string("prefetch-playlist-cache-bytes", "4MiB");
    initialize();
    if (mpv_stream_cb_add_ro(ctx, "slowraw", NULL, open_stream) < 0)
        fail("could not register the controlled stream\n");
    mp_thread events;
    if (mp_thread_create(&events, collect_events, NULL))
        fail("could not start event collector\n");

    for (int id = 0; id < NUM_STREAMS; id++) {
        char uri[32];
        snprintf(uri, sizeof(uri), "slowraw://%d", id);
        const char *append[] = {"loadfile", uri, "append", NULL};
        command(append);
    }
    const char *play[] = {"playlist-play-index", "0", NULL};
    command(play);
    wait_count(&state.loaded, 1, "current file");
    wait_count(&state.blocked, NUM_SLOW, "five pending speculative reads");
    check_int("prefetched-count", NUM_SLOW);
    set_property_string("prefetch-playlist-realtime", "no");

    const char *reorder[] = {
        "playlist-reorder", "0,6,7,8,9,10,1,2,3,4,5", NULL,
    };
    if (async) {
        if (mpv_command_async(ctx, 1, reorder) < 0)
            fail("could not submit asynchronous reorder\n");
        wait_count(&state.replies, 1, "asynchronous reorder completion");
    } else {
        command(reorder);
    }
    wait_count(&state.retirement_waits, 1, "saturated retirement pool");
    mp_mutex_lock(&state.lock);
    if (state.closed_slow || state.max_retired != 2)
        fail("the controlled reads did not keep both retirement slots occupied\n");
    mp_mutex_unlock(&state.lock);

    // A second request arrives while reconciliation yields in mp_idle().
    // With realtime disabled, losing this request would leave the next entry
    // unprefetched (or leave caches alive after disabling prefetch).
    if (disable)
        set_property_string("prefetch-playlist", "no");
    const char *second[] = {
        "playlist-reorder", "0,5,4,3,2,1,6,7,8,9,10", NULL,
    };
    command(second);
    mp_mutex_lock(&state.lock);
    state.release = true;
    mp_cond_broadcast(&state.cond);
    mp_mutex_unlock(&state.lock);
    wait_count(&state.closed_slow, NUM_SLOW, "all speculative cleanup");

    if (!disable) {
        wait_count(&state.opened[10], 1, "new nearest-next prefetch");
        const char *next[] = {"playlist-next", NULL};
        command(next);
        wait_count(&state.loaded, 2, "adopted next entry");
        wait_count(&state.adopted, 1, "prefetched demuxer adoption");
        check_int("playlist-playing-pos", 1);
        mp_mutex_lock(&state.lock);
        if (state.opened[10] != 1)
            fail("nearest-next demuxer was reopened\n");
        mp_mutex_unlock(&state.lock);
    } else {
        check_int("prefetched-count", 0);
        check_flag("prefetch-active", 0);
    }
    command_string("stop");
    mp_mutex_lock(&state.lock);
    state.stop_events = true;
    mp_mutex_unlock(&state.lock);
    mpv_wakeup(ctx);
    mp_thread_join(events);
    exit_cleanup();
    int total = 0;
    for (int id = 0; id < NUM_STREAMS; id++)
        total += state.opened[id];
    if (state.closed_total != total)
        fail("stream resources survived termination (%d/%d closed)\n",
             state.closed_total, total);
    if (disable) {
        for (int id = NUM_SLOW + 1; id < NUM_STREAMS; id++) {
            if (state.opened[id])
                fail("replacement stream %d opened after prefetch was disabled\n", id);
        }
    }
    mp_cond_destroy(&state.cond);
    mp_mutex_destroy(&state.lock);
    printf("playlist dispatch (%s): cleanup bounded, requests preserved\n", argv[1]);
    return 0;
}
