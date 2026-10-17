--- Psyker source model: restore fractions, talent names and blessing procs for the mission statistics.
-- The Psyker has no Toughness-sharing talent, so this model only feeds the generic mission
-- statistics (Generated, Replenished, Overflowed); the live meter stays hidden. Below full the HUD
-- element measures every replenish from the Toughness bar itself, so this module serves the part
-- the bar cannot show: what is clamped at the cap or lands at full. It exports the fractions,
-- buff names, reason strings and timings of every discrete and continuous source
-- `OverflowMeter_pulses_psyker.lua` reconstructs on the client, and tells warp attacks apart for
-- Soulstealer.
--
-- Explicit module loaded by `OverflowMeter.lua` and stored as `mod._sources_psyker` (and as
-- `psyker` in `mod._sources_by_archetype`).
-- module: OverflowMeter_sources_psyker
-- author: LucLeto
local mod = get_mod("OverflowMeter")
local ArchetypeToughnessTemplates = require("scripts/settings/toughness/archetype_toughness_templates")
local BuffTemplates = require("scripts/settings/buff/buff_templates")
local DamageProfileTemplates = require("scripts/settings/damage/damage_profile_templates")
local DamageSettings = require("scripts/settings/damage/damage_settings")
local ExplosionTemplates = require("scripts/settings/damage/explosion_templates")
local ProjectileTemplates = require("scripts/settings/projectile/projectile_templates")
local TalentSettings = require("scripts/settings/talent/talent_settings")
local WeaponTemplates = require("scripts/settings/equipment/weapon_templates/weapon_templates")

local pairs = pairs
local pcall = pcall
local rawget = rawget
local string_gsub = string.gsub
local table_concat = table.concat
local table_sort = table.sort
local type = type

-- ----------------------------------------------------------------------------
-- Constants
-- ----------------------------------------------------------------------------

local psyker_settings = TalentSettings.psyker or {}
local psyker_settings_2 = TalentSettings.psyker_2 or {}

--- Talent tuning read from the game's talent, buff and toughness settings.
-- The melee-kill base is the archetype toughness template's. Soulstealer is
-- `psyker_2.toughness_2`, Quietude's Peril-to-Toughness rate `psyker_2.toughness_3` and Warp
-- Expenditure's per-hit restore `psyker.melee_toughness`. Disrupt Destiny's marked-kill restore is
-- the passive buff template's `toughness_percentage`, spread over the 2.5 s the bonus buff's
-- update function hard-codes. Essence Harvest restores `psyker_2.toughness_1.percent_toughness`
-- per second. Every value falls back to its 1.13 number when a path is missing.
local psyker_toughness_template = ArchetypeToughnessTemplates.psyker
local psyker_recovery_percentages = psyker_toughness_template and psyker_toughness_template.recovery_percentages
local melee_kill_base_fraction = psyker_recovery_percentages and psyker_recovery_percentages.melee_kill or 0.05

local warp_kill_settings = psyker_settings_2.toughness_2
local warp_kill_fraction = warp_kill_settings and warp_kill_settings.percent_toughness or 0.075

local quietude_settings = psyker_settings_2.toughness_3
local quietude_multiplier = quietude_settings and quietude_settings.multiplier or 0.4

local melee_toughness_settings = psyker_settings.melee_toughness
local melee_hit_fraction = melee_toughness_settings and melee_toughness_settings.instant_toughness or 0.025

local MARKED_KILL_BONUS_DURATION = 2.5
local marked_enemies_template = BuffTemplates.psyker_marked_enemies_passive
local marked_kill_total = marked_enemies_template and marked_enemies_template.toughness_percentage or 0.25

local essence_harvest_settings = psyker_settings_2.toughness_1
local essence_harvest_rate = essence_harvest_settings and essence_harvest_settings.percent_toughness or 0.06

--- Talent buff templates; a buff template tier above 0 means the build has the talent. Quietude
-- grants both Peril buffs.
local WARP_KILL_BUFF_NAME = "psyker_toughness_on_warp_kill"
local MELEE_HIT_BUFF_NAME = "psyker_toughness_on_melee"
local WARP_GENERATION_BUFF_NAME = "psyker_toughness_on_warp_generation"
local VENT_BUFF_NAME = "psyker_toughness_on_vent"

