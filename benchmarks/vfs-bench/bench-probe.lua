-- bench-probe.lua: in-process driver and recorder for the rclone-VFS benchmark.
--
-- Scenario: the first file plays `frames` frames, then the probe issues
-- `playlist-next`; the second file plays `frames` frames, then `quit`.
-- All timestamps are mp.get_time() (same clock as the mpv log file).
--
-- Options (--script-opts-append=benchprobe-<key>=<value>):
--   out        JSON result path (required)
--   frames     frames to play per file (default 300)
--   pipe       named pipe for clock anchoring (optional)
--   markerdir  directory for FileIO/Procmon correlation markers (optional)
--   trial      trial id used in marker names
--   timeout    hard safety quit after N seconds (default 180)

local mp = require "mp"
local utils = require "mp.utils"
local options = require "mp.options"

local o = { out = "", frames = 300, pipe = "", markerdir = "", trial = "t", timeout = 180 }
options.read_options(o, "benchprobe")

local t_load = mp.get_time()
local events, samples, playlists, props = {}, {}, {}, {}
local file_index, marker_seq = 0, 0
local next_sent, quit_sent = false, false
local next_attempts = 0
local pipe = nil
local done_frames = {}

local function now() return mp.get_time() end

local function pipe_send(line)
    if pipe then
        local ok = pcall(function() pipe:write(line .. "\n"); pipe:flush() end)
        if not ok then pipe = nil end
    end
end

local function marker(name)
    if o.markerdir == "" then return end
    marker_seq = marker_seq + 1
    -- A stat of a nonexistent, uniquely named path: visible as a NAME NOT FOUND
    -- CreateFile in ETW FileIO and Procmon, on this process, at this instant.
    utils.file_info(string.format("%s\\%s-%02d-%s.mark", o.markerdir, o.trial, marker_seq, name))
end

