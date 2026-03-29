# Shared Schemas

This document defines the data contracts shared by `LibEchoesMusic`, the
`EchoesOfAzeroth` core addon, and content plugins.

## Plugin Manifest

Plugins register passive metadata and content only.

```lua
{
    id = "quelthalas",
    title = "Quel'Thalas",
    description = "Original and alternate music for Quel'Thalas zones.",
    order = 10,
    category = "Eastern Kingdoms",
    icon = nil,
    tracks = ns.Tracks,
    durations = ns.TrackDurations,
    packs = ns.MusicPacks,
    packOrder = ns.MusicPackOrder,
    zones = ns.ZoneMusic,
    locales = ns.L,
    subzoneNames = ns.SubzoneNames,
    subzoneKeys = ns.SubzoneKeys,
}
```

## Pack Schema

```lua
{
    label = "Silvermoon (TBC)",
    intro = 53473,
    day = { 53474, 53475, 53476 },
    night = { 53477, 53478, 53479 },
    any = {},
    disabledByDefault = {
        [12345] = true,
    },
}
```

`day`, `night`, and `any` use FileDataIDs. `disabledByDefault` is optional and
is interpreted as a tri-state with user overrides:

- `true`: force disabled
- `false`: force enabled
- `nil`: use pack default

User-authored custom packs follow the same shape. Fields may be omitted in
saved data for backwards compatibility, but the runtime should treat them as:

```lua
{
    label = "My Custom Pack",
    intro = nil,
    day = {},
    night = {},
    any = {},
}
```

## Pack Override Schema

```lua
{
    disabled = {
        [12345] = true,
        [12346] = false,
    },
    introEnabled = false,
}
```

`packOverrides` are user-authored overrides applied to an existing resolved pack:

- `disabled[id] = true`: force that rotating track off
- `disabled[id] = false`: force that rotating track on even if disabled by default
- `disabled[id] = nil`: use the pack default
- `introEnabled = false`: force the intro off
- `introEnabled = true`: force the intro on
- `introEnabled = nil`: use the pack default

## Zone Schema

```lua
{
    nameKey = "SILVERMOON_CITY",
    pack = "SILVERMOON",
    subzones = {
        MURDER_ROW = "GHOSTLANDS",
    },
}
```

Zones use local plugin pack keys. The core stores overrides per plugin and
resolves them back against the plugin catalog before handing data to the lib.

## Profile Schema

```lua
{
    name = "Default",
    plugins = {
        quelthalas = {
            zoneOverrides = {},
            customPacks = {},
            packOverrides = {},
        },
    },
}
```

Core-level settings live at the DB root:

```lua
{
    enabled = true,
    verbose = false,
    silenceGap = 4,
    crossfadeSec = 3,
    activeProfile = "default",
    profiles = { ... },
}
```

## Namespacing Rules

- Plugin IDs are globally unique.
- Track, pack, and locale keys are plugin-local in plugin files.
- The core keeps plugin state scoped by plugin ID.
- The core may build qualified runtime keys when merging multiple plugins, but
  the persisted plugin payloads remain local to each plugin.
