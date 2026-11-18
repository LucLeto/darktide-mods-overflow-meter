--- Confident Strike (chained-hit blessings) followed the way the game decides each restore.
-- The blessing's buff activates on every finished melee sweep, but restores only from the second
-- chained hit on: a sweep that hit something and was not the first attack of a combo raises a
-- chain counter, any other sweep resets it to 1, and the restore needs the counter above 1. The
-- activation the server reports to the client therefore over-counts. The sweep-finish event is
-- queued on the client too (`ActionSweep._handle_exit_procs`), so the pulse modules pass it here
-- and record the restore only when the game's counter would allow one.
--
-- The blessing only procs while its weapon is wielded, and its restore is a fixed percentage of
-- maximum Toughness that ignores stat buffs. One counter is enough: a player carries one melee
-- weapon.
--
-- Explicit module loaded by `OverflowMeter.lua` and stored as `mod._chained_hits`.
-- module: OverflowMeter_chained_hits
-- alias: ChainedHits
-- author: LucLeto
local ChainedHits = {}

--- The chained-hit blessing buffs of every weapon that has one; the pulse modules skip their
-- activations and count them from the sweeps instead.
ChainedHits.templates = {
    weapon_trait_bespoke_powermaul_p2_toughness_recovery_on_chained_attacks = true,
    weapon_trait_bespoke_powermaul_p3_toughness_recovery_on_chained_attacks = true,
    weapon_trait_bespoke_powermaul_shield_p1_toughness_recovery_on_chained_attacks = true
}

--- The game's chain counter for the current blessing; 0 before the first sweep, as at buff start.
local counter = 0

--- Forgets the chain, when a pulse module's context starts or ends.
ChainedHits.reset = function ()
    counter = 0
end

--- Returns the local player's chained-hit blessing buff, if the equipped weapon has one.
-- tab: buff_extension local player's buff extension
-- treturn: ?tab buff instance
local function _find_blessing(buff_extension)
    local buffs = buff_extension.buffs and buff_extension:buffs()

    if not buffs then
        return nil
    end

    local templates = ChainedHits.templates

    for i = 1, #buffs do
        local instance = buffs[i]
        local template_name = instance.template_name and instance:template_name()

        if template_name and templates[template_name] then
            return instance
        end
    end

    return nil
end

--- Follows one finished sweep and returns the blessing's restore if the game gives one for it.
-- tab: buff_extension local player's buff extension
-- ?tab: params sweep-finish event parameters (`num_hit_units`, `combo_count`)
-- ?tab: inventory_component local player's `inventory` component
-- treturn: ?number restore as a fraction of maximum Toughness, without stat buffs
ChainedHits.on_sweep_finish = function (buff_extension, params, inventory_component)
    local instance = buff_extension and _find_blessing(buff_extension)

    if not instance or not params then
        return nil
    end

    local template_context = instance.template_context and instance:template_context()
    local item_slot_name = template_context and template_context.item_slot_name

    if item_slot_name and inventory_component and inventory_component.wielded_slot ~= item_slot_name then
        return nil
    end

    local active = (params.num_hit_units or 0) > 0 and (params.combo_count or 0) > 0

    if active then
        counter = counter + 1
    else
        counter = 1
    end

    if counter <= 1 then
        return nil
    end

    local override_data = template_context and template_context.template_override_data
    local template = instance.template and instance:template()

    return override_data and override_data.toughness_fixed_percentage or template and template.toughness_fixed_percentage
end

return ChainedHits