local function ev(name, detail)
    local t = now()
    events[#events + 1] = { t = t, name = name, file = file_index, detail = detail }
    pipe_send(string.format("%.6f %s", t, name))
    marker(name)
    return t
end

local function snapshot_playlist(tag)
    local pl = mp.get_property_native("playlist") or {}
    local entries = {}
    for i, e in ipairs(pl) do
        local fn = e.filename or ""
        entries[#entries + 1] = {
            index = i - 1, name = fn:match("[^\\/]+$") or fn,
            current = e.current or false, playing = e.playing or false,
            prefetched = mp.get_property_native("playlist/" .. (i - 1) .. "/prefetched") or false,
        }
    end
    playlists[#playlists + 1] = { t = now(), tag = tag, file = file_index,
        pos = mp.get_property_native("playlist-pos"), count = #pl, entries = entries }
end

local function cache_state()
    local s = mp.get_property_native("demuxer-cache-state") or {}
    return { fw = s["fw-bytes"], total = s["total-bytes"], file = s["file-cache-bytes"],
        cend = s["cache-end"], eof = s["eof"], underrun = s["underrun"], idle = s["idle"],
        rate = s["raw-input-rate"], dur = s["cache-duration"] }
end

local function sample()
    samples[#samples + 1] = {
        t = now(), file = file_index,
        frame = mp.get_property_native("estimated-frame-number"),
        cache = cache_state(),
        cache_speed = mp.get_property_native("cache-speed"),
        prefetch_active = mp.get_property_native("prefetch-active"),
        prefetched_count = mp.get_property_native("prefetched-count"),
        playlist_count = mp.get_property_native("playlist-count"),
        drops = mp.get_property_native("frame-drop-count"),
        dec_drops = mp.get_property_native("decoder-frame-drop-count"),
        delayed = mp.get_property_native("vo-delayed-frame-count"),
        mistimed = mp.get_property_native("mistimed-frame-count"),
        paused_for_cache = mp.get_property_native("paused-for-cache"),
    }
end

local function file_props(tag)
    props[#props + 1] = { t = now(), tag = tag, file = file_index,
        path = mp.get_property("path"), hwdec = mp.get_property("hwdec-current"),
        vo = mp.get_property("current-vo"), vf = mp.get_property_native("vf"),
        video = mp.get_property_native("video-params"), fps = mp.get_property_native("container-fps"),
        display_fps = mp.get_property_native("display-fps"), demuxer = mp.get_property("current-demuxer"),
        cache_opt = mp.get_property("options/cache"), max_bytes = mp.get_property("options/demuxer-max-bytes"),
        prefetch = mp.get_property_native("options/prefetch-playlist"),
        prefetch_max = mp.get_property_native("options/prefetch-playlist-max"),
        autocreate = mp.get_property("options/autocreate-playlist"),
        drops = mp.get_property_native("frame-drop-count"), dec_drops = mp.get_property_native("decoder-frame-drop-count"),
        delayed = mp.get_property_native("vo-delayed-frame-count"), mistimed = mp.get_property_native("mistimed-frame-count") }
end

local function write_result()
    local res = {
        schemaVersion = 1, trial = o.trial, frames = o.frames, t_load = t_load,
        events = events, samples = samples, playlists = playlists, props = props,
        next_attempts = next_attempts, pipe_ok = pipe ~= nil,
    }
    local f = io.open(o.out, "w")
    if f then f:write(utils.format_json(res)); f:close() end
end

local function try_next()
    if next_sent then return end
    next_attempts = next_attempts + 1
    local count = mp.get_property_native("playlist-count") or 0
    local pos = mp.get_property_native("playlist-pos") or -1
    if count > pos + 1 then
        snapshot_playlist("before-next")
        ev("cmd-playlist-next", { pos = pos, count = count, attempts = next_attempts })
        next_sent = true
        mp.commandv("playlist-next")
    else
        ev("next-deferred", { pos = pos, count = count })
        mp.add_timeout(0.1, try_next)
    end
end

local function do_quit()
    if quit_sent then return end
    quit_sent = true
    snapshot_playlist("before-quit")
    file_props("before-quit")
    ev("cmd-quit")
    mp.commandv("quit")
end

-- `estimated-frame-number` is computed on get and emits no change notifications
-- on this build: observe_property never fired, so the first trial ran to the
-- safety timeout with next_attempts=0. Poll it instead; 50 ms bounds the trigger
-- latency to ~1.5 frames at 30 fps.
local function check_frames()
    local fi = file_index
    if fi < 1 or done_frames[fi] then return end
    local n = mp.get_property_native("estimated-frame-number")
    if not n then return end
    if n >= o.frames - 1 then            -- frame index frames-1 displayed => `frames` frames played
        done_frames[fi] = true
        ev("frames-reached", { frame = n })
        if fi == 1 then try_next() elseif fi >= 2 then do_quit() end
    end
end
mp.add_periodic_timer(0.05, check_frames)

for _, name in ipairs({ "prefetch-active", "prefetched-count", "playlist-count", "hwdec-current", "vo-configured", "paused-for-cache" }) do
    mp.observe_property(name, "native", function(_, v) ev("prop:" .. name, { value = v }) end)
end

mp.register_event("start-file", function(e)
    file_index = file_index + 1
    ev("start-file", { id = e.playlist_entry_id })
end)
mp.register_event("file-loaded", function()
    ev("file-loaded", { path = mp.get_property("path") })
    file_props("file-loaded")
end)
mp.register_event("video-reconfig", function() ev("video-reconfig") end)
mp.register_event("audio-reconfig", function() ev("audio-reconfig") end)
mp.register_event("playback-restart", function()
    ev("playback-restart")
    snapshot_playlist("playback-restart")
    file_props("playback-restart")
end)
mp.register_event("end-file", function(e)
    ev("end-file", { reason = e.reason, error = e.error, id = e.playlist_entry_id })
end)
mp.register_event("shutdown", function()
    ev("shutdown")
    write_result()
    if pipe then pcall(function() pipe:close() end) end
end)

if o.pipe ~= "" then
    pipe = io.open("\\\\.\\pipe\\" .. o.pipe, "w")
    if pipe then pipe:setvbuf("no") end
end
ev("probe-loaded", { pipe = pipe ~= nil })
mp.add_periodic_timer(0.2, sample)
mp.add_timeout(tonumber(o.timeout) or 180, function()
    ev("safety-timeout")
    do_quit()
end)
