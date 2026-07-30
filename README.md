# darktide-mods-overflow-meter
Overflow Meter adds a multiplayer-focused HUD for the invisible Toughness-sharing talents: the **Skitarii** *Power Overflow* and the **Veteran** *Born Leader*. Both are processed by the server and share none of their values with multiplayer clients, so the mod estimates when and how effectively you share Toughness with nearby teammates, showing Coherency, team demand, and approximate Toughness offered in real time. The meter detects your class automatically and adapts its labels and estimation model to whichever talent you have equipped.

## Display

The meter has two styles, selectable in the settings:

* **Gauge** - a segmented arc that lights up cold-teal to hot-red with the estimated sharing rate, with the `~X.X Toughness/s` value in the centre and a peak marker. The arc's full-scale is generated dynamically from the replenishment sources your build currently has available, so it rescales as sources are added, removed, activated, or deactivated.
* **Text** - the compact `Sharing: ~X.X Toughness/s` readout used during testing.
* **Both** (default) - the gauge with the text lines beneath it.

The displayed rate can be shown in one of two units (the `Rate display` setting):

* **Total offered** (default) - the sum of Toughness offered to all allies in Coherency. Power Overflow gives **each** ally the full 25 % share rather than splitting it, so this value scales with the number of allies in Coherency: total ÷ allies = what each ally receives.
* **Per ally** - what each single ally in Coherency receives. This value stays the same regardless of how many allies are nearby, so it does not jump when teammates walk in and out of Coherency.

## What it shows

The widget is active while playing a Skitarii with Power Overflow **or** a Veteran with Born Leader selected, and switches between these states:

| State | Meaning |
| --- | --- |
| Inactive | *(Power Overflow only)* You are below full Toughness, so Power Overflow cannot activate. |
| Ready | No supported replenishment activity is currently measurable. |
| Sharing | Sharing Toughness with allies in Coherency. |
| Useful sharing | At least one ally in Coherency is currently missing Toughness. |
| No demand | Sharing, but all nearby allies are at full Toughness. |

Born Leader has no arming condition, so it never shows the **Inactive** state; that state and its `Show inactive state` setting apply to Power Overflow only.

With `Show output tier labels` enabled (off by default), the sharing text also carries a **Low / Mid / High** badge comparing the current estimated rate to your equipped build's sustained ceiling.

All displayed rates are marked with `~` because they are estimates.

## Mission summary

Next to the live meter the mod keeps per-mission totals, answering how much of your Toughness generation was actually useful and how much was thrown away against your Toughness cap. The panel is shown while a key is **held** - the keybind is unbound by default, so assign one under `Show summary (hold)` - or permanently via `Always show the summary`.

Binding it to `TAB` pairs it with the game's own Tactical Overlay, so both appear together. The panel therefore defaults to the **bottom right**, clear of the Tactical Overlay's left panel (which spans x 25-625 at full height) and of its right-hand content - move it with `Summary position X / Y` if your HUD is laid out differently.

| Metric | Meaning |
| --- | --- |
| Generated | Total Toughness your tracked sources asked to restore, before clamping (`Replenished + Overflowed`). |
| Replenished | Toughness that actually filled your bar. |
| Overflowed | Toughness that could not restore you because you were already at, or reached, your current maximum. |
| Shared | Toughness offered to allies through Power Overflow or Born Leader. Follows the `Rate display` setting, so it is either the total across all allies in Coherency or the amount each single ally receives. |
| Efficiency | Share efficiency: of all the Toughness the talent *could* have offered, the percentage that actually reached an ally. Replenishing with nobody in Coherency drives it down. Ally count deliberately does not matter, because both talents give every ally the full share rather than splitting it - one ally in Coherency is 100 %, none is 0 %. |

**Only `Replenished` is observed**, read from your own replicated Toughness bar. Everything else is inferred and is therefore prefixed with `~`, the same estimate marker the live meter uses.

