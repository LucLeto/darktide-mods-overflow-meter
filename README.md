# darktide-mods-overflow-meter
Overflow Meter adds a multiplayer-focused HUD for Skitarii using the Power Overflow talent. It estimates when and how effectively you share Toughness with nearby teammates, showing Coherency, team demand, and approximate Toughness offered in real time.

## Display

The meter has two styles, selectable in the settings:

* **Gauge** - a segmented arc that lights up cold-teal to hot-red with the estimated sharing rate, with the `~X.X Toughness/s` value in the centre and a peak marker. The arc's full-scale is generated dynamically from the replenishment sources your build currently has available, so it rescales as sources are added, removed, activated, or deactivated.
* **Text** - the compact `Sharing: ~X.X Toughness/s` readout used during testing.
* **Both** (default) - the gauge with the text lines beneath it.

The displayed rate can be shown in one of two units (the `Rate display` setting):

* **Total offered** (default) - the sum of Toughness offered to all allies in Coherency. Power Overflow gives **each** ally the full 25 % share rather than splitting it, so this value scales with the number of allies in Coherency: total ÷ allies = what each ally receives.
* **Per ally** - what each single ally in Coherency receives. This value stays the same regardless of how many allies are nearby, so it does not jump when teammates walk in and out of Coherency.

## What it shows

The widget is only active while playing a Skitarii with Power Overflow selected, and switches between five states:

| State | Meaning |
| --- | --- |
| Inactive | You are below full Toughness, so Power Overflow cannot activate. |
| Ready | You are at full Toughness, but no supported replenishment source is active. |
| Sharing | A supported source is active and allies are in Coherency. |
| Useful sharing | At least one ally in Coherency is currently missing Toughness. |
| No demand | Sharing, but all nearby allies are at full Toughness. |

All displayed rates are marked with `~` because they are estimates.

## Toughness replenishment sources

Complete reference of Skitarius Toughness replenishment. Any replenishment that lands while at full Toughness feeds Power Overflow, with two exceptions: coherency regeneration (disabled at 100 % Toughness, so it can never overflow) and effects that restore Toughness directly to allies. Data and icons from kuli's guides (see [Credits & Sources](#credits--sources)).

### Base Skitarius replenishment source

| Name | Icon | Mechanics |
| --- | --- | --- |
| Melee Kill | - | Killing an enemy with a melee attack replenishes 5 % of max Toughness (base for every class; increased by Slaughter Protocol). |
| Coherency Regeneration | - | Passive regeneration while in Coherency and missing Toughness. Disabled at 100 % Toughness, so it never feeds Power Overflow. |

### Talent nodes

