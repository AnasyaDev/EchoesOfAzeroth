local addonName, ns = ...

local api = _G.EchoesOfAzeroth or {}
_G.EchoesOfAzeroth = api
local unpackList = table.unpack or unpack

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

local function CopyList(list, fieldName)
    if list == nil then
        return nil
    end
    if type(list) ~= "table" then
        error(("EchoesOfAzeroth.PluginDsl.%s expects a list table"):format(fieldName))
    end
    local out = {}
    for i, value in ipairs(list) do
        out[i] = value
    end
    return out
end

local function ValidateTable(value, fieldName)
    if value ~= nil and type(value) ~= "table" then
        error(("EchoesOfAzeroth.PluginDsl expected %s to be a table"):format(fieldName))
    end
end

local function NormalizePackArgs(labelOrSpec, spec, helperName)
    local label = labelOrSpec
    local packSpec = spec
    if packSpec == nil then
        if type(labelOrSpec) ~= "table" then
            error(("EchoesOfAzeroth.PluginDsl.%s requires a spec table"):format(helperName))
        end
        packSpec = labelOrSpec
        label = packSpec.label
    end
    if type(label) ~= "string" or label == "" then
        error(("EchoesOfAzeroth.PluginDsl.%s requires a non-empty label"):format(helperName))
    end
    if type(packSpec) ~= "table" then
        error(("EchoesOfAzeroth.PluginDsl.%s requires a spec table"):format(helperName))
    end
    return label, packSpec
end

local Dsl = {}

function Dsl.mergeUnique(...)
    local out = {}
    local seen = {}
    for i = 1, select("#", ...) do
        local list = select(i, ...)
        if list ~= nil then
            if type(list) ~= "table" then
                error("EchoesOfAzeroth.PluginDsl.mergeUnique expects list tables")
            end
            for _, track in ipairs(list) do
                if track ~= nil and not seen[track] then
                    seen[track] = true
                    out[#out + 1] = track
                end
            end
        end
    end
    return out
end

function Dsl.pack(label, spec)
    local resolvedLabel, resolvedSpec = NormalizePackArgs(label, spec, "pack")

    local pack = {
        label = resolvedLabel,
    }

    if resolvedSpec.intro ~= nil then
        pack.intro = resolvedSpec.intro
    end
    if resolvedSpec.day ~= nil then
        pack.day = CopyList(resolvedSpec.day, "pack.day")
    end
    if resolvedSpec.night ~= nil then
        pack.night = CopyList(resolvedSpec.night, "pack.night")
    end
    if resolvedSpec.any ~= nil then
        pack.any = CopyList(resolvedSpec.any, "pack.any")
    end

    if not pack.day and not pack.night and not pack.any then
        error("EchoesOfAzeroth.PluginDsl.pack requires at least one of day, night, or any")
    end

    return pack
end

function Dsl.mixedPack(label, ...)
    if type(label) ~= "string" or label == "" then
        error("EchoesOfAzeroth.PluginDsl.mixedPack requires a non-empty label")
    end

    local sourceCount = select("#", ...)
    if sourceCount == 0 then
        error("EchoesOfAzeroth.PluginDsl.mixedPack requires at least one source pack")
    end

    local pack = { label = label }
    local dayLists = {}
    local nightLists = {}
    local anyLists = {}

    for i = 1, sourceCount do
        local source = select(i, ...)
        if type(source) ~= "table" then
            error("EchoesOfAzeroth.PluginDsl.mixedPack expects pack tables")
        end
        if pack.intro == nil and source.intro ~= nil then
            pack.intro = source.intro
        end
        if source.day ~= nil then
            dayLists[#dayLists + 1] = source.day
        end
        if source.night ~= nil then
            nightLists[#nightLists + 1] = source.night
        end
        if source.any ~= nil then
            anyLists[#anyLists + 1] = source.any
        end
    end

    if #dayLists > 0 then
        pack.day = Dsl.mergeUnique(unpackList(dayLists))
    end
    if #nightLists > 0 then
        pack.night = Dsl.mergeUnique(unpackList(nightLists))
    end
    if #anyLists > 0 then
        pack.any = Dsl.mergeUnique(unpackList(anyLists))
    end

    return Dsl.pack(pack)
end

function Dsl.zone(nameKey, packKey, subzones)
    if type(nameKey) ~= "string" or nameKey == "" then
        error("EchoesOfAzeroth.PluginDsl.zone requires a non-empty nameKey")
    end
    if packKey ~= nil and type(packKey) ~= "string" then
        error("EchoesOfAzeroth.PluginDsl.zone pack key must be a string or nil")
    end
    ValidateTable(subzones, "subzones")

    local zone = {
        nameKey = nameKey,
        pack = packKey,
    }

    if subzones then
        zone.subzones = DeepCopy(subzones)
    end

    if zone.pack == nil and zone.subzones == nil then
        error("EchoesOfAzeroth.PluginDsl.zone requires a pack key or subzones")
    end

    return zone
end

function Dsl.plugin(def)
    if type(def) ~= "table" then
        error("EchoesOfAzeroth.PluginDsl.plugin requires a table")
    end
    if type(def.id) ~= "string" or def.id == "" then
        error("EchoesOfAzeroth.PluginDsl.plugin requires a non-empty id")
    end
    if type(def.title) ~= "string" or def.title == "" then
        error("EchoesOfAzeroth.PluginDsl.plugin requires a non-empty title")
    end

    local plugin = DeepCopy(def)
    plugin.tracks = plugin.tracks or {}
    plugin.durations = plugin.durations or {}
    plugin.packs = plugin.packs or {}
    plugin.zones = plugin.zones or {}
    plugin.locales = plugin.locales or {}
    plugin.subzoneNames = plugin.subzoneNames or {}
    plugin.subzoneKeys = plugin.subzoneKeys or {}
    return plugin
end

function Dsl.registerPlugin(def)
    local register = (_G.EchoesOfAzeroth and _G.EchoesOfAzeroth.RegisterPlugin) or api.RegisterPlugin
    if not register then
        error("EchoesOfAzeroth core must load before using PluginDsl.registerPlugin")
    end
    return register(Dsl.plugin(def))
end

ns.PluginDsl = Dsl
api.PluginDsl = Dsl
