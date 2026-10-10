--- Zealot pulse tracking: the replenishes the Toughness bar cannot show, for the mission statistics.
-- The HUD element measures what fills the replicated bar, which misses the part clamped at the
-- cap and everything that lands at full. This module infers that part from client-side events:
-- kills in local attack reports (melee kills and heavy-attack kills), weapon blessing and dodge
-- procs, Chastise the Wicked's dash, and the Zealot buffs whose replenish also runs on the client
-- (Shroudfield, the in-melee regeneration, Momentum and Fanatic Rage at maximum stacks). It also
-- models the elite-kill regeneration window, because its replenish carries no reason to capture.
--
-- The HUD element drains `pending_excess`, the clamped excess of every restore in Toughness
-- points, each sample. The Zealot shares nothing, so the burst queues of the sharing archetypes
-- always read 0.
--
-- After a misprediction the client re-simulates the local unit's last frames, running its buffs
-- and character states again. Replenish requests and lunges seen while the unit re-simulates were
-- already counted the first time, so they are ignored.
--
-- Explicit module loaded by `OverflowMeter.lua` and stored as `mod._pulses_zealot`.
-- `on_proc_active`, `on_attack_result` and `on_replenish_percentage` are called from the shared
-- hooks in `OverflowMeter.lua`; the lunge hook is registered here, because no other module needs
-- it yet (once another archetype's lunge is tracked it has to move to the shared hooks, since DMF
-- keeps only one hook per mod and method). `set_context` enables it for the local player's unit,
-- and it ignores every event while disabled.
-- module: OverflowMeter_pulses_zealot
-- alias: Pulses
-- author: LucLeto
local mod = get_mod("OverflowMeter")
local AttackSettings = require("scripts/settings/damage/attack_settings")
local LungeTemplates = require("scripts/settings/lunge/lunge_templates")
local Sources = mod._sources_zealot

local ScriptUnit = ScriptUnit
local Managers = Managers
local math_min = math.min
local type = type

local ATTACK_RESULT_DIED = AttackSettings.attack_results.died
local ATTACK_TYPE_MELEE = AttackSettings.attack_types.melee
local MELEE_ATTACK_STRENGTH_HEAVY = "heavy"
--- Timer value for "never happened", so the first event is never de-duplicated.
local NEVER = -math.huge

--- Pulse state.
-- Besides the queue and the local Zealot's unit, extensions and talent flags, it holds the
-- modelled timers: when the elite-kill regeneration ends and the last counted Shroudfield
-- restore and Chastise dash.
local Pulses = {
    enabled = false,
    pending_excess = 0,
    unit = nil,
    buff_extension = nil,
    toughness_extension = nil,
    unit_data_extension = nil,
    disabled_component = nil,
    has_heavy_kill_talent = false,
    has_elite_kill_talent = false,
    elite_regen_until = 0,
    last_stealth_t = NEVER,
    last_lunge_t = NEVER
}

-- ----------------------------------------------------------------------------
-- Context and queues
-- ----------------------------------------------------------------------------

--- Returns whether the build has the talent that grants a buff template.
-- ?tab: talent_extension local player's talent extension
-- string: buff_template_name buff template the talent grants
-- treturn: bool
local function _has_talent_buff(talent_extension, buff_template_name)
    if not talent_extension or not talent_extension.buff_template_tier then
        return false
    end

    local tier = talent_extension:buff_template_tier(buff_template_name)

    return tier ~= nil and tier ~= 0
end

--- Enables the module for the local player's unit and caches its extensions and talent flags.
-- The HUD element calls it again every second while supported, so the timers only restart when
-- the module was disabled or the unit changed.
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

    Pulses.unit_data_extension = unit_data_extension
    Pulses.disabled_component = unit_data_extension and unit_data_extension.read_component and unit_data_extension:read_component("disabled_character_state")
    Pulses.has_heavy_kill_talent = _has_talent_buff(talent_extension, Sources.heavy_kill_talent_buff_name)
    Pulses.has_elite_kill_talent = _has_talent_buff(talent_extension, Sources.elite_kill_talent_buff_name)

    if not same_unit then
        Pulses.elite_regen_until = 0
        Pulses.last_stealth_t = NEVER
        Pulses.last_lunge_t = NEVER
    end
