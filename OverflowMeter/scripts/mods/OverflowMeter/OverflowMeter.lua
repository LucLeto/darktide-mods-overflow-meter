local mod = get_mod("OverflowMeter")

local settings = { meter_style = "gauge", show_title = true, show_rate = true, rate_mode = "total", show_allies_count = true, show_allies_missing = true, show_inactive_state = true, rate_window = 2, widget_x = 30, widget_y = 420, widget_scale = 100, widget_opacity = 100 }

local SETTING_IDS = { "meter_style", "show_title", "show_rate", "rate_mode", "show_allies_count", "show_allies_missing", "show_inactive_state", "rate_window", "widget_x", "widget_y", "widget_scale", "widget_opacity" }

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

mod.on_game_state_changed = function (status, state_name)
    if state_name == "StateGameplay" then
        mod._reset_requested = true

        if mod._pulses then
            mod._pulses.disable()
        end
    end
end

mod.on_enabled = function ()
    refresh_settings()
    mod._reset_requested = true
end

mod.on_disabled = function ()
    mod._reset_requested = true

    if mod._pulses then
        mod._pulses.disable()
    end
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
