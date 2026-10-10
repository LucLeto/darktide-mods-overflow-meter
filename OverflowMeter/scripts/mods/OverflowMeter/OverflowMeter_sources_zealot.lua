--- Zealot source model: restore fractions, talent names and blessing procs for the mission statistics.
-- The Zealot has no Toughness-sharing talent, so this model only feeds the generic mission
-- statistics (Generated, Replenished, Overflowed); the live meter stays hidden. Below full the HUD
-- element measures every replenish from the Toughness bar itself, so this module serves the part
-- the bar cannot show: what is clamped at the cap or lands at full. It exports the fractions,
-- buff names, reason strings and timings of every discrete and continuous source
-- `OverflowMeter_pulses_zealot.lua` reconstructs on the client.
--
-- Explicit module loaded by `OverflowMeter.lua` and stored as `mod._sources_zealot` (and as
-- `zealot` in `mod._sources_by_archetype`).
-- module: OverflowMeter_sources_zealot
-- author: LucLeto
local ArchetypeToughnessTemplates = require("scripts/settings/toughness/archetype_toughness_templates")
local TalentSettings = require("scripts/settings/talent/talent_settings")

-- ----------------------------------------------------------------------------
-- Constants
-- ----------------------------------------------------------------------------

local zealot_settings = TalentSettings.zealot or {}

--- Talent tuning read from the game's talent and toughness settings.
-- The melee-kill base is the archetype toughness template's; the base talent's +75 %
-- (`zealot_more_toughness_on_melee`) is a melee replenish stat buff and is applied with the other
-- stat buffs. The elite-kill regeneration
-- is `zealot.zealot_elite_kills_empowers`. Every value falls back to its 1.13 number when a
-- settings path is missing.
local zealot_toughness_template = ArchetypeToughnessTemplates.zealot
local zealot_recovery_percentages = zealot_toughness_template and zealot_toughness_template.recovery_percentages
local melee_kill_base_fraction = zealot_recovery_percentages and zealot_recovery_percentages.melee_kill or 0.05

local elite_kills_settings = zealot_settings.zealot_elite_kills_empowers
local elite_kill_regen_total = elite_kills_settings and elite_kills_settings.toughness or 0.15
local elite_kill_regen_duration = elite_kills_settings and elite_kills_settings.duration or 5

--- Talent buff templates; a buff template tier above 0 means the build has the talent.
local HEAVY_KILL_BUFF_NAME = "zealot_toughness_on_heavy_kills"
local ELITE_KILLS_BUFF_NAME = "zealot_elite_kills_empowers"

--- Talent proc buffs whose activation the server reports to the client (they have a cooldown).
-- The restored fraction is the template's `toughness_percentage`, scaled by the stat buffs.
local TALENT_TOUGHNESS_PROC_TEMPLATES = {
    zealot_toughness_on_dodge = true
}

--- Replenish reasons of the Zealot buffs whose `start_func` or `update_func` also runs on the
-- client: Shroudfield's restore (`zealot_stealth`), the in-melee regeneration
-- (`talent_toughness_3`), Momentum (`zealot_quickness_active`) and Fanatic Rage at maximum
-- stacks (`fanatic_rage`). Calls without a reason are never captured, because the weapon
-- blessings and the elite-kill regeneration use none and are counted by other means.
local REPLENISH_CAPTURE_REASONS = {
    zealot_stealth = true,
    talent_toughness_3 = true,
    zealot_quickness_active = true,
    fanatic_rage = true
}

local STEALTH_CAPTURE_REASON = "zealot_stealth"

--- Weapon blessing proc buffs that restore a fixed percentage of Toughness, grouped by trigger.
-- A deliberate superset: a template for a weapon the Zealot cannot equip simply never procs.
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
-- Interface
-- ----------------------------------------------------------------------------

--- The Zealot source model.
-- `share_fraction` is 0 because the Zealot has no sharing talent; the estimator mode, the empty
-- adapter list and `available_max_fraction` only keep the interface uniform with the sharing
-- archetypes. The remaining fields are inputs for `OverflowMeter_pulses_zealot.lua`. The heavy-kill
-- restore and the two de-duplication windows are hard-coded, the first because the game's buff
-- template hard-codes it as well.
return {
    continuous_when_full = false,
    has_inactive_state = false,

    share_fraction = 0,
    adapters = {},

    available_max_fraction = function (ctx)
        return 0
    end,

    weapon_toughness_proc_templates = WEAPON_TOUGHNESS_PROC_TEMPLATES,
    continuous_fire_templates = CONTINUOUS_FIRE_TEMPLATES,
    max_continuous_fire_steps = 5,
    talent_toughness_proc_templates = TALENT_TOUGHNESS_PROC_TEMPLATES,

    melee_kill_base_fraction = melee_kill_base_fraction,

    heavy_kill_fraction = 0.1,
    heavy_kill_talent_buff_name = HEAVY_KILL_BUFF_NAME,

    elite_kill_talent_buff_name = ELITE_KILLS_BUFF_NAME,
    elite_kill_regen_rate = elite_kill_regen_total / elite_kill_regen_duration,
    elite_kill_regen_duration = elite_kill_regen_duration,

    replenish_capture_reasons = REPLENISH_CAPTURE_REASONS,
    stealth_capture_reason = STEALTH_CAPTURE_REASON,
    stealth_dedupe_window = 1,
    lunge_dedupe_window = 0.5
}
