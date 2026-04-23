local MAJOR, MINOR = "LibEchoesMusic-1.0", 1
local LibStub = _G.LibStub

if not LibStub then
    error(MAJOR .. " requires LibStub")
end

local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then
    return
end

local DEFAULT_DUR = 90
local MAX_DEPTH = 5
local RANDOM_SAFETY = 20
local SILENCE_TRACK = "Interface\\AddOns\\EchoesOfAzeroth\\silence.ogg"

local Player = {}
Player.__index = Player

local function tblcopy(src)
    local out = {}
    if not src then
        return out
    end
    for k, v in pairs(src) do
        out[k] = v
    end
    return out
end

local function listcopy(src)
    if not src then
        return nil
    end
    local out = {}
    for i, v in ipairs(src) do
        out[i] = v
    end
    return out
end

function lib:NewPlayer(opts)
    local player = setmetatable({}, Player)
    player.catalog = {
        packs = {},
        zones = {},
        durations = {},
        subzoneKeys = {},
        subzoneNames = {},
        trackNames = {},
    }
    player.settings = {
        enabled = true,
        silenceGap = 4,
        crossfadeSec = 3,
        verbose = false,
        zoneOverrides = {},
        customPacks = {},
        packOverrides = {},
    }
    player.transport = {}
    player.callbacks = {}
    player:ResetState()

    if opts then
        if opts.transport then
            player:SetTransport(opts.transport)
        end
        if opts.catalog then
            player:SetCatalog(opts.catalog)
        end
        if opts.settings then
            player:SetSettings(opts.settings)
        end
        if opts.callbacks then
            player:SetCallbacks(opts.callbacks)
        end
    end

    return player
end

function Player:ResetState()
    self.enabled = true
    self.isPlaying = false
    self.isPreviewing = false
    self.currentZoneId = nil
    self.currentConfig = nil
    self.currentGroup = nil
    self.currentPackKey = nil
    self.currentTrack = nil
    self.currentSubKey = nil
    self.lastTrack = nil
    self.introPlayed = false
    self.rotateTicker = nil
    self.fadeTimer = nil
    self.currentContext = nil
    self.lastResolution = nil
end

function Player:SetTransport(transport)
    self.transport = transport or {}
end

function Player:SetCallbacks(callbacks)
    self.callbacks = callbacks or {}
end

function Player:SetCatalog(catalog)
    catalog = catalog or {}
    self.catalog = {
        packs = catalog.packs or {},
        zones = catalog.zones or {},
        durations = catalog.durations or {},
        subzoneKeys = catalog.subzoneKeys or {},
        subzoneNames = catalog.subzoneNames or {},
        trackNames = catalog.trackNames or {},
    }
end

function Player:SetSettings(settings)
    settings = settings or {}
    self.settings.enabled = settings.enabled ~= false
    if settings.silenceGap == nil then
        self.settings.silenceGap = 4
    else
        self.settings.silenceGap = settings.silenceGap
    end
    if settings.crossfadeSec == nil then
        self.settings.crossfadeSec = 3
    else
        self.settings.crossfadeSec = settings.crossfadeSec
    end
    self.settings.verbose = settings.verbose == true
    self.settings.zoneOverrides = settings.zoneOverrides or {}
    self.settings.customPacks = settings.customPacks or {}
    self.settings.packOverrides = settings.packOverrides or {}
end

function Player:GetState()
    return {
        isPlaying = self.isPlaying,
        isPreviewing = self.isPreviewing,
        currentZoneId = self.currentZoneId,
        currentGroup = self.currentGroup,
        currentPackKey = self.currentPackKey,
        currentTrack = self.currentTrack,
        currentSubKey = self.currentSubKey,
        lastResolution = self.lastResolution,
    }
end

function Player:_emit(name, ...)
    local callback = self.callbacks and self.callbacks[name]
    if callback then
        callback(...)
    end
end

function Player:_playMusic(track)
    local fn = self.transport.PlayMusic or _G.PlayMusic
    if fn then
        fn(track)
    end