--- Disrupt Destiny's bonus buff, which runs while a marked kill's restore lasts, and Essence
-- Harvest's, which runs for 5 s after gaining a Warp Charge (Warp Siphon). Both are synced to the
-- client; Essence Harvest's update function restores on the server only.
local MARKED_KILL_BONUS_BUFF_NAME = "psyker_marked_enemies_passive_bonus"
local ESSENCE_HARVEST_BUFF_NAME = "psyker_souls_replenish_toughness_stacking_buff"

--- Replenish reasons of the Psyker buffs whose `update_func` also runs on the client: Mettle and
-- Souldrinker (`psyker_crits_regen_toughness_movement_speed`, shared by both), Scrier's Gaze
-- (`overcharge_stance`), Warp Expenditure's weakspot-kill regeneration (`psyker_melee_toughness`)
-- and the Telekine Dome's (`psyker_sphere`, counted only in the Psyker's own dome). Calls without
-- a reason are never captured, because the weapon blessings and Disrupt Destiny use none and are
-- counted by other means.
local REPLENISH_CAPTURE_REASONS = {
    psyker_crits_regen_toughness_movement_speed = true,
    overcharge_stance = true,
    psyker_melee_toughness = true,
    psyker_sphere = true
}

--- The Telekine Dome's reason and the buff it gives everyone inside, which names the Psyker who
-- cast the dome as its owner.
local SPHERE_CAPTURE_REASON = "psyker_sphere"
local SPHERE_BUFF_NAME = "psyker_boost_allies_in_sphere_buff"

--- Warp Expenditure's per-hit restore shares the regeneration's reason but runs only on the
-- server, so the hook skips calls of exactly this fraction when hosting and the attack reports
-- count it everywhere.
local MELEE_HIT_CAPTURE_REASON = "psyker_melee_toughness"

--- Weapon blessing proc buffs that restore a fixed percentage of Toughness, grouped by trigger.
-- A deliberate superset: a template for a weapon the Psyker cannot equip simply never procs.
local WEAPON_TOUGHNESS_PROC_TEMPLATES = {
    -- Continuous fire
    weapon_trait_bespoke_arc_rifle_p1_toughness_on_continuous_fire = true,
    weapon_trait_bespoke_autogun_p2_toughness_on_continuous_fire = true,
    weapon_trait_bespoke_autopistol_p1_toughness_on_continuous_fire = true,
    weapon_trait_bespoke_dual_autopistols_p1_toughness_on_continuous_fire = true,
    weapon_trait_bespoke_bolter_p1_toughness_on_continuous_fire = true,
    weapon_trait_bespoke_flamer_p1_toughness_on_continuous_fire = true,
    weapon_trait_bespoke_shotgun_p4_toughness_on_continuous_fire = true,
    weapon_trait_bespoke_shotgun_p3_toughness_on_continuous_fire = true,
    -- Elite / crit / close-range kills
    weapon_trait_bespoke_bolter_p1_toughness_on_elite_kills = true,
    weapon_trait_bespoke_boltpistol_p1_toughness_on_elite_kills = true,
    weapon_trait_bespoke_galvanic_rifle_p1_toughness_on_elite_kills = true,
    weapon_trait_bespoke_phosphor_pistol_p1_toughness_on_elite_kills = true,
    weapon_trait_bespoke_plasmagun_p1_toughness_on_elite_kills = true,
    weapon_trait_bespoke_stubrevolver_p1_toughness_on_elite_kills = true,
    weapon_trait_bespoke_shotpistol_shield_p1_toughness_on_elite_kills = true,
    weapon_trait_bespoke_needlepistol_p1_toughness_on_elite_kills = true,
    weapon_trait_bespoke_laspistol_p1_toughness_on_crit_kills = true,
    weapon_trait_bespoke_needlepistol_p1_toughness_on_crit_kills = true,
    weapon_trait_bespoke_dual_stubpistols_p1_toughness_on_close_range_kills = true,
    weapon_trait_bespoke_shotgun_p4_toughness_on_close_range_kills = true,
    weapon_trait_bespoke_shotgun_p3_toughness_on_close_range_kills = true,
    weapon_trait_bespoke_shotgun_p3_toughness_on_elite_kills = true,
    -- Melee specials / chained hits
    weapon_trait_bespoke_chainsword_2h_p1_toughness_recovery_on_multiple_hits = true,
    weapon_trait_bespoke_forcesword_2h_p1_toughness_recovery_on_multiple_hits = true,
    weapon_trait_bespoke_thunderhammer_2h_p1_toughness_recovery_on_multiple_hits = true,
    weapon_trait_bespoke_bespoke_powersword_p2_regain_toughness_on_multiple_hits_by_weapon_special = true,
    weapon_trait_bespoke_bespoke_powersword_2h_p1_regain_toughness_on_multiple_hits_by_weapon_special = true,
    weapon_trait_bespoke_powermaul_p2_toughness_recovery_on_chained_attacks = true,
    weapon_trait_bespoke_powermaul_p3_toughness_recovery_on_chained_attacks = true,
    weapon_trait_bespoke_powermaul_shield_p1_toughness_recovery_on_chained_attacks = true
}

