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

#include <errno.h>
#include <math.h>
#ifdef _WIN32
#include <direct.h>
#include <process.h>
#define mp_mkdir(path) _mkdir(path)
#define mp_getpid() _getpid()
#else
#include <sys/stat.h>
#include <unistd.h>
#define mp_mkdir(path) mkdir((path), 0700)
#define mp_getpid() getpid()
#endif

#include "libmpv_common.h"

static char directory[128];
static char paths[3][160];
static uint64_t ids[3];
static void *identities[3];
static int opens[3];
static int cached_prepares;
static int reset_prepares;
static int retained_count;
static int max_retired;
static bool require_same_identity;
static double first_frame_pts[3];
static bool have_first_frame[3];

static void cleanup(void)
{
    if (ctx)
        exit_cleanup();
    for (int n = 0; n < 3; n++)
        remove(paths[n]);
#ifdef _WIN32
    _rmdir(directory);
#else
    rmdir(directory);
#endif
}

static void process_event(mpv_event *event)
{
    if (event->event_id != MPV_EVENT_LOG_MESSAGE)
        return;
    mpv_event_log_message *msg = event->data;
    printf("[%s:%s] %s", msg->prefix, msg->level, msg->text);
    if (msg->log_level <= MPV_LOG_LEVEL_ERROR)
        fail("error was logged\n");
    for (int n = 0; n < 3; n++) {
        const char *basename = paths[n] + strlen(directory) + 1;
        if (strstr(msg->text, "Opening done:") && strstr(msg->text, basename))
            opens[n]++;
    }
    void *identity = NULL;
    uint64_t id = 0;
    if (sscanf(msg->text, "Adopted demuxer %p for entry %" SCNu64,
               &identity, &id) == 2)
    {
        for (int n = 0; n < 3; n++) {
            if (ids[n] != id)
                continue;
            if (require_same_identity && identities[n] && identities[n] != identity)
                fail("entry %d was reopened instead of reusing its demuxer\n", n);
            identities[n] = identity;
        }
    }
    if (strstr(msg->text, "Preparing retained beginning")) {
        cached_prepares += strstr(msg->text, "cached=1") != NULL;
        reset_prepares += strstr(msg->text, "cached=0") != NULL;
    }
    retained_count += strstr(msg->text, "Retained demuxer") != NULL;
    int retired = 0;
    if (sscanf(msg->text, "Demux cleanup queued (%d pending)", &retired) == 1) {
        max_retired = retired > max_retired ? retired : max_retired;
        if (retired > 2)
            fail("unbounded retirement queue: %d\n", retired);
    }
}

static void drain_events(double timeout)
{
    for (;;) {
        mpv_event *event = mpv_wait_event(ctx, timeout);
        if (event->event_id == MPV_EVENT_NONE)
            return;
        process_event(event);
    }
}

static void wait_for_frame(void)
{
    bool loaded = false;
    for (;;) {
        mpv_event *event = mpv_wait_event(ctx, 5);
        if (event->event_id == MPV_EVENT_NONE)
            fail("timed out waiting for the first frame\n");
        process_event(event);
        loaded |= event->event_id == MPV_EVENT_FILE_LOADED;
        if (loaded && event->event_id == MPV_EVENT_PLAYBACK_RESTART)
            return;
    }
}

static void expect_beginning(int index)
{
    check_int("playlist-playing-pos", index);
    double pts = -1;
    get_property("time-pos", MPV_FORMAT_DOUBLE, &pts);
    if (!isfinite(pts) || fabs(pts) > 0.1)
        fail("entry %d did not restart at beginning: %.6f\n", index, pts);
    if (have_first_frame[index]) {
        if (fabs(pts - first_frame_pts[index]) > 0.001)
            fail("entry %d first frame changed from %.6f to %.6f\n",
                 index, first_frame_pts[index], pts);
    } else {
        first_frame_pts[index] = pts;
        have_first_frame[index] = true;
    }
}

static void navigate(const char *name, int index)
{
    const char *cmd[] = {name, NULL};
    command(cmd);
    wait_for_frame();
    expect_beginning(index);
}

static void setup_case(const char *history, const char *budget)
{
    require_same_identity = false;
    command_string("stop");
    drain_events(0.1);
    memset(identities, 0, sizeof(identities));
    memset(opens, 0, sizeof(opens));
    memset(have_first_frame, 0, sizeof(have_first_frame));
    set_property_string("demuxer", "");
    set_property_string("vid", "auto");
    set_property_string("aid", "auto");
    set_property_string("prefetch-playlist", "yes");
    set_property_string("prefetch-playlist-history", history);
    set_property_string("prefetch-playlist-max", "1");
    set_property_string("prefetch-playlist-realtime", "yes");
    set_property_string("prefetch-playlist-cache-secs", "10");
    set_property_string("prefetch-playlist-cache-bytes", budget);
    set_property_string("prefetch-playlist-start-secs", "0");
    set_property_string("prefetch-playlist-start-bytes", "0");
    set_property_string("demuxer-max-bytes", "8MiB");
    set_property_string("demuxer-max-back-bytes", "4GiB");
    set_property_string("cache", "yes");
    set_property_string("demuxer-seekable-cache", "yes");
    set_property_string("pause", "yes");
    for (int n = 0; n < 3; n++) {
        const char *cmd[] = {"loadfile", paths[n], "append", NULL};
        command(cmd);
        char property[32];
        snprintf(property, sizeof(property), "playlist/%d/id", n);
        int64_t id;
        get_property(property, MPV_FORMAT_INT64, &id);
        ids[n] = id;
    }
    require_same_identity = true;
    command_string("playlist-play-index 0");
    wait_for_frame();
    expect_beginning(0);
    drain_events(0.2);
}

