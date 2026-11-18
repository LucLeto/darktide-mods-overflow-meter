--- Skitarii (Power Overflow) pulse tracking: discrete restores the bar cannot show while full.
-- Power Overflow only shares replenishes that land at full Toughness, where the replicated bar
-- cannot move, so discrete restores are inferred from client-side events: local attack reports
-- (melee kills, Servo-Core Recharge Engine weakspot kills, Flensing Protocols Elite and
-- Specialist kills, Voltaic Overcharge hits), weapon blessing procs, the Voltaic Emitter ability,
-- Voltaic Restoration's restore on every combat ability use, Data Sensor Protocol's restore when
-- the Skitarius takes health damage, and Invigorating Overload's restore when the overload
-- keystone triggers. Each restore becomes a fraction of maximum Toughness and is queued for the
-- HUD element, which drains the queues every sample. `pending_fraction` holds restores that
-- landed at full and is shared as a one-sample pulse; `pending_burst_fraction` holds Voltaic
-- Overcharge's on-use restore at full and is shown as a flash; `pending_overflow` holds the
-- Toughness lost against the cap, at full or not, in Toughness points.
--
-- Confident Strike restores only from the second chained hit on, so its activations are not
-- counted; the sweeps are followed through `OverflowMeter_chained_hits.lua` instead.
--
-- The overflow needs the missing Toughness from before the restore. Kills, hits, procs and the
-- Voltaic Emitter are seen only after the server restored Toughness, and by then the bar can
-- already show it (when hosting it always does). For those the missing Toughness at the last
-- sample is used as well, less what the restores counted since then took up. The ability and
-- sweep events arrive before the game applies their restore, so they read the bar as it is. This
-- only concerns the statistics; whether a restore landed at full, which decides what Power
-- Overflow shares, is still read from the bar at the event.
--
-- After a misprediction the client re-simulates the local unit's last frames and queues its
-- ability and sweep events again; those are ignored, as they were counted the first time.
--
-- Explicit module loaded by `OverflowMeter.lua` and stored as `mod._pulses`. `on_proc_active`,
-- `on_proc_event` and `on_attack_result` are called from the shared hooks in `OverflowMeter.lua`;
-- the Voltaic Emitter hook is registered here. `set_context` enables it for the local player's
-- unit, and it ignores every event while disabled.
-- module: OverflowMeter_pulses
-- alias: Pulses
-- author: LucLeto
local mod = get_mod("OverflowMeter")
local AttackSettings = require("scripts/settings/damage/attack_settings")
local BuffSettings = require("scripts/settings/buff/buff_settings")
local Sources = mod._sources
local ChainedHits = mod._chained_hits
local Blocked = mod._blocked_replenish

local ScriptUnit = ScriptUnit
local Managers = Managers
local math_min = math.min

local ATTACK_RESULT_DIED = AttackSettings.attack_results.died
local ATTACK_TYPE_MELEE = AttackSettings.attack_types.melee
local proc_events = BuffSettings.proc_events or {}
local PROC_EVENT_SWEEP_FINISH = proc_events.on_sweep_finish or "on_sweep_finish"
local PROC_EVENT_COMBAT_ABILITY = proc_events.on_combat_ability or "on_combat_ability"
local DEAD_STATE_NAME = "dead"
--- Replenish reason of the talent restores that follow; none of them passes a refusing keyword.
local REASON_CRYPTIC_TALENT = "cryptic_talent"
--- Toughness fraction treated as full, matching the HUD element.
local FULL_TOUGHNESS_EPSILON = 0.999
local COMBAT_ABILITY_TYPE = "combat_ability"
--- Health damage below which a change counts as none.
local HEALTH_DAMAGE_EPSILON = 0.01
--- Timer value for "never happened", so the first trigger is never on cooldown.
local NEVER = -math.huge

