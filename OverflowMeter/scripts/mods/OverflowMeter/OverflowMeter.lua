local mod = get_mod("OverflowMeter")

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
    widget_opacity = 100
}

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
    "widget_opacity"
}

mod._settings = settings
mod._settings_version = 0
mod._reset_requested = false

local function refresh_settings()
    for i = 1, #SETTING_IDS do
        local setting_id = SETTING_IDS[i]
        local value = mod:get(setting_id)

        if value ~= nil then
            settings[setting_id] = value
        end
    end

    mod._settings_version = mod._settings_version + 1
end

refresh_settings()

mod.on_setting_changed = function ()
    refresh_settings()
end

mod._sources = mod:io_dofile("OverflowMeter/scripts/mods/OverflowMeter/OverflowMeter_sources")
mod._pulses = mod:io_dofile("OverflowMeter/scripts/mods/OverflowMeter/OverflowMeter_pulses")
mod._sources_veteran = mod:io_dofile("OverflowMeter/scripts/mods/OverflowMeter/OverflowMeter_sources_veteran")
mod._pulses_veteran = mod:io_dofile("OverflowMeter/scripts/mods/OverflowMeter/OverflowMeter_pulses_veteran")

mod._sources_by_archetype = {
    cryptic = mod._sources,
    veteran = mod._sources_veteran
}

mod._pulses_by_archetype = {
    cryptic = mod._pulses,
    veteran = mod._pulses_veteran
}

mod:hook_safe(CLASS.PlayerUnitBuffExtension, "_set_proc_active_start_time", function (self, index, activation_time, skip_send_active_time_rpc)
    local pulses = mod._pulses

    if not pulses.enabled then
        pulses = mod._pulses_veteran

        if not pulses.enabled then
            return
        end
    end

    pulses.on_proc_active(self, index)
end)

mod:hook_safe(CLASS.AttackReportManager, "add_attack_result", function (self, damage_profile, attacked_unit, attacking_unit, attack_direction, hit_world_position, hit_weakspot, damage, attack_result, attack_type, damage_efficiency, is_critical_strike)
    local pulses = mod._pulses

    if not pulses.enabled then
        pulses = mod._pulses_veteran

        if not pulses.enabled then
            return
        end
    end

    pulses.on_attack_result(damage_profile, attacked_unit, attacking_unit, attack_direction, hit_world_position, hit_weakspot, damage, attack_result, attack_type, damage_efficiency, is_critical_strike)
end)

local function disable_all_pulses()
    local pulses_by_archetype = mod._pulses_by_archetype

    for _, pulses in pairs(pulses_by_archetype) do
        if pulses then
            pulses.disable()
        end
    end
end

mod._disable_all_pulses = disable_all_pulses

mod.on_game_state_changed = function (status, state_name)
    if state_name == "StateGameplay" then
        mod._reset_requested = true

        disable_all_pulses()
    end
end

mod.on_enabled = function ()
    refresh_settings()
    mod._reset_requested = true
end

mod.on_disabled = function ()
    mod._reset_requested = true

    disable_all_pulses()
end

mod:register_hud_element({
    class_name = "HudElementOverflowMeter",
    filename = "OverflowMeter/scripts/mods/OverflowMeter/ui/OverflowMeter_hud_element",
    use_hud_scale = true,
    visibility_groups = {
        "alive"
    }
})

return mod
