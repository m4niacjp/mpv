local mp = require 'mp'
local utils = require 'mp.utils'
local o = {out='', hold=10}
require('mp.options').read_options(o, 'quickperf')
local f = assert(io.open(o.out, 'w'))
f:setvbuf('no')
local idx, switches, seen = 0, 0, {}
local finished = false
local function props()
    local r = {}
    for _, k in ipairs({'path','playlist-pos','playlist-count','time-pos','estimated-frame-number','current-vo','hwdec-current','video-params','vf','prefetch-active','prefetched-count','paused-for-cache','demuxer-cache-state','frame-drop-count','decoder-frame-drop-count','vo-delayed-frame-count','options/video-latency-hacks','options/prefetch-playlist','options/prefetch-playlist-max','mpv-version'}) do
        r[k] = mp.get_property_native(k)
    end
    return r
end
local function ev(name, detail)
    f:write(utils.format_json({t=mp.get_time(),name=name,file=idx,detail=detail}) .. '\n')
end
local function quit(reason)
    if finished then return end
    finished = true
    ev('quit-command', {reason=reason,switches=switches})
    mp.commandv('quit')
end
local function next_video()
    if finished then return end
    switches = switches + 1
    ev('next-command', {switch=switches})
    local ok, err = mp.commandv('playlist-next')
    ev('next-return', {ok=ok,error=err})
end
mp.enable_messages('v')
mp.register_event('log-message',function(e)
    if e.prefix ~= 'cplayer' or not e.text:find('first video frame after restart shown',1,true) or finished or seen[idx] then return end
    seen[idx]=true
    ev('first-frame',{log_time=e.time})
    if idx==1 then mp.add_timeout(o.hold,next_video)
    elseif switches < 6 then next_video()
    else quit('complete') end
end)
mp.register_event('start-file',function(e)
    idx=idx+1
    ev('start-file',e)
    local current=idx
    mp.add_timeout(30,function() if not finished and idx==current and not seen[current] then quit('first-frame-timeout') end end)
end)
mp.register_event('file-loaded',function() ev('file-loaded') end)
mp.register_event('playback-restart',function() ev('playback-restart') end)
mp.register_event('end-file',function(e) ev('end-file',e) end)
mp.register_event('shutdown',function() ev('shutdown'); f:close() end)
mp.observe_property('paused-for-cache','native',function(_,v) ev('paused-for-cache',{value=v}) end)
mp.add_periodic_timer(0.25,function() if not finished and switches==0 then ev('sample',props()) end end)
mp.add_timeout(90,function() quit('overall-timeout') end)
ev('probe-loaded',props())