--- TEMPORARY: labels of the counted sources for the solo-play comparison, matching the game's
-- reason, or the reason and the buff template that restored where several talents share one.
local SOURCE_MELEE_KILL = "melee_kill"
local SOURCE_WEAKSPOT_KILL = "cryptic_talent:cryptic_weakspot_kills_restore_toughness"
local SOURCE_DISSECTOR = "cryptic_talent:cryptic_dissector"
local SOURCE_DISCHARGE_HIT = "discharge_hit"
local SOURCE_DISCHARGE_USE = "discharge_use"
local SOURCE_BLESSING = "blessing"
local SOURCE_VOLTAIC_RESTORATION = "cryptic_talent:cryptic_coherency_toughness_on_ability"
local SOURCE_DATA_SENSOR = "cryptic_talent:cryptic_ally_coherency_defenses_toughness"
local SOURCE_OVERLOAD = "cryptic_talent:cryptic_overload_keystone"

--- Pulse state: the pending queues, the local Skitarius' unit, extensions and components,
-- whether the build has the talent behind each pulse, the missing Toughness at the last sample
-- and how much of it the restores since then took up, and the triggers followed per sample: the
-- health damage and overload stacks last seen and when Data Sensor Protocol last restored.
local Pulses = {
    enabled = false,
    pending_fraction = 0,
    pending_burst_fraction = 0,
    pending_overflow = 0,
    sample_damage = 0,
    used_headroom = 0,
    unit = nil,
    buff_extension = nil,
    toughness_extension = nil,
    unit_data_extension = nil,
    health_extension = nil,
    inventory_component = nil,
    character_state_component = nil,
    assisted_state_input_component = nil,
    has_weakspot_talent = false,
    has_dissector_talent = false,
    has_discharge_toughness_talent = false,
    has_voltaic_restoration = false,
    has_data_sensor = false,
    has_overload_restore = false,
    last_health_damage = 0,
    last_overload_stacks = 0,
    last_data_sensor_t = NEVER
}

-- ----------------------------------------------------------------------------
-- Context and queues
-- ----------------------------------------------------------------------------

--- Returns whether the build has the talent that grants a buff template.
-- The game keeps a tier only for the first buff template of a talent that grants several
-- (`CharacterSheet._handle_buff_tier`), as Data Sensor Protocol does, so the passive buff itself
-- on the unit counts as well.
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

--- Returns the current gameplay time, or 0 before the gameplay timer exists.
-- treturn: number
local function _now()
    local time_manager = Managers.time

    if time_manager and time_manager.has_timer and time_manager:has_timer("gameplay") then
        return time_manager:time("gameplay")
    end

    return 0
end

--- Returns the overload keystone's current stacks, including its permanent base stack.
-- treturn: number
local function _overload_stacks()
    local buff_extension = Pulses.buff_extension

    return buff_extension and buff_extension.current_stacks and buff_extension:current_stacks(Sources.overload_stack_buff_name) or 0
end

--- Returns the health damage the Skitarius has taken, or 0 without a health extension.
-- treturn: number
local function _health_damage()
    local health_extension = Pulses.health_extension

    return health_extension and health_extension.damage_taken and health_extension:damage_taken() or 0
end

