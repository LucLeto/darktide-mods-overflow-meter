--- Psyker pulse tracking: the replenishes the Toughness bar cannot show, for the mission statistics.
-- The HUD element measures what fills the replicated bar, which misses the part clamped at the
-- cap and everything that lands at full. This module infers that part from client-side signals:
-- kills and hits in local attack reports (melee kills, Soulstealer's warp kills and Warp
-- Expenditure's per-hit restore), weapon blessing procs, the Peril changes Quietude converts, and
-- the Psyker buffs whose replenish also runs on the client (Mettle, Souldrinker, Scrier's Gaze and
-- Warp Expenditure's weakspot-kill regeneration). It also models Disrupt Destiny's marked-kill
-- restore and Essence Harvest's regeneration while their buffs run: the first replenish carries
-- no reason to capture, the second runs on the server only.
--
-- Soulstealer, Warp Expenditure's per-hit restore and Quietude are proc functions of buffs the
-- game does not predict, so only the server runs them. They are counted from their triggers on
-- every machine, also when hosting, so solo play checks the same path a client uses.
--
-- The HUD element drains `pending_excess`, the clamped excess of every restore in Toughness
-- points, each sample. The Psyker shares nothing, so the burst queues of the sharing archetypes
-- always read 0.
--
-- The clamped excess needs the missing Toughness from before the restore. The replenish requests
-- arrive before the game applies them, so the bar is current for them. Kills, hits, procs and
-- Peril changes are seen only after the server has restored Toughness, and by then the bar can
-- already show the restore (when hosting it always does). For those the missing Toughness at the
-- last sample is used as well, less what the restores counted since then took up.
--
-- After a misprediction the client re-simulates the local unit's last frames, running its buffs
-- again. Replenish requests seen while the unit re-simulates were already counted the first time,
-- so they are ignored.
--
-- Explicit module loaded by `OverflowMeter.lua` and stored as `mod._pulses_psyker`.
-- `on_proc_active`, `on_attack_result` and `on_replenish_percentage` are called from the shared
-- hooks in `OverflowMeter.lua`, `update` every frame by the HUD element. `set_context` enables it
-- for the local player's unit, and it ignores every event while disabled.
-- module: OverflowMeter_pulses_psyker
-- alias: Pulses
-- author: LucLeto
local mod = get_mod("OverflowMeter")
local AttackSettings = require("scripts/settings/damage/attack_settings")
local Sources = mod._sources_psyker

local ScriptUnit = ScriptUnit
local Managers = Managers
local math_min = math.min
local type = type

local ATTACK_RESULT_DIED = AttackSettings.attack_results.died
local ATTACK_TYPE_MELEE = AttackSettings.attack_types.melee
local WARP_CHARGE_EXPLODING = "exploding"

--- Labels of the counted sources: the game's replenish reason where the source has one, which
-- lets the TEMPORARY solo-play comparison set each source against the game's own figure. Warp
-- Expenditure's per-hit restore has its own label, so the comparison can tell it from the
-- regeneration that shares its reason.
local SOURCE_MELEE_KILL = "melee_kill"
local SOURCE_WARP_KILL = "talent_toughness_2"
local SOURCE_MELEE_HIT = "psyker_melee_hit"
local SOURCE_WARP_GENERATION = "toughness_on_warp_generation"
local SOURCE_VENT = "toughness_on_vent"
local SOURCE_BLESSING = "blessing"
local SOURCE_ESSENCE_HARVEST = "talent_toughness_1"
local SOURCE_CONTINUOUS_MODEL = "continuous_model"
--- Timer value for "never happened", so the first hit always starts an attack.
local NEVER = -math.huge

--- Pulse state.
-- Besides the queue and the local Psyker's unit, extensions and talent flags, it holds the missing
-- Toughness at the last sample and how much of it the restores since then took up, the Peril seen
-- last frame and whether it was exploding, and when the last melee attack's first hit landed.
-- `continuous_source` labels the modelled regeneration for the TEMPORARY solo-play comparison.
local Pulses = {
    enabled = false,
    continuous_source = SOURCE_CONTINUOUS_MODEL,
    pending_excess = 0,
    sample_damage = 0,
    used_headroom = 0,
    unit = nil,
    buff_extension = nil,
    toughness_extension = nil,
    unit_data_extension = nil,
    warp_charge_component = nil,
    has_warp_kill_talent = false,
    has_melee_hit_talent = false,
    has_warp_generation_talent = false,
    has_vent_talent = false,
    last_warp_charge = 0,
    last_warp_charge_exploding = false,
    last_melee_attack_t = NEVER
}

-- ----------------------------------------------------------------------------
-- Context and queues
-- ----------------------------------------------------------------------------

--- Returns whether the build has the talent that grants a buff template.
-- The game keeps a tier only for the first buff template of a talent that grants several
-- (`CharacterSheet._handle_buff_tier`), and Quietude grants two, so the passive buff itself on the
-- unit counts as well.
-- ?tab: talent_extension local player's talent extension
-- ?tab: buff_extension local player's buff extension
-- string: buff_template_name buff template the talent grants
-- treturn: bool
local function _has_talent_buff(talent_extension, buff_extension, buff_template_name)
    if talent_extension and talent_extension.buff_template_tier then
        local tier = talent_extension:buff_template_tier(buff_template_name)

        if tier ~= nil and tier ~= 0 then
            return true
        end
    end

    return buff_extension ~= nil and buff_extension.has_buff_using_buff_template ~= nil and buff_extension:has_buff_using_buff_template(buff_template_name)
end

--- Enables the module for the local player's unit and caches its extensions and talent flags.
-- The HUD element calls it again every second while supported, so the Peril and attack trackers
-- only restart when the module was disabled or the unit changed.
-- param: unit local player unit
-- tab: buff_extension its buff extension
-- tab: toughness_extension its toughness extension
-- ?tab: talent_extension its talent extension
Pulses.set_context = function(unit, buff_extension, toughness_extension, talent_extension)
    local same_unit = Pulses.enabled and Pulses.unit == unit

    Pulses.enabled = true
    Pulses.unit = unit
    Pulses.buff_extension = buff_extension
    Pulses.toughness_extension = toughness_extension

    local unit_data_extension = ScriptUnit.has_extension(unit, "unit_data_system")
    local warp_charge_component = unit_data_extension and unit_data_extension.read_component and unit_data_extension:read_component("warp_charge")

    Pulses.unit_data_extension = unit_data_extension
    Pulses.warp_charge_component = warp_charge_component
    Pulses.has_warp_kill_talent = _has_talent_buff(talent_extension, buff_extension, Sources.warp_kill_talent_buff_name)
    Pulses.has_melee_hit_talent = _has_talent_buff(talent_extension, buff_extension, Sources.melee_hit_talent_buff_name)
    Pulses.has_warp_generation_talent = _has_talent_buff(talent_extension, buff_extension, Sources.warp_generation_talent_buff_name)
    Pulses.has_vent_talent = _has_talent_buff(talent_extension, buff_extension, Sources.vent_talent_buff_name)

    if not same_unit then
        if Pulses.has_warp_kill_talent then
            Sources.prepare_warp_profiles()
        end

        Pulses.sample_damage = toughness_extension:toughness_damage()
        Pulses.used_headroom = 0
        Pulses.last_warp_charge = warp_charge_component and warp_charge_component.current_percentage or 0
        Pulses.last_warp_charge_exploding = false
        Pulses.last_melee_attack_t = NEVER
    end
end

--- Disables the module and clears the queue, every cached reference, talent flag and tracker.
Pulses.disable = function()
    Pulses.enabled = false
    Pulses.continuous_source = SOURCE_CONTINUOUS_MODEL
    Pulses.pending_excess = 0
    Pulses.sample_damage = 0
    Pulses.used_headroom = 0
    Pulses.unit = nil
    Pulses.buff_extension = nil
    Pulses.toughness_extension = nil
    Pulses.unit_data_extension = nil
    Pulses.warp_charge_component = nil
    Pulses.has_warp_kill_talent = false
    Pulses.has_melee_hit_talent = false
    Pulses.has_warp_generation_talent = false
    Pulses.has_vent_talent = false
    Pulses.last_warp_charge = 0
    Pulses.last_warp_charge_exploding = false
    Pulses.last_melee_attack_t = NEVER
end

--- Returns and clears the clamped excess of the restores since the last sample.
-- The HUD element calls it once per sample, so it also takes the missing Toughness of this sample
-- as the reference for the restores that follow.
-- treturn: number Toughness points
Pulses.consume = function()
    local pending_excess = Pulses.pending_excess
    local toughness_extension = Pulses.toughness_extension

    Pulses.pending_excess = 0
    Pulses.sample_damage = toughness_extension and toughness_extension:toughness_damage() or 0
    Pulses.used_headroom = 0

    return pending_excess
end

--- The Psyker shares nothing with allies, so there is never a share burst.
-- treturn: number always 0
Pulses.consume_burst = function()
    return 0
end

--- The Psyker has no burst restore of its own.
-- treturn: number always 0
Pulses.consume_burst_overflow = function()
    return 0
end

-- ----------------------------------------------------------------------------
-- Pulse recording
-- ----------------------------------------------------------------------------

--- Adds the part of a wanted restore that exceeds the missing Toughness to the excess queue.
-- A restore seen before the game applies it uses the current missing Toughness. One seen after
-- the server applied it uses the larger of the current missing Toughness and the missing Toughness
-- at the last sample less what the restores since then took up, because the bar may already show
-- this restore.
-- ?number: wanted wanted restore in Toughness points; ignored unless positive
-- string: source label of the source
-- ?bool: before_applied true when the restore is seen before the game applies it
local function _accumulate_wanted(wanted, source, before_applied)
    if not wanted or wanted <= 0 then
        return
    end

    local toughness_extension = Pulses.toughness_extension

    if not toughness_extension then
        return
    end

    local damage = toughness_extension:toughness_damage()
    local headroom = damage

    if not before_applied then
        local remaining = Pulses.sample_damage - Pulses.used_headroom

        if remaining > headroom then
            headroom = remaining
        end
    end

    local excess = wanted - headroom

    if excess > 0 then
        Pulses.pending_excess = Pulses.pending_excess + excess
        Pulses.used_headroom = Pulses.used_headroom + headroom
    else
        Pulses.used_headroom = Pulses.used_headroom + wanted
    end

    -- TEMPORARY: per-source figures for the solo-play comparison, and how the bar looked when a
    -- restore applied by the server arrived.
    local debug_truth = mod._debug_truth

    if debug_truth then
        debug_truth.record_mod(source, wanted, excess > 0 and excess or 0)

        if not before_applied then
            debug_truth.record_headroom(source, wanted, damage, Pulses.sample_damage, wanted - damage, excess)
        end
    end
end

--- Records a restore given as a fraction of maximum Toughness.
-- ?number: fraction restore fraction; ignored unless positive
-- ?bool: apply_replenish_stat_buffs scale by `toughness_replenish_modifier` and
-- `toughness_replenish_multiplier`, as the game does for restores that use stat buffs
-- string: source label of the source
-- ?bool: before_applied true when the restore is seen before the game applies it
local function _add_pulse(fraction, apply_replenish_stat_buffs, source, before_applied)
    if not fraction or fraction <= 0 then
        return
    end

    local toughness_extension = Pulses.toughness_extension

    if not toughness_extension then
        return
    end

    local wanted = fraction * toughness_extension:max_toughness()

    if apply_replenish_stat_buffs then
        local buff_extension = Pulses.buff_extension
        local stat_buffs = buff_extension and buff_extension.stat_buffs and buff_extension:stat_buffs()

        if stat_buffs then
            wanted = wanted * (stat_buffs.toughness_replenish_modifier or 1) * (stat_buffs.toughness_replenish_multiplier or 1)
        end
    end

    _accumulate_wanted(wanted, source, before_applied)
end

--- Records the base melee-kill restore, scaled the way the game's toughness template does.
-- The melee replenish bonus adds to the replenish modifier, and the replenish multiplier applies
-- on top.
local function _add_melee_kill_pulse()
    local toughness_extension = Pulses.toughness_extension

    if not toughness_extension then
        return
    end

    local fraction = Sources.melee_kill_base_fraction
    local buff_extension = Pulses.buff_extension
    local stat_buffs = buff_extension and buff_extension.stat_buffs and buff_extension:stat_buffs()

    if stat_buffs then
        fraction = fraction * ((stat_buffs.toughness_melee_replenish or 1) + (stat_buffs.toughness_replenish_modifier or 1) - 1) * (stat_buffs.toughness_replenish_multiplier or 1)
    end

    if fraction > 0 then
        _accumulate_wanted(fraction * toughness_extension:max_toughness(), SOURCE_MELEE_KILL)
    end
end

-- ----------------------------------------------------------------------------
-- Continuous sources
-- ----------------------------------------------------------------------------

--- Returns the current gameplay time, or 0 before the gameplay timer exists.
-- treturn: number
local function _now()
    local time_manager = Managers.time

    if time_manager and time_manager.has_timer and time_manager:has_timer("gameplay") then
        return time_manager:time("gameplay")
    end

    return 0
end

--- Returns whether the client is re-simulating the Psyker's last frames after a misprediction.
-- treturn: bool
local function _is_resimulating()
    local unit_data_extension = Pulses.unit_data_extension

    return unit_data_extension and unit_data_extension.is_resimulating or false
end

--- Returns the rate of the continuous sources currently running.
-- Two are modelled from their buffs, which the server syncs to the client: Disrupt Destiny, whose
-- marked kill adds a bonus buff that restores its share every frame for 2.5 s, and Essence
-- Harvest, whose buff restores every frame for 5 s after a Warp Charge is gained. The two
-- keystones exclude each other. The HUD element uses the rate only at full Toughness, where the
-- bar cannot show it.
-- treturn: number fraction of maximum Toughness per second, before stat buffs
Pulses.active_continuous_fraction = function()
    local buff_extension = Pulses.buff_extension

    if not Pulses.enabled or not buff_extension or not buff_extension.current_stacks then
        return 0
    end

    local fraction = 0

    if buff_extension:current_stacks(Sources.marked_kill_bonus_buff_name) > 0 then
        fraction = fraction + Sources.marked_kill_regen_rate
        Pulses.continuous_source = SOURCE_CONTINUOUS_MODEL
    end

    if buff_extension:current_stacks(Sources.essence_harvest_buff_name) > 0 then
        fraction = fraction + Sources.essence_harvest_regen_rate
        Pulses.continuous_source = SOURCE_ESSENCE_HARVEST
    end

    return fraction
end

--- Follows the Psyker's Peril every frame for Quietude.
-- The talent restores 0.4 % of maximum Toughness per 1 % of Peril generated, and as much per 1 %
-- quelled, whether by venting, passively or at once. The game converts every change of the warp
-- charge as it happens, so the change since last frame is recorded in the same way. Peril cleared
-- after Perils of the Warp is skipped: the game clears it without a buff event. The Peril is
-- followed without the talent too, so a change of talents never counts the gap as one change.
Pulses.update = function()
    local component = Pulses.warp_charge_component

    if not Pulses.enabled or not component then
        return
    end

    local current = component.current_percentage or 0
    local was_exploding = Pulses.last_warp_charge_exploding
    local change = current - Pulses.last_warp_charge

    Pulses.last_warp_charge = current
    Pulses.last_warp_charge_exploding = component.state == WARP_CHARGE_EXPLODING

    if change > 0 then
        if Pulses.has_warp_generation_talent then
            _add_pulse(change * Sources.quietude_multiplier, true, SOURCE_WARP_GENERATION)
        end
    elseif change < 0 and Pulses.has_vent_talent and not was_exploding then
        _add_pulse(-change * Sources.quietude_multiplier, true, SOURCE_VENT)
    end
end

-- ----------------------------------------------------------------------------
-- Events
-- ----------------------------------------------------------------------------

--- Records a weapon blessing proc of the local player.
-- A blessing restores the fixed percentage from its tier's override data, or else the template,
-- multiplied by the fire step (at most 5) for continuous fire, and ignores Toughness stat buffs.
-- A multi-hit blessing restores its tier's `buff_data.replenish_percentage` instead, scaled by the
-- stat buffs.
-- tab: buff_extension buff extension whose proc became active
-- ?int: index index of the buff instance
Pulses.on_proc_active = function(buff_extension, index)
    if not Pulses.enabled or buff_extension ~= Pulses.buff_extension then
        return
    end

    local buff_instance = index and buff_extension._buffs_by_index[index]

    if not buff_instance or not buff_instance.template_name then
        return
    end

    local template_name = buff_instance:template_name()

    if not Sources.weapon_toughness_proc_templates[template_name] then
        return
    end

    local template_context = buff_instance.template_context and buff_instance:template_context()
    local override_data = template_context and template_context.template_override_data
    local template = buff_instance.template and buff_instance:template()

    if Sources.multiple_hits_templates[template_name] then
        local buff_data = override_data and override_data.buff_data or template and template.buff_data

        _add_pulse(buff_data and buff_data.replenish_percentage, true, SOURCE_BLESSING)

        return
    end

    local fixed_percentage = override_data and override_data.toughness_fixed_percentage or template and template.toughness_fixed_percentage

    if not fixed_percentage then
        return
    end

    if Sources.continuous_fire_templates[template_name] then
        local fire_step = buff_instance.visual_stack_count and buff_instance:visual_stack_count() or 1

        if fire_step < 1 then
            fire_step = 1
        end

        fixed_percentage = fixed_percentage * math_min(fire_step, Sources.max_continuous_fire_steps)
    end

    _add_pulse(fixed_percentage, false, SOURCE_BLESSING)
end

--- Records what one of the Psyker's own hits or kills restores.
-- Melee kills add the base melee restore and warp kills Soulstealer's. Warp Expenditure restores
-- on the first target of each melee attack, unless that hit is a weakspot kill, which starts the
-- regeneration instead; the reports carry no target index, so a melee hit opens an attack when
-- the last one opened at least `melee_attack_window` earlier. Profiles that never proc on hit are
-- skipped for both talents, as the game skips them. The arguments are those of
-- `AttackReportManager.add_attack_result`.
-- ?tab: damage_profile damage profile of the attack
-- param: attacked_unit unit that was hit
-- param: attacking_unit unit that attacked; only the local player's hits count
-- ?bool: hit_weakspot whether the hit landed on a weakspot
-- string: attack_result `died` for a kill
-- string: attack_type such as `melee` or `ranged`
Pulses.on_attack_result = function(damage_profile, attacked_unit, attacking_unit, attack_direction, hit_world_position, hit_weakspot, damage, attack_result, attack_type, damage_efficiency, is_critical_strike)
    if not Pulses.enabled or attacking_unit ~= Pulses.unit then
        return
    end

    local died = attack_result == ATTACK_RESULT_DIED
    local is_melee = attack_type == ATTACK_TYPE_MELEE

    if died and is_melee then
        _add_melee_kill_pulse()
    end

    if not damage_profile or damage_profile.skip_on_hit_proc then
        return
    end

    if died and Pulses.has_warp_kill_talent and Sources.is_warp_damage_profile(damage_profile) then
        _add_pulse(Sources.warp_kill_fraction, true, SOURCE_WARP_KILL)
    end

    if is_melee and Pulses.has_melee_hit_talent then
        local now = _now()

        if now >= Pulses.last_melee_attack_t + Sources.melee_attack_window then
            Pulses.last_melee_attack_t = now

            if not (died and hit_weakspot) then
                _add_pulse(Sources.melee_hit_fraction, true, SOURCE_MELEE_HIT)
            end
        end
    end
end

--- Records a replenish the game asked for on the local player's unit.
-- Only the whitelisted Psyker reasons count, and none while the unit re-simulates. When hosting,
-- Warp Expenditure's per-hit restore also arrives here under the regeneration's reason; it is
-- told apart by its fraction and skipped, because the attack reports count it.
-- param: unit unit being replenished
-- ?number: fixed_percentage restore as a fraction of maximum Toughness
-- ?bool: ignore_stat_buffs true when the restore ignores Toughness stat buffs
-- ?string: reason replenish reason
Pulses.on_replenish_percentage = function(unit, fixed_percentage, ignore_stat_buffs, reason)
    if not Pulses.enabled or unit ~= Pulses.unit or type(fixed_percentage) ~= "number" or not reason or not Sources.replenish_capture_reasons[reason] or _is_resimulating() then
        return
    end

    if reason == Sources.melee_hit_capture_reason and fixed_percentage == Sources.melee_hit_fraction then
        return
    end

    _add_pulse(fixed_percentage, not ignore_stat_buffs, reason, true)
end

return Pulses
