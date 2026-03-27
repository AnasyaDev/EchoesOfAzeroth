local addonName, ns = ...

local LibStub = _G.LibStub
local MusicLib = LibStub and LibStub("LibEchoesMusic-1.0", true)
local PREFIX = "|cffFFD700Echoes of Azeroth:|r "
local CORE_DB_VERSION = 2
local LEGACY_PLUGIN_ID = "quelthalas"
local CUSTOM_PLUGIN_ID = "custom"
local EMPTY_LABELS = setmetatable({}, {
    __index = function(_, key)
        return key
    end,
})

local frame = CreateFrame("Frame")
local registeredPlugins = {}
local pluginOrder = {}
local pluginRegistrationSeq = 0
local runtimeCatalog = nil

local db
local player
local pendingCheck
local loadingScreenEnded = false
local optionsInitialized = false
local api = _G.EchoesOfAzeroth or {}

_G.EchoesOfAzeroth = api
ns.PluginDsl = ns.PluginDsl or api.PluginDsl
api.PluginDsl = ns.PluginDsl

local function DeepCopy(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for key, inner in pairs(value) do
        out[key] = DeepCopy(inner)
    end
    return out
end

local function BuildTrackNames(tracks)
    local names = {}
    for name, id in pairs(tracks or {}) do
        names[id] = name
    end
    return names
end

local function Warn(message)
    if _G.DEFAULT_CHAT_FRAME and _G.DEFAULT_CHAT_FRAME.AddMessage then
        _G.DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. message)
        return
    end
    print(PREFIX .. message)
end

local function BuildDerivedSubzoneKeys(subzoneNames)
    local subzoneKeys = {}
    for key, localizedText in pairs(subzoneNames or {}) do
        if localizedText ~= nil then
            subzoneKeys[localizedText] = key
        end
    end
    return subzoneKeys
end