--- Enables the module for the local player's unit and caches its extensions, components and
-- talent flags. The HUD element calls it again every second while supported, so the chain, the
-- sample reference and the triggers only restart when the module was disabled or the unit
-- changed.
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
    local can_read = unit_data_extension and unit_data_extension.read_component

    Pulses.unit_data_extension = unit_data_extension
    Pulses.health_extension = ScriptUnit.has_extension(unit, "health_system")
    Pulses.inventory_component = can_read and unit_data_extension:read_component("inventory")
    Pulses.character_state_component = can_read and unit_data_extension:read_component("character_state")
    Pulses.assisted_state_input_component = can_read and unit_data_extension:read_component("assisted_state_input")
    Pulses.has_weakspot_talent = _has_talent_buff(talent_extension, buff_extension, Sources.weakspot_talent_buff_name)
    Pulses.has_dissector_talent = _has_talent_buff(talent_extension, buff_extension, Sources.dissector_talent_buff_name)
    Pulses.has_discharge_toughness_talent = _has_talent_buff(talent_extension, buff_extension, Sources.discharge_toughness_talent_buff_name)
    Pulses.has_voltaic_restoration = _has_talent_buff(talent_extension, buff_extension, Sources.voltaic_restoration_talent_buff_name)
    Pulses.has_data_sensor = _has_talent_buff(talent_extension, buff_extension, Sources.data_sensor_talent_buff_name)
    Pulses.has_overload_restore = talent_extension ~= nil and talent_extension.has_special_rule ~= nil and talent_extension:has_special_rule(Sources.overload_restore_special_rule) and true or false

    if not same_unit then
        ChainedHits.reset()

        Pulses.sample_damage = toughness_extension:toughness_damage()
        Pulses.used_headroom = 0
        Pulses.last_health_damage = _health_damage()
        Pulses.last_overload_stacks = _overload_stacks()
        Pulses.last_data_sensor_t = NEVER
    end
end

--- Disables the module and clears every queue, cached reference, talent flag and trigger.
Pulses.disable = function()
    ChainedHits.reset()

    Pulses.enabled = false
    Pulses.pending_fraction = 0
    Pulses.pending_burst_fraction = 0
    Pulses.pending_overflow = 0
    Pulses.sample_damage = 0
    Pulses.used_headroom = 0
    Pulses.unit = nil
    Pulses.buff_extension = nil
    Pulses.toughness_extension = nil
    Pulses.unit_data_extension = nil
    Pulses.health_extension = nil
    Pulses.inventory_component = nil
    Pulses.character_state_component = nil
    Pulses.assisted_state_input_component = nil
    Pulses.has_weakspot_talent = false
    Pulses.has_dissector_talent = false
    Pulses.has_discharge_toughness_talent = false
    Pulses.has_voltaic_restoration = false
    Pulses.has_data_sensor = false
    Pulses.has_overload_restore = false
    Pulses.last_health_damage = 0
    Pulses.last_overload_stacks = 0
    Pulses.last_data_sensor_t = NEVER
end

-- ----------------------------------------------------------------------------
-- Pulse recording
-- ----------------------------------------------------------------------------

--- Returns whether the local player is at full Toughness.
-- treturn: bool
local function _is_full()
    local toughness_extension = Pulses.toughness_extension

    return toughness_extension ~= nil and toughness_extension:current_toughness_percent() >= FULL_TOUGHNESS_EPSILON
end

--- Returns whether the game would refuse one of the talent restores below right now.
-- treturn: bool
local function _is_blocked()
    return Blocked.is_blocked(Pulses.character_state_component, Pulses.assisted_state_input_component, Pulses.buff_extension, REASON_CRYPTIC_TALENT)
end

--- Adds the part of a restore that exceeds the missing Toughness to the overflow.
-- A restore seen before the game applies it uses the current missing Toughness. One seen after
-- the server applied it uses the larger of the current missing Toughness and the missing
-- Toughness at the last sample less what the restores since then took up.
-- number: fraction restore as a fraction of maximum Toughness
-- string: source TEMPORARY label of the source
-- ?bool: before_applied true when the restore is seen before the game applies it
local function _accumulate_overflow(fraction, source, before_applied)
    local toughness_extension = Pulses.toughness_extension

    if not toughness_extension then
        return
    end

    local wanted = fraction * toughness_extension:max_toughness()
    local headroom = toughness_extension:toughness_damage()

    if not before_applied then
        local remaining = Pulses.sample_damage - Pulses.used_headroom

        if remaining > headroom then
            headroom = remaining
        end
    end

    local excess = wanted - headroom

    if excess > 0 then
        Pulses.pending_overflow = Pulses.pending_overflow + excess
        Pulses.used_headroom = Pulses.used_headroom + headroom
    else
        Pulses.used_headroom = Pulses.used_headroom + wanted
    end

    -- TEMPORARY: per-source figures for the solo-play comparison.
    local debug_truth = mod._debug_truth

    if debug_truth then
        debug_truth.record_mod(source, wanted, excess > 0 and excess or 0)
    end
