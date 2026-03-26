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