local function BuildSortedPackOrder(packs, qualifyFn)
    local keys = {}
    for key in pairs(packs or {}) do
        keys[#keys + 1] = key
    end
    table.sort(keys, function(a, b)
        local packA = packs and packs[a] or nil
        local packB = packs and packs[b] or nil
        local labelA = tostring((packA and packA.label) or a or "")
        local labelB = tostring((packB and packB.label) or b or "")
        if labelA ~= labelB then
            return labelA < labelB
        end
        local tieA = qualifyFn and qualifyFn(a) or a
        local tieB = qualifyFn and qualifyFn(b) or b
        return tostring(tieA or "") < tostring(tieB or "")
    end)
    if not qualifyFn then
        return keys
    end
    local qualified = {}
    for _, key in ipairs(keys) do
        qualified[#qualified + 1] = qualifyFn(key)
    end
    return qualified
end

local function QualifyKey(pluginId, key)
    if not pluginId or not key then
        return key
    end
    return pluginId .. "::" .. key
end

local function SplitQualifiedKey(key)
    if type(key) ~= "string" then
        return nil, key
    end
    local idx = key:find("::", 1, true)
    if not idx then
        return nil, key
    end
    return key:sub(1, idx - 1), key:sub(idx + 2)
end

local function QualifyPackKey(pluginId, key)
    if not key or key == "DEFAULT" or key == "NONE" then
        return key
    end
    local existingPluginId = SplitQualifiedKey(key)
    if existingPluginId then
        return key
    end
    return QualifyKey(pluginId, key)
end

local function ValidateTrackList(pluginId, fieldName, list)
    if list == nil then
        return
    end
    if type(list) ~= "table" then
        error(("Echoes plugin '%s' field %s must be a list table"):format(pluginId, fieldName))
    end
    for i, value in ipairs(list) do
        if type(value) ~= "number" then
            error(("Echoes plugin '%s' field %s[%d] must be a number"):format(pluginId, fieldName, i))
        end
    end
end

local function ValidatePackReference(pluginId, packs, ref, fieldName)
    if ref == nil or ref == "DEFAULT" or ref == "NONE" then
        return
    end
    if type(ref) ~= "string" then
        error(("Echoes plugin '%s' field %s must be a pack key string"):format(pluginId, fieldName))
    end
    local foreignPluginId = SplitQualifiedKey(ref)
    if foreignPluginId then
        return
    end
    if not (packs and packs[ref]) then
        error(("Echoes plugin '%s' field %s references unknown pack '%s'"):format(pluginId, fieldName, ref))
    end
end

local function ValidatePluginDefinition(def)
    if type(def) ~= "table" or not def.id then
        error("Echoes plugin registration requires an id")
    end

    local pluginId = def.id
    if type(def.title) ~= "string" or def.title == "" then
        error(("Echoes plugin '%s' requires a non-empty title"):format(pluginId))
    end

    local fields = {
        { key = "tracks", required = true },
        { key = "durations", required = true },
        { key = "packs", required = true },
        { key = "zones", required = true },
        { key = "locales", required = true },
        { key = "subzoneNames", required = true },
    }

    for _, field in ipairs(fields) do
        local value = def[field.key]
        if value == nil then
            if field.required then
                error(("Echoes plugin '%s' is missing required table '%s'"):format(pluginId, field.key))
            end
        elseif type(value) ~= "table" then
            error(("Echoes plugin '%s' field '%s' must be a table"):format(pluginId, field.key))
        end
    end

    if def.subzoneKeys ~= nil and type(def.subzoneKeys) ~= "table" then
        error(("Echoes plugin '%s' field 'subzoneKeys' must be a table"):format(pluginId))
    end

    local missingDurationCount = 0
    for trackName, id in pairs(def.tracks or {}) do
        if type(trackName) ~= "string" or trackName == "" then
            error(("Echoes plugin '%s' tracks must use non-empty string keys"):format(pluginId))
        end
        if type(id) ~= "number" then
            error(("Echoes plugin '%s' track '%s' must map to a numeric FileDataID"):format(pluginId, tostring(trackName)))
        end
        if (def.durations or {})[id] == nil then
            missingDurationCount = missingDurationCount + 1
        end
    end
    for id, duration in pairs(def.durations or {}) do
        if type(id) ~= "number" or type(duration) ~= "number" then
            error(("Echoes plugin '%s' durations must map numeric FileDataIDs to numeric durations"):format(pluginId))
        end
    end

    for packKey, pack in pairs(def.packs or {}) do
        if type(packKey) ~= "string" or packKey == "" then
            error(("Echoes plugin '%s' packs must use non-empty string keys"):format(pluginId))
        end
        if type(pack) ~= "table" then
            error(("Echoes plugin '%s' pack '%s' must be a table"):format(pluginId, packKey))
        end
        if type(pack.label) ~= "string" or pack.label == "" then
            error(("Echoes plugin '%s' pack '%s' requires a non-empty label"):format(pluginId, packKey))
        end
        if pack.intro ~= nil and type(pack.intro) ~= "number" then
            error(("Echoes plugin '%s' pack '%s' intro must be a numeric FileDataID"):format(pluginId, packKey))
        end
        ValidateTrackList(pluginId, ("packs['%s'].day"):format(packKey), pack.day)
        ValidateTrackList(pluginId, ("packs['%s'].night"):format(packKey), pack.night)
        ValidateTrackList(pluginId, ("packs['%s'].any"):format(packKey), pack.any)
        if pack.day == nil and pack.night == nil and pack.any == nil then
            error(("Echoes plugin '%s' pack '%s' must define day, night, or any tracks"):format(pluginId, packKey))
        end
    end

    local missingZoneLabelCount = 0
    local missingSubzoneLabelCount = 0
    for mapId, zoneEntry in pairs(def.zones or {}) do
        if type(mapId) ~= "number" then
            error(("Echoes plugin '%s' zone keys must be numeric UiMapIDs"):format(pluginId))
        end
        if type(zoneEntry) ~= "table" then
            error(("Echoes plugin '%s' zone '%s' must be a table"):format(pluginId, tostring(mapId)))
        end
        if type(zoneEntry.nameKey) ~= "string" or zoneEntry.nameKey == "" then
            error(("Echoes plugin '%s' zone '%s' requires a non-empty nameKey"):format(pluginId, tostring(mapId)))
        end
        if not (def.locales or EMPTY_LABELS)[zoneEntry.nameKey] then
            missingZoneLabelCount = missingZoneLabelCount + 1
        end
        ValidatePackReference(pluginId, def.packs, zoneEntry.pack, ("zones[%s].pack"):format(mapId))
        if zoneEntry.subzones ~= nil and type(zoneEntry.subzones) ~= "table" then
            error(("Echoes plugin '%s' zone '%s' subzones must be a table"):format(pluginId, tostring(mapId)))
        end
        for subKey, packRef in pairs(zoneEntry.subzones or {}) do
            if type(subKey) ~= "string" or subKey == "" then
                error(("Echoes plugin '%s' zone '%s' subzone keys must be non-empty strings"):format(pluginId, tostring(mapId)))
            end
            ValidatePackReference(pluginId, def.packs, packRef, ("zones[%s].subzones['%s']"):format(mapId, subKey))
            if not (def.subzoneNames or {})[subKey] then
                missingSubzoneLabelCount = missingSubzoneLabelCount + 1
            end
        end
    end

    if def.packOrder ~= nil then
        Warn(("Plugin '%s' provided deprecated field 'packOrder'; pack order is now generated alphabetically."):format(pluginId))
    end
    if def.subzoneKeys == nil and next(def.subzoneNames or {}) ~= nil then
        Warn(("Plugin '%s' omitted 'subzoneKeys'; they will be generated automatically from 'subzoneNames'."):format(pluginId))
    end
    if missingDurationCount > 0 then
        Warn(("Plugin '%s' is missing durations for %d track(s)."):format(pluginId, missingDurationCount))
    end
    if missingZoneLabelCount > 0 then
        Warn(("Plugin '%s' is missing locale labels for %d zone name key(s)."):format(pluginId, missingZoneLabelCount))
    end
    if missingSubzoneLabelCount > 0 then
        Warn(("Plugin '%s' is missing labels for %d subzone key(s)."):format(pluginId, missingSubzoneLabelCount))
    end
end

local function EnsurePluginState(profile, pluginId)
    profile.plugins = profile.plugins or {}
    if not profile.plugins[pluginId] then
        profile.plugins[pluginId] = {
            zoneOverrides = {},
            customPacks = {},
            packOverrides = {},
        }
    end
    local state = profile.plugins[pluginId]
    state.zoneOverrides = state.zoneOverrides or {}
    state.customPacks = state.customPacks or {}
    state.packOverrides = state.packOverrides or {}
    return state
end

local function EnsureProfile(key, name)
    db.profiles = db.profiles or {}
    if not db.profiles[key] then
        db.profiles[key] = {
            name = name or key,
            plugins = {},
            enabledPlugins = {},
        }
    end
    db.profiles[key].name = db.profiles[key].name or name or key
    db.profiles[key].plugins = db.profiles[key].plugins or {}
    db.profiles[key].enabledPlugins = db.profiles[key].enabledPlugins or {}
    return db.profiles[key]
end

local function SortPluginOrder()
    wipe(pluginOrder)
    for pluginId in pairs(registeredPlugins) do
        pluginOrder[#pluginOrder + 1] = pluginId
    end
    table.sort(pluginOrder, function(a, b)
        local pa = registeredPlugins[a]
        local pb = registeredPlugins[b]
        local ao = pa and pa.order or 9999
        local bo = pb and pb.order or 9999
        if ao ~= bo then
            return ao < bo
        end
        return a < b
    end)
end

local function GetPluginIdsByLoadOrder()
    local ordered = {}
    for pluginId in pairs(registeredPlugins) do
        ordered[#ordered + 1] = pluginId
    end
    table.sort(ordered, function(a, b)
        local pa = registeredPlugins[a]
        local pb = registeredPlugins[b]
        local ai = pa and pa.__loadIndex or 0
        local bi = pb and pb.__loadIndex or 0
        if ai ~= bi then
            return ai < bi
        end
        return a < b
    end)
    return ordered
end

local function IsCustomPlugin(pluginId)
    return pluginId == CUSTOM_PLUGIN_ID
end

local function HasContentPlugins()
    for pluginId in pairs(registeredPlugins) do
        if not IsCustomPlugin(pluginId) then
            return true
        end
    end
    return false
end

local function GetCustomState(profile)
    return EnsurePluginState(profile, CUSTOM_PLUGIN_ID)
end

local function IsPluginEnabled(profile, pluginId)
    if not profile or not pluginId then
        return false
    end
    profile.enabledPlugins = profile.enabledPlugins or {}
    return profile.enabledPlugins[pluginId] ~= false
end

local function GetFirstPluginId()
    SortPluginOrder()
    local fallback = nil
    for _, pluginId in ipairs(pluginOrder) do
        if not fallback then
            fallback = pluginId
        end
        if not IsCustomPlugin(pluginId) then
            return pluginId
        end
    end
    return fallback
end

local function GetActivePluginId()
    if db and db.activePlugin and registeredPlugins[db.activePlugin] then
        return db.activePlugin
    end
    return GetFirstPluginId()
end

local function GetActivePlugin()
    local pluginId = GetActivePluginId()
    return pluginId and registeredPlugins[pluginId] or nil, pluginId
end

local function BuildAggregateCatalog()
    local profile = db and EnsureProfile(db.activeProfile or "default", "Default") or nil
    local catalog = {
        packs = {},
        zones = {},
        durations = {},
        subzoneKeys = {},
        subzoneNames = {},
        subzoneLookup = {},
        trackNames = {},
        labels = setmetatable({}, {
            __index = function(_, key)
                return key
            end,
        }),
    }

    for _, pluginId in ipairs(GetPluginIdsByLoadOrder()) do
        local plugin = registeredPlugins[pluginId]
        if not profile or IsPluginEnabled(profile, pluginId) then

            for localKey, pack in pairs(plugin.packs or {}) do
                local qualifiedKey = QualifyKey(pluginId, localKey)
                local aggregatePack = DeepCopy(pack)
                aggregatePack.pluginId = pluginId
                aggregatePack.localKey = localKey
                catalog.packs[qualifiedKey] = aggregatePack
            end

            for name, id in pairs(plugin.tracks or {}) do
                if catalog.trackNames[id] == nil then
                    catalog.trackNames[id] = name
                end
            end

            for id, dur in pairs(plugin.durations or {}) do
                catalog.durations[id] = dur
            end

            for localeKey, label in pairs(plugin.locales or {}) do
                catalog.labels[QualifyKey(pluginId, localeKey)] = label
            end

            for localKey, localizedText in pairs(plugin.subzoneNames or {}) do
                local displayKey = localizedText or localKey
                catalog.subzoneKeys[localKey] = displayKey
                catalog.subzoneKeys[displayKey] = displayKey
                catalog.subzoneNames[localKey] = displayKey
                catalog.subzoneNames[displayKey] = displayKey
                catalog.subzoneLookup[displayKey] = localKey
            end

            for mapId, zoneEntry in pairs(plugin.zones or {}) do
                local aggregateZone = {
                    pluginId = pluginId,
                    nameKey = zoneEntry.nameKey and QualifyKey(pluginId, zoneEntry.nameKey) or nil,
                    pack = QualifyPackKey(pluginId, zoneEntry.pack),
                }

                if zoneEntry.subzones then
                    aggregateZone.subzones = {}
                    for subKey, packKey in pairs(zoneEntry.subzones) do
                        local displayKey = (plugin.subzoneNames and plugin.subzoneNames[subKey]) or subKey
                        aggregateZone.subzones[displayKey] = QualifyPackKey(pluginId, packKey)
                        catalog.subzoneKeys[subKey] = displayKey
                        catalog.subzoneKeys[displayKey] = displayKey
                        catalog.subzoneNames[subKey] = displayKey
                        catalog.subzoneNames[displayKey] = displayKey
                        catalog.subzoneLookup[displayKey] = subKey
                    end
                end

                catalog.zones[mapId] = aggregateZone
            end
        end
    end

    catalog.packOrder = BuildSortedPackOrder(catalog.packs, function(key)
        local pack = catalog.packs and catalog.packs[key]
        local pluginId = pack and pack.pluginId or nil
        return pluginId and QualifyKey(pluginId, pack.localKey or key) or key
    end)
    return catalog
end

local function BuildAggregateSettings(catalog)
    local profile = EnsureProfile(db.activeProfile or "default", "Default")
    local settings = {
        enabled = db.enabled,
        verbose = db.verbose,
        silenceGap = db.silenceGap,
        crossfadeSec = db.crossfadeSec,
        zoneOverrides = {},
        customPacks = {},
        packOverrides = {},
    }

    if not IsPluginEnabled(profile, CUSTOM_PLUGIN_ID) then
        return settings
    end

    local customState = GetCustomState(profile)
    local subzoneKeys = catalog and catalog.subzoneKeys or {}

    for mapId, override in pairs(customState.zoneOverrides or {}) do
        local aggregateOverride = {
            pluginId = CUSTOM_PLUGIN_ID,
            isCustom = override.isCustom,
            name = override.name,
            pack = QualifyPackKey(CUSTOM_PLUGIN_ID, override.pack),
        }

        if override.subzones then
            aggregateOverride.subzones = {}
            for subKey, packKey in pairs(override.subzones) do
                local displayKey = subzoneKeys[subKey] or subKey
                aggregateOverride.subzones[displayKey] = QualifyPackKey(CUSTOM_PLUGIN_ID, packKey)
            end
        end

        settings.zoneOverrides[mapId] = aggregateOverride
    end

    for localKey, pack in pairs(customState.customPacks or {}) do
        local qualifiedKey = QualifyKey(CUSTOM_PLUGIN_ID, localKey)
        local aggregatePack = DeepCopy(pack)
        aggregatePack.pluginId = CUSTOM_PLUGIN_ID
        aggregatePack.localKey = localKey
        settings.customPacks[qualifiedKey] = aggregatePack
    end

    for localKey, override in pairs(customState.packOverrides or {}) do
        local qualifiedKey = SplitQualifiedKey(localKey) and localKey or QualifyKey(CUSTOM_PLUGIN_ID, localKey)
        settings.packOverrides[qualifiedKey] = DeepCopy(override)
    end

    return settings
end

local function GetCatalogZoneDisplayName(catalog, mapId, zoneEntry)
    local labels = catalog and catalog.labels or EMPTY_LABELS
    if zoneEntry and zoneEntry.nameKey and labels[zoneEntry.nameKey] then
        return labels[zoneEntry.nameKey]
    end
    local info = _G.C_Map and _G.C_Map.GetMapInfo and _G.C_Map.GetMapInfo(mapId)
    return (info and info.name) or ("Zone " .. tostring(mapId))
end

local function MigrateCollidingCustomZones(catalog)
    if not db or not db.profiles then
        return
    end

    local profile = EnsureProfile(db.activeProfile or "default", "Default")
    local customState = GetCustomState(profile)
    local converted = {}

    for mapId, override in pairs(customState.zoneOverrides or {}) do
        local zoneEntry = catalog and catalog.zones and catalog.zones[mapId]
        local ownerPluginId = zoneEntry and zoneEntry.pluginId or nil
        if override and override.isCustom and ownerPluginId and ownerPluginId ~= CUSTOM_PLUGIN_ID then
            override.isCustom = nil
            override.name = nil

            if not override.pack and not override.subzones then
                customState.zoneOverrides[mapId] = nil
            end

            local plugin = registeredPlugins[ownerPluginId]
            converted[#converted + 1] = {
                zoneName = GetCatalogZoneDisplayName(catalog, mapId, zoneEntry),
                pluginTitle = (plugin and plugin.title) or ownerPluginId,
            }
        end
    end

    if #converted == 0 then
        return
    end

    local details = {}
    for _, entry in ipairs(converted) do
        details[#details + 1] = ("%s -> %s"):format(entry.zoneName, entry.pluginTitle)
    end
    Warn(("Converted %d custom zone collision(s) into plugin overrides: %s"):format(#converted, table.concat(details, ", ")))
end

local function SyncActivePluginView()
    local plugin, pluginId = GetActivePlugin()
    if db and pluginId then
        local profile = EnsureProfile(db.activeProfile or "default", "Default")
        local customState = GetCustomState(profile)
        local pluginState = EnsurePluginState(profile, pluginId)
        if db.activePlugin ~= pluginId and (db.activePlugin or pluginId ~= CUSTOM_PLUGIN_ID or HasContentPlugins()) then
            db.activePlugin = pluginId
        end
        db.zoneOverrides = customState.zoneOverrides
        db.customPacks = customState.customPacks
        db.packOverrides = customState.packOverrides
        ns.pluginState = pluginState
        ns.CustomState = customState
    else
        ns.pluginState = nil
        ns.CustomState = nil
    end

    ns.ActivePluginId = pluginId
    ns.ActivePlugin = plugin
    ns.Tracks = plugin and plugin.tracks or {}
    ns.TrackDurations = plugin and plugin.durations or {}
    ns.MusicPacks = plugin and plugin.packs or {}
    ns.MusicPackOrder = BuildSortedPackOrder(ns.MusicPacks)
    ns.ZoneMusic = plugin and plugin.zones or {}
    ns.L = plugin and plugin.locales or EMPTY_LABELS
    ns.SubzoneNames = plugin and plugin.subzoneNames or {}
    ns.SubzoneKeys = (plugin and plugin.subzoneKeys) or BuildDerivedSubzoneKeys(ns.SubzoneNames)
    ns.TrackNames = BuildTrackNames(ns.Tracks)
end

local function SyncRuntimeCatalog()
    SortPluginOrder()
    runtimeCatalog = BuildAggregateCatalog()
    MigrateCollidingCustomZones(runtimeCatalog)
    ns.RuntimeCatalog = runtimeCatalog
    ns.RuntimeLabels = runtimeCatalog.labels
    if player and db then
        player:SetCatalog(runtimeCatalog)
        player:SetSettings(BuildAggregateSettings(runtimeCatalog))
    end
end

local function SyncAllViews()
    if db then
        SyncActivePluginView()
    end
    SyncRuntimeCatalog()
    if ns.InvalidateOptionCaches then
        ns.InvalidateOptionCaches()
    end
end

local function GetMigrationPluginIds(profile)
    local ordered = {}
    for pluginId in pairs(profile.plugins or {}) do
        if not IsCustomPlugin(pluginId) then
            ordered[#ordered + 1] = pluginId
        end
    end
    table.sort(ordered, function(a, b)
        local pa = registeredPlugins[a]
        local pb = registeredPlugins[b]
        local ai = pa and pa.__loadIndex or 0
        local bi = pb and pb.__loadIndex or 0
        if ai ~= bi then
            return ai < bi
        end
        return a < b
    end)
    return ordered
end

local function ReserveCustomPackKey(reserved, sourcePluginId, localKey)
    local base = localKey
    if sourcePluginId ~= CUSTOM_PLUGIN_ID then
        base = sourcePluginId .. "__" .. localKey
    end
    local candidate = base
    local idx = 2
    while reserved[candidate] do
        candidate = base .. "_" .. idx
        idx = idx + 1
    end
    reserved[candidate] = true
    return candidate
end

local function RemapPackReferenceForCustomState(sourcePluginId, customPackMap, packKey)
    if not packKey or packKey == "DEFAULT" or packKey == "NONE" then
        return packKey
    end
    if SplitQualifiedKey(packKey) then
        return packKey
    end
    if customPackMap and customPackMap[packKey] then
        return customPackMap[packKey]
    end
    if sourcePluginId == CUSTOM_PLUGIN_ID then
        return packKey
    end
    return QualifyKey(sourcePluginId, packKey)
end

local function ConsolidateProfileToCustomState(profile)
    profile.plugins = profile.plugins or {}
    profile.enabledPlugins = profile.enabledPlugins or {}

    local customState = GetCustomState(profile)
    local preservedCustom = DeepCopy(customState)
    local mergedState = {
        zoneOverrides = {},
        customPacks = {},
        packOverrides = {},
    }
    local reservedCustomPackKeys = {}
    for localKey in pairs(preservedCustom.customPacks or {}) do
        reservedCustomPackKeys[localKey] = true
    end

    for _, pluginId in ipairs(GetMigrationPluginIds(profile)) do
        local sourceState = EnsurePluginState(profile, pluginId)
        local customPackMap = {}

        for localKey, pack in pairs(sourceState.customPacks or {}) do
            local targetKey = ReserveCustomPackKey(reservedCustomPackKeys, pluginId, localKey)
            mergedState.customPacks[targetKey] = DeepCopy(pack)
            customPackMap[localKey] = targetKey
        end

        for mapId, override in pairs(sourceState.zoneOverrides or {}) do
            local converted = {
                isCustom = override.isCustom,
                name = override.name,
                pack = RemapPackReferenceForCustomState(pluginId, customPackMap, override.pack),
            }
            if override.subzones then
                converted.subzones = {}
                for subKey, packKey in pairs(override.subzones) do
                    converted.subzones[subKey] = RemapPackReferenceForCustomState(pluginId, customPackMap, packKey)
                end
            end
            mergedState.zoneOverrides[mapId] = converted
        end

        for localKey, override in pairs(sourceState.packOverrides or {}) do
            local targetKey = RemapPackReferenceForCustomState(pluginId, customPackMap, localKey)
            mergedState.packOverrides[targetKey] = DeepCopy(override)
        end
    end

    for mapId, override in pairs(preservedCustom.zoneOverrides or {}) do
        mergedState.zoneOverrides[mapId] = DeepCopy(override)
    end
    for localKey, pack in pairs(preservedCustom.customPacks or {}) do
        mergedState.customPacks[localKey] = DeepCopy(pack)
    end
    for packKey, override in pairs(preservedCustom.packOverrides or {}) do
        mergedState.packOverrides[packKey] = DeepCopy(override)
    end

    customState.zoneOverrides = mergedState.zoneOverrides
    customState.customPacks = mergedState.customPacks
    customState.packOverrides = mergedState.packOverrides

    for pluginId, state in pairs(profile.plugins) do
        if not IsCustomPlugin(pluginId) then
            state.zoneOverrides = {}
            state.customPacks = {}
            state.packOverrides = {}
        end
    end
end

local function MigrateLegacyDb(target)
    local legacy = _G.EchoesOfQuelThalasDB
    if target.enabled == nil then
        target.enabled = legacy and legacy.enabled
        if target.enabled == nil then
            target.enabled = true
        end
    end

    if target.verbose == nil then
        target.verbose = legacy and legacy.verbose or false
    end
    if target.silenceGap == nil then
        target.silenceGap = legacy and legacy.silenceGap or 4
    end
    if target.crossfadeSec == nil then
        target.crossfadeSec = 3
    end

    if not target.profiles then
        target.profiles = {}
    end

    if next(target.profiles) == nil then
        if legacy and legacy.profiles then
            for key, profile in pairs(legacy.profiles) do
                target.profiles[key] = {
                    name = profile.name or key,
                    plugins = {
                        [LEGACY_PLUGIN_ID] = {
                            zoneOverrides = DeepCopy(profile.zoneOverrides or {}),
                            customPacks = DeepCopy(profile.customPacks or {}),
                            packOverrides = DeepCopy(legacy.packOverrides or {}),
                        },
                    },
                    enabledPlugins = {},
                }
            end
        elseif legacy and (legacy.zoneOverrides or legacy.customPacks or legacy.packOverrides) then
            target.profiles.default = {
                name = "Default",
                plugins = {
                    [LEGACY_PLUGIN_ID] = {
                        zoneOverrides = DeepCopy(legacy.zoneOverrides or {}),
                        customPacks = DeepCopy(legacy.customPacks or {}),
                        packOverrides = DeepCopy(legacy.packOverrides or {}),
                    },
                },
                enabledPlugins = {},
            }
        else
            target.profiles.default = {
                name = "Default",
                plugins = {},
                enabledPlugins = {},
            }
        end
    end

    for key, profile in pairs(target.profiles) do
        if not profile.plugins then
            profile.plugins = {
                [LEGACY_PLUGIN_ID] = {
                    zoneOverrides = DeepCopy(profile.zoneOverrides or {}),
                    customPacks = DeepCopy(profile.customPacks or {}),
                    packOverrides = DeepCopy(target.packOverrides or {}),
                },
            }
            profile.zoneOverrides = nil
            profile.customPacks = nil
        end
        profile.enabledPlugins = profile.enabledPlugins or {}
        EnsurePluginState(profile, LEGACY_PLUGIN_ID)
        EnsurePluginState(profile, CUSTOM_PLUGIN_ID)
        ConsolidateProfileToCustomState(profile)
        profile.name = profile.name or key
    end

    target.activeProfile = target.activeProfile or (legacy and legacy.activeProfile) or "default"
    if not target.profiles[target.activeProfile] then
        target.activeProfile = "default"
    end
    if not target.activePlugin or not registeredPlugins[target.activePlugin] or target.activePlugin == CUSTOM_PLUGIN_ID then
        target.activePlugin = GetFirstPluginId()
    end

    target.schemaVersion = CORE_DB_VERSION
    return target
end

local function CaptureContext(isLoadingTransition)
    return {
        mapId = C_Map.GetBestMapForUnit("player"),
        subzoneText = GetSubZoneText() or "",
        zoneText = GetZoneText() or "",
        isInInstance = IsInInstance(),
        musicEnabled = GetCVar("Sound_EnableMusic") ~= "0",
        isLoadingScreenTransition = isLoadingTransition == true,
        hour = GetGameTime(),
    }
end

local function CheckZone(forceRestart)
    if not player or not db then
        return
    end
    local context = CaptureContext(loadingScreenEnded)
    loadingScreenEnded = false
    player:UpdateContext(context, forceRestart)
end

local function ScheduleCheck()
    if pendingCheck or not player then
        return
    end
    pendingCheck = C_Timer.NewTimer(0.5, function()
        pendingCheck = nil
        CheckZone()
    end)
end

local function CancelPendingCheck()
    if pendingCheck then
        pendingCheck:Cancel()
        pendingCheck = nil
    end
end

local function PrintTrack(track, dur)
    if not db or not db.verbose then
        return
    end
    local name = runtimeCatalog and runtimeCatalog.trackNames and runtimeCatalog.trackNames[track] or tostring(track)
    print(PREFIX .. name .. "  (" .. string.format("%.0f", dur) .. "s)")
end

local function EnsurePlayer()
    if player or not MusicLib then
        return
    end
    player = MusicLib:NewPlayer({
        callbacks = {
            OnTrackStart = PrintTrack,
        },
    })
    if db then
        SyncRuntimeCatalog()
    end
end

local function DecodeProfilePayload(str)
    local LibSerialize = LibStub and LibStub("LibSerialize", true)
    local LibDeflate = LibStub and LibStub("LibDeflate", true)
    if not LibSerialize or not LibDeflate then
        return nil, "Libraries not loaded"
    end

    local mode = nil
    local payload = nil
    if str:sub(1, 6) == "EoA:3:" then
        mode = "eoa3"
        payload = str:sub(7)
    elseif str:sub(1, 6) == "EoA:2:" then
        mode = "eoa2"
        payload = str:sub(7)
    elseif str:sub(1, 6) == "EoA:1:" then
        mode = "eoa1"
        payload = str:sub(7)
    elseif str:sub(1, 7) == "EoQT:2:" then
        mode = "eoqt2"
        payload = str:sub(8)
    elseif str:sub(1, 7) == "EoQT:1:" then
        mode = "eoqt1"
        payload = str:sub(8)
    else
        return nil, "Not a valid Echoes profile string"
    end

    local compressed = LibDeflate:DecodeForPrint(payload)
    if not compressed then
        return nil, "Failed to decode string"
    end

    local decompressed = LibDeflate:DecompressDeflate(compressed)
    if not decompressed then
        return nil, "Failed to decompress"
    end

    local ok, data = LibSerialize:Deserialize(decompressed)
    if not ok or type(data) ~= "table" then
        return nil, "Failed to deserialize"
    end

    if mode == "eoa3" or mode == "eoa2" then
        return data
    end

    if mode == "eoa1" then
        return data
    end

    if mode == "eoqt2" then
        return {
            pluginId = LEGACY_PLUGIN_ID,
            plugin = {
                zoneOverrides = data.zoneOverrides or {},
                customPacks = data.customPacks or {},
                packOverrides = {},
            },
        }
    end

    return {
        pluginId = LEGACY_PLUGIN_ID,
        plugin = {
            zoneOverrides = data or {},
            customPacks = {},
            packOverrides = {},
        },
    }
end

local function NormalizeImportedPluginPayload(data)
    if type(data) ~= "table" then
        return {}
    end
    if data.profile and type(data.profile.plugins) == "table" then
        return data.profile.plugins
    end
    if data.pluginId and data.plugin then
        return {
            [data.pluginId] = data.plugin,
        }
    end
    return {}
end

local function NormalizeImportedEnabledPlugins(data)
    if type(data) ~= "table" then
        return {}
    end
    if data.profile and type(data.profile.enabledPlugins) == "table" then
        return data.profile.enabledPlugins
    end
    return {}
end

local function BuildFilteredImportedPlugins(data)
    local imported = {}
    for pluginId, pluginData in pairs(NormalizeImportedPluginPayload(data)) do
        if registeredPlugins[pluginId] and type(pluginData) == "table" then
            imported[pluginId] = {
                zoneOverrides = DeepCopy(pluginData.zoneOverrides or {}),
                customPacks = DeepCopy(pluginData.customPacks or {}),
                packOverrides = DeepCopy(pluginData.packOverrides or {}),
            }
        end
    end
    return imported
end

local function BuildFilteredImportedEnabledPlugins(data)
    local enabledPlugins = {}
    for pluginId, enabled in pairs(NormalizeImportedEnabledPlugins(data)) do
        if registeredPlugins[pluginId] then
            if enabled == false then
                enabledPlugins[pluginId] = false
            end
        end
    end
    return enabledPlugins
end

local function MergePluginState(targetState, sourceState)
    for key, value in pairs(sourceState.zoneOverrides or {}) do
        if targetState.zoneOverrides[key] == nil then
            targetState.zoneOverrides[key] = DeepCopy(value)
        end
    end
    for key, value in pairs(sourceState.customPacks or {}) do
        if targetState.customPacks[key] == nil then
            targetState.customPacks[key] = DeepCopy(value)
        end
    end
    for key, value in pairs(sourceState.packOverrides or {}) do
        if targetState.packOverrides[key] == nil then
            targetState.packOverrides[key] = DeepCopy(value)
        end
    end
end

ns.RegisterPlugin = function(def)
    ValidatePluginDefinition(def)
    local plugin = DeepCopy(def)
    plugin.subzoneKeys = plugin.subzoneKeys or BuildDerivedSubzoneKeys(plugin.subzoneNames)
    if not plugin.__loadIndex then
        pluginRegistrationSeq = pluginRegistrationSeq + 1
        plugin.__loadIndex = pluginRegistrationSeq
    end
    registeredPlugins[plugin.id] = plugin
    if db then
        for _, profile in pairs(db.profiles or {}) do
            EnsurePluginState(profile, plugin.id)
            profile.enabledPlugins = profile.enabledPlugins or {}
        end
        if not db.activePlugin or not registeredPlugins[db.activePlugin] or (db.activePlugin == CUSTOM_PLUGIN_ID and not IsCustomPlugin(plugin.id)) then
            db.activePlugin = GetFirstPluginId() or plugin.id
        end
    end
    SyncAllViews()
    if optionsInitialized and ns.RefreshAllOptions then
        ns.RefreshAllOptions()
    end
    ScheduleCheck()
end

api.RegisterPlugin = ns.RegisterPlugin
api.GetRegisteredPlugins = function()
    return registeredPlugins
end

ns.RegisterPlugin({
    id = CUSTOM_PLUGIN_ID,
    title = "Custom",
    description = "User overrides, custom packs, and custom zones.",
    order = 100000,
    category = "User",
    tracks = {},
    durations = {},
    packs = {},
    zones = {},
    locales = EMPTY_LABELS,
    subzoneNames = {},
    subzoneKeys = {},
    isInternal = true,
    isCustom = true,
})

ns.GetRegisteredPlugins = function()
    return registeredPlugins
end

ns.GetEditablePlugins = function()
    local profile = db and EnsureProfile(db.activeProfile or "default", "Default") or nil
    SortPluginOrder()
    local list = {}
    for _, pluginId in ipairs(pluginOrder) do
        local plugin = registeredPlugins[pluginId]
        list[#list + 1] = {
            id = pluginId,
            title = (plugin and plugin.title) or pluginId,
            description = plugin and plugin.description or nil,
            category = plugin and plugin.category or nil,
            isCustom = IsCustomPlugin(pluginId),
            enabled = profile and IsPluginEnabled(profile, pluginId) or true,
        }
    end
    return list
end

ns.IsPluginEnabled = function(pluginId)
    if not db or not registeredPlugins[pluginId] then
        return false
    end
    local profile = EnsureProfile(db.activeProfile or "default", "Default")
    return IsPluginEnabled(profile, pluginId)
end

ns.SetPluginEnabled = function(pluginId, enabled)
    if not db or not registeredPlugins[pluginId] then
        return false
    end
    local profile = EnsureProfile(db.activeProfile or "default", "Default")
    profile.enabledPlugins = profile.enabledPlugins or {}
    if enabled == false then
        profile.enabledPlugins[pluginId] = false
    else
        profile.enabledPlugins[pluginId] = nil
    end
    SyncAllViews()
    if ns.RefreshAllOptions then
        ns.RefreshAllOptions()
    end
    ns.ForceCheckZone()
    return true
end

ns.SetActivePlugin = function(pluginId)
    if not db or not registeredPlugins[pluginId] then
        return false
    end
    db.activePlugin = pluginId
    SyncAllViews()
    if ns.RefreshAllOptions then
        ns.RefreshAllOptions()
    end
    return true
end

ns.GetPluginState = function(pluginId)
    if not db or not db.profiles then
        return nil
    end
    local profile = EnsureProfile(db.activeProfile or "default", "Default")
    return EnsurePluginState(profile, pluginId)
end

ns.GetCustomPluginId = function()
    return CUSTOM_PLUGIN_ID
end

ns.IsCustomPluginId = function(pluginId)
    return IsCustomPlugin(pluginId)
end

ns.GetSelectablePacks = function()
    local profile = db and EnsureProfile(db.activeProfile or "default", "Default") or nil
    local list = {}
    for _, packKey in ipairs(runtimeCatalog and runtimeCatalog.packOrder or {}) do
        local pack = runtimeCatalog and runtimeCatalog.packs and runtimeCatalog.packs[packKey]
        local plugin = pack and registeredPlugins[pack.pluginId] or nil
        if pack then
            list[#list + 1] = {
                key = packKey,
                label = ((plugin and plugin.title) or pack.pluginId or "Plugin") .. ": " .. (pack.label or packKey),
                pluginId = pack.pluginId,
                isCustomPack = false,
            }
        end
    end
    if profile then
        local customState = GetCustomState(profile)
        for localKey, pack in pairs(customState.customPacks or {}) do
            list[#list + 1] = {
                key = localKey,
                label = (pack.label or localKey) .. " *",
                pluginId = CUSTOM_PLUGIN_ID,
                isCustomPack = true,
            }
        end
    end
    table.sort(list, function(a, b)
        return (a.label or "") < (b.label or "")
    end)
    return list
end

ns.GetPack = function(key)
    if not key then
        return nil
    end
    local pluginId = SplitQualifiedKey(key)
    if pluginId then
        if player then
            return player:GetPack(key)
        end
        return runtimeCatalog and runtimeCatalog.packs and runtimeCatalog.packs[key] or nil
    end
    return ns.MusicPacks[key] or (db and db.customPacks and db.customPacks[key])
end

ns.BuildPool = function(config, packKey)
    if not player then
        return {}
    end
    local effectivePackKey = packKey
    if packKey then
        local pluginId = SplitQualifiedKey(packKey)
        if not pluginId and ns.ActivePluginId then
            effectivePackKey = QualifyKey(ns.ActivePluginId, packKey)
        end
    end
    return player:BuildPool(config, effectivePackKey, CaptureContext(false))
end

ns.ResolveZone = function(mapId)
    if not player then
        return nil, nil
    end
    return player:ResolveZone(mapId)
end

ns.ForceCheckZone = function(forceRestart)
    CancelPendingCheck()
    CheckZone(forceRestart)
end

ns.PreviewTrack = function(fdid)
    EnsurePlayer()
    if player then
        player:PreviewTrack(fdid)
    end
end

ns.StopPreview = function()
    if not player then
        return
    end
    local context = CaptureContext(false)
    local zoneId = ns.ResolveZone(context.mapId)
    if zoneId then
        player:StopPreview(context)
    else
        player:StopPreview(nil)
    end
end

ns.SetEnabled = function(val)
    if not db then
        return
    end
    db.enabled = val
    SyncRuntimeCatalog()
    if val then
        ns.ForceCheckZone()
    elseif player then
        player:Stop(false)
    end
end

ns.ApplyRuntimeSettings = function()
    if not db then
        return
    end
    SyncRuntimeCatalog()
end

ns.GetProfileList = function()
    if not db or not db.profiles then
        return {}
    end
    local list = {}
    for key, profile in pairs(db.profiles) do
        list[#list + 1] = {
            key = key,
            name = profile.name or key,
            active = key == db.activeProfile,
        }
    end
    table.sort(list, function(a, b)
        if a.key == "default" then
            return true
        end
        if b.key == "default" then
            return false
        end
        return (a.name or "") < (b.name or "")
    end)
    return list
end

ns.SwitchProfile = function(key)
    if not db or not db.profiles or not db.profiles[key] then
        return false
    end
    db.activeProfile = key
    SyncAllViews()
    if ns.RefreshAllOptions then
        ns.RefreshAllOptions()
    end
    ns.ForceCheckZone()
    return true
end

ns.CreateProfile = function(name)
    if not db then
        return nil
    end
    local key = "prof_" .. time()
    local profile = EnsureProfile(key, name or "New Profile")
    for pluginId in pairs(registeredPlugins) do
        EnsurePluginState(profile, pluginId)
    end
    return key
end

ns.RenameProfile = function(key, newName)
    if db and db.profiles and db.profiles[key] then
        db.profiles[key].name = newName
    end
end

ns.DeleteProfile = function(key)
    if key == "default" then
        return false, "Cannot delete the Default profile"
    end
    if not db or not db.profiles or not db.profiles[key] then
        return false, "Profile not found"
    end
    db.profiles[key] = nil
    if db.activeProfile == key then
        ns.SwitchProfile("default")
    end
    return true
end

ns.ExportProfile = function()
    if not db then
        return nil, "Addon not loaded"
    end
    local profile = EnsureProfile(db.activeProfile or "default", "Default")
    local LibSerialize = LibStub and LibStub("LibSerialize", true)
    local LibDeflate = LibStub and LibStub("LibDeflate", true)
    if not LibSerialize or not LibDeflate then
        return nil, "Libraries not loaded"
    end

    local payload = {
        profile = {
            plugins = DeepCopy(profile.plugins or {}),
            enabledPlugins = DeepCopy(profile.enabledPlugins or {}),
        },
    }
    local serialized = LibSerialize:Serialize(payload)
    local compressed = LibDeflate:CompressDeflate(serialized)
    local encoded = LibDeflate:EncodeForPrint(compressed)
    return "EoA:3:" .. encoded
end

ns.ImportProfile = function(str, mode)
    if type(str) ~= "string" then
        return false, "Invalid input"
    end
    if not db then
        return false, "Addon not loaded"
    end

    local data, err = DecodeProfilePayload(str)
    if not data then
        return false, err
    end

    local profile = EnsureProfile(db.activeProfile or "default", "Default")
    local importedPlugins = BuildFilteredImportedPlugins(data)
    local importedEnabledPlugins = BuildFilteredImportedEnabledPlugins(data)

    if mode == "replace" then
        profile.plugins = {}
        profile.enabledPlugins = {}
        for pluginId in pairs(registeredPlugins) do
            local state = EnsurePluginState(profile, pluginId)
            local pluginData = importedPlugins[pluginId]
            if pluginData then
                state.zoneOverrides = DeepCopy(pluginData.zoneOverrides or {})
                state.customPacks = DeepCopy(pluginData.customPacks or {})
                state.packOverrides = DeepCopy(pluginData.packOverrides or {})
            end
        end
        for pluginId, enabled in pairs(importedEnabledPlugins) do
            if enabled == false then
                profile.enabledPlugins[pluginId] = false
            end
        end
    else
        for pluginId, pluginData in pairs(importedPlugins) do
            local state = EnsurePluginState(profile, pluginId)
            MergePluginState(state, pluginData)
        end
        for pluginId, enabled in pairs(importedEnabledPlugins) do
            if enabled == false and profile.enabledPlugins[pluginId] == nil then
                profile.enabledPlugins[pluginId] = false
            end
        end
    end

    ConsolidateProfileToCustomState(profile)

    SyncAllViews()
    if ns.RefreshAllOptions then
        ns.RefreshAllOptions()
    end
    ns.ForceCheckZone()
    return true
end

ns.ImportIntoNewProfile = function(str, name)
    if type(str) ~= "string" then
        return false, "Invalid input"
    end
    if not db then
        return false, "Addon not loaded"
    end

    local data, err = DecodeProfilePayload(str)
    if not data then
        return false, err
    end

    local key = "prof_" .. time()
    local profile = EnsureProfile(key, name or "Imported Profile")
    local importedPlugins = BuildFilteredImportedPlugins(data)
    local importedEnabledPlugins = BuildFilteredImportedEnabledPlugins(data)
    profile.plugins = {}
    profile.enabledPlugins = {}
    for pluginId in pairs(registeredPlugins) do
        local state = EnsurePluginState(profile, pluginId)
        local pluginData = importedPlugins[pluginId]
        if pluginData then
            state.zoneOverrides = DeepCopy(pluginData.zoneOverrides or {})
            state.customPacks = DeepCopy(pluginData.customPacks or {})
            state.packOverrides = DeepCopy(pluginData.packOverrides or {})
        end
    end
    for pluginId, enabled in pairs(importedEnabledPlugins) do
        if enabled == false then
            profile.enabledPlugins[pluginId] = false
        end
    end
    ConsolidateProfileToCustomState(profile)
    return true, key
end

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
frame:RegisterEvent("ZONE_CHANGED")
frame:RegisterEvent("ZONE_CHANGED_INDOORS")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("CVAR_UPDATE")

frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then
        _G.EchoesOfAzerothDB = _G.EchoesOfAzerothDB or {}
        db = MigrateLegacyDb(_G.EchoesOfAzerothDB)
        ns.db = db
        EnsurePlayer()
        SyncAllViews()
        if ns.InitOptions and not optionsInitialized then
            ns.InitOptions()
            optionsInitialized = true
        end
        return
    end

    if event == "PLAYER_LOGOUT" then
        CancelPendingCheck()
        if player then
            player:Stop(true)
        end
        return
    end

    if event == "PLAYER_ENTERING_WORLD" then
        loadingScreenEnded = true
    end

    if event == "CVAR_UPDATE" and arg1 ~= "Sound_EnableMusic" then
        return
    end

    if not db then
        return
    end
    ScheduleCheck()
end)

SLASH_ECHOESOFAZEROTH1 = "/eoa"
SLASH_ECHOESOFAZEROTH2 = "/eoqt"
SlashCmdList["ECHOESOFAZEROTH"] = function(msg)
    msg = msg:lower():trim()

    if msg == "on" then
        ns.SetEnabled(true)
        print(PREFIX .. "Enabled.")

    elseif msg == "off" then
        ns.SetEnabled(false)
        print(PREFIX .. "Disabled.")

    elseif msg == "zones" then
        print(PREFIX .. "Configured zones:")
        for mapId, zoneEntry in pairs(runtimeCatalog and runtimeCatalog.zones or {}) do
            local packConfig = zoneEntry.pack and ns.GetPack(zoneEntry.pack)
            local n = packConfig and #ns.BuildPool(packConfig, zoneEntry.pack) or 0
            local subs = zoneEntry.subzones and 0 or nil
            if zoneEntry.subzones then
                for _ in pairs(zoneEntry.subzones) do
                    subs = subs + 1
                end
            end
            local packLabel = packConfig and packConfig.label or "?"
            local line = "  " .. ((runtimeCatalog and runtimeCatalog.labels and runtimeCatalog.labels[zoneEntry.nameKey]) or zoneEntry.nameKey or mapId) ..
                "  (mapId " .. mapId .. ")  - " .. packLabel .. " (" .. n .. " tracks)"
            if subs and subs > 0 then
                line = line .. ", " .. subs .. " subzones"
            end
            print(line)
        end

    elseif msg == "now" then
        local context = CaptureContext(false)
        local zoneId, zoneConfig = ns.ResolveZone(context.mapId)
        local chain = {}
        local walkId = context.mapId
        for _ = 1, 7 do
            if not walkId or walkId == 0 then
                break
            end
            local info = C_Map.GetMapInfo(walkId)
            if not info then
                break
            end
            chain[#chain + 1] = info.name .. " (" .. walkId .. ")"
            walkId = info.parentMapID
        end

        print(PREFIX .. "subzone=\"" .. context.subzoneText .. "\"  zone=\"" .. context.zoneText .. "\"")
        print(PREFIX .. "map chain: " .. table.concat(chain, " > "))

        if zoneId and zoneConfig and player then
            local resolved = player:ResolveContext(context)
            if resolved and resolved.effectiveConfig then
                local trackCount = #ns.BuildPool(resolved.effectiveConfig, resolved.groupKey)
                local zoneName = (zoneConfig.nameKey and runtimeCatalog and runtimeCatalog.labels and runtimeCatalog.labels[zoneConfig.nameKey]) or ("zone " .. zoneId)
                local groupStr = resolved.groupKey and ("  group=\"" .. resolved.groupKey .. "\"") or ""
                if resolved.subKey then
                    print(PREFIX .. "Mapped: " .. zoneName .. " > " .. resolved.subKey .. "  (" .. trackCount .. " tracks)" .. groupStr)
                else
                    print(PREFIX .. "Mapped: " .. zoneName .. "  [zone defaults]  (" .. trackCount .. " tracks)" .. groupStr)
                end
            else
                print(PREFIX .. "No music configured for this location.")
            end
        else
            print(PREFIX .. "No music configured for this location.")
        end

    elseif msg == "options" or msg == "config" then
        if ns.settingsCategoryID then
            Settings.OpenToCategory(ns.settingsCategoryID)
        else
            print(PREFIX .. "Settings panel not ready yet.")
        end

    elseif msg == "verbose" then
        db.verbose = not db.verbose
        SyncRuntimeCatalog()
        print(PREFIX .. (db.verbose and "Verbose mode on." or "Verbose mode off."))

    elseif msg:match("^plugin%s+") then
        local pluginId = msg:match("^plugin%s+(.+)$")
        if ns.SetActivePlugin(pluginId) then
            local plugin = registeredPlugins[pluginId]
            print(PREFIX .. "Active plugin: " .. ((plugin and plugin.title) or pluginId))
        else
            print(PREFIX .. "Unknown plugin: " .. tostring(pluginId))
        end

    elseif msg == "export" then
        local str, err = ns.ExportProfile()
        if not str then
            print(PREFIX .. "Export failed: " .. (err or "nothing to export"))
            return
        end
        local chunk = 200
        local total = math.ceil(#str / chunk)
        print(PREFIX .. "Profile export (" .. #str .. " chars, " .. total .. " message(s)):")
        for i = 1, total do
            DEFAULT_CHAT_FRAME:AddMessage(string.format("[EoA %d/%d] %s", i, total, str:sub((i - 1) * chunk + 1, i * chunk)))
        end

    elseif msg == "" then
        ns.SetEnabled(not db.enabled)
        print(PREFIX .. (db.enabled and "Enabled." or "Disabled."))

    else
        print(PREFIX .. "Commands: /eoa [on|off|zones|now|verbose|options|export|plugin <id>]")
    end
end