end

--- Records a restore: its overflow always, and the restore itself when it lands at full.
-- ?number: fraction restore as a fraction of maximum Toughness; ignored unless positive
-- ?bool: apply_replenish_stat_buffs scale by `toughness_replenish_modifier` and
-- `toughness_replenish_multiplier`, as the game does for restores that use stat buffs
-- ?bool: as_burst queue a restore at full as a burst instead of a pulse
-- string: source TEMPORARY label of the source
-- ?bool: before_applied true when the restore is seen before the game applies it
local function _add_pulse(fraction, apply_replenish_stat_buffs, as_burst, source, before_applied)
    if not fraction or fraction <= 0 then
        return
    end

    if apply_replenish_stat_buffs then
        local buff_extension = Pulses.buff_extension
        local stat_buffs = buff_extension and buff_extension.stat_buffs and buff_extension:stat_buffs()

        if stat_buffs then
            fraction = fraction * (stat_buffs.toughness_replenish_modifier or 1) * (stat_buffs.toughness_replenish_multiplier or 1)
        end
    end

    _accumulate_overflow(fraction, source, before_applied)

    if _is_full() then
        if as_burst then
            Pulses.pending_burst_fraction = Pulses.pending_burst_fraction + fraction
        else
            Pulses.pending_fraction = Pulses.pending_fraction + fraction
        end
    end
end

--- Records the base melee-kill restore, scaled the way the game's toughness template does.
-- The melee replenish bonus (Slaughter Protocol) adds to the replenish modifier, and the
-- replenish multiplier applies on top.
local function _add_melee_kill_pulse()
    local fraction = Sources.melee_kill_base_fraction
    local buff_extension = Pulses.buff_extension
    local stat_buffs = buff_extension and buff_extension.stat_buffs and buff_extension:stat_buffs()

    if stat_buffs then
        fraction = fraction * ((stat_buffs.toughness_melee_replenish or 1) + (stat_buffs.toughness_replenish_modifier or 1) - 1) * (stat_buffs.toughness_replenish_multiplier or 1)
    end

    if fraction > 0 then
        _accumulate_overflow(fraction, SOURCE_MELEE_KILL)

        if _is_full() then
            Pulses.pending_fraction = Pulses.pending_fraction + fraction
        end
    end
end

--- Records the restores whose triggers are followed per sample.
-- Data Sensor Protocol restores 25 % when the Skitarius takes health damage and lives, at most
-- once per its cooldown; the cooldown starts with the restore. Invigorating Overload restores
-- 20 % when the overload keystone triggers. The trigger is the only thing that removes the stacks
-- the keystone built, all at once, and leaves its base stack, so any drop with the base stack
-- still there is one; kills later in the same sweep can already have added new stacks. The game
-- refuses both restores while knocked down or under a refusing keyword.
local function _poll_triggers()
    if Pulses.has_data_sensor then
        local health_damage = _health_damage()

        if health_damage > Pulses.last_health_damage + HEALTH_DAMAGE_EPSILON then
            local now = _now()
            local component = Pulses.character_state_component
            local dead = component and component.state_name == DEAD_STATE_NAME

            if not dead and now >= Pulses.last_data_sensor_t + Sources.data_sensor_cooldown then
                Pulses.last_data_sensor_t = now

                if not _is_blocked() then
                    _add_pulse(Sources.data_sensor_fraction, true, false, SOURCE_DATA_SENSOR)
                end
            end
        end

        Pulses.last_health_damage = health_damage
    end

    local stacks = _overload_stacks()

    if Pulses.has_overload_restore and stacks >= 1 and stacks < Pulses.last_overload_stacks and not _is_blocked() then
        _add_pulse(Sources.overload_restore_fraction, true, false, SOURCE_OVERLOAD)
    end

    Pulses.last_overload_stacks = stacks