--- Multi-hit blessings of the two-handed force sword, the Heavy Eviscerator and the Thunder Hammer
-- (`base_weapon_trait_buff_templates.toughness_recovery_on_multiple_hits`). Their restore is the
-- tier's `buff_data.replenish_percentage` and, unlike the other blessings, it is scaled by the
-- Toughness stat buffs. They are also listed in `WEAPON_TOUGHNESS_PROC_TEMPLATES`.
local MULTIPLE_HITS_TEMPLATES = {
    weapon_trait_bespoke_chainsword_2h_p1_toughness_recovery_on_multiple_hits = true,
    weapon_trait_bespoke_forcesword_2h_p1_toughness_recovery_on_multiple_hits = true,
    weapon_trait_bespoke_thunderhammer_2h_p1_toughness_recovery_on_multiple_hits = true
}

--- Continuous-fire blessings, whose restore is multiplied by the current fire step (up to 5).
local CONTINUOUS_FIRE_TEMPLATES = {
    weapon_trait_bespoke_arc_rifle_p1_toughness_on_continuous_fire = true,
    weapon_trait_bespoke_autogun_p2_toughness_on_continuous_fire = true,
    weapon_trait_bespoke_autopistol_p1_toughness_on_continuous_fire = true,
    weapon_trait_bespoke_dual_autopistols_p1_toughness_on_continuous_fire = true,
    weapon_trait_bespoke_bolter_p1_toughness_on_continuous_fire = true,
    weapon_trait_bespoke_flamer_p1_toughness_on_continuous_fire = true,
    weapon_trait_bespoke_shotgun_p4_toughness_on_continuous_fire = true,
    weapon_trait_bespoke_shotgun_p3_toughness_on_continuous_fire = true
}

-- ----------------------------------------------------------------------------
-- Warp attacks
-- ----------------------------------------------------------------------------

local warp_damage_types = DamageSettings.warp_damage_types or {}

--- Damage profiles by whether they hit as a warp attack, built on first use; nil until then.
local warp_profiles = nil

--- Notes one pairing of a damage profile with a damage type. A profile counts as warp only while
-- every pairing found is a warp type.
-- tab: lookup warp flag by profile
-- tab: profile damage profile
-- string: damage_type damage type paired with it
local function _note_pairing(lookup, profile, damage_type)
    if not warp_damage_types[damage_type] then
        lookup[profile] = false
    elseif lookup[profile] == nil then
        lookup[profile] = true
    end
end

--- Walks a settings table and notes every damage profile next to its damage type. The type sits
-- beside the profile under the matching key: `damage_profile` with `damage_type`,
-- `close_damage_profile` with `close_damage_type`, `damage_profile_special_active` with
-- `damage_type_special_active` and so on. Profiles themselves are not entered.
-- tab: lookup warp flag by profile
-- tab: profiles set of every damage profile
-- tab: tbl table to walk
-- tab: visited tables walked already
local function _collect_pairings(lookup, profiles, tbl, visited)
    if visited[tbl] then
        return
    end

    visited[tbl] = true

    for key, value in pairs(tbl) do
        if type(value) == "table" then
            if profiles[value] then
                if type(key) == "string" then
                    local damage_type = rawget(tbl, (string_gsub(key, "damage_profile", "damage_type")))

                    if type(damage_type) == "string" then
                        _note_pairing(lookup, value, damage_type)
                    end
                end
            else
                _collect_pairings(lookup, profiles, value, visited)
            end
        end
    end
end