end

--- Disables the module and clears the queue, every cached reference, talent flag and timer.
Pulses.disable = function()
    Pulses.enabled = false
    Pulses.pending_excess = 0
    Pulses.unit = nil
    Pulses.buff_extension = nil
    Pulses.toughness_extension = nil
    Pulses.unit_data_extension = nil
    Pulses.disabled_component = nil
    Pulses.has_heavy_kill_talent = false
    Pulses.has_elite_kill_talent = false
    Pulses.elite_regen_until = 0
    Pulses.last_stealth_t = NEVER
    Pulses.last_lunge_t = NEVER
end

--- Returns and clears the clamped excess of the restores since the last sample.
-- treturn: number Toughness points
Pulses.consume = function()
    local pending_excess = Pulses.pending_excess

    Pulses.pending_excess = 0

    return pending_excess
end

--- The Zealot shares nothing with allies, so there is never a share burst.
-- treturn: number always 0
Pulses.consume_burst = function()
    return 0
end

--- The Zealot has no burst restore of its own; Chastise counts as an ordinary restore.
-- treturn: number always 0
Pulses.consume_burst_overflow = function()
    return 0
end

-- ----------------------------------------------------------------------------
-- Pulse recording
-- ----------------------------------------------------------------------------

--- Adds the part of a wanted restore that exceeds the missing Toughness to the excess queue.
-- ?number: wanted wanted restore in Toughness points; ignored unless positive
local function _accumulate_wanted(wanted)
    if not wanted or wanted <= 0 then
        return
    end

    local toughness_extension = Pulses.toughness_extension

    if not toughness_extension then
        return
    end

    local headroom = toughness_extension:toughness_damage()
    local excess = wanted - headroom

    if excess > 0 then
        Pulses.pending_excess = Pulses.pending_excess + excess
    end
end

--- Records a restore given as a fraction of maximum Toughness.
-- ?number: fraction restore fraction; ignored unless positive
-- ?bool: apply_replenish_stat_buffs scale by `toughness_replenish_modifier` and
-- `toughness_replenish_multiplier`, as the game does for restores that use stat buffs
local function _add_pulse(fraction, apply_replenish_stat_buffs)
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

    _accumulate_wanted(wanted)
end