end

--- Returns and clears the restores that landed at full Toughness, after recording the restores
-- whose triggers are followed per sample (the HUD element calls this first each sample).
-- treturn: number fraction of maximum Toughness
Pulses.consume = function()
    if Pulses.enabled then
        _poll_triggers()
    end

    local pending_fraction = Pulses.pending_fraction

    Pulses.pending_fraction = 0

    return pending_fraction
end

--- Returns and clears Voltaic Overcharge's on-use restores that landed at full Toughness.
-- treturn: number fraction of maximum Toughness
Pulses.consume_burst_fraction = function()
    local pending_burst_fraction = Pulses.pending_burst_fraction

    Pulses.pending_burst_fraction = 0

    return pending_burst_fraction
end

--- Returns and clears the Toughness lost against the cap.
-- The HUD element calls it once per sample, last, so it also takes the missing Toughness of this
-- sample as the reference for the restores that follow.
-- treturn: number Toughness points
Pulses.consume_overflow = function()
    local pending_overflow = Pulses.pending_overflow
    local toughness_extension = Pulses.toughness_extension

    Pulses.pending_overflow = 0
    Pulses.sample_damage = toughness_extension and toughness_extension:toughness_damage() or 0
    Pulses.used_headroom = 0

    return pending_overflow
end

-- ----------------------------------------------------------------------------
-- Events
-- ----------------------------------------------------------------------------

--- Returns whether the client is re-simulating the Skitarius' last frames after a misprediction.
-- treturn: bool
local function _is_resimulating()
    local unit_data_extension = Pulses.unit_data_extension

    return unit_data_extension and unit_data_extension.is_resimulating or false
end

--- Records a weapon blessing proc of the local player.
-- The fixed percentage comes from the blessing tier's override data, or else the template.
-- Continuous fire multiplies it by the fire step, at most 5. Blessing restores ignore Toughness
-- stat buffs. Confident Strike's activations are skipped: its restores come from the sweeps.
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

    if not Sources.weapon_toughness_proc_templates[template_name] or ChainedHits.templates[template_name] then
        return
    end

    local template_context = buff_instance.template_context and buff_instance:template_context()
    local override_data = template_context and template_context.template_override_data
    local template = buff_instance.template and buff_instance:template()
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

    _add_pulse(fixed_percentage, false, false, SOURCE_BLESSING)
end

--- Records what a buff event queued for the local player restores.
-- A finished melee sweep may give Confident Strike's restore, and every combat ability use gives
-- Voltaic Restoration's. Both events come before the game applies the restore, and none counts
-- while the unit re-simulates.
-- tab: buff_extension buff extension the event was queued for
-- string: event proc event name
-- ?tab: params event parameters
Pulses.on_proc_event = function(buff_extension, event, params)
    if not Pulses.enabled or buff_extension ~= Pulses.buff_extension then
        return
    end

    if event == PROC_EVENT_SWEEP_FINISH then
        if _is_resimulating() then
            return
        end

        local fraction = ChainedHits.on_sweep_finish(buff_extension, params, Pulses.inventory_component)

        if fraction then
            _add_pulse(fraction, false, false, SOURCE_BLESSING, true)
        end
    elseif event == PROC_EVENT_COMBAT_ABILITY then
        if Pulses.has_voltaic_restoration and not _is_resimulating() and not _is_blocked() then
            _add_pulse(Sources.voltaic_restoration_fraction, true, false, SOURCE_VOLTAIC_RESTORATION, true)
        end
    end
end