The totals reset when you enter a new mission and keep accumulating whether or not the panel is shown, so you can check them at any point - including after going down, when the meter itself has already stopped.

The current maximum Toughness is used throughout, so temporary increases such as Veteran's *Duty and Honour* or a Zealot's *Chorus* raise the cap that overflow is measured against, exactly as they do in game.

### At the end of a mission

The game destroys the whole HUD during mission teardown, before the end-of-round screen opens, so the panel cannot follow you there. Two things can:

* **A chat line** (`Post the summary to chat at mission end`, on by default). When the end-of-round screen opens, the totals are written as a single `mod:echo` line. Chat is one of the few UI layers that stays alive on that screen, so the message is readable there and remains in your chat history.
* **Scoreboard rows**, described next.

The two are independent - run either, or both.

### Scoreboard support (optional)

When the [Scoreboard](https://www.nexusmods.com/warhammer40kdarktide/mods/22) mod is installed, all five metrics are registered as rows through its plugin API, in Scoreboard's *Defence* group. They appear both in Scoreboard's Tactical Overlay panel and, more usefully, **on the end-of-mission screen**, which the mod's own panel cannot reach (see below). Each row has its own checkbox in the `Mission summary` settings group, so you can show only the ones you care about; without Scoreboard installed the settings do nothing.

Two behaviours worth knowing:

* **All rows rank "higher is better."** Teammates without a sharing talent always score zero, so ranking *Overflowed* as "lower is better" would grey out the only player the row actually applies to.
* **Efficiency is written differently from the other rows.** Every numeric row type in Scoreboard accumulates, which would make a percentage ratchet upwards instead of showing its current value. Its cell is therefore replaced on each update rather than pushed through `update_stat` - the same approach Ovenproof's plugin uses for its Weakspot and Critical Rate rows. It displays as a plain number, with the unit in the row label.
* **Placement adapts to [Ovenproof's Scoreboard Plugin](https://www.nexusmods.com/warhammer40kdarktide/mods/514).** That plugin rebuilds the board into a single group of its own, which would otherwise leave these rows stranded in an empty *Defence* group above everything else. When it is detected, the rows are moved into its list directly after *Total [Times Killed | Players Rescued]* and adopt its group. Without it they stay in Scoreboard's *Defence* group and feed its auto-generated **Defense Score** as normal.

  Scoreboard has no ordering field, so this is done by moving the registered row entries, anchored on a named Ovenproof spacer row. If that row is ever renamed or removed the repositioning is skipped and the rows simply stay where they were.
* **Scoreboard's panel is capped at 1000 px** (`Scoreboard panel height`, whose maximum *is* its default). Past that the frame stops growing while rows keep drawing, so they spill over the bottom border and the overflowing rows get progressively indented. Adding these five rows costs roughly 126 px, including the *Defense Score* row that the Defence group only generates once it has at least one visible row. If your scoreboard already overflows, the cheapest space to reclaim is elsewhere: Ovenproof's plugin has a `bottom_padding` option gating four blank spacer rows (~72 px, no information lost), and its per-tier options each gate a large block of rows. Otherwise, untick the rows here you can do without - *Generated* is simply Replenished + Overflowed, and *Efficiency* is their ratio.

## Skitarii (Power Overflow) replenishment sources

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
| Inspiring Barrage | <img src="https://images.steamusercontent.com/ugc/2524914144964040721/7C232C64AF6B5882CB9F0450F6947F075EB7137C/" width="44"> | During continuous fire, every 10 % of the magazine spent restores Toughness per stack (max 5), Arc Rifle / Autopistol / Braced Autogun: 1 / 2 / 3 / 4 % per stack (up to 20 %). |
| Reassuringly Accurate | <img src="https://images.steamusercontent.com/ugc/2520411179232525014/3BAF122DC6B64673C7A062D257BB3E06F989FBD6/" width="44"> | Critical hit kills restore Toughness, Laspistol: 10 / 12 / 14 / 16 %. |
| Gloryhunter | <img src="https://images.steamusercontent.com/ugc/2524914144960338357/8ADA540685A2930E2E6A035BEFB1A6ADCAFFA3DA/" width="44"> | Elite kills restore Toughness, Galvanic Rifle: 10–16 %, Phosphor Blast Pistol: 17.5–25 %, Plasma Gun: 17.5–25 %, Stub Revolver: 18–30 % per tier. |

The meter currently estimates all of the above except Data Sensor Protocol and the self-restores of Voltaic Restoration and Invigorating Overload (no reliable client-side trigger yet); ally-targeted restores and coherency regeneration are excluded by design because they cannot feed Power Overflow.

## Veteran (Born Leader) replenishment sources

Complete reference of Veteran Toughness replenishment. Born Leader shares **20 % of the wanted amount of every replenish you make** with allies in Coherency and also grants **+50 % Coherency radius**. Unlike Power Overflow it has no full-Toughness requirement, so it has no *Inactive* state; coherency regeneration is shared too, but only while below full Toughness (the regeneration tick stops at 100 %). The only replenishment it cannot share is one that restores Toughness directly to allies rather than to you. All amounts are % of maximum Toughness and scale with Toughness-replenish stat buffs unless noted. Data and icons from kuli's guides (see [Credits & Sources](#credits--sources)).

### Base Veteran replenishment sources

| Name | Icon | Mechanics |
| --- | --- | --- |
| Melee Kill | - | Killing an enemy with a melee attack replenishes 5 % of max Toughness (base for every class). |
| Coherency Regeneration | - | Passive regeneration while in Coherency and missing Toughness. Shared by Born Leader, but only while below full Toughness, because the regeneration tick stops at 100 %. |

### Talent nodes

| Name | Icon | Mechanics |
| --- | --- | --- |
| Born Leader | <img src="https://images.steamusercontent.com/ugc/2315475838576764629/C21814108BD54F11F8487253B6E072E7710E2C48/" width="44"> | The talent this mod meters: allies in Coherency replenish 20 % of any Toughness you replenish, and your Coherency radius is increased by 50 %. |
| Out for Blood | <img src="https://images.steamusercontent.com/ugc/2315475838576763041/02D4F133EFC50B3FF20B64E2D41A6376B1BB1FA2/" width="44"> | Any kill - melee, ranged, explosion or damage-over-time - replenishes an additional 5 % Toughness. |
| Confirmed Kill | <img src="https://images.steamusercontent.com/ugc/2315475838576763023/FE374F06E0E47B441629375ABFEF577CA26D3BEF/" width="44"> | Elite or Specialist kills instantly replenish 10 % Toughness and a further 20 % over 10 s (2 %/s). |
| Exhilarating Takedown | <img src="https://images.steamusercontent.com/ugc/2315475838576763002/D6C23A6CBC66992640459CD62D2D640D5547E08C/" width="44"> | Ranged weakspot kills replenish 15 % Toughness and grant +10 % Toughness damage reduction for 8 s (stacks 3×, decaying one at a time). |
| Catch a Breath | <img src="https://images.steamusercontent.com/ugc/2315475838576762995/A09FE2032198FC111F9BBDDC7DF2CBFFDBC65160/" width="44"> | When you have not been the target of a melee attack for 5 s, replenishes 5 % Toughness per second. |
| Field Improvisation | <img src="https://images.steamusercontent.com/ugc/2315475838576764725/1143C5700FB030B75C71B82913A02C27BB70533F/" width="44"> | While near your deployed Medi-Pack, replenishes 1 % Toughness per second (the Medi-Pack also heals faster and cleanses Corruption). |

### Combat Ability Nodes

| Name | Icon | Mechanics |
| --- | --- | --- |
| Executioner's Stance | <img src="https://images.steamusercontent.com/ugc/2315475838576767639/6BD53F8265A160514869473870732E2B2B4EC256/" width="44"> | While in Ranged Stance, replenishes 10 % Toughness per second for the stance's duration (6 s, or 9 s with Master of the Killing Zone; refreshed by highlighted kills with Superiority Complex). Only the upgraded **Executioner's Stance** regenerates - the base *Volley Fire* node grants the damage bonuses without any Toughness. |
| Voice of Command | <img src="https://images.steamusercontent.com/ugc/2315475838576767602/3FA6B49FFBE084BCEE5EE80BC7BE978F6141846A/" width="44"> | On use, replenishes your maximum Toughness and staggers nearby enemies. Shares 20 % of your maximum Toughness to each ally in Coherency, even at full Toughness. With **Duty and Honour** it additionally grants +50 bonus Toughness to you and Coherency allies for 10 s - that bonus raises maximum Toughness instead of replenishing it, so Born Leader does not share it. |
| Infiltrate | <img src="https://images.steamusercontent.com/ugc/2315475838576767575/AE60D2F78CEA91B4FCFDBF97F09E4D403B841EE1/" width="44"> | On use, replenishes your maximum Toughness and enters Stealth. Shares 20 % of your maximum Toughness to each ally in Coherency, even at full Toughness. |

### Keystone Nodes

The three base keystones (Marksman's Focus, Focus Target!, Weapons Specialist) do not replenish Toughness, but three of their upgrade nodes interact with Born Leader:

| Name | Icon | Mechanics |
| --- | --- | --- |
| Tunnel Vision | <img src="https://images.steamusercontent.com/ugc/2315475838576768914/9E4B306F467B645AE75A69861A59B3FCA66F388D/" width="44"> | +4 % Toughness Replenishment per stack of Focus (Marksman's Focus). This is a replenishment *multiplier*, not a source of its own - it raises the wanted amount of your other stat-buff-affected replenishes, and therefore the amount Born Leader shares from them. |
| Target Down! | <img src="https://images.steamusercontent.com/ugc/2315475838576768949/7AB6875F5D5AF001B742E91D4F309FF7CD9AFBBC/" width="44"> | When a Tagged enemy dies, replenishes 5 % Toughness per applied Focus Target stack to you **and** allies in Coherency (Focus Target!). The portion restored to *you* feeds Born Leader; the direct top-up to allies does not. |
| On Your Toes | <img src="https://images.steamusercontent.com/ugc/2315475838576768884/60768CE3378157828319723371D6868B2E827E6C/" width="44"> | Activating Melee or Ranged Specialist replenishes 20 % Toughness to you, on an independent 3 s cooldown per side (Weapons Specialist). Kills build stacks for the weapon you are *not* holding - melee kills charge the Ranged Specialist and vice versa - and swapping to that weapon spends them. This is a self-replenish and feeds Born Leader. |

The keystones' other Toughness-adjacent upgrades are **not** feeders: Redirect Fire! grants Damage, Always Prepared restores ammunition, and Invigorated restores Stamina, none of which replenish your Toughness.

### Weapon blessings

| Name | Icon | Mechanics |
| --- | --- | --- |
| Inspiring Barrage | <img src="https://images.steamusercontent.com/ugc/2524914144964040721/7C232C64AF6B5882CB9F0450F6947F075EB7137C/" width="44"> | During continuous fire, every 10 % of the magazine spent replenishes Toughness per stack (max 5), Autopistol / Braced Autogun / Bolter: 1 / 2 / 3 / 4 % per stack (up to 20 %). |
| Reassuringly Accurate | <img src="https://images.steamusercontent.com/ugc/2520411179232525014/3BAF122DC6B64673C7A062D257BB3E06F989FBD6/" width="44"> | Critical hit kills replenish Toughness, Laspistol: 10 / 12 / 14 / 16 %. |
| Gloryhunter | <img src="https://images.steamusercontent.com/ugc/2524914144960338357/8ADA540685A2930E2E6A035BEFB1A6ADCAFFA3DA/" width="44"> | Elite kills replenish Toughness, Bolter: 10–16 %, Bolt Pistol: 18–30 %, Plasma Gun: 17.5–25 %, Stub Revolver: 18–30 % per tier. |

The meter measures continuous sharing below full Toughness from your own replicated Toughness-bar delta (20 % × recovered Toughness), which is source-agnostic: it covers coherency regeneration and every self-replenish without a per-source model - coherency regen, Catch a Breath, Executioner's Stance, Field Improvisation, continuous-fire blessings, and the self-portion of keystone upgrades such as Target Down! and On Your Toes are all captured automatically, already scaled by any Tunnel Vision multiplier. Discrete pulses (kills, blessings) add only their clamp overflow so they are never double-counted against the bar, and Voice of Command / Infiltrate are surfaced as a brief `Shout: ~X Toughness per ally` flash and a peak-marker spike rather than folding into the sustained rate. Ally-targeted restores such as **Covering Fire** (which replenishes nearby allies directly, not you) are excluded by design because they cannot feed Born Leader.

At full Toughness the bar is static, so the meter switches to modelling the sources instead:

* **Discrete self-replenishes** are inferred from their trigger events - kills, weapon-blessing procs and shouts, plus **Target Down!** (when you kill your own Tagged enemy, scaled by your current Focus Target stacks) and **On Your Toes** (read at the weapon swap from your replicated Specialist stack count, honouring the game's 3 s per-side cooldown).
* **Continuous talent regeneration** that keeps ticking while already at full is modelled from its own active window: **Executioner's Stance** (10 %/s while the stance is up, extended by highlighted kills when Master of the Killing Zone is taken), **Catch a Breath** (5 %/s once you have not been hit in melee for 5 s) and **Confirmed Kill**'s over-time regeneration (2 %/s for 10 s after an Elite or Specialist kill). All three are scaled by your current replenishment modifiers, so Tunnel Vision and debuffs such as toxic gas are reflected, and they pause while you are disabled.

Because these two paths are mutually exclusive - the bar delta below full, the model at full - nothing is counted twice. The remaining at-full undercount is **Field Improvisation** (1 %/s near your deployed Medi-Pack), which has no reliable client-side signal for the proximity check. Note also that **Duty and Honour**'s +50 bonus Toughness is *not* counted: it raises maximum Toughness rather than replenishing it, so Born Leader does not share it.

## Settings

`Power Overflow Meter` group: meter style (Gauge / Text / Both), meter title visibility, estimated rate display, rate display mode (Total offered / Per ally), allies-in-Coherency display, allies-missing-Toughness display, inactive-state visibility (Power Overflow only), output tier labels (off by default), rolling average duration, widget position, meter size (25–300 %), and opacity. To turn the meter off entirely, disable the mod through the standard mod toggle.

`Mission summary` group: the hold-to-show keybind (unbound by default), permanent visibility, the end-of-mission chat line (on by default), one checkbox per Scoreboard row (Generated / Replenished / Overflowed / Shared / Efficiency, all on by default), and the summary panel's position. The panel reuses the meter's size and opacity settings.

## Custom HUD support (optional)

When the [Custom HUD](https://www.nexusmods.com/warhammer40kdarktide/mods/10) mod is installed, the meter integrates with it automatically - no configuration needed:

The meter and the mission summary panel appear as **two independent boxes** in Custom HUD's edit mode, so they can be placed and sized separately.

* **Move** either one in Custom HUD's edit mode; once a box has been moved there, the mod's own position setting for it stops being applied so the two never fight.
* **Resize** either one through Custom HUD (drag handle or width field); a size set there takes precedence over the mod's meter-size setting until that box is reset in Custom HUD.
* **Hide and opacity are per element, not per box.** Custom HUD applies them to the whole HUD element, so hiding either box hides the meter *and* the summary together. To show only one of them, use the mod's own settings - clear the summary keybind and leave `Always show the summary` off, or pick a meter style you want.

Without Custom HUD everything behaves exactly as before - the integration is read-only and never requires the mod.

## Limitations

Power Overflow and Born Leader are processed by the server, and multiplayer clients do not receive exact source attribution or recovered Toughness values. The displayed values are therefore estimates and may differ from the true amounts:

* Replenishment events that are entirely server-side and have no client-observable trigger are not counted.
* Some temporary regeneration buffs drain a server-side pool the client cannot see, so their tail end can be overestimated.
* Recipient-side replenishment modifiers and server-side caps are unknown to the client.
* Short events hidden between network snapshots may be missed.
* Effects that restore Toughness directly to allies (coherency-on-ability, Overload keystone bursts, the medicae Servo Skull) are not Power Overflow input and are deliberately excluded.
* The server-side Power Overflow proc does not verify who generated the incoming replenishment, so external effects such as another player's Voice of Command can technically trigger sharing while you are full. The client cannot attribute these reliably, so they are deliberately omitted (a small undercount).
* Kill- and hit-based pulses are inferred from local attack reports and can differ slightly from the server's proc order (for example an explosion hit that kills its target).
* *(Born Leader)* The continuous regeneration counted while at full Toughness is modelled from talent selection and timers rather than read from the server's buffs, so its active windows are approximations. In particular, Catch a Breath's cooldown is restarted from melee hits that land on you; **blocking** an attack also restarts it in game but is not observable client-side, so the meter can credit a little regeneration that the server did not grant.
* *(Born Leader)* Field Improvisation's 1 %/s near a deployed Medi-Pack is not counted while at full Toughness (no reliable client-side proximity signal), and Duty and Honour's +50 bonus Toughness is excluded by design because it raises maximum Toughness rather than replenishing it.

### Mission summary

The summary inherits all of the above, plus:

* **`Replenished` is sampled, not integrated.** The Toughness bar is read four times a second, so a gain that is immediately cancelled by incoming damage inside the same 250 ms window is netted out and slightly under-counted.
* **`Overflowed` reads the replicated bar at trigger time.** When several pulses land in quick succession the client may still see the pre-pulse missing Toughness for the later ones, which under-counts their clamp excess.
* *(Power Overflow)* Toughness wasted while **below** full counts as `Overflowed` but never as `Shared`: the talent only procs when the replenishment restored nothing at all, so a partial clamp is wasted without being shared. Expect `Shared` to be well under 25 % of `Generated`.
* *(Born Leader)* When Duty and Honour raises maximum Toughness in the same instant Voice of Command restores it, that one bar-delta sample is skipped by the max-change guard, so `Replenished` misses that shout's restored portion.
* `Shared` is what the talent *offers*. The server does not tell clients how much each ally actually received, and per-ally delivery is out of scope.
* **The panel itself is in-mission only.** The game destroys the whole HUD (and `Managers.state`) during mission teardown, before the end-of-round screen opens, so no HUD element can render there. The chat line and the Scoreboard rows are the two supported ways to see the totals on that screen.
* The chat line depends on DMF's own `echo` output mode. If you have set DMF to route echoes to the log only, the message will not appear in chat.

## Credits & Sources

Talent, ability, keystone, and blessing data and icons are taken from the excellent guides by [kuli](https://steamcommunity.com/id/kulii):

* [\[1.12.x\] Skitarius Talents & Mechanics](https://steamcommunity.com/sharedfiles/filedetails/?id=3674757853)
* [\[1.12.x\] Veteran Talents & Mechanics](https://steamcommunity.com/sharedfiles/filedetails/?id=3094038976)
* [\[1.12.x\] Melee Weapon Blessings & Mechanics](https://steamcommunity.com/sharedfiles/filedetails/?id=3286161222)
* [\[1.12.x\] Ranged Weapon Blessings & Mechanics](https://steamcommunity.com/sharedfiles/filedetails/?id=3293278399)
