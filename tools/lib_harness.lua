-- Lua 5.1 harness for LibEchoesMusic: virtual clock + timers + fake PlayMusic.
-- usage (from the repo root): lua5.1 tools/lib_harness.lua [path to LibEchoesMusic.lua]
-- Simulates the loading-screen and finish-track flows against LibEchoesMusic
-- with a virtual clock, virtual timers and a recorded PlayMusic/StopMusic.
local libPath = arg[1] or "lib/LibEchoesMusic.lua"
_G.Enum = { UIMapType = { Dungeon = 4 } }
dofile("lib/LibStub.lua")
dofile(libPath)
local lib = LibStub("LibEchoesMusic-1.0")

-- virtual scheduler ---------------------------------------------------------
local now = 0
local timers = {}
local function NewTimer(delay, cb)
    local t = { at = now + delay, cb = cb, cancelled = false }
    function t:Cancel() self.cancelled = true end
    timers[#timers + 1] = t
    return t
end
local function advance(seconds)
    local target = now + seconds
    while true do
        local next, idx = nil, nil
        for i, t in ipairs(timers) do
            if not t.cancelled and t.at <= target and (not next or t.at < next.at) then next, idx = t, i end
        end
        if not next then break end
        table.remove(timers, idx)
        now = next.at
        next.cb()
    end
    now = target
end

local calls = {}
local function log(kind, v) calls[#calls + 1] = { kind = kind, v = v, at = now } end
local SILENCE = "Interface\\AddOns\\EchoesOfAzeroth\\silence.ogg"
local maps = {
    [2393] = { parentMapID = 2537, mapType = 3 }, [2405] = { parentMapID = 2537, mapType = 3 },
    [2537] = { parentMapID = 13, mapType = 2 }, [13] = { parentMapID = 947, mapType = 2 },
    [947] = { parentMapID = 946, mapType = 1 }, [946] = { parentMapID = 0, mapType = 0 },
    [9999] = { parentMapID = 946, mapType = 3 },
}
local deferred = {}
local player = lib:NewPlayer({
    transport = {
        PlayMusic = function(t) log("play", t) end,
        StopMusic = function() log("stop") end,
        NewTimer = NewTimer,
        Now = function() return now end,
        GetMapInfo = function(id) return maps[id] end,
        GetMapGroupMembers = function() return nil end,
    },
    catalog = {
        packs = {
            SILVERMOON = { label = "Silvermoon", any = { 101 } },
            NETHERSTORM = { label = "Netherstorm", any = { 201 } },
            AREA52 = { label = "Area 52", any = { 301 } },
        },
        zones = {
            [2393] = { nameKey = "SILVERMOON", pack = "SILVERMOON" },
            [2405] = { nameKey = "VOIDSTORM", pack = "NETHERSTORM", subzones = { THE_HOWLING_RIDGE = "AREA52" } },
        },
        durations = { [101] = 120, [201] = 180, [301] = 90 },
        subzoneKeys = { ["The Howling Ridge"] = "THE_HOWLING_RIDGE" },
        subzoneNames = { THE_HOWLING_RIDGE = "The Howling Ridge" },
    },
    settings = { enabled = true, silenceGap = 4, crossfadeSec = 3, finishTrack = "zone" },
    callbacks = { OnSwitchDeferred = function(p) deferred[#deferred + 1] = p end },
})

local function ctx(mapId, sub, opts)
    opts = opts or {}
    return { mapId = mapId, subzoneText = sub or "", zoneText = "", isInInstance = opts.instance == true,
        instanceType = opts.instance and "party" or "none", musicEnabled = true,
        isLoadingScreenTransition = opts.loading == true, holdSilence = opts.hold == true, isEarly = false, hour = 12 }
end
local function reset() calls = {}; deferred = {} end
local function lastPlay()
    for i = #calls, 1, -1 do if calls[i].kind == "play" then return calls[i].v end end
    return nil
end
local function count(kind, v)
    local n = 0
    for _, c in ipairs(calls) do if c.kind == kind and (v == nil or c.v == v) then n = n + 1 end end
    return n
end
local failures = 0
local function check(name, cond, detail)
    print((cond and "  ok   " or "  FAIL ") .. name .. (cond and "" or ("  <- " .. tostring(detail))))
    if not cond then failures = failures + 1 end
end
local function state() return player:GetState() end

local function startInSilvermoon()
    player:ResetState(); timers = {}; now = 0; reset()
    player:UpdateContext(ctx(2393, "Silvermoon City"))
    assert(lastPlay() == 101 and state().isPlaying, "setup: Silvermoon track should play")
    advance(30)
    reset()
end

print("S1  portal with map unknown at PLAYER_ENTERING_WORLD, finishTrack=zone")
startInSilvermoon()
player:UpdateContext(ctx(nil, "", { loading = true, hold = true }))      -- PEW, map not known yet
check("silence held at PEW", lastPlay() == SILENCE, lastPlay())
check("playing state dropped at PEW", not state().isPlaying, state().isPlaying)
reset()
player:UpdateContext(ctx(2405, "The Howling Ridge"))                     -- LOADING_SCREEN_DISABLED
check("Howling Ridge pack starts at LSD", lastPlay() == 301, lastPlay())
check("no deferred switch", #deferred == 0, #deferred)

print("S1b portal with the old map still reported at PEW")
startInSilvermoon()
player:UpdateContext(ctx(2393, "Silvermoon City", { loading = true, hold = true }))
check("silence held even for the same pack", lastPlay() == SILENCE, lastPlay())
check("playing state dropped", not state().isPlaying, state().isPlaying)
reset()
player:UpdateContext(ctx(2405, "The Howling Ridge"))
check("Howling Ridge pack starts at LSD", lastPlay() == 301, lastPlay())
check("no deferred switch", #deferred == 0, #deferred)

print("S2  portal with the new map known at PEW")
startInSilvermoon()
player:UpdateContext(ctx(2405, "", { loading = true, hold = true }))
check("silence held", lastPlay() == SILENCE, lastPlay())
reset()
player:UpdateContext(ctx(2405, ""))
check("zone pack starts at LSD", lastPlay() == 201, lastPlay())
reset()
advance(0.5)
player:UpdateContext(ctx(2405, "The Howling Ridge"))                     -- subzone text settled
check("settle re-check switches at once (grace period)", lastPlay() == 301 and #deferred == 0, tostring(lastPlay()) .. "/" .. #deferred)

print("S3  portal to an unmapped zone releases the channel")
startInSilvermoon()
player:UpdateContext(ctx(9999, "", { loading = true, hold = true }))
check("StopMusic at PEW", count("stop") == 1 and count("play") == 0, count("stop") .. "/" .. count("play"))
reset()
player:UpdateContext(ctx(9999, ""))
check("nothing played at LSD", count("play") == 0, count("play"))
check("no deferred stop pending", state().pendingSwitch == nil, state().pendingSwitch)

print("S4  finish-track behaviour unchanged past the grace period")
player:ResetState(); timers = {}; now = 0; reset()
player:UpdateContext(ctx(2405, ""))
advance(10); reset()
player:UpdateContext(ctx(2405, "The Howling Ridge"))
check("mid-track subzone change is deferred", #deferred == 1 and count("play") == 0, #deferred .. "/" .. count("play"))
advance(180 + 4 + 0.01)
check("pack switches after the track and the gap", lastPlay() == 301, lastPlay())
reset(); deferred = {}
advance(10)
player:UpdateContext(ctx(9999, ""))
check("leaving to unmapped mid-track defers the stop", #deferred == 1 and count("stop") == 0, #deferred .. "/" .. count("stop"))
advance(90)
check("channel released at track end", count("stop") == 1 and not state().isPlaying, count("stop"))

print("S5  entering an unmapped instance still stops at once")
player:ResetState(); timers = {}; now = 0; reset()
player:UpdateContext(ctx(2405, ""))
advance(10); reset()
player:UpdateContext(ctx(nil, "", { loading = true, hold = true, instance = true }))
check("StopMusic at PEW for an instance with unknown map", count("stop") == 1 and not state().isPlaying, count("stop"))

print(failures == 0 and "ALL PASS" or (failures .. " FAILURE(S)"))
os.exit(failures == 0 and 0 or 1)