--- Records the base melee-kill restore, scaled the way the game's toughness template does.
-- The melee replenish bonus (the Zealot base talent's +75 %) adds to the replenish modifier, and
-- the replenish multiplier applies on top.
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
        _accumulate_wanted(fraction * toughness_extension:max_toughness())
    end
end

-- ----------------------------------------------------------------------------
-- Continuous source model
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

--- Returns whether the client is re-simulating the Zealot's last frames after a misprediction.
-- treturn: bool
local function _is_resimulating()
    local unit_data_extension = Pulses.unit_data_extension

    return unit_data_extension and unit_data_extension.is_resimulating or false
end

--- Returns whether the Zealot is disabled (for example netted or pounced), which pauses the
-- modelled regeneration as it does in game.
-- treturn: bool
local function _is_disabled()
    local component = Pulses.disabled_component

    return component and component.is_disabled or false
end

--- Returns the rate of the continuous sources currently modelled as running.
-- Only the elite-kill regeneration is modelled: it runs for its duration after an Elite kill and
-- is refreshed by the next one. The HUD element uses it only at full Toughness, where the bar
-- cannot show it.
-- treturn: number fraction of maximum Toughness per second, before stat buffs
Pulses.active_continuous_fraction = function()
    if not Pulses.enabled or not Pulses.has_elite_kill_talent or _is_disabled() then
        return 0
    end

    if _now() < Pulses.elite_regen_until then
        return Sources.elite_kill_regen_rate
    end

    return 0
end

-- ----------------------------------------------------------------------------
-- Events
-- ----------------------------------------------------------------------------

--- Records a weapon blessing or Zealot talent proc of the local player.
-- A blessing restores the fixed percentage from its tier's override data, or else the template,
-- multiplied by the fire step (at most 5) for continuous fire, and ignores Toughness stat buffs.
-- A talent proc restores its template's `toughness_percentage`, scaled by the stat buffs.
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

    if Sources.talent_toughness_proc_templates[template_name] then
        local template = buff_instance.template and buff_instance:template()

        _add_pulse(template and template.toughness_percentage, true)

        return
    end

    if not Sources.weapon_toughness_proc_templates[template_name] then
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

    _add_pulse(fixed_percentage, false)
end

--- Records what one of the Zealot's own kills restores.
-- Melee kills add the base melee restore, heavy-attack kills the heavy-kill talent's restore, and
-- Elite kills open the elite-kill regeneration window. The arguments are those of
-- `AttackReportManager.add_attack_result`.
-- ?tab: damage_profile damage profile of the attack
-- param: attacked_unit unit that was hit
-- param: attacking_unit unit that attacked; only the local player's kills count
-- string: attack_result `died` for a kill
-- string: attack_type such as `melee` or `ranged`
Pulses.on_attack_result = function(damage_profile, attacked_unit, attacking_unit, attack_direction, hit_world_position, hit_weakspot, damage, attack_result, attack_type, damage_efficiency, is_critical_strike)
    if not Pulses.enabled or attacking_unit ~= Pulses.unit or attack_result ~= ATTACK_RESULT_DIED then
        return
    end

    if attack_type == ATTACK_TYPE_MELEE then
        _add_melee_kill_pulse()
    end

    if Pulses.has_heavy_kill_talent and damage_profile and damage_profile.melee_attack_strength == MELEE_ATTACK_STRENGTH_HEAVY then
        _add_pulse(Sources.heavy_kill_fraction, true)
    end

    if Pulses.has_elite_kill_talent and attacked_unit then
        local unit_data_extension = ScriptUnit.has_extension(attacked_unit, "unit_data_system")
        local breed = unit_data_extension and unit_data_extension.breed and unit_data_extension:breed()
        local tags = breed and breed.tags

        if tags and tags.elite then
            Pulses.elite_regen_until = _now() + Sources.elite_kill_regen_duration
        end
    end
end

--- Records a replenish the game asked for on the local player's unit.
-- Only the whitelisted Zealot reasons count, and none while the unit re-simulates. Shroudfield's
-- restore runs in a predicted buff, so a second one shortly after the first is a server
-- correction re-adding the buff and is ignored.
-- param: unit unit being replenished
-- ?number: fixed_percentage restore as a fraction of maximum Toughness
-- ?bool: ignore_stat_buffs true when the restore ignores Toughness stat buffs
-- ?string: reason replenish reason
Pulses.on_replenish_percentage = function(unit, fixed_percentage, ignore_stat_buffs, reason)
    if not Pulses.enabled or unit ~= Pulses.unit or type(fixed_percentage) ~= "number" or not reason or not Sources.replenish_capture_reasons[reason] or _is_resimulating() then
        return
    end

    if reason == Sources.stealth_capture_reason then
        local now = _now()

        if now < Pulses.last_stealth_t + Sources.stealth_dedupe_window then
            return
        end

        Pulses.last_stealth_t = now
    end

    _add_pulse(fixed_percentage, not ignore_stat_buffs)
end

-- ----------------------------------------------------------------------------
-- Hooks
-- ----------------------------------------------------------------------------

-- A lunge started. Chastise the Wicked's dash restores its lunge template's
-- `restore_toughness` (50 %, without stat buffs) on the server only, so it is recorded here from
-- the client's own lunging state. A start while the unit re-simulates, or within a short window of
-- the last one, is a re-run of the same dash. The hook names the class, so DMF applies it once the
-- class exists.
mod:hook_safe("PlayerCharacterStateLunging", "on_enter", function(self, unit, dt, t, previous_state, params)
    if not Pulses.enabled or unit ~= Pulses.unit or _is_resimulating() then
        return
    end

    local component = self._lunge_character_state_component
    local template_name = component and component.lunge_template
    local lunge_template = template_name and LungeTemplates[template_name]
    local restore_toughness = lunge_template and lunge_template.restore_toughness

    if not restore_toughness then
        return
    end

    local now = type(t) == "number" and t or _now()

    if now < Pulses.last_lunge_t + Sources.lunge_dedupe_window then
        return
    end

    Pulses.last_lunge_t = now

    _add_pulse(restore_toughness, false)
end)

return Pulses
