# Data Migration

`EchoesOfAzeroth` migrates the old `EchoesOfQuelThalasDB` shape into the new
core DB at load time.

## Legacy Shape

```lua
EchoesOfQuelThalasDB = {
    enabled = true,
    verbose = false,
    silenceGap = 4,
    packOverrides = {},
    profiles = {
        default = {
            name = "Default",
            zoneOverrides = {},
            customPacks = {},
        },
    },
    activeProfile = "default",
}
```

## Target Shape

```lua
EchoesOfAzerothDB = {
    enabled = true,
    verbose = false,
    silenceGap = 4,
    crossfadeSec = 3,
    activeProfile = "default",
    profiles = {
        default = {
            name = "Default",
            enabledPlugins = {
                -- plugin omitted => enabled
                -- plugin = false => disabled for this profile
            },
            plugins = {
                custom = {
                    zoneOverrides = {},
                    customPacks = {},
                    packOverrides = {},
                },
                quelthalas = {
                    zoneOverrides = {},
                    customPacks = {},
                    packOverrides = {},
                },
            },
        },
    },
}
```

## Migration Rules

- Preserve `enabled`, `verbose`, and `silenceGap`.
- Introduce `crossfadeSec` with a default of `3` when missing.
- Introduce `enabledPlugins` per profile. Plugins are enabled by default unless
  explicitly set to `false`.
- Consolidate all user-authored `zoneOverrides`, `customPacks`, and
  `packOverrides` into the internal `plugins.custom` bucket.
- Preserve content plugins as providers of default packs and zone mappings only.
- If the legacy DB is flat and lacks named profiles, wrap it into the default
  profile.
- Keep a migration marker so the conversion only runs once.

## Compatibility Notes

- The core still exposes convenience shortcuts for the active plugin so the
  existing options code can run while the architecture is being modularized.
- Full-profile export now uses the `EoA:3` payload format and serializes the
  active profile's `plugins` and `enabledPlugins`.
- Import still accepts older `EoA:1`, `EoQT:1`, and `EoQT:2` payloads for
  compatibility.
- Older `EoA:2` payloads are normalized into the new `custom` user layer on
  import.
- Imported data for plugins that are not currently installed is ignored.
