--- TEMPORARY: compares the mission statistics with the game's own Toughness accounting in solo play.
-- When this machine runs the game session (solo play, the Psykhanium, hosting), every Toughness
-- restore of the local player passes through `PlayerUnitToughnessExtension._handle_procs(amount,
-- recovered_amount, reason)` with the exact amount it asked for and the amount that restored the
-- bar. This module sums both per reason and logs them next to the mod's own totals: one line a
-- minute, and a per-reason breakdown plus a chat line when the mission ends. On a client the local
-- player has no such extension, so the hook never fires there.
--
-- The game's totals use the mod's definitions: Replenished is everything that restored the bar,
-- Overflowed is what was asked for but clamped, without the support teammates give you
-- (`ALLY_REASONS`), and Generated is their sum.
--
-- The pulse modules label what they count with the game's replenish reason (`record_mod`), so the
-- breakdown sets each source's requested and overflowed amounts against the game's. Sources the
-- game restores without a reason (`<nil>`) are labelled by the mod and summed onto `<nil>`
-- (`MOD_TAG_REASONS`), as are labels the mod splits off a reason. Only the Zealot and Psyker
-- modules label their sources so far.
--
-- It also records, for every restore the server applied before the mod saw it (kills, procs, the
-- lunge), whether the replicated bar already showed it, and the overflow the old headroom read
-- (the current bar) and the new one (`record_headroom`) gave. That part works on a client too, so
-- multiplayer missions show how often the bar is ahead of the event.
--
-- On a client several such restores can arrive before the bar shows the first one (a sweep that
-- kills three), and each then finds the same missing Toughness. A restore is `stacked` when the
-- bar has not moved since an earlier restore it did not show yet; `alt` is the overflow with
-- what those earlier restores took up subtracted from the bar. Only measured, not counted.
--
-- Loaded by `OverflowMeter.lua` while `DEBUG_TRUTH` is on and stored as `mod._debug_truth`.
-- Remove before release, together with its load line, its three calls there, the `record_mod`
-- calls in `OverflowMeter_pulses_zealot.lua`, `OverflowMeter_pulses_psyker.lua` and the HUD
-- element, and the warp profile line in `OverflowMeter_sources_psyker.lua`.
-- module: OverflowMeter_debug_truth
-- alias: Truth
-- author: LucLeto
local mod = get_mod("OverflowMeter")
local Stats = mod._stats

local Managers = Managers
local math_abs = math.abs
local math_floor = math.floor
local next = next
local pairs = pairs
local string_format = string.format
local table_sort = table.sort
local type = type

--- Seconds between the running total lines.
local INTERVAL = 60

--- Replenish reasons of support teammates give you, kept out of Overflowed like the mod does.
local ALLY_REASONS = {
    shared = true,
    adamant_buff_drone = true,
    psyker_sphere = true,
    pinning_dog_kills_buff_allies = true
}

--- Mod labels for sources the game restores without a reason, or under a reason it shares with
-- another source, and the game reason they sum onto. `continuous_model` is the modelled at-full
-- regeneration: the Zealot's elite-kill window, the Psyker's Disrupt Destiny. `psyker_melee_hit`
-- is Warp Expenditure's per-hit restore, which shares its reason with the talent's regeneration.
local MOD_TAG_REASONS = {
    blessing = "<nil>",
    continuous_model = "<nil>",
    psyker_melee_hit = "psyker_melee_toughness"
}

local Truth = {}

--- The game's sums per reason (`calls`, `wanted`, `recovered`), the mod's per label (`events`,
-- `wanted`, `overflowed`), the time to the next total line, and whether this mission was reported
-- already.
local reasons = {}
local mod_sources = {}
local headroom = {}
local timer = 0
local reported = false

--- Missing Toughness at the last restore the server applied before the mod saw it, and what the
-- restores since the bar last moved took up without the bar showing it yet.
local last_damage = nil
local unshown = 0

--- Below this many Toughness points the bar counts as full, and a change as none.
local EPSILON = 0.5

--- Returns the local player's unit, if any.
-- treturn: ?param unit
local function _local_unit()
    local player_manager = Managers.player
    local player = player_manager and player_manager.local_player_safe and player_manager:local_player_safe(1)

    return player and player.player_unit
end

-- The game restored, or tried to restore, Toughness on a player unit; sums the local player's.
mod:hook_safe("PlayerUnitToughnessExtension", "_handle_procs", function (self, amount, recovered_amount, reason)
    if type(amount) ~= "number" or amount <= 0 or self._unit ~= _local_unit() then
        return
    end

    local key = reason or "<nil>"
    local entry = reasons[key]

    if not entry then
        entry = {
            calls = 0,
            wanted = 0,
            recovered = 0
        }
        reasons[key] = entry
    end

    entry.calls = entry.calls + 1
    entry.wanted = entry.wanted + amount
    entry.recovered = entry.recovered + (type(recovered_amount) == "number" and recovered_amount or 0)
end)

