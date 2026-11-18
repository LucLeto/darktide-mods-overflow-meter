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
-- (`MOD_TAG_REASONS`), as are labels the mod splits off a reason. Every tracked archetype's
-- modules label their sources. Most Skitarii talents restore under the one reason
-- `cryptic_talent`, and Veteran talents share `talent_toughness_1` and `talent_toughness_3`, so the
-- game's side splits those reasons by the buff template that restored, found on the call stack
-- (`SPLIT_REASONS`).
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
-- Three diagnostics follow the at-full gaps. Per reason, the game's calls are counted as full
-- (nothing restored) or partial (clamped in part), with the time each kind covered: the gap to
-- the reason's previous call, when that was at most `MAX_TICK_GAP` ago. The breakdown sets that
-- time next to the mod's samples for the label (each covers `SAMPLE_INTERVAL`), which compares
-- the time at full of the continuous sources. The HUD element reports every sample's missing
-- Toughness (`record_sample`), bucketed by how far below full the bar was, overall and while a
-- modelled continuous source ran. And a restore larger than `OUTLIER_FACTOR` times maximum
-- Toughness is logged at once with its callers, to find where such restores come from.
--
-- Loaded by `OverflowMeter.lua` while `DEBUG_TRUTH` is on and stored as `mod._debug_truth`.
-- Remove before release, together with its load line, its three calls there, the `record_sample`
-- calls in the HUD element, the `record_mod` calls in `OverflowMeter_pulses_zealot.lua`, `OverflowMeter_pulses_psyker.lua`,
-- `OverflowMeter_pulses.lua`, `OverflowMeter_pulses_veteran.lua` and the HUD element, the source
-- labels passed in `OverflowMeter_pulses.lua` and `OverflowMeter_pulses_veteran.lua` (with the
-- latter's `continuous_parts`), and the warp profile line in `OverflowMeter_sources_psyker.lua`.
-- module: OverflowMeter_debug_truth
-- alias: Truth
-- author: LucLeto
local mod = get_mod("OverflowMeter")
local Stats = mod._stats

local Managers = Managers
local debug_getinfo = debug and debug.getinfo
local debug_getlocal = debug and debug.getlocal
local math_abs = math.abs
local math_floor = math.floor
local next = next
local pairs = pairs
local string_find = string.find
local string_format = string.format
local table_concat = table.concat
local table_sort = table.sort
local tostring = tostring
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
-- The two residual labels are Quietude's Peril changes no report covered. `psyker_sphere` is the
-- Psyker's own dome, which the game's side keeps apart from a teammate's (`OWN_DOME_REASON`).
local MOD_TAG_REASONS = {
    blessing = "<nil>",
    continuous_model = "<nil>",
    psyker_melee_hit = "psyker_melee_toughness",
    warp_generation_residual = "toughness_on_warp_generation",
    vent_residual = "toughness_on_vent",
    psyker_sphere = "psyker_sphere_own",
    discharge_use = "ability_shout",
    discharge_hit = "ability_shout"
}

--- Reasons the game shares between several talents of a class, split by the buff template that
-- restored: the key becomes `reason:template`. Per archetype, because other classes reuse the
-- names (`talent_toughness_3` is also the Zealot's in-melee regeneration).
local SPLIT_REASONS = {
    cryptic = {
        cryptic_talent = true
    },
    veteran = {
        talent_toughness_1 = true,
        talent_toughness_3 = true
    }
}

--- Buff templates the mod models together, summed under one key: the Skitarii adapter that
-- covers every temporary regeneration talent.
local TEMPLATE_GROUPS = {
    cryptic_multi_hits_restore_toughness = "temporary_regeneration",
    cryptic_crits_grant_tdr = "temporary_regeneration",
    cryptic_elite_kills_toughness = "temporary_regeneration",
    cryptic_electrocution_toughness = "temporary_regeneration",
    cryptic_toughness_on_damage_taken = "temporary_regeneration",
    cryptic_redline_toughness = "temporary_regeneration"
}

--- The Skitarii HUD adapters' labels, matching the game's keys above.
local ADAPTER_LABELS = {
    precision_stance = "ability_stance",
    toughness_per_charge = "cryptic_talent:cryptic_toughness_per_charge",
    ranged_kill_regeneration = "cryptic_talent:cryptic_ranged_stacking_toughness_stack",
    temporary_regeneration = "cryptic_talent:temporary_regeneration"
}

--- How far up the call stack the restoring buff function is searched for.
local MAX_STACK_DEPTH = 16

--- Longest gap between two calls of one reason that still counts as one running source, in
-- seconds; longer gaps are a new start and cover no time.
local MAX_TICK_GAP = 1.1
--- The HUD element's sample interval, the time each of the mod's at-full samples covers.
local SAMPLE_INTERVAL = 0.25
--- A restore asking for more than this many times maximum Toughness is logged as an outlier.
local OUTLIER_FACTOR = 1.5
--- At most this many outliers are logged per mission; the rest are only counted.
local MAX_OUTLIER_LOGS = 20
--- Caller frames logged per outlier, from the hooked function's caller on.
local OUTLIER_STACK_FIRST = 3
local OUTLIER_STACK_LAST = 14
--- Upper bounds of the sample buckets, as fractions of maximum Toughness missing: full (as the
-- HUD element counts it), below 1 %, below 5 %; anything more is `lower`.
local BUCKET_FULL = 0.001
local BUCKET_1 = 0.01
local BUCKET_5 = 0.05

--- The Telekine Dome's reason, the buff it gives everyone inside, and the key the game's restores
-- inside the local Psyker's own dome are summed under (not ally support).
local DOME_REASON = "psyker_sphere"
local DOME_BUFF_NAME = "psyker_boost_allies_in_sphere_buff"
local OWN_DOME_REASON = "psyker_sphere_own"

local Truth = {}

--- The game's sums per reason (`calls`, `wanted`, `recovered`), the mod's per label (`events`,
-- `wanted`, `overflowed`), the time to the next total line, and whether this mission was reported
-- already.
local reasons = {}
local mod_sources = {}
local headroom = {}
local timer = 0
local reported = false

--- Restores above the outlier size this mission.
local outliers = 0

--- Sample buckets (`full`, `below_1`, `below_5`, `lower`) over every sample, and over the
-- samples while a modelled continuous source ran.
local samples_all = {
    count = 0,
    full = 0,
    below_1 = 0,
    below_5 = 0,
    lower = 0
}
local samples_continuous = {
    count = 0,
    full = 0,
    below_1 = 0,
    below_5 = 0,
    lower = 0
}
local SAMPLE_BUCKETS = {
    samples_all,
    samples_continuous
}
local SAMPLE_BUCKET_LABELS = {
    "all",
    "continuous"
}

--- Missing Toughness at the last restore the server applied before the mod saw it, and what the
-- restores since the bar last moved took up without the bar showing it yet.
local last_damage = nil
local unshown = 0

--- Below this many Toughness points the bar counts as full, and a change as none.
local EPSILON = 0.5
--- Below this many Toughness points a call restored nothing. Power Overflow asks for exactly 0,
-- and per-frame ticks restore far less than `EPSILON`, so this has to be tiny.
local NOTHING_RESTORED = 1e-4

--- Returns the local player, if any.
-- treturn: ?tab player
local function _local_player()
    local player_manager = Managers.player

    return player_manager and player_manager.local_player_safe and player_manager:local_player_safe(1)
end

--- Returns the local player's unit, if any.
-- treturn: ?param unit
local function _local_unit()
    local player = _local_player()

    return player and player.player_unit
end

--- Returns the reasons to split for the local player's archetype, if any.
-- treturn: ?tab set of reasons
local function _split_reasons()
    local player = _local_player()
    local archetype = player and player.archetype_name and player:archetype_name()

    return archetype and SPLIT_REASONS[archetype]
end

--- Returns the name of the buff template whose function asked for the restore, from the call
-- stack: the nearest buff file frame with a `template_context` among its first parameters.
-- treturn: ?string template name, nil when no buff restored or the debug library is missing
local function _restoring_template()
    if not debug_getinfo or not debug_getlocal then
        return nil
    end

    for level = 3, MAX_STACK_DEPTH do
        local info = debug_getinfo(level, "S")

        if not info then
            return nil
        end

        local source = info.source

        if type(source) == "string" and string_find(source, "buff", 1, true) then
            for index = 1, 4 do
                local name, value = debug_getlocal(level, index)

                if not name then
                    break
                end

                if name == "template_context" and type(value) == "table" then
                    local template = value.template

                    return type(template) == "table" and template.name or nil
                end
            end
        end
    end

    return nil
end

--- Returns the current gameplay time, or nil before the gameplay timer exists.
-- treturn: ?number
local function _now()
    local time_manager = Managers.time

    if time_manager and time_manager.has_timer and time_manager:has_timer("gameplay") then
        return time_manager:time("gameplay")
    end

    return nil
end

--- Returns the callers of the hooked function as `file:line` frames.
-- treturn: string
local function _caller_frames()
    if not debug_getinfo then
        return "?"
    end

    local frames = {}

    for level = OUTLIER_STACK_FIRST, OUTLIER_STACK_LAST do
        local info = debug_getinfo(level, "Sl")

        if not info then
            break
        end

        frames[#frames + 1] = string_format("%s:%s", tostring(info.short_src), tostring(info.currentline))
    end

    return table_concat(frames, " < ")
end

--- Logs a restore larger than the outlier size, with its callers, up to the per-mission limit.
-- tab: toughness_extension the local player's toughness extension
-- number: amount wanted restore
-- ?number: recovered_amount what restored the bar
-- ?string: reason replenish reason
local function _check_outlier(toughness_extension, amount, recovered_amount, reason)
    local max_toughness = toughness_extension.max_toughness and toughness_extension:max_toughness()

    if type(max_toughness) ~= "number" or max_toughness <= 0 or amount <= OUTLIER_FACTOR * max_toughness then
        return
    end

    outliers = outliers + 1

    if outliers <= MAX_OUTLIER_LOGS then
        mod:info("[OFM] truth outlier #%d reason=%s amount=%.1f recovered=%.1f max=%.1f (x%.1f) callers: %s", outliers, tostring(reason), amount, type(recovered_amount) == "number" and recovered_amount or 0, max_toughness, amount / max_toughness, _caller_frames())
    end
end

-- The game restored, or tried to restore, Toughness on a player unit; sums the local player's.
mod:hook_safe("PlayerUnitToughnessExtension", "_handle_procs", function (self, amount, recovered_amount, reason)
    if type(amount) ~= "number" or amount <= 0 or self._unit ~= _local_unit() then
        return
    end

    _check_outlier(self, amount, recovered_amount, reason)

    local key = reason or "<nil>"
    local split_reasons = reason and _split_reasons()

    if split_reasons and split_reasons[reason] then
        local template_name = _restoring_template()

        key = reason .. ":" .. (template_name and (TEMPLATE_GROUPS[template_name] or template_name) or "?")
    elseif reason == DOME_REASON then
        local buff_extension = self._buff_extension

        if buff_extension and buff_extension.has_buff_using_buff_template_with_owner and buff_extension:has_buff_using_buff_template_with_owner(DOME_BUFF_NAME, self._unit) then
            key = OWN_DOME_REASON
        end
    end

    local entry = reasons[key]

    if not entry then
        entry = {
            calls = 0,
            wanted = 0,
            recovered = 0,
            full_calls = 0,
            partial_calls = 0,
            full_time = 0,
            partial_time = 0,
            active_time = 0,
            last_t = nil
        }
        reasons[key] = entry
    end

    local recovered = type(recovered_amount) == "number" and recovered_amount or 0

    entry.calls = entry.calls + 1
    entry.wanted = entry.wanted + amount
    entry.recovered = entry.recovered + recovered

    -- Time the reason covered since its previous call, split by how this call was clamped.
    local now = _now()
    local last_t = entry.last_t
    local gap = now and last_t and now - last_t
    local covered = gap and gap >= 0 and gap <= MAX_TICK_GAP and gap or 0

    entry.last_t = now
    entry.active_time = entry.active_time + covered

    if recovered < NOTHING_RESTORED then
        entry.full_calls = entry.full_calls + 1
        entry.full_time = entry.full_time + covered
    elseif recovered < amount - NOTHING_RESTORED then
        entry.partial_calls = entry.partial_calls + 1
        entry.partial_time = entry.partial_time + covered
    end
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

--- Returns the comparison label of a Skitarii HUD adapter, matching the game's split keys.
-- string: name adapter name
-- treturn: string
Truth.adapter_label = function (name)
    return ADAPTER_LABELS[name] or name
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

--- Adds one sample's bar state to its bucket, overall and while a continuous source ran.
-- number: damage missing Toughness at the sample
-- number: max_toughness maximum Toughness
-- ?bool: continuous_active whether a modelled continuous source ran
Truth.record_sample = function (damage, max_toughness, continuous_active)
    if type(damage) ~= "number" or type(max_toughness) ~= "number" or max_toughness <= 0 then
        return
    end

    local fraction = damage / max_toughness
    local bucket

    if fraction <= BUCKET_FULL then
        bucket = "full"
    elseif fraction < BUCKET_1 then
        bucket = "below_1"
    elseif fraction < BUCKET_5 then
        bucket = "below_5"
    else
        bucket = "lower"
    end

    samples_all.count = samples_all.count + 1
    samples_all[bucket] = samples_all[bucket] + 1

    if continuous_active then
        samples_continuous.count = samples_continuous.count + 1
        samples_continuous[bucket] = samples_continuous[bucket] + 1
    end
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
    outliers = 0

    for key in pairs(samples_all) do
        samples_all[key] = 0
        samples_continuous[key] = 0
    end
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

--- Logs the sample buckets, each with its share of the samples.
local function _report_samples()
    for i = 1, 2 do
        local bucket = SAMPLE_BUCKETS[i]
        local count = bucket.count

        if count > 0 then
            mod:info("[OFM] samples %s count=%d (%.1fs) full=%d (%.1f%%) below1%%=%d (%.1f%%) below5%%=%d (%.1f%%) lower=%d (%.1f%%)", SAMPLE_BUCKET_LABELS[i], count, count * SAMPLE_INTERVAL, bucket.full, 100 * bucket.full / count, bucket.below_1, 100 * bucket.below_1 / count, bucket.below_5, 100 * bucket.below_5 / count, bucket.lower, 100 * bucket.lower / count)
        end
    end
end

--- Logs the bar states, and when hosting the per-reason breakdown and the totals with a comparison
-- line in the local chat; once per mission and only if anything was recorded.
Truth.report = function ()
    local has_game = next(reasons) ~= nil

    if reported or (not has_game and next(headroom) == nil and samples_all.count == 0) then
        return
    end

    reported = true

    _report_headroom()
    _report_samples()

    if outliers > 0 then
        mod:info("[OFM] truth outliers=%d (above %.1fx maximum Toughness; first %d logged)", outliers, OUTLIER_FACTOR, MAX_OUTLIER_LOGS)
    end

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

        if entry.full_calls > 0 or entry.partial_calls > 0 then
            mod:info("[OFM] truth   time reason=%s game full=%d calls (%.1fs) partial=%d calls (%.1fs) running=%.1fs | mod samples=%d (%.1fs)", key, entry.full_calls, entry.full_time, entry.partial_calls, entry.partial_time, entry.active_time, mod_events or 0, (mod_events or 0) * SAMPLE_INTERVAL)
        end
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