| Name | Icon | Mechanics |
| --- | --- | --- |
| Power Overflow | <img src="https://images.steamusercontent.com/ugc/9494943548435459003/138FDB3717BBF82A99E4705EBC59F091BC2B6342/" width="44"> | The talent this mod meters: while at full Toughness, 25 % of the excess Toughness you actively replenish is distributed to each ally in Coherency. |
| Auto-Repair Doctrines | <img src="https://images.steamusercontent.com/ugc/15480205412231895975/B6A065E0CE1E1E43C50DED3B5C6E80C6CEC94674/" width="44"> | Continuously replenishes 3 % of max Toughness per second, +0.5 %/s per currently held ability charge. |
| Binary Ballistics Protocol | <img src="https://images.steamusercontent.com/ugc/11945717323485494393/04500A5BEA0050A71A48970E56134D6C9526FF44/" width="44"> | Elite kills restore 15 % Toughness over 3 s (5 %/s, refreshable). |
| Data Sensor Protocol | <img src="https://images.steamusercontent.com/ugc/16541431713315840342/88FE84F854FA207126117E9B756AD6C3011F9FF6/" width="44"> | When you or a Coherency ally takes health damage, restores 25 % Toughness (15 s cooldown). |
| Entropic Transfer | <img src="https://images.steamusercontent.com/ugc/13183919381563786449/459E247E2AC9684A3C18035B26DC28B74AF3E9C4/" width="44"> | Electrocuting an enemy restores 12 % Toughness over 4 s (3 %/s, refreshable). |
| Kinetic Energy Distributors | <img src="https://images.steamusercontent.com/ugc/18343475585024670845/F4CC79FEC0A38A5AD4F032706A3ECDFEADE63C2C/" width="44"> | Taking damage restores 25 % Toughness over 5 s (5 %/s; 10 s cooldown). |
| Omnissian Recharge Litany | <img src="https://images.steamusercontent.com/ugc/12599871299242739814/FC0FA3877435875A2C43627EB2E3DC6E6B88D8EA/" width="44"> | Hitting 3+ enemies with one attack restores 10 % Toughness over 3 s (3.33 %/s; 0.25 s internal cooldown). |
| Power Redistribution Uplink | <img src="https://images.steamusercontent.com/ugc/15720054801093890247/C714BD2A5B09A2BCC2A849816E8FF9755E2E505D/" width="44"> | Critical hits restore 7.5 % Toughness over 3 s (2.5 %/s) and grant 15 % Toughness damage reduction. |
| Servo-Core Recharge Engine | <img src="https://images.steamusercontent.com/ugc/12780575782612186435/824749A4E9D670782A835957656CC7FEC28EEE63/" width="44"> | Weakspot kills instantly restore 5 % Toughness (on melee kills, in addition to the base 5 %). |
| Slaughter Protocol | <img src="https://images.steamusercontent.com/ugc/15153225070005254053/7D5FA7E9B67AF5278C1ADDE253B5CD597880C9E2/" width="44"> | Increases the base melee-kill replenishment by 25 % (to 6.25 %), or by 50 % (to 7.5 %) while at 0 ability charges. |
| Superior Defence Engrams | <img src="https://images.steamusercontent.com/ugc/14395235793433949240/5D421B8F79C9FE53465C483CB00AF0CFBA13A76D/" width="44"> | Ranged kills grant stacks (max 5, 8 s, refreshable); each stack replenishes 1 % of max Toughness per second. |
| Voltaic Restoration | <img src="https://images.steamusercontent.com/ugc/18178859633858041478/6B60E86580B08016E017A6F2F372727F13DF2938/" width="44"> | On ability use, restores 20 % Toughness to you and to allies in Coherency. |
| Resurgence (Aura) | <img src="https://images.steamusercontent.com/ugc/11650668476252403499/6DF82FCE2D8990278B16FFF4BD2A1F679E2573C9/" width="44"> | You and Coherency allies keep 25 % of the base coherency Toughness regeneration even in combat, coherency regeneration never feeds Power Overflow. |

### Combat Ability Nodes

| Name | Icon | Mechanics |
| --- | --- | --- |
| Restoration Protocol | <img src="https://images.steamusercontent.com/ugc/11694792458731858273/FB16AD950E6F30E71342FD5021186345FAABA595/" width="44"> | Advanced Combat Doctrines restores 10 % of max Toughness per second for the stance's duration (and clears all suppression on activation). |
| Voltaic Overcharge | <img src="https://images.steamusercontent.com/ugc/15365734486430885741/DF96D8DD9B0C1DDF467208030A7B8B856AF95E71/" width="44"> | Voltaic Emitter restores 25 % Toughness on use, plus 1 % for each enemy hit by the electric discharge. |
| Medicae Servo-Skull (Blitz) | <img src="https://images.steamusercontent.com/ugc/11312963796425562478/2F9E96764EA2004CF8F6C054FD6B4EDD3379F202/" width="44"> | The injected ally is revived and restored 20 % Toughness per second for 5 s (+75 % Toughness damage reduction), restores the ally, not the Skitarius. |

### Keystone Nodes

| Name | Icon | Mechanics |
| --- | --- | --- |
| Flensing Protocols | <img src="https://images.steamusercontent.com/ugc/12044430078789981717/90AD99217DE66079751879B04D180A37D44231A9/" width="44"> | Elite and Specialist kills restore 15 % Toughness (and 2 Flensing stacks). |
| Surge-Extension | <img src="https://images.steamusercontent.com/ugc/12730560071133596249/33BB7E39085E7A9C57B8837BD44ED5E8803B4531/" width="44"> | Gaining a Redline Capacitors stack (spending or gaining a charge) restores 25 % Toughness over 5 s (5 %/s, refreshable). |
| Invigorating Overload | <img src="https://images.steamusercontent.com/ugc/14264435998497762394/D777587D8BCB1221F9CB55747E04F03B5FBD4FEC/" width="44"> | When the Power Overload overload triggers, you and Coherency allies restore 20 % Toughness (and 20 % stamina). |

### Weapon blessings