--- Returns the game's totals in the mod's definitions.
-- treturn: number generated
-- treturn: number replenished
-- treturn: number overflowed, without ally support
-- treturn: number ally support that overflowed
local function _totals()
    local replenished = 0
    local overflowed = 0
    local ally_overflowed = 0

    for key, entry in pairs(reasons) do
        local excess = entry.wanted - entry.recovered

        replenished = replenished + entry.recovered

        if excess > 0 then
            if ALLY_REASONS[key] then
                ally_overflowed = ally_overflowed + excess
            else
                overflowed = overflowed + excess
            end
        end
    end

    return replenished + overflowed, replenished, overflowed, ally_overflowed
end

--- Returns the game's and the mod's totals as one log line.
-- string: label line label
-- treturn: string
local function _totals_line(label)
    local generated, replenished, overflowed, ally_overflowed = _totals()

    return string_format(
        "[OFM] truth %s: game generated=%.0f replenished=%.0f overflowed=%.0f (ally support overflowed=%.0f) | mod generated=%.0f replenished=%.0f overflowed=%.0f",
        label,
        generated,
        replenished,
        overflowed,
        ally_overflowed,
        Stats.generated,
        Stats.replenished,
        Stats.overflowed
    )
end

--- Adds one restore the mod counted.
-- ?string: source label of the source, the game's replenish reason where there is one
-- number: wanted wanted restore in Toughness points
-- number: overflowed part of it counted as overflowed
Truth.record_mod = function (source, wanted, overflowed)
    local key = source or "<untagged>"
    local entry = mod_sources[key]

    if not entry then
        entry = {
            events = 0,
            wanted = 0,
            overflowed = 0
        }
        mod_sources[key] = entry
    end

    entry.events = entry.events + 1
    entry.wanted = entry.wanted + wanted
    entry.overflowed = entry.overflowed + overflowed
end

--- Adds how the bar looked when a restore the server already applied reached the mod.
-- `full` when the bar was full at the last sample and still is, `refilled` when it already rose
-- by at least half of what the restore could fill, `pending` otherwise. `stacked` and the `alt`
-- overflow measure restores that arrive before the bar shows an earlier one: the bar has not moved
-- since that restore, is not full and was not ahead of the last sample for either.
-- ?string: source label of the source
-- number: wanted wanted restore in Toughness points
-- number: damage missing Toughness when the restore arrived
-- number: sample_damage missing Toughness at the last sample
-- number: old_excess wanted minus the current missing Toughness (the old headroom read)
-- number: new_excess the excess counted now
Truth.record_headroom = function (source, wanted, damage, sample_damage, old_excess, new_excess)
    local key = source or "<untagged>"
    local entry = headroom[key]

    if not entry then
        entry = {
            events = 0,
            full = 0,
            refilled = 0,
            pending = 0,
            stacked = 0,
            old_overflowed = 0,
            new_overflowed = 0,
            alt_overflowed = 0
        }
        headroom[key] = entry
    end

    local fillable = wanted < sample_damage and wanted or sample_damage

    if sample_damage < EPSILON and damage < EPSILON then
        entry.full = entry.full + 1
    elseif fillable >= EPSILON and sample_damage - damage >= 0.5 * fillable then
        entry.refilled = entry.refilled + 1
    else
        entry.pending = entry.pending + 1
    end

    -- The new read is below the old one only when the bar is ahead of the last sample, so it
    -- already shows this restore and the earlier ones.
    local ahead = new_excess < old_excess

    if not last_damage or math_abs(damage - last_damage) >= EPSILON then
        unshown = 0
    end

    local alt_excess = new_excess

    if not ahead and unshown > 0 and damage >= EPSILON then
        local alt_headroom = damage - unshown

        alt_excess = wanted - (alt_headroom > 0 and alt_headroom or 0)
        entry.stacked = entry.stacked + 1
    end

    if ahead then
        unshown = 0
    else
        unshown = unshown + wanted - (alt_excess > 0 and alt_excess or 0)
    end

    last_damage = damage

    entry.events = entry.events + 1
    entry.old_overflowed = entry.old_overflowed + (old_excess > 0 and old_excess or 0)
    entry.new_overflowed = entry.new_overflowed + (new_excess > 0 and new_excess or 0)
    entry.alt_overflowed = entry.alt_overflowed + (alt_excess > 0 and alt_excess or 0)
end

