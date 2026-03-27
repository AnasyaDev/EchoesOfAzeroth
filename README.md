# Echoes of Azeroth

Echoes of Azeroth is the core addon for modular contextual music replacement in World of Warcraft.

It provides the runtime, settings UI, profile system, custom packs, custom zones, import/export, and plugin management used by content addons such as `EchoesOfAzeroth_QuelThalas` and `EchoesOfAzeroth_ZulAman`.

## What the core addon does

- Loads and manages music content plugins
- Lets you enable or disable plugins per profile
- Lets you override zone and subzone mappings
- Supports custom music packs and custom zones
- Exports and imports profiles
- Handles track rotation, silence gaps, and crossfade timing

## Installation

Install `EchoesOfAzeroth` first, then install one or more content plugins.

Examples:

- `EchoesOfAzeroth_QuelThalas`
- `EchoesOfAzeroth_ZulAman`

Plugins depend on this core addon and will not work correctly without it.

## Settings

Open the settings from:

- `/eoa options`
- `/eoqt options`
- `Options -> AddOns -> Echoes of Azeroth`

Main sections:

- `Zone Mapping`
- `Music Packs`
- `Plugins`
- `Profiles`

## Slash commands

- `/eoa on`
- `/eoa off`
- `/eoa now`
- `/eoa zones`
- `/eoa verbose`
- `/eoa options`
- `/eoa export`
- `/eoa plugin <id>`

`/eoqt` is kept as an alias for compatibility with the older addon.

## Profiles and plugins

Each profile stores:

- enabled plugins
- custom zone and subzone overrides
- custom packs
- pack-level track toggles

This lets you keep different music setups for different characters or playstyles.

## For plugin authors

Content plugins register:

- tracks
- durations
- packs
- zone mappings
- localized labels

The core addon aggregates enabled plugins at runtime and exposes them through a single UI.

### Plugin DSL

The core addon exposes `EchoesOfAzeroth.PluginDsl` as the standard way to author content plugins.

Available helpers:

- `PluginDsl.mergeUnique(...)`
- `PluginDsl.pack(label, spec)` or `PluginDsl.pack(spec)`
- `PluginDsl.mixedPack(label, ...)`
- `PluginDsl.zone(nameKey, packKey, subzones)`
- `PluginDsl.plugin(def)`
- `PluginDsl.registerPlugin(def)`

Example:

```lua
local _, ns = ...

local api = _G.EchoesOfAzeroth
local Dsl = api and api.PluginDsl
if not Dsl then
    error("EchoesOfAzeroth core must load before this plugin")
end

local T = ns.Tracks

local TBC_TRACKS = {
    T.ZA_WalkUni01,
    T.ZA_WalkUni02,
}

local MIDNIGHT_TRACKS = {
    T.MN_ZulAmanA,
    T.MN_ZulAmanB,
}

local packs = {
    ZULAMAN = Dsl.pack {
        label = "Zul'Aman (TBC)",
        any = TBC_TRACKS,
    },
    ZULAMAN_MIDNIGHT = Dsl.pack {
        label = "Zul'Aman (Midnight)",
        any = MIDNIGHT_TRACKS,
    },
}

packs.ZULAMAN_MIXED = Dsl.mixedPack("Zul'Aman (TBC + Midnight)", packs.ZULAMAN, packs.ZULAMAN_MIDNIGHT)

local zones = {
    [2437] = Dsl.zone("ZULAMAN", "ZULAMAN_MIXED"),
}

Dsl.registerPlugin({
    id = "zulaman",
    title = "Zul'Aman",
    description = "Amani and broader troll music for Zul'Aman.",
    order = 20,
    category = "Eastern Kingdoms",
    tracks = ns.Tracks,
    durations = ns.TrackDurations,
    packs = packs,
    zones = zones,
    locales = ns.L,
    subzoneNames = ns.SubzoneNames,
    subzoneKeys = ns.SubzoneKeys,
})
```

## Plugin author tutorial

This section walks through the practical order for building a content plugin from scratch.

The most important idea is:

1. Define tracks and durations.
2. Build music packs from those tracks.
3. Assign default packs to zones and subzones.
4. Add localized labels for zones and subzones.
5. Register the plugin.

Even though the addon is split into multiple files, the data model is simple:

- tracks are the raw audio building blocks
- packs are named track collections
- zones point to packs
- locales provide user-facing names

### Recommended file layout

Most plugins follow this layout:

- `Tracks.lua`
- `Packs.lua`
- `Zones.lua`
- `Locale.lua`
- `Plugin.lua`

This keeps content easy to debug and review.

Authoring standard:

- use `Dsl.pack(...)` and `Dsl.mixedPack(...)` in `Packs.lua`
- use `Dsl.zone(...)` in `Zones.lua`
- use `Dsl.registerPlugin(...)` in `Plugin.lua`
- do not provide `packOrder`; the core generates a stable alphabetical order automatically