static void test_reuse(bool reset)
{
    int before = reset ? reset_prepares : cached_prepares;
    setup_case("1", reset ? "64KiB" : "32MiB");
    command_string("seek 0.8 absolute+exact");
    for (;;) {
        mpv_event *event = mpv_wait_event(ctx, 5);
        if (event->event_id == MPV_EVENT_NONE)
            fail("timed out waiting for seek\n");
        process_event(event);
        if (event->event_id == MPV_EVENT_PLAYBACK_RESTART)
            break;
    }
    drain_events(0.2);
    navigate("playlist-next", 1);
    navigate("playlist-prev", 0);
    navigate("playlist-next", 1);
    for (int n = 0; n < 5; n++) {
        navigate("playlist-prev", 0);
        navigate("playlist-next", 1);
    }
    drain_events(0.2);
    if (!identities[0] || !identities[1] || opens[0] != 1 || opens[1] != 1)
        fail("A/B were not opened exactly once (%d/%d)\n", opens[0], opens[1]);
    if ((reset ? reset_prepares : cached_prepares) <= before)
        fail("expected %s preparation was not exercised\n", reset ? "reset" : "cached");
}

static void test_two_history(void)
{
    setup_case("2", "32MiB");
    navigate("playlist-next", 1);
    navigate("playlist-next", 2);
    navigate("playlist-prev", 1);
    navigate("playlist-prev", 0);
    navigate("playlist-next", 1);
}

static void test_disabled(void)
{
    setup_case("0", "32MiB");
    require_same_identity = false;
    int before = retained_count;
    navigate("playlist-next", 1);
    navigate("playlist-prev", 0);
    drain_events(0.2);
    if (retained_count != before || opens[0] != 2)
        fail("history=0 did not preserve ordinary disposal\n");
}

static void test_invalidation(const char *name, const char *value)
{
    setup_case("1", "32MiB");
    require_same_identity = false;
    set_property_string(name, value);
    drain_events(0.2); // allow prefetch_next to consume UPDATE_DEMUXER
    navigate("playlist-next", 1);
    navigate("playlist-prev", 0);
    drain_events(0.2);
    if (opens[0] != 2)
        fail("%s change reused the old current instance\n", name);
}

static void test_prefetch_gating(void)
{
    setup_case("1", "32MiB");
    set_property_string("prefetch-playlist", "no");
    drain_events(0.1);
    set_property_string("prefetch-playlist", "yes");
    drain_events(0.2);
    navigate("playlist-next", 1);
    navigate("playlist-prev", 0);
    navigate("playlist-next", 1);
    drain_events(0.2);
    if (opens[0] != 1)
        fail("prefetch gating invalidated the current demuxer\n");
}

int main(int argc, char **argv)
{
    if (argc != 2)
        return 1;
    snprintf(directory, sizeof(directory), "mpv-rolling-%d", (int)mp_getpid());
    if (mp_mkdir(directory) != 0 && errno != EEXIST)
        return 1;
    for (int n = 0; n < 3; n++) {
        snprintf(paths[n], sizeof(paths[n]), "%s/%c.mkv", directory, 'a' + n);
        FILE *in = fopen(argv[1], "rb");
        FILE *out = fopen(paths[n], "wb");
        if (!in || !out)
            return 1;
        char buf[4096];
        size_t size;
        while ((size = fread(buf, 1, sizeof(buf), in))) {
            if (fwrite(buf, 1, size, out) != size)
                return 1;
        }
        fclose(in);
        fclose(out);
    }
    atexit(cleanup);
    ctx = mpv_create();
    if (!ctx)
        return 1;
    set_property_string("idle", "yes");
    initialize();
    check_int("prefetch-playlist-history", 0);
    printf("================ HISTORY DISABLED ================\n");
    test_disabled();
    printf("================ CACHED BEGINNING ================\n");
    test_reuse(false);
    printf("================ RESET BEGINNING ================\n");
    test_reuse(true);
    printf("================ TWO HISTORY ENTRIES ================\n");
    test_two_history();
    printf("================ PREFETCH GATING ================\n");
    test_prefetch_gating();
    printf("================ OPTIONS INVALIDATION ================\n");
    test_invalidation("demuxer", "lavf");
    test_invalidation("vid", "1");
    test_invalidation("aid", "no");
    if (!retained_count || max_retired > 2)
        fail("retention/retirement paths were not valid\n");
    command_string("quit");
    for (;;) {
        mpv_event *event = mpv_wait_event(ctx, 5);
        if (event->event_id == MPV_EVENT_NONE)
            fail("timed out waiting for quit\n");
        process_event(event);
        if (event->event_id == MPV_EVENT_SHUTDOWN)
            break;
    }
    return 0;
}
