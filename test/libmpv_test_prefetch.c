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

#include "libmpv_common.h"

static int prefetch_count;
static int opening_done_count;

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

static void test_prefetch_realtime(const char *file)
{
    check_int("prefetch-playlist-max", 1);
    check_flag("prefetch-playlist-realtime", 0);
    set_property_string("prefetch-playlist", "yes");
    set_property_string("prefetch-playlist-max", "2");
    set_property_string("pause", "yes");
    set_property_string("image-display-duration", "inf");

    append_file("av://lavfi:testsrc");
    for (int n = 0; n < 3; n++)
        append_file(file);

    const char *play[] = {"playlist-play-index", "0", NULL};
    command(play);
    wait_for_file_loaded();

    while (1) {
        mpv_event *event = mpv_wait_event(ctx, 1);
        if (event->event_id == MPV_EVENT_NONE)
            break;
        process_event(event);
    }

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

    while (1) {
        mpv_event *event = mpv_wait_event(ctx, 1);
        if (event->event_id == MPV_EVENT_NONE)
            break;
        process_event(event);
    }

    if (prefetch_count != 2)
        fail("expected exactly two prefetched entries, got %d\n", prefetch_count);
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
    printf("================ SHUTDOWN ================\n");

    command_string("quit");
    while (wrap_wait_event()->event_id != MPV_EVENT_SHUTDOWN) {}

    return 0;
}
