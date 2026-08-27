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
    if not ns.settings.showTooltip or not guid or ns.IsForbidden(tip) then return end

    local person = ns.Roster.PersonForGUID(guid)
    if not person then return end

    -- What we know about them, gathered before deciding whether it is worth a
    -- block at all. Item level comes from whatever the inspect queue last
    -- recorded; the scores prefer the live RaiderIO addon over the companion
    -- snapshot (see Rating/Lookup.lua).
    local char = ns.Roster.MainCharacter(person)
    local ilvl = char and char.ilvl
    local rio, rioPrev = nil, nil
    if char then rio, rioPrev = ns.Lookup.RIO(char.guid) end

    local runs = ns.Roster.RunsTogether(person)
    if runs == 0 and (person.note or "") == "" and not next(person.tags)
        and not (ilvl and ilvl > 0) and not (rio and rio > 0) then
        return
    end

    local tier, source = ns.Roster.EffectiveTier(person)
    local color = ns.TIER_COLOR[tier] or ns.TIER_COLOR.Neutral

    tip:AddLine(" ")
    tip:AddDoubleLine(
        "|cff8f5fd6PugRater|r " .. tier .. (source == "override" and "*" or ""),
        runs > 0 and string.format("%d run%s together", runs, runs == 1 and "" or "s") or "",
        color.r, color.g, color.b, 0.7, 0.7, 0.76)

    -- Item level and scores on one line, each part dropped when we do not have
    -- it, and the whole line skipped when we have none of them -- a tooltip
    -- should never gain a blank row.
    local stats = {}
    if ilvl and ilvl > 0 then
        stats[#stats + 1] = "item level |cffffffff" .. ilvl .. "|r"
    end
    if rio and rio > 0 then
        stats[#stats + 1] = "Raider.IO |cffffffff" .. math.floor(rio) .. "|r"
    end
    if rioPrev and rioPrev > 0 then
        -- Last season is not on this season's scale, so it takes RaiderIO's own
        -- previous-season colour rather than sitting in the same white.
        local text = "S1 " .. math.floor(rioPrev)
        local c = ns.RaiderIOBridge.ScoreColor(rioPrev, true)
        stats[#stats + 1] = "(" .. (c and ns.Colorize(text, c) or text) .. ")"
    end
    if #stats > 0 then
        tip:AddLine(table.concat(stats, "   "), 0.6, 0.72, 0.85)
    end

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

end

local function onUnitTooltip(tip)
    -- The setting gates the whole hook, not just the lines we add. Checking it
    -- inside Decorate left GetUnit() still running with the feature switched
    -- off, which made "turn off tooltips" useless as a way to rule this hook out.
    if not ns.settings.showTooltip then return end

    -- AddTooltipPostCall hands us every unit tooltip in the game, forbidden ones
    -- included, and calling any method on one of those -- GetUnit included --
    -- raises ADDON_ACTION_FORBIDDEN. Clear it before touching it at all.
    if ns.IsForbidden(tip) then return end
    ns.Trace("tooltip:unit")
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
