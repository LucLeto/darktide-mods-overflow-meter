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
-- (`MOD_TAG_REASONS`). Only the Zealot module labels its sources so far.
--
-- Loaded by `OverflowMeter.lua` while `DEBUG_TRUTH` is on and stored as `mod._debug_truth`.
-- Remove before release, together with its load line, its three calls there and the `record_mod`
-- calls in `OverflowMeter_pulses_zealot.lua` and the HUD element.
-- module: OverflowMeter_debug_truth
-- alias: Truth
-- author: LucLeto
local mod = get_mod("OverflowMeter")
local Stats = mod._stats

local Managers = Managers
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

--- Mod labels for sources the game restores without a reason, and the game reason they sum onto.
-- `continuous_model` is the modelled at-full regeneration, for the Zealot the elite-kill window.
local MOD_TAG_REASONS = {
    blessing = "<nil>",
    continuous_model = "<nil>"
}

local Truth = {}

--- The game's sums per reason (`calls`, `wanted`, `recovered`), the mod's per label (`events`,
-- `wanted`, `overflowed`), the time to the next total line, and whether this mission was reported
-- already.
local reasons = {}
local mod_sources = {}
local timer = 0
local reported = false

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

    timer = 0
    reported = false
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

--- Logs the per-reason breakdown and the totals, and writes a comparison line to the local chat,
-- once per mission and only if anything was recorded.
Truth.report = function ()
    if reported or next(reasons) == nil then
        return
    end

    reported = true

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
