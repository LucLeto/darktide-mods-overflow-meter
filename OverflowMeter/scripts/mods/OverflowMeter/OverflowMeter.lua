--- DMF entry script that caches the settings, loads the modules and owns the shared hooks.
-- DMF runs this file as the `mod_script` named in `OverflowMeter.mod`; `OverflowMeter_data.lua`
-- and `OverflowMeter_localization.lua` are loaded by DMF from the same declaration.
--
-- Every setting is cached in `mod._settings` and refreshed per changed id. The modules are
-- loaded in dependency order through `mod:io_dofile` and stored on `mod`: the mission
-- statistics, the Skitarii, Veteran and Zealot sources and pulses, the scoreboard snapshot with
-- its optional adapters, mission summary sharing and the Session Stats rows. The HUD element
-- (`ui/OverflowMeter_hud_element.lua`) is registered last and reaches everything through these
-- `mod` fields.
--
-- DMF keeps only one hook per mod and method, so the hooks several pulse modules need
-- (`PlayerUnitBuffExtension._set_proc_active_start_time`,
-- `AttackReportManager.add_attack_result` and `Toughness.replenish_percentage`) are registered
-- here once and dispatched to the pulse module the HUD element enabled, `mod._active_pulses`.
-- module: OverflowMeter
-- author: LucLeto
local mod = get_mod("OverflowMeter")
local Toughness = require("scripts/utilities/toughness/toughness")

--- Mod version from DMF's `info.json` metadata, or `unknown` on DMF releases without it.
mod.version = mod.get_metadata and mod:get_metadata("version") or "unknown"

local math_floor = math.floor
local pcall = pcall

-- ----------------------------------------------------------------------------
-- Settings cache
-- ----------------------------------------------------------------------------

--- Cached setting values by setting id, seeded with the defaults from `OverflowMeter_data.lua`.
-- Exposed as `mod._settings`, so per-frame code reads a table field instead of calling `mod:get`.
local settings = {
    meter_style = "gauge",
    show_title = true,
    show_rate = true,
    rate_mode = "total",
    show_allies_count = true,
    show_allies_missing = true,
    show_inactive_state = true,
    show_tier_labels = false,
    rate_window = 2,
    widget_x = 30,
    widget_y = 420,
    widget_scale = 100,
    widget_opacity = 100,
    show_summary = false,
    summary_x = 1630,
    summary_y = 850,
    scoreboard_row_generated = true,
    scoreboard_row_replenished = true,
    scoreboard_row_overflowed = true,
    scoreboard_row_shared = true,
    scoreboard_row_efficiency = true,
    summary_chat_on_end = true,
    share_mission_summary = true,
    session_stats_rows = true,
    session_stats_row_1 = "generated",
    session_stats_row_2 = "shared",
    session_stats_row_3 = "efficiency"
}

--- Every setting id mirrored into the cache.
local SETTING_IDS = {
    "meter_style",
    "show_title",
    "show_rate",
    "rate_mode",
    "show_allies_count",
    "show_allies_missing",
    "show_inactive_state",
    "show_tier_labels",
    "rate_window",
    "widget_x",
    "widget_y",
    "widget_scale",
    "widget_opacity",
    "show_summary",
    "summary_x",
    "summary_y",
    "scoreboard_row_generated",
    "scoreboard_row_replenished",
    "scoreboard_row_overflowed",
    "scoreboard_row_shared",
    "scoreboard_row_efficiency",
    "summary_chat_on_end",
    "share_mission_summary",
    "session_stats_rows",
    "session_stats_row_1",
    "session_stats_row_2",
    "session_stats_row_3"
}

--- Lookup set of `SETTING_IDS`, so a change to an uncached setting (the keybind) is ignored.
local CACHED_SETTING_IDS = {}

for i = 1, #SETTING_IDS do
    CACHED_SETTING_IDS[SETTING_IDS[i]] = true
end

--- Settings whose change refreshes mission summary sharing.
local SHARE_SETTING_IDS = {
    share_mission_summary = true
}

