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

#include <errno.h>
#include <stdio.h>
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

static int prefetch_count;
static int opening_done_count;
static int using_prefetched_count;
static int start_window_ready_count;
static int autocreate_count;

static void process_event(mpv_event *event)
{
    if (event->event_id != MPV_EVENT_LOG_MESSAGE)
        return;

    mpv_event_log_message *msg = event->data;
    printf("[%s:%s] %s", msg->prefix, msg->level, msg->text);
    if (msg->log_level <= MPV_LOG_LEVEL_ERROR)
        fail("error was logged");
    if (strstr(msg->text, "Prefetching:"))
        prefetch_count++;
    if (strstr(msg->text, "Opening done:"))
        opening_done_count++;
    if (strstr(msg->text, "Using prefetched URL"))
        using_prefetched_count++;
    if (strstr(msg->text, "Prefetch start window ready."))
        start_window_ready_count++;
    if (strstr(msg->text, "Autocreate playlist:"))
        autocreate_count++;
}

static void append_file(const char *file)
{
    const char *cmd[] = {"loadfile", file, "append", NULL};
    command(cmd);
}

static void wait_for_file_loaded(void)
{
    while (1) {
        mpv_event *event = mpv_wait_event(ctx, 5);
        if (event->event_id == MPV_EVENT_NONE)
            fail("timed out waiting for the current file to load\n");
        process_event(event);
        if (event->event_id == MPV_EVENT_FILE_LOADED)
            return;
    }
}

static void drain_events(double timeout)
{
    while (1) {
        mpv_event *event = mpv_wait_event(ctx, timeout);
        if (event->event_id == MPV_EVENT_NONE)
            break;
        process_event(event);
    }
}

static void copy_file(const char *src, const char *dst)
{
    FILE *in = fopen(src, "rb");
    FILE *out = fopen(dst, "wb");
    if (!in || !out)
        fail("failed to copy '%s' to '%s'\n", src, dst);
    char buf[4096];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), in)) > 0) {
        if (fwrite(buf, 1, n, out) != n)
            fail("failed writing '%s'\n", dst);
    }
    fclose(in);
    fclose(out);
}

static void test_prefetch_realtime(const char *file)
{
    check_int("prefetch-playlist-max", 1);
    check_flag("prefetch-playlist-realtime", 0);
    set_property_string("prefetch-playlist", "yes");
    set_property_string("prefetch-playlist-max", "2");
    set_property_string("prefetch-playlist-start-secs", "0");
    set_property_string("prefetch-playlist-start-bytes", "0");
    set_property_string("pause", "yes");
    set_property_string("image-display-duration", "inf");

    append_file("av://lavfi:testsrc");
    for (int n = 0; n < 3; n++)
        append_file(file);

    const char *play[] = {"playlist-play-index", "0", NULL};
    command(play);
    wait_for_file_loaded();

    drain_events(1);

    if (prefetch_count)
        fail("prefetched before realtime mode was enabled\n");

    set_property_string("prefetch-playlist-realtime", "yes");

    while (prefetch_count < 2 || opening_done_count < 3) {
        mpv_event *event = mpv_wait_event(ctx, 5);
        if (event->event_id == MPV_EVENT_NONE)
            fail("timed out waiting for two completed prefetch opens\n");
        process_event(event);
    }

    check_int("playlist-playing-pos", 0);

    drain_events(1);

    if (prefetch_count != 2)
        fail("expected exactly two prefetched entries, got %d\n", prefetch_count);
}

static void test_prefetch_adopt(void)
{
    int opening_before = opening_done_count;
    const char *next[] = {"playlist-next", NULL};
    command(next);
    wait_for_file_loaded();
    drain_events(1);

    if (!using_prefetched_count)
        fail("playlist-next did not reuse a prefetched demuxer\n");
    if (opening_done_count != opening_before) {
        fail("playlist-next reopened the next URL (%d new Opening done)\n",
             opening_done_count - opening_before);
    }
}

static void test_prefetch_start_window(void)
{
    command_string("stop");
    drain_events(1);
    prefetch_count = 0;
    opening_done_count = 0;
    using_prefetched_count = 0;
    start_window_ready_count = 0;

    set_property_string("prefetch-playlist", "yes");
    set_property_string("prefetch-playlist-max", "2");
    set_property_string("prefetch-playlist-realtime", "yes");
    set_property_string("prefetch-playlist-start-secs", "3600");
    set_property_string("prefetch-playlist-start-bytes", "1GiB");
    set_property_string("pause", "yes");

    append_file("av://lavfi:testsrc=size=16x16:rate=1");
    append_file("av://lavfi:testsrc=size=16x16:rate=1");
    append_file("av://lavfi:testsrc=size=16x16:rate=1");

    const char *play[] = {"playlist-play-index", "0", NULL};
    command(play);
    wait_for_file_loaded();
    drain_events(1.5);

    if (prefetch_count < 1)
        fail("start-window did not prefetch the immediate next entry\n");
    if (prefetch_count > 1)
        fail("start-window opened extra entries too early (%d)\n", prefetch_count);
}

static void test_autocreate_playlist(const char *file)
{
    command_string("stop");
    drain_events(1);
    autocreate_count = 0;

    char dir[512], path_a[576], path_b[576];
    snprintf(dir, sizeof(dir), "mpv-ac-%d", (int)mp_getpid());
    if (mp_mkdir(dir) != 0 && errno != EEXIST)
        fail("failed to create temp dir '%s'\n", dir);
    snprintf(path_a, sizeof(path_a), "%s/a.png", dir);
    snprintf(path_b, sizeof(path_b), "%s/b.png", dir);
    copy_file(file, path_a);
    copy_file(file, path_b);

    set_property_string("autocreate-playlist", "filter");
    set_property_string("directory-filter-types", "image");
    set_property_string("directory-mode", "ignore");
    set_property_string("pause", "yes");
    set_property_string("image-display-duration", "inf");

    const char *cmd[] = {"loadfile", path_a, NULL};
    command(cmd);
    wait_for_file_loaded();

    int64_t count = 0;
    get_property("playlist-count", MPV_FORMAT_INT64, &count);
    while (count < 2) {
        mpv_event *event = mpv_wait_event(ctx, 5);
        if (event->event_id == MPV_EVENT_NONE)
            fail("timed out waiting for autocreate siblings\n");
        process_event(event);
        get_property("playlist-count", MPV_FORMAT_INT64, &count);
    }

    if (!autocreate_count)
        fail("missing autocreate playlist log\n");

    remove(path_a);
    remove(path_b);
#ifdef _WIN32
    _rmdir(dir);
#else
    rmdir(dir);
#endif
}

int main(int argc, char *argv[])
{
    if (argc != 2)
        return 1;

    ctx = mpv_create();
    if (!ctx)
        return 1;

    atexit(exit_cleanup);
    set_property_string("idle", "yes");
    initialize();

    printf("================ TEST: test_prefetch_realtime ================\n");
    test_prefetch_realtime(argv[1]);
    printf("================ TEST: test_prefetch_adopt ================\n");
    test_prefetch_adopt();
    printf("================ TEST: test_prefetch_start_window ================\n");
    test_prefetch_start_window();
    printf("================ TEST: test_autocreate_playlist ================\n");
    test_autocreate_playlist(argv[1]);
    printf("================ SHUTDOWN ================\n");

    command_string("quit");
    while (wrap_wait_event()->event_id != MPV_EVENT_SHUTDOWN) {}

    return 0;
}