--- Builds the warp flag of every damage profile from the weapon, projectile and explosion
-- templates. A profile no template pairs with a type uses its own `damage_type`, as the
-- Soulblaze burn and Assail do.
-- treturn: tab warp flag by profile
local function _build_warp_profiles()
    local profiles = {}

    for _, profile in pairs(DamageProfileTemplates) do
        if type(profile) == "table" then
            profiles[profile] = true
        end
    end

    local lookup = {}
    local visited = {}

    _collect_pairings(lookup, profiles, WeaponTemplates, visited)
    _collect_pairings(lookup, profiles, ProjectileTemplates, visited)
    _collect_pairings(lookup, profiles, ExplosionTemplates, visited)

    for profile in pairs(profiles) do
        if lookup[profile] == nil then
            local damage_type = rawget(profile, "damage_type")

            if type(damage_type) == "string" then
                lookup[profile] = warp_damage_types[damage_type] == true
            end
        end
    end

    return lookup
end

--- Builds the warp lookup unless it exists. Walking every weapon template takes a moment, so the
-- pulse module calls this when the Psyker spawns rather than at the first kill. If the build
-- fails, no profile counts as warp.
local function prepare_warp_profiles()
    if warp_profiles then
        return
    end

    local ok, lookup = pcall(_build_warp_profiles)

    warp_profiles = ok and lookup or {}

    -- TEMPORARY: which profiles count as warp, for checking against the game.
    if mod._debug_truth then
        local names = {}

        for profile, is_warp in pairs(warp_profiles) do
            if is_warp then
                names[#names + 1] = tostring(rawget(profile, "name"))
            end
        end

        table_sort(names)

        mod:info("[OFM] warp profiles: ok=%s count=%d %s", tostring(ok), #names, table_concat(names, ","))
    end
end

--- Returns whether a damage profile hits as a warp attack, which is what Soulstealer needs. The
-- game passes the damage type separately from the profile and attack reports carry only the
-- profile, so the type is looked up from where the game's templates pair the two.
-- ?tab: damage_profile damage profile of an attack report
-- treturn: bool
local function is_warp_damage_profile(damage_profile)
    if not warp_profiles then
        prepare_warp_profiles()
    end

    return damage_profile ~= nil and warp_profiles[damage_profile] == true
end

-- ----------------------------------------------------------------------------
-- Interface
-- ----------------------------------------------------------------------------

--- The Psyker source model.
-- `share_fraction` is 0 because the Psyker has no sharing talent; the estimator mode, the empty
-- adapter list and `available_max_fraction` only keep the interface uniform with the sharing
-- archetypes. The remaining fields are inputs for `OverflowMeter_pulses_psyker.lua`. The window
-- that groups the hits of one melee attack is hard-coded: attack reports do not carry the target
-- index the game checks.
return {
    continuous_when_full = false,
    has_inactive_state = false,

    share_fraction = 0,
    adapters = {},

    available_max_fraction = function (ctx)
        return 0
    end,

    weapon_toughness_proc_templates = WEAPON_TOUGHNESS_PROC_TEMPLATES,
    multiple_hits_templates = MULTIPLE_HITS_TEMPLATES,
    continuous_fire_templates = CONTINUOUS_FIRE_TEMPLATES,
    max_continuous_fire_steps = 5,

    melee_kill_base_fraction = melee_kill_base_fraction,

    warp_kill_fraction = warp_kill_fraction,
    warp_kill_talent_buff_name = WARP_KILL_BUFF_NAME,
    prepare_warp_profiles = prepare_warp_profiles,
    is_warp_damage_profile = is_warp_damage_profile,

    melee_hit_fraction = melee_hit_fraction,
    melee_hit_talent_buff_name = MELEE_HIT_BUFF_NAME,
    melee_hit_capture_reason = MELEE_HIT_CAPTURE_REASON,
    melee_attack_window = 0.2,

    quietude_multiplier = quietude_multiplier,
    warp_generation_talent_buff_name = WARP_GENERATION_BUFF_NAME,
    vent_talent_buff_name = VENT_BUFF_NAME,

    marked_kill_bonus_buff_name = MARKED_KILL_BONUS_BUFF_NAME,
    marked_kill_regen_rate = marked_kill_total / MARKED_KILL_BONUS_DURATION,

    essence_harvest_buff_name = ESSENCE_HARVEST_BUFF_NAME,
    essence_harvest_regen_rate = essence_harvest_rate,

    replenish_capture_reasons = REPLENISH_CAPTURE_REASONS,
    sphere_capture_reason = SPHERE_CAPTURE_REASON,
    sphere_buff_name = SPHERE_BUFF_NAME
}