### Step 1: Define tracks and durations

Start with the smallest possible track catalog.

Each symbolic track name maps to a `FileDataID`, and each `FileDataID` should also have a duration:

```lua
local _, ns = ...

ns.Tracks = {
    MY_ZONE_DAY_A = 123456,
    MY_ZONE_DAY_B = 123457,
    MY_ZONE_NIGHT_A = 123458,
}

ns.TrackDurations = {
    [123456] = 95.2,
    [123457] = 87.1,
    [123458] = 102.4,
}
```

### Step 2: Define packs

Once tracks exist, create one or more packs that reference them.

With the standard DSL:

```lua
local _, ns = ...
local Dsl = _G.EchoesOfAzeroth and _G.EchoesOfAzeroth.PluginDsl
local T = ns.Tracks

ns.MusicPacks = {
    MY_ZONE = Dsl.pack {
        label = "My Zone",
        day = {
            T.MY_ZONE_DAY_A,
            T.MY_ZONE_DAY_B,
        },
        night = {
            T.MY_ZONE_NIGHT_A,
        },
    },
}
```

If you have two base packs and want a combined variant, use `Dsl.mixedPack(...)`:

```lua
local base = Dsl.pack {
    label = "My Zone (Classic)",
    any = { T.MY_ZONE_DAY_A },
}

local modern = Dsl.pack {
    label = "My Zone (Modern)",
    any = { T.MY_ZONE_DAY_B },
}

local mixed = Dsl.mixedPack("My Zone (Classic + Modern)", base, modern)
```

Tips:

- Pack order is generated automatically by the core.
- Packs are shown alphabetically by label, with a stable key-based tie-breaker.

### Step 3: Assign packs to zones

After packs exist, map zones to default packs.

```lua
local _, ns = ...
local Dsl = _G.EchoesOfAzeroth and _G.EchoesOfAzeroth.PluginDsl

ns.ZoneMusic = {
    [1234] = Dsl.zone("MY_ZONE_NAME", "MY_ZONE", {
        MY_SUBZONE = "MY_ZONE",
    }),
}
```

Tips:

- A zone references pack keys, not track names.
- Add subzones only when you know their stable in-game names. If you do, be wary that subzones do not have IDs and that the best way to cover all clients is to get the translation on wago.tools.

### Step 4: Add locales

Zones and subzones need user-facing labels.

English can be your base locale; other locales can override later.

```lua
local _, ns = ...

local names = {
    MY_ZONE_NAME = "My Zone",
}

local subzones = {
    MY_SUBZONE = "My Subzone",
}

ns.L = setmetatable(names, {
    __index = function(_, key)
        return key
    end,
})

ns.SubzoneNames = subzones
```

Tips:

- Every `nameKey` used in `Zones.lua` should exist here.
- Every subzone key used in `Zones.lua` should also exist here.
- `subzoneKeys` is optional; the core can derive it automatically from `subzoneNames`.
- If you skip labels entirely, the plugin may still load, but the UI and subzone resolution will be confusing or incomplete.

### Step 5: Register the plugin

Finally, register the plugin with the core addon:

```lua
local _, ns = ...

local api = _G.EchoesOfAzeroth
local Dsl = api and api.PluginDsl
if not Dsl then
    error("EchoesOfAzeroth core must load before this plugin")
end

Dsl.registerPlugin({
    id = "myplugin",
    title = "My Plugin",
    description = "Custom music for my zone.",
    order = 50,
    category = "Custom",
    tracks = ns.Tracks,
    durations = ns.TrackDurations,
    packs = ns.MusicPacks,
    zones = ns.ZoneMusic,
    locales = ns.L,
    subzoneNames = ns.SubzoneNames,
})
```

### Minimal workflow

If you want the fastest path to a working plugin:

1. Add 2-3 tracks with durations.
2. Create one pack.
3. Map one zone to that pack.
4. Add one English zone label.
5. Register the plugin.
6. Test in game.

Only after that should you add:

- additional variants
- mixed packs
- subzones
- extra locales

### Common mistakes

- Defining a zone before the referenced pack exists.
- Defining a pack before the referenced tracks exist.
- Forgetting durations for newly added tracks (will default to 90 seconds, so the transition will be harsh).
- Using a `nameKey` or subzone key in `Zones.lua` that does not exist in `Locale.lua`.
- Adding complex subzone mappings before validating the base zone pack works.

### Recommended authoring mindset

Think in this order:

1. "What tracks do I need?"
2. "What packs should the player be able to select?"
3. "Which pack should each zone use by default?"
4. "What labels should players see in the UI?"

If you follow that order, plugin creation stays predictable and much easier to debug.
