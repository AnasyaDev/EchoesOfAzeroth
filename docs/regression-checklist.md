# Regression Checklist

Use this checklist to validate parity with the original `EchoesOfQuelThalas`
behavior.

## Playback

- Enter a configured zone and confirm plugin music starts.
- Leave a configured zone and confirm fade-to-silence, then native music.
- Re-enter the same zone and confirm the intro track only plays once per entry.
- Stay in-zone long enough to verify duration-aware rotation.
- Verify the silence gap works at `0`, default, and a larger custom value.
- With `Finish Current Track` = `On subzone changes`: cross into a subzone mapped to another pack and confirm the track keeps playing, then the new pack starts after the silence gap; go back before the track ends and confirm nothing switches; enter another zone and confirm the switch is immediate.
- With `Finish Current Track` = `On subzone and zone changes`: leave to an unmapped zone and confirm the track plays to its end, then native music comes back with no silence gap; change zone mid-track and confirm the new zone's intro plays once the track ends.
- With `Finish Current Track` on, enter a dungeon (loading screen) and confirm the switch is still immediate; change a zone mapping in the options and confirm playback restarts at once.
- With `Finish Current Track` = `On subzone and zone changes`, take a portal between two mapped zones (Silvermoon -> Voidstorm) while a track plays: the old track is cut by the loading screen and the new zone's pack must start at `LOADING_SCREEN_DISABLED`, with no native music in between. `/eoa trace` must show silence at `PLAYER_ENTERING_WORLD` (even with `map=nil`) and no `switch deferred` line. Same check with a portal into a zone that resolves to the pack already playing, and with a portal into an unmapped zone (native music from the start, no deferred stop).
- With `Finish Current Track` on, arrive by portal in a subzone mapped to another pack than its zone (e.g. The Howling Ridge in Voidstorm): if the subzone name settles after the zone pack started, the switch within 3 seconds must be immediate; a change made later in the track must still wait for the track to end.
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
- Log in inside a mapped zone and confirm addon music starts straight away, without the native zone music playing first and fading out. The first login after install has no resume hint; log out (or `/reload`) while addon music plays and log back in: `/eoa trace` must show the silence pre-empt at `ADDON_LOADED`, only silence until `LOADING_SCREEN_DISABLED`, then the real track exactly once (immediately on login/zoning, ~0.75s later after a `/reload`). Nothing audible may play while the loading screen is still up.
- Log out while addon music plays, log into a character standing in an unmapped zone, and confirm native music comes back (silence released at `PLAYER_ENTERING_WORLD`, or at the first `ZONE_CHANGED_NEW_AREA` when the client only reported the continent map until then).
- Take a portal into a mapped zone (Voidstorm -> Silvermoon): no native music between `LOADING_SCREEN_DISABLED` and the addon track. `/eoa trace` must show `check map=nil (coarse 2537)` with silence held, then the track right at `ZONE_CHANGED_NEW_AREA`, never a `StopMusic` at `PLAYER_ENTERING_WORLD`. Take a portal into an unmapped zone and confirm native music starts as soon as the zone map is known (no 3s wait); stay somewhere the client only reports a continent map and confirm the channel is released after ~3s.
- With another addon playing music (e.g. boss music) in an unmapped zone, confirm zone changes do not cut it (no `StopMusic` unless Echoes held the channel).
- Enter an unmapped dungeon and confirm addon music stops immediately instead of inheriting parent-zone music.
- Enter an unmapped delve or lair (difficulty 208) and confirm addon music stops; `/eoa now` must report `instance: scenario (difficulty 208)`.
- Enter a mapped instance and confirm addon music starts, including on other floors of the same map group.
- Exit the instance and confirm addon music resumes where appropriate.
- Reload after a loading screen and confirm music state is correct.
- Take a portal out of a mapped zone while addon music plays: the native music of the zone being left must not be heard during the first second of the loading screen. `/eoa trace` must show `leave hold` at `LOADING_SCREEN_ENABLED`, silence ticks, then `leave hold released (PLAYER_LEAVING_WORLD)`; leaving an unmapped zone must show no hold at all.

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