--- Records the restores triggered by one of the local player's attack reports.
-- Any Voltaic Overcharge explosion hit restores 1 %. A kill adds the base melee restore for melee
-- kills, Servo-Core Recharge Engine for weakspot kills and Flensing Protocols for Elite and
-- Specialist kills. The arguments are those of `AttackReportManager.add_attack_result`.
-- ?tab: damage_profile damage profile of the attack
-- param: attacked_unit unit that was hit
-- param: attacking_unit unit that attacked; only the local player's attacks count
-- bool: hit_weakspot whether a weakspot was hit
-- string: attack_result `died` for a kill
-- string: attack_type such as `melee` or `ranged`
Pulses.on_attack_result = function(damage_profile, attacked_unit, attacking_unit, attack_direction, hit_world_position, hit_weakspot, damage, attack_result, attack_type, damage_efficiency, is_critical_strike)
    if not Pulses.enabled or attacking_unit ~= Pulses.unit then
        return
    end

    if Pulses.has_discharge_toughness_talent and damage_profile and damage_profile.name == Sources.discharge_damage_profile_name then
        _add_pulse(Sources.discharge_hit_fraction, true, false, SOURCE_DISCHARGE_HIT)
    end

    if attack_result ~= ATTACK_RESULT_DIED then
        return
    end

    if attack_type == ATTACK_TYPE_MELEE then
        _add_melee_kill_pulse()
    end

    if hit_weakspot and Pulses.has_weakspot_talent then
        _add_pulse(Sources.weakspot_kill_fraction, true, false, SOURCE_WEAKSPOT_KILL)
    end

    if Pulses.has_dissector_talent and attacked_unit then
        local unit_data_extension = ScriptUnit.has_extension(attacked_unit, "unit_data_system")
        local breed = unit_data_extension and unit_data_extension.breed and unit_data_extension:breed()
        local tags = breed and breed.tags

        if tags and (tags.elite or tags.special) then
            _add_pulse(Sources.dissector_kill_fraction, true, false, SOURCE_DISSECTOR)
        end
    end
end

--- Returns how many combat ability charges a Voltaic Emitter use counts as, the way the game does.
-- The Mortis Trials full-charge keyword makes every use count as the maximum. Otherwise it is the
-- cost `ActionAbilityBase.start` consumed, falling back to the ability extension's last count and
-- then 1, capped at the maximum.
-- tab: action the `ActionCrypticDischarge` instance
-- treturn: number charges, 1 to the maximum
local function _discharge_charges(action)
    local max_charges = Sources.discharge_max_charges
    local buff_extension = action._buff_extension

    if buff_extension and buff_extension.has_keyword and buff_extension:has_keyword(Sources.discharge_full_charges_keyword) then
        return max_charges
    end

    local charges = action._ability_cost_at_start

    if type(charges) ~= "number" or charges < 1 then
        local ability_extension = action._ability_extension

        charges = ability_extension and ability_extension.ability_charges_used_on_activation and ability_extension:ability_charges_used_on_activation(COMBAT_ABILITY_TYPE)
    end

    if type(charges) ~= "number" or charges < 1 then
        return 1
    end

    return math_min(charges, max_charges)
end

-- Voltaic Emitter use. With Voltaic Overcharge it restores 25 % per charge spent, queued as a
-- burst. The hook runs after `ActionAbilityBase.start` has consumed the charges.
mod:hook_safe(CLASS.ActionCrypticDischarge, "start", function(self, action_settings, t, time_scale, action_start_params)
    if not Pulses.enabled or self._player_unit ~= Pulses.unit then
        return
    end

    local talent_extension = self._talent_extension

    if talent_extension and talent_extension.has_special_rule and talent_extension:has_special_rule(Sources.discharge_restore_special_rule) then
        _add_pulse(Sources.discharge_use_fraction * _discharge_charges(self), true, true, SOURCE_DISCHARGE_USE)
    end
end)

return Pulses
