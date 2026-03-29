# Regression Checklist

Use this checklist to validate parity with the original `EchoesOfQuelThalas`
behavior.

## Playback

- Enter a configured zone and confirm plugin music starts.
- Leave a configured zone and confirm fade-to-silence, then native music.
- Re-enter the same zone and confirm the intro track only plays once per entry.
- Stay in-zone long enough to verify duration-aware rotation.
- Verify the silence gap works at `0`, default, and a larger custom value.
- Verify preview playback starts and stops correctly.

## Resolution

- Confirm default zone mapping works.
- Confirm that when two plugins define the same `mapId`, the last loaded plugin wins.
- Confirm default subzone mapping overrides the zone pack.
- Confirm a user zone override replaces the default pack.
- Confirm a user subzone override takes priority over both.
- Confirm disabling a content plugin removes its packs and zone defaults from runtime immediately.
- Confirm disabling the `custom` plugin removes all user overrides and custom packs from runtime immediately.
- Confirm custom zones can be added, renamed, and deleted.
- Confirm custom subzones can be added and deleted.
- Confirm arbitrary zones can only be added from the `Custom` plugin.
- Confirm content plugins still allow override edits on their existing zones and subzones.

## Settings

- Toggle addon enabled state on and off.
- Toggle `Sound_EnableMusic` and confirm playback reacts immediately.
- Enter an instance and confirm addon music stops.
- Exit the instance and confirm addon music resumes where appropriate.
- Reload after a loading screen and confirm music state is correct.

## Packs And Profiles

- Enable and disable individual built-in tracks.
- Disable a built-in pack intro from the UI and confirm it no longer plays.
- Create, rename, and delete a custom pack.
- Add and remove tracks from a custom pack.
- Set and clear a custom pack intro.
- Create a custom pack with `day` only and confirm it resolves correctly during the day.
- Create a custom pack with `day`, `night`, and `any` tracks and confirm the correct bucket is used for the current time of day.
- Confirm custom packs are only editable from the `Custom` plugin page.
- Confirm zone overrides in `Custom` can target custom packs and packs from enabled content plugins.
- Confirm packs from disabled content plugins are no longer selectable/resolvable by user overrides.
- Create, rename, switch, and delete profiles.
- Export a profile and confirm data for all installed plugins plus `enabledPlugins` is present.
- Import a profile back into the current profile and confirm installed-plugin data merges or replaces correctly.
- Import a profile as a new profile.
- Confirm imports with missing plugins succeed and ignore absent-plugin data.
- Confirm two profiles can keep different plugin activation combinations.

## Migration

- Start with an old `EchoesOfQuelThalasDB` and verify data appears in the
  `custom` plugin bucket.
- Confirm old exports still import successfully.
