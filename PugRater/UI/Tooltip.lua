-- UI/Tooltip.lua -- tier, runs together, tags and note on player tooltips.
--
-- Retail moved unit tooltips onto TooltipDataProcessor; the OnTooltipSetUnit
-- hook still exists on older shapes. Feature-detect both and take whichever is
-- there, because a tooltip that errors every mouseover is worse than no badge.

local ADDON, ns = ...

local Tooltip = {}
ns.Tooltip = Tooltip

local MAX_TAGS = 4

-- Adds our lines to `tip` for the given GUID. Shared by every entry point.
function Tooltip.Decorate(tip, guid)
    if not ns.settings.showTooltip or not guid or not tip then return end

    local person = ns.Roster.PersonForGUID(guid)
    if not person then return end

    local runs = ns.Roster.RunsTogether(person)
    if runs == 0 and (person.note or "") == "" and not next(person.tags) then return end

    local tier, source = ns.Roster.EffectiveTier(person)
    local color = ns.TIER_COLOR[tier] or ns.TIER_COLOR.Neutral

    tip:AddLine(" ")
    tip:AddDoubleLine(
        "|cff8f5fd6PugRater|r " .. tier .. (source == "override" and "*" or ""),
        runs > 0 and string.format("%d run%s together", runs, runs == 1 and "" or "s") or "",
        color.r, color.g, color.b, 0.7, 0.7, 0.76)

    -- Manual tags only: the auto-tags are all visible elsewhere on the tooltip.
    local tags = {}
    for tag in pairs(person.tags) do tags[#tags + 1] = tag end
    table.sort(tags)
    if #tags > 0 then
        local shown = {}
        for i = 1, math.min(MAX_TAGS, #tags) do shown[i] = tags[i] end
        local text = table.concat(shown, ", ")
        if #tags > MAX_TAGS then text = text .. string.format(" +%d", #tags - MAX_TAGS) end
        tip:AddLine(text, 0.68, 0.60, 0.82)
    end

    if (person.note or "") ~= "" then
        local note = person.note:gsub("\n", " ")
        if #note > 70 then note = note:sub(1, 67) .. "..." end
        tip:AddLine('"' .. note .. '"', 0.75, 0.75, 0.6, true)
    end

    local char = ns.Roster.MainCharacter(person)
    local rio = char and select(1, ns.Lookup.RIO(char.guid))
    if rio and rio > 0 then
        tip:AddLine(string.format("Raider.IO %d", math.floor(rio)), 0.6, 0.72, 0.85)
    end
end

local function onUnitTooltip(tip)
    if tip ~= GameTooltip and tip ~= GameTooltipTooltip then return end
    local _, unit = tip:GetUnit()
    if not unit or not UnitIsPlayer(unit) then return end
    Tooltip.Decorate(tip, UnitGUID(unit))
end

ns.OnInit(function()
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tip)
            local ok = pcall(onUnitTooltip, tip)
            if not ok then --[[ never break a tooltip ]] end
        end)
    elseif GameTooltip and GameTooltip.HookScript then
        GameTooltip:HookScript("OnTooltipSetUnit", function(tip) pcall(onUnitTooltip, tip) end)
    end
end)