--- Returns the mod's sums for a game reason, over every label that maps onto it.
-- string: reason game reason
-- treturn: ?number events, nil when no label maps onto the reason
-- treturn: number wanted
-- treturn: number overflowed
local function _mod_for_reason(reason)
    local events, wanted, overflowed = nil, 0, 0

    for key, entry in pairs(mod_sources) do
        if (MOD_TAG_REASONS[key] or key) == reason then
            events = (events or 0) + entry.events
            wanted = wanted + entry.wanted
            overflowed = overflowed + entry.overflowed
        end
    end

    return events, wanted, overflowed
end

--- Forgets every sum, when a mission starts.
Truth.reset = function ()
    for key in pairs(reasons) do
        reasons[key] = nil
    end

    for key in pairs(mod_sources) do
        mod_sources[key] = nil
    end

    for key in pairs(headroom) do
        headroom[key] = nil
    end

    timer = 0
    reported = false
    last_damage = nil
    unshown = 0
end

--- Logs the running totals once a minute while anything was recorded.
-- number: dt frame delta time
Truth.update = function (dt)
    if next(reasons) == nil then
        return
    end

    timer = timer + dt

    if timer < INTERVAL then
        return
    end

    timer = 0

    mod:info("%s", _totals_line("running"))
end

--- Logs the bar state per source for the restores the server applied before the mod saw them,
-- and their sum.
local function _report_headroom()
    local events, stacked, old_overflowed, new_overflowed, alt_overflowed = 0, 0, 0, 0, 0

    for key, entry in pairs(headroom) do
        mod:info("[OFM] headroom source=%s events=%d full=%d refilled=%d pending=%d stacked=%d overflowed old=%.1f new=%.1f alt=%.1f", key, entry.events, entry.full, entry.refilled, entry.pending, entry.stacked, entry.old_overflowed, entry.new_overflowed, entry.alt_overflowed)

        events = events + entry.events
        stacked = stacked + entry.stacked
        old_overflowed = old_overflowed + entry.old_overflowed
        new_overflowed = new_overflowed + entry.new_overflowed
        alt_overflowed = alt_overflowed + entry.alt_overflowed
    end

    mod:info("[OFM] headroom all events=%d stacked=%d overflowed old=%.1f new=%.1f alt=%.1f", events, stacked, old_overflowed, new_overflowed, alt_overflowed)
end

--- Logs the bar states, and when hosting the per-reason breakdown and the totals with a comparison
-- line in the local chat; once per mission and only if anything was recorded.
Truth.report = function ()
    local has_game = next(reasons) ~= nil

    if reported or (not has_game and next(headroom) == nil) then
        return
    end

    reported = true

    _report_headroom()

    if not has_game then
        return
    end

    local keys = {}

    for key in pairs(reasons) do
        keys[#keys + 1] = key
    end

    table_sort(keys, function (a, b)
        return reasons[a].wanted > reasons[b].wanted
    end)

    for i = 1, #keys do
        local key = keys[i]
        local entry = reasons[key]
        local mod_events, mod_wanted, mod_overflowed = _mod_for_reason(key)
        local mod_part = mod_events and string_format("mod events=%d wanted=%.1f overflowed=%.1f", mod_events, mod_wanted, mod_overflowed) or "mod -"

        mod:info("[OFM] truth reason=%s calls=%d wanted=%.1f recovered=%.1f overflowed=%.1f%s | %s", key, entry.calls, entry.wanted, entry.recovered, entry.wanted - entry.recovered, ALLY_REASONS[key] and " (ally)" or "", mod_part)
    end

    local tagged_overflowed = 0

    for key, entry in pairs(mod_sources) do
        local reason = MOD_TAG_REASONS[key]

        tagged_overflowed = tagged_overflowed + entry.overflowed

        if reason then
            mod:info("[OFM] truth   %s part: mod source=%s events=%d wanted=%.1f overflowed=%.1f", reason, key, entry.events, entry.wanted, entry.overflowed)
        elseif not reasons[key] then
            mod:info("[OFM] truth mod-only source=%s events=%d wanted=%.1f overflowed=%.1f", key, entry.events, entry.wanted, entry.overflowed)
        end
    end

    mod:info("[OFM] truth mod overflowed by label=%.1f, unlabelled=%.1f", tagged_overflowed, Stats.overflowed - tagged_overflowed)
    mod:info("%s", _totals_line("mission"))

    local generated, replenished, overflowed = _totals()

    mod:echo("%s", string_format(
        "Overflow Meter check (solo)  |  game: Generated %d  Replenished %d  Overflowed %d  |  mod: Generated ~%d  Replenished %d  Overflowed ~%d",
        math_floor(generated + 0.5),
        math_floor(replenished + 0.5),
        math_floor(overflowed + 0.5),
        math_floor(Stats.generated + 0.5),
        math_floor(Stats.replenished + 0.5),
        math_floor(Stats.overflowed + 0.5)
    ))
end

return Truth
