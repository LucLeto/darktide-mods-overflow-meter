--- When the game refuses a Toughness replenish, mirrored on the client.
-- The server's Toughness extension restores nothing while the player is knocked down (unless being
-- force-assisted) or carries a keyword that prevents replenishing, such as standing in fire or gas.
-- Two of those keywords still let ability restores through. Pulses inferred from client-side
-- events do not pass through that check, so the pulse modules ask this module before counting one.
-- The reason lists mirror `PlayerUnitToughnessExtension._toughness_regen_disabled` (1.13); restores
-- the game gives without a reason, such as kills and blessings, are blocked by all three keywords.
--
-- Explicit module loaded by `OverflowMeter.lua` and stored as `mod._blocked_replenish`.
-- module: OverflowMeter_blocked_replenish
-- alias: Blocked
-- author: LucLeto
local BuffSettings = require("scripts/settings/buff/buff_settings")

local buff_keywords = BuffSettings.keywords or {}

local KNOCKED_DOWN_STATE_NAME = "knocked_down"
local KEYWORD_PREVENT = buff_keywords.prevent_toughness_replenish or "prevent_toughness_replenish"
local KEYWORD_PREVENT_EXCEPT_ABILITIES = buff_keywords.prevent_toughness_replenish_except_abilities or "prevent_toughness_replenish_except_abilities"
local KEYWORD_PREVENT_EXCEPT_COMBAT_ABILITIES = buff_keywords.prevent_toughness_replenish_except_all_combat_abilities or "prevent_toughness_replenish_except_all_combat_abilities"

--- Replenish reasons of abilities that still restore under the "except abilities" keyword.
local ABILITY_REASONS = {
    ability_shout = true,
    ability_stance = true,
    adamant_buff_drone = true,
    adamant_charge = true,
    bull_rush_toughness_talent = true,
    cryptic_precision_stance = true,
    lunging = true,
    ogryn_ranged_stance_reload = true,
    ogryn_ranged_stance_shoot = true,
    ogryn_taunt_restore_toughness = true,
    ogryn_taunt_restore_toughness_over_time = true,
    overcharge_stance = true,
    psyker_sphere = true,
    veteran_ranged_stance = true,
    zealot_channel = true,
    zealot_stealth = true
}

--- Replenish reasons that still restore under the "except all combat abilities" keyword.
local COMBAT_ABILITY_REASONS = {
    ability_shout = true,
    ability_stance = true,
    adamant_buff_drone = true,
    adamant_charge = true,
    bull_rush_toughness_talent = true,
    cryptic_precision_stance = true,
    lunging = true,
    ogryn_ranged_stance_reload = true,
    ogryn_taunt_restore_toughness = true,
    ogryn_taunt_restore_toughness_over_time = true,
    overcharge_stance = true,
    psyker_sphere = true,
    veteran_ranged_stance = true,
    zealot_channel = true,
    zealot_stealth = true
}

local Blocked = {}

--- Returns whether the game would refuse a replenish for the local player right now.
-- ?tab: character_state_component the player's `character_state` component
-- ?tab: assisted_state_input_component the player's `assisted_state_input` component
-- ?tab: buff_extension the player's buff extension
-- ?string: reason replenish reason; nil for restores the game gives without one
-- treturn: bool
Blocked.is_blocked = function (character_state_component, assisted_state_input_component, buff_extension, reason)
    if character_state_component and character_state_component.state_name == KNOCKED_DOWN_STATE_NAME and not (assisted_state_input_component and assisted_state_input_component.force_assist) then
        return true
    end

    if not buff_extension or not buff_extension.has_keyword then
        return false
    end

    if buff_extension:has_keyword(KEYWORD_PREVENT) then
        return true
    end

    if buff_extension:has_keyword(KEYWORD_PREVENT_EXCEPT_COMBAT_ABILITIES) and not COMBAT_ABILITY_REASONS[reason] then
        return true
    end

    if buff_extension:has_keyword(KEYWORD_PREVENT_EXCEPT_ABILITIES) and not ABILITY_REASONS[reason] then
        return true
    end

    return false
end

return Blocked