| Name | Icon | Mechanics |
| --- | --- | --- |
| Confident Strike | <img src="https://images.steamusercontent.com/ugc/2555311714939721201/DD67931B832A7080C1384E6DCB2B94C5001D08DF/" width="44"> | Chained melee hits replenish Toughness per hit, Arc Maul: 4 / 5 / 6 / 7 % per tier. |
| Syphon | <img src="https://images.steamusercontent.com/ugc/47946743622588631/291A3F7DF94EF10A831879AD6460BDF776A8FFDA/" width="44"> | Hitting 3+ enemies while the weapon special is active regains Toughness, Relic Blade: 10 / 12 / 14 / 16 %. |
| Inspiring Barrage | <img src="https://images.steamusercontent.com/ugc/2524914144964040721/7C232C64AF6B5882CB9F0450F6947F075EB7137C/" width="44"> | During continuous fire, every 10 % of the magazine spent restores Toughness per stack (max 5), Arc Rifle / Autopistol / Braced Autogun: 1 / 2 / 3 / 4 % per stack (up to 20 %). |
| Reassuringly Accurate | <img src="https://images.steamusercontent.com/ugc/2520411179232525014/3BAF122DC6B64673C7A062D257BB3E06F989FBD6/" width="44"> | Critical hit kills restore Toughness, Laspistol: 10 / 12 / 14 / 16 %. |
| Gloryhunter | <img src="https://images.steamusercontent.com/ugc/2524914144960338357/8ADA540685A2930E2E6A035BEFB1A6ADCAFFA3DA/" width="44"> | Elite kills restore Toughness, Galvanic Rifle: 10–16 %, Phosphor Blast Pistol: 17.5–25 %, Plasma Gun: 17.5–25 %, Stub Revolver: 18–30 % per tier. |

The meter currently estimates all of the above except Data Sensor Protocol and the self-restores of Voltaic Restoration and Invigorating Overload (no reliable client-side trigger yet); ally-targeted restores and coherency regeneration are excluded by design because they cannot feed Power Overflow.

## Settings

`Power Overflow Meter` group: meter style (Gauge / Text / Both), meter title visibility, estimated rate display, rate display mode (Total offered / Per ally), allies-in-Coherency display, allies-missing-Toughness display, inactive-state visibility, rolling average duration, widget position, meter size (25–300 %), and opacity. To turn the meter off entirely, disable the mod through the standard mod toggle.

## Custom HUD support (optional)

When the [Custom HUD](https://www.nexusmods.com/warhammer40kdarktide/mods/10) mod is installed, the meter integrates with it automatically - no configuration needed:

* **Move** the meter in Custom HUD's edit mode; once it has been moved there, the mod's own position settings stop being applied so the two never fight.
* **Resize** the meter through Custom HUD (drag handle or width field); a size set there takes precedence over the mod's meter-size setting until the node is reset in Custom HUD.
* Custom HUD's hide and opacity controls work on the meter as on any other HUD element.

Without Custom HUD everything behaves exactly as before - the integration is read-only and never requires the mod.

## Limitations

Power Overflow is processed by the server, and multiplayer clients do not receive exact source attribution or recovered Toughness values. The displayed values are therefore estimates and may differ from the true amounts:

* Replenishment events that are entirely server-side and have no client-observable trigger are not counted.
* Some temporary regeneration buffs drain a server-side pool the client cannot see, so their tail end can be overestimated.
* Recipient-side replenishment modifiers and server-side caps are unknown to the client.
* Short events hidden between network snapshots may be missed.
* Effects that restore Toughness directly to allies (coherency-on-ability, Overload keystone bursts, the medicae Servo Skull) are not Power Overflow input and are deliberately excluded.
* The server-side Power Overflow proc does not verify who generated the incoming replenishment, so external effects such as another player's Voice of Command can technically trigger sharing while you are full. The client cannot attribute these reliably, so they are deliberately omitted (a small undercount).
* Kill- and hit-based pulses are inferred from local attack reports and can differ slightly from the server's proc order (for example an explosion hit that kills its target).

## Credits & Sources

Talent, ability, keystone, and blessing data and icons are taken from the excellent guides by [kuli](https://steamcommunity.com/id/kulii):

* [\[1.12.x\] Skitarius Talents & Mechanics](https://steamcommunity.com/sharedfiles/filedetails/?id=3674757853)
* [\[1.12.x\] Melee Weapon Blessings & Mechanics](https://steamcommunity.com/sharedfiles/filedetails/?id=3286161222)
* [\[1.12.x\] Ranged Weapon Blessings & Mechanics](https://steamcommunity.com/sharedfiles/filedetails/?id=3293278399)