--- Settings whose change republishes the scoreboard snapshot (row choice and the shared value's unit).
local SNAPSHOT_SETTING_IDS = {
    rate_mode = true,
    scoreboard_row_generated = true,
    scoreboard_row_replenished = true,
    scoreboard_row_overflowed = true,
    scoreboard_row_shared = true,
    scoreboard_row_efficiency = true
}

--- Shared runtime state read by the HUD element and the integrations.
-- `_settings_version` changes with every cached setting and makes the HUD element reapply its
-- display settings; `_snapshot_settings_version` changes only for `SNAPSHOT_SETTING_IDS` and
-- makes it republish the scoreboard snapshot. `_reset_requested` asks the HUD element to reset
-- its estimator, `_summary_held` mirrors the hold keybind and `_summary_echoed` limits the
-- end-of-mission chat line to once per mission.
mod._settings = settings
mod._settings_version = 0
mod._snapshot_settings_version = 0
mod._reset_requested = false
mod._summary_held = false
mod._summary_echoed = false

--- Rereads every cached setting from DMF and bumps both settings versions.
local function refresh_settings()
    for i = 1, #SETTING_IDS do
        local setting_id = SETTING_IDS[i]
        local value = mod:get(setting_id)

        if value ~= nil then
            settings[setting_id] = value
        end
    end

    mod._settings_version = mod._settings_version + 1
    mod._snapshot_settings_version = mod._snapshot_settings_version + 1
end

refresh_settings()

--- DMF callback; updates the changed setting's cached value.
-- Numeric sliders call it for every drag step, so only the changed value is copied, and sharing
-- and the snapshot are refreshed only for the settings that affect them. A nil id rereads every
-- setting and refreshes both.
-- ?string: setting_id changed setting
mod.on_setting_changed = function (setting_id)
    if setting_id == nil then
        refresh_settings()

        mod._share.refresh()
        mod._snapshot.refresh()

        return
    end

    if not CACHED_SETTING_IDS[setting_id] then
        return
    end

    local value = mod:get(setting_id)

    if value ~= nil then
        settings[setting_id] = value
    end

    mod._settings_version = mod._settings_version + 1

    if SHARE_SETTING_IDS[setting_id] then
        mod._share.refresh()
    end

    if SNAPSHOT_SETTING_IDS[setting_id] then
        mod._snapshot_settings_version = mod._snapshot_settings_version + 1

        mod._snapshot.refresh()
    end
end

-- ----------------------------------------------------------------------------
-- Modules
-- ----------------------------------------------------------------------------

-- Loaded in dependency order: the pulse modules read their sources from `mod`, and the
-- snapshot reads the statistics.
mod._stats = mod:io_dofile("OverflowMeter/scripts/mods/OverflowMeter/OverflowMeter_stats")
mod._sources = mod:io_dofile("OverflowMeter/scripts/mods/OverflowMeter/OverflowMeter_sources")
mod._pulses = mod:io_dofile("OverflowMeter/scripts/mods/OverflowMeter/OverflowMeter_pulses")
mod._sources_veteran = mod:io_dofile("OverflowMeter/scripts/mods/OverflowMeter/OverflowMeter_sources_veteran")
mod._pulses_veteran = mod:io_dofile("OverflowMeter/scripts/mods/OverflowMeter/OverflowMeter_pulses_veteran")
mod._sources_zealot = mod:io_dofile("OverflowMeter/scripts/mods/OverflowMeter/OverflowMeter_sources_zealot")
mod._pulses_zealot = mod:io_dofile("OverflowMeter/scripts/mods/OverflowMeter/OverflowMeter_pulses_zealot")

--- Source models by archetype name, as returned by `player:archetype_name()` (Skitarii is `cryptic`).
-- An archetype listed here has its mission statistics tracked; the live meter additionally needs
-- its sharing talent (see `ARCHETYPES` in the HUD element).
mod._sources_by_archetype = {
    cryptic = mod._sources,
    veteran = mod._sources_veteran,
    zealot = mod._sources_zealot
}

--- Pulse modules by archetype name; the HUD element enables the one for the local player.
mod._pulses_by_archetype = {
    cryptic = mod._pulses,
    veteran = mod._pulses_veteran,
    zealot = mod._pulses_zealot
}

--- The pulse module the HUD element enabled for the local player, or nil. The shared hooks
-- dispatch to it while it is enabled.
mod._active_pulses = nil

mod._snapshot = mod:io_dofile("OverflowMeter/scripts/mods/OverflowMeter/integrations/OverflowMeter_snapshot")

-- Optional scoreboard adapters. Each registers itself with the snapshot and stays inactive
-- while its host mod is missing.
mod:io_dofile("OverflowMeter/scripts/mods/OverflowMeter/integrations/OverflowMeter_scoreboard")
mod:io_dofile("OverflowMeter/scripts/mods/OverflowMeter/integrations/OverflowMeter_vt2_scoreboard")
mod:io_dofile("OverflowMeter/scripts/mods/OverflowMeter/integrations/OverflowMeter_scores")
mod:io_dofile("OverflowMeter/scripts/mods/OverflowMeter/integrations/OverflowMeter_power_di")
mod:io_dofile("OverflowMeter/scripts/mods/OverflowMeter/integrations/OverflowMeter_another_scoreboard")

mod._share = mod:io_dofile("OverflowMeter/scripts/mods/OverflowMeter/OverflowMeter_share")

-- Optional rows in the game's own Session Stats panel on the end-of-round screen.
mod:io_dofile("OverflowMeter/scripts/mods/OverflowMeter/integrations/OverflowMeter_session_stats")

-- ----------------------------------------------------------------------------
-- Shared hooks
-- ----------------------------------------------------------------------------

-- A proc buff became active (weapon blessing and talent procs). Dispatched to the enabled pulse
-- module, which checks the buff extension and template itself.
mod:hook_safe(CLASS.PlayerUnitBuffExtension, "_set_proc_active_start_time", function (self, index, activation_time, skip_send_active_time_rpc)
    local pulses = mod._active_pulses

    if not pulses or not pulses.enabled then
        return
    end

    pulses.on_proc_active(self, index)
end)

-- A local attack report (a hit, a kill, or the local player being hit). Dispatched to the
-- enabled pulse module.
mod:hook_safe(CLASS.AttackReportManager, "add_attack_result", function (self, damage_profile, attacked_unit, attacking_unit, attack_direction, hit_world_position, hit_weakspot, damage, attack_result, attack_type, damage_efficiency, is_critical_strike)
    local pulses = mod._active_pulses

    if not pulses or not pulses.enabled then
        return
    end

    pulses.on_attack_result(damage_profile, attacked_unit, attacking_unit, attack_direction, hit_world_position, hit_weakspot, damage, attack_result, attack_type, damage_efficiency, is_critical_strike)
end)

-- ----------------------------------------------------------------------------
-- TEMPORARY replenish debug log (remove before release)
-- ----------------------------------------------------------------------------

--- TEMPORARY: whether the local player's `Toughness.replenish_percentage` calls are logged.
-- Lines go to the console log (`%AppData%\Fatshark\Darktide\console_logs`) with an `[OFM]`
-- prefix: the first call of each reason per mission at once, then one summary line per reason
-- every `DEBUG_REPLENISH_INTERVAL` seconds while it keeps firing. `resim` counts the calls made
-- while the client re-simulated the unit after a misprediction, which the pulse module ignores.
local DEBUG_REPLENISH = true
local DEBUG_REPLENISH_INTERVAL = 5

--- TEMPORARY: per-reason counters since the last summary, and the time to the next summary.
local debug_replenish_reasons = {}
local debug_replenish_timer = 0

--- TEMPORARY: returns whether this machine runs the game session (solo play, hosting).
-- treturn: ?bool nil outside a game session
local function _debug_is_server()
    local state_managers = Managers.state
    local game_session_manager = state_managers and state_managers.game_session

    if not game_session_manager or not game_session_manager.is_server then
        return nil
    end

    return game_session_manager:is_server()
end

--- TEMPORARY: counts one replenish call of the local player, logging the first one per reason.
-- tab: pulses the active pulse module
-- ?number: fixed_percentage requested fraction of maximum Toughness
-- ?bool: ignore_stat_buffs whether the request ignores stat buffs
-- ?string: reason replenish reason
-- number: excess_before the module's excess queue before its handler ran
local function _debug_replenish(pulses, fixed_percentage, ignore_stat_buffs, reason, excess_before)
    local key = reason or "<nil>"
    local fraction = type(fixed_percentage) == "number" and fixed_percentage or 0
    local captured = (pulses.pending_excess or 0) - excess_before
    local unit_data_extension = pulses.unit_data_extension
    local resimulating = unit_data_extension and unit_data_extension.is_resimulating or false
    local entry = debug_replenish_reasons[key]

    if not entry then
        entry = {
            count = 0,
            resim = 0,
            fraction = 0,
            captured = 0
        }
        debug_replenish_reasons[key] = entry

        local toughness_extension = pulses.toughness_extension
        local damage = toughness_extension and toughness_extension:toughness_damage() or -1
        local max_toughness = toughness_extension and toughness_extension:max_toughness() or -1

        mod:info("[OFM] replenish first: reason=%s pct=%.4f ignore_stat_buffs=%s captured=%.2f damage=%.1f max=%.1f server=%s handler=%s", key, fraction, tostring(ignore_stat_buffs), captured, damage, max_toughness, tostring(_debug_is_server()), tostring(pulses.on_replenish_percentage ~= nil))
    end

    entry.count = entry.count + 1
    entry.fraction = entry.fraction + fraction
    entry.captured = entry.captured + captured

    if resimulating then
        entry.resim = entry.resim + 1
    end
end

--- TEMPORARY: writes one summary line per reason that fired since the last one.
-- number: dt frame delta time
local function _debug_flush_replenish(dt)
    debug_replenish_timer = debug_replenish_timer + dt

    if debug_replenish_timer < DEBUG_REPLENISH_INTERVAL then
        return
    end

    debug_replenish_timer = 0

    for key, entry in pairs(debug_replenish_reasons) do
        if entry.count > 0 then
            mod:info("[OFM] replenish %ds: reason=%s calls=%d resim=%d sum_pct=%.4f captured=%.2f", DEBUG_REPLENISH_INTERVAL, key, entry.count, entry.resim, entry.fraction, entry.captured)

            entry.count = 0
            entry.resim = 0
            entry.fraction = 0
            entry.captured = 0
        end
    end
end

--- TEMPORARY: forgets every reason, so the next mission logs each first call again.
local function _debug_reset_replenish()
    for key in pairs(debug_replenish_reasons) do
        debug_replenish_reasons[key] = nil
    end

    debug_replenish_timer = 0
end

-- A replenish was requested. On a client the local player's Toughness extension ignores it, but
-- the buffs whose functions also run on the client still make the call, which is the only way to
-- see the restores they ask for at full Toughness. Dispatched to the enabled pulse module when it
-- tracks such restores and the unit is the local player's. The pulse module runs before the
-- original (a host applies the replenish in it, which would hide the headroom it had) and is
-- protected, so an error in it can never stop the game's own replenish.
mod:hook(Toughness, "replenish_percentage", function (func, unit, fixed_percentage, ignore_stat_buffs, reason, ...)
    local pulses = mod._active_pulses

    if pulses and pulses.enabled and unit == pulses.unit then
        local on_replenish_percentage = pulses.on_replenish_percentage
        local excess_before = DEBUG_REPLENISH and pulses.pending_excess or 0

        if on_replenish_percentage then
            pcall(on_replenish_percentage, unit, fixed_percentage, ignore_stat_buffs, reason)
        end

        if DEBUG_REPLENISH then
            pcall(_debug_replenish, pulses, fixed_percentage, ignore_stat_buffs, reason, excess_before)
        end
    end

    return func(unit, fixed_percentage, ignore_stat_buffs, reason, ...)
end)

-- ----------------------------------------------------------------------------
-- Lifecycle
-- ----------------------------------------------------------------------------

--- Disables every pulse module, clearing their pending amounts and cached extensions, and
-- forgets the active one. Exposed as `mod._disable_all_pulses` for the HUD element.
local function disable_all_pulses()
    local pulses_by_archetype = mod._pulses_by_archetype

    for _, pulses in pairs(pulses_by_archetype) do
        if pulses then
            pulses.disable()
        end
    end

    mod._active_pulses = nil
end

mod._disable_all_pulses = disable_all_pulses

--- DMF callback for game state changes.
-- Entering or leaving `StateGameplay` disables the pulses and asks the HUD element to reset.
-- Entering it also resets the statistics, sharing and the snapshot, so every mission starts from
-- zero; leaving keeps the totals for the end-of-round screen.
-- string: status `enter` or `exit`
-- string: state_name game state class name
mod.on_game_state_changed = function (status, state_name)
    if state_name == "StateGameplay" then
        mod._reset_requested = true

        if status == "enter" then
            mod._summary_echoed = false

            mod._stats.reset()
            mod._share.reset()
            mod._snapshot.reset()

            -- TEMPORARY: replenish debug log per mission.
            if DEBUG_REPLENISH then
                _debug_reset_replenish()
            end
        end

        disable_all_pulses()
    end
end

--- Writes the mission totals to the local chat, once per mission and only if anything was generated.
-- A build without a sharing talent gets the shorter line without Shared and the efficiency. The
-- message is passed as an argument because `mod:echo` formats its first argument and a localized
-- text can contain a literal `%`.
local function echo_mission_summary()
    if mod._summary_echoed or not settings.summary_chat_on_end then
        return
    end

    local stats = mod._stats

    if stats.generated <= 0 then
        return
    end

    mod._summary_echoed = true

    local message

    if stats.has_share_metrics then
        local shared = settings.rate_mode ~= "per_ally" and stats.shared_total or stats.shared

        message = mod:localize(
            "summary_chat",
            math_floor(stats.generated + 0.5),
            math_floor(stats.replenished + 0.5),
            math_floor(stats.overflowed + 0.5),
            math_floor(shared + 0.5),
            math_floor(stats.efficiency() * 100 + 0.5)
        )
    else
        message = mod:localize(
            "summary_chat_no_share",
            math_floor(stats.generated + 0.5),
            math_floor(stats.replenished + 0.5),
            math_floor(stats.overflowed + 0.5)
        )
    end

    mod:echo("%s", message)
end

-- The end-of-round screen opened. The HUD is already destroyed by then, but the module-level
-- totals survive: echo the chat line, read the teammates' published totals and push the final
-- snapshot to the scoreboards. The view is package-loaded, so the hook uses the class name and
-- DMF applies it once the class exists.
mod:hook_safe("EndView", "on_enter", function ()
    echo_mission_summary()

    mod._share.push_peers()
    mod._snapshot.flush()
end)

--- DMF callback; installs the presence hook for sharing and lets the scoreboard adapters find
-- their host mods, which only exist once every mod has loaded.
mod.on_all_mods_loaded = function ()
    mod._share.setup()
    mod._snapshot.setup()
end

--- DMF update callback; drives the periodic publishing and reading of mission summaries.
-- number: dt frame delta time
mod.update = function (dt)
    mod._share.update(dt)

    -- TEMPORARY: replenish debug summaries.
    if DEBUG_REPLENISH then
        _debug_flush_replenish(dt)
    end
end

--- DMF callback; rereads the settings and starts tracking from zero.
mod.on_enabled = function ()
    refresh_settings()

    mod._reset_requested = true

    mod._stats.reset()
    mod._share.refresh()
    mod._snapshot.reset()
end

--- DMF callback; stops tracking, clears the totals, withdraws the published summary and
-- detaches the scoreboard adapters.
mod.on_disabled = function ()
    mod._reset_requested = true
    mod._summary_held = false

    mod._stats.reset()
    mod._share.teardown()
    mod._snapshot.reset()
    mod._snapshot.teardown()

    disable_all_pulses()
end

--- DMF callback; withdraws the published summary and detaches the scoreboard adapters before unloading.
mod.on_unload = function ()
    mod._share.teardown()
    mod._snapshot.teardown()
end

--- Keybind callback of `Show summary (hold)`.
-- DMF calls it without `self` on press and again on release.
-- bool: is_pressed true while the key is held
mod.hold_mission_summary = function (is_pressed)
    mod._summary_held = is_pressed and true or false
end

-- ----------------------------------------------------------------------------
-- Scoreboard rows and HUD element
-- ----------------------------------------------------------------------------

--- Row declarations the Scoreboard mod collects from every mod's `scoreboard_rows` table.
-- `DIFF` rows add the difference between two published totals. Efficiency is a percentage
-- that must not add up, so its adapter writes the value straight into the row data.
mod.scoreboard_rows = {
    {
        name = "overflow_meter_generated",
        text = "scoreboard_generated",
        validation = "ASC",
        iteration = "DIFF",
        group = "defense",
        setting = "scoreboard_row_generated"
    },
    {
        name = "overflow_meter_replenished",
        text = "scoreboard_replenished",
        validation = "ASC",
        iteration = "DIFF",
        group = "defense",
        setting = "scoreboard_row_replenished"
    },
    {
        name = "overflow_meter_overflowed",
        text = "scoreboard_overflowed",
        validation = "ASC",
        iteration = "DIFF",
        group = "defense",
        setting = "scoreboard_row_overflowed"
    },
    {
        name = "overflow_meter_shared",
        text = "scoreboard_shared",
        validation = "ASC",
        iteration = "DIFF",
        group = "defense",
        setting = "scoreboard_row_shared"
    },
    {
        name = "overflow_meter_efficiency",
        text = "scoreboard_efficiency",
        validation = "ASC",
        iteration = "ADD",
        group = "defense",
        setting = "scoreboard_row_efficiency"
    }
}

-- The meter and the mission summary panel. The `alive` visibility group is also true in the
-- hub, so the element checks the game mode itself.
mod:register_hud_element({
    class_name = "HudElementOverflowMeter",
    filename = "OverflowMeter/scripts/mods/OverflowMeter/ui/OverflowMeter_hud_element",
    use_hud_scale = true,
    visibility_groups = {
        "alive"
    }
})

return mod