end

function Player:_stopMusic()
    local fn = self.transport.StopMusic or _G.StopMusic
    if fn then
        fn()
    end
end

function Player:_newTimer(delay, callback)
    local fn = self.transport.NewTimer
    if fn then
        return fn(delay, callback)
    end
    return _G.C_Timer.NewTimer(delay, callback)
end

function Player:_getMapInfo(mapId)
    local fn = self.transport.GetMapInfo
    if fn then
        return fn(mapId)
    end
    return _G.C_Map.GetMapInfo(mapId)
end

function Player:_cancelTimer(timer)
    if timer and timer.Cancel then
        timer:Cancel()
    end
end

function Player:_isDaytime(context)
    local hour = context and context.hour
    if hour == nil then
        hour = select(1, _G.GetGameTime())
    end
    return hour >= 6 and hour < 21
end

function Player:GetPack(key)
    if not key then
        return nil
    end
    return self.catalog.packs[key] or self.settings.customPacks[key]
end

function Player:ResolveEffectivePack(config, packKey)
    if not config then
        return nil
    end

    local resolved = {
        label = config.label,
        pluginId = config.pluginId,
        localKey = config.localKey,
        intro = config.intro,
        day = listcopy(config.day),
        night = listcopy(config.night),
        any = listcopy(config.any),
    }

    local ov = packKey and self.settings.packOverrides and self.settings.packOverrides[packKey]
    if ov and ov.introEnabled == false then
        resolved.intro = nil
    elseif ov and ov.introEnabled == true then
        resolved.intro = config.intro
    end

    local dis = ov and ov.disabled
    local dbd = config.disabledByDefault
    if not dis and not dbd then
        return resolved
    end

    local function filter(list)
        if not list then
            return nil
        end
        local filtered = {}
        for _, id in ipairs(list) do
            local userSet = dis and dis[id]
            if userSet ~= true then
                if userSet == false or not (dbd and dbd[id]) then
                    filtered[#filtered + 1] = id
                end
            end
        end
        return filtered
    end

    resolved.day = filter(resolved.day)
    resolved.night = filter(resolved.night)
    resolved.any = filter(resolved.any)
    return resolved
end

function Player:ResolveZone(mapId)
    if not mapId then
        return nil, nil
    end

    local overrides = self.settings.zoneOverrides
    for _ = 1, MAX_DEPTH do
        if overrides and overrides[mapId] and overrides[mapId].isCustom then
            return mapId, overrides[mapId]
        end
        if self.catalog.zones[mapId] then
            return mapId, self.catalog.zones[mapId]
        end
        local info = self:_getMapInfo(mapId)
        if not info or not info.parentMapID or info.parentMapID == 0 then
            return nil, nil
        end
        mapId = info.parentMapID
    end

    return nil, nil
end

function Player:ResolveConfig(zoneId, zoneEntry, subzoneText)
    local overrides = self.settings.zoneOverrides
    local zoneOv = overrides and overrides[zoneId]
    local subzoneKeys = self.catalog.subzoneKeys

    if subzoneText and subzoneText ~= "" and zoneOv and zoneOv.subzones then
        local key = subzoneKeys[subzoneText] or subzoneText
        local packKey = zoneOv.subzones[key]
        if packKey and packKey ~= "DEFAULT" then
            if packKey == "NONE" then
                return nil, key, nil
            end
            local pack = self:GetPack(packKey)
            if pack then
                return self:ResolveEffectivePack(pack, packKey), key, packKey
            end
        end
    end

    if zoneEntry.subzones and subzoneText and subzoneText ~= "" then
        local key = subzoneKeys[subzoneText]
        if key and zoneEntry.subzones[key] then
            local packKey = zoneEntry.subzones[key]
            local pack = self:GetPack(packKey)
            if pack then
                return self:ResolveEffectivePack(pack, packKey), key, packKey
            end
        end
    end

    if zoneOv and zoneOv.pack and zoneOv.pack ~= "DEFAULT" then
        if zoneOv.pack == "NONE" then
            return nil, nil, nil
        end
        local pack = self:GetPack(zoneOv.pack)
        if pack then
            return self:ResolveEffectivePack(pack, zoneOv.pack), nil, zoneOv.pack
        end
    end

    if zoneEntry.pack then
        local pack = self:GetPack(zoneEntry.pack)
        if pack then
            return self:ResolveEffectivePack(pack, zoneEntry.pack), nil, zoneEntry.pack
        end
    end

    return nil, nil, nil
end

function Player:BuildPool(config, packKey, context)
    local pool = {}
    local timed = self:_isDaytime(context) and config.day or config.night
    if timed then
        for _, id in ipairs(timed) do
            pool[#pool + 1] = id
        end
    end
    if config.any then
        for _, id in ipairs(config.any) do
            pool[#pool + 1] = id
        end
    end
    return pool
end

function Player:PickTrack(config, packKey, context)
    local pool = self:BuildPool(config, packKey, context)
    if #pool == 0 then
        return nil
    end
    if #pool == 1 then
        self.lastTrack = pool[1]
        return pool[1]
    end

    for _ = 1, RANDOM_SAFETY do
        local track = pool[math.random(#pool)]
        if track ~= self.lastTrack then
            self.lastTrack = track
            return track
        end
    end

    self.lastTrack = pool[1]
    return pool[1]
end

function Player:CancelTimers()
    self:_cancelTimer(self.rotateTicker)
    self.rotateTicker = nil
    self:_cancelTimer(self.fadeTimer)
    self.fadeTimer = nil
end

function Player:HardStop()
    self:CancelTimers()
    self:_stopMusic()
    self.isPlaying = false
    self.currentZoneId = nil
    self.currentConfig = nil
    self.currentGroup = nil
    self.currentPackKey = nil
    self.currentTrack = nil
    self.currentSubKey = nil
    self.lastTrack = nil
end

function Player:FadeOutThenStop()
    if not self.isPlaying then
        self:HardStop()
        return
    end

    self:CancelTimers()
    self.isPlaying = false
    self.currentZoneId = nil
    self.currentConfig = nil
    self.currentGroup = nil
    self.currentPackKey = nil
    self.currentTrack = nil
    self.currentSubKey = nil
    self.lastTrack = nil

    self:_playMusic(SILENCE_TRACK)
    self.fadeTimer = self:_newTimer(self.settings.crossfadeSec, function()
        self.fadeTimer = nil
        self:_stopMusic()
    end)
end

function Player:_emitTrack(track, dur)
    self:_emit("OnTrackStart", track, dur, tblcopy(self:GetState()))
end

function Player:ScheduleRotation(track, dur)
    self:_cancelTimer(self.rotateTicker)
    self.rotateTicker = self:_newTimer(dur, function()
        self:_playMusic(SILENCE_TRACK)
        self.rotateTicker = self:_newTimer(self.settings.silenceGap, function()
            self.rotateTicker = nil
            if not self.isPlaying or not self.currentConfig then
                return
            end
            local nextTrack = self:PickTrack(self.currentConfig, self.currentGroup, self.currentContext)
            if not nextTrack then
                return
            end
            local nextDur = self.catalog.durations[nextTrack] or DEFAULT_DUR
            self.currentTrack = nextTrack
            self:_playMusic(nextTrack)
            self:_emitTrack(nextTrack, nextDur)
            self:ScheduleRotation(nextTrack, nextDur)
        end)
    end)
end

function Player:BeginPlayback(zoneId, effectiveConfig, introTrack, groupKey, subKey)
    local track
    if introTrack and not self.introPlayed then
        track = introTrack
        self.introPlayed = true
    else
        track = self:PickTrack(effectiveConfig, groupKey, self.currentContext)
    end

    if not track then
        return
    end

    self:_cancelTimer(self.rotateTicker)
    self.rotateTicker = nil

    self.currentZoneId = zoneId
    self.currentConfig = effectiveConfig
    self.currentGroup = groupKey
    self.currentPackKey = groupKey
    self.currentTrack = track
    self.currentSubKey = subKey
    self.isPlaying = true

    local dur = self.catalog.durations[track] or DEFAULT_DUR
    self:_playMusic(track)
    self:_emitTrack(track, dur)
    self:ScheduleRotation(track, dur)
end

function Player:StartMusic(zoneId, effectiveConfig, forceRestart, introTrack, groupKey, subKey)
    if not forceRestart and self.isPlaying and groupKey and self.currentGroup and groupKey == self.currentGroup then
        self.currentZoneId = zoneId
        self.currentConfig = effectiveConfig
        self.currentSubKey = subKey
        return
    end

    if not forceRestart and self.isPlaying and self.currentZoneId == zoneId and self.currentConfig == effectiveConfig then
        self.currentSubKey = subKey
        return
    end

    self:_cancelTimer(self.fadeTimer)
    self.fadeTimer = nil

    if zoneId ~= self.currentZoneId then
        self.introPlayed = false
    end

    self:BeginPlayback(zoneId, effectiveConfig, introTrack, groupKey, subKey)
end

function Player:Stop(skipFade)
    if skipFade or not self.isPlaying then
        self:HardStop()
    else
        self:FadeOutThenStop()
    end
end

function Player:ResolveContext(context)
    local mapId = context and context.mapId
    local subzoneText = context and context.subzoneText
    local zoneId, zoneEntry = self:ResolveZone(mapId)
    if not zoneId or not zoneEntry then
        return nil
    end

    local effectiveConfig, subKey, groupKey = self:ResolveConfig(zoneId, zoneEntry, subzoneText)
    if not effectiveConfig then
        return {
            zoneId = zoneId,
            zoneEntry = zoneEntry,
            disabled = true,
            subKey = subKey,
            groupKey = groupKey,
        }
    end

    return {
        zoneId = zoneId,
        zoneEntry = zoneEntry,
        effectiveConfig = effectiveConfig,
        subKey = subKey,
        groupKey = groupKey,
        intro = effectiveConfig and effectiveConfig.intro,
    }
end

function Player:CheckContext(context, forceRestart)
    self.currentContext = context or self.currentContext or {}
    local ctx = self.currentContext
    local skipFade = ctx.isLoadingScreenTransition

    if self.isPreviewing then
        return
    end

    if not self.settings.enabled or not ctx.musicEnabled then
        if self.isPlaying then
            self:Stop(skipFade)
        end
        self.lastResolution = nil
        return
    end

    local resolved = self:ResolveContext(ctx)

    -- Historically we suppressed all instance playback so open-world-only
    -- plugins never fought scripted dungeon/raid music.  When a plugin
    -- explicitly maps the current UiMapID, allow playback there.
    if ctx.isInInstance and not (resolved and resolved.effectiveConfig) then
        if self.isPlaying then
            self:Stop(skipFade)
        end
        self.lastResolution = nil
        return
    end

    self.lastResolution = resolved

    if resolved and resolved.effectiveConfig then
        self:StartMusic(
            resolved.zoneId,
            resolved.effectiveConfig,
            forceRestart or skipFade,
            resolved.intro,
            resolved.groupKey,
            resolved.subKey
        )
    else
        self:Stop(skipFade)
    end
end

function Player:UpdateContext(context, forceRestart)
    self.currentContext = context or {}
    self:CheckContext(self.currentContext, forceRestart)
end

function Player:RefreshNow(forceRestart)
    self:CheckContext(self.currentContext or {}, forceRestart)
end

function Player:PreviewTrack(fdid)
    self.isPreviewing = true
    self:CancelTimers()
    self.currentTrack = fdid
    self:_playMusic(fdid)
end

function Player:StopPreview(context)
    self.isPreviewing = false
    if context then
        self.currentContext = context
        self:CheckContext(context)
    else
        self:_stopMusic()
    end
end

lib.Player = Player
