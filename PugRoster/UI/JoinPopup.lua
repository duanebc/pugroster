-- UI/JoinPopup.lua -- a small toast when someone you have rated joins the group.
--
-- Only fires for people who are actually interesting: a non-Neutral tier, a
-- note, or a manual tag. Otherwise every pug invite would produce a popup, which
-- is how people end up turning the addon off.

local ADDON, ns = ...
local UI = ns.UI

local JoinPopup = {}
ns.JoinPopup = JoinPopup

local DURATION = 12
local known = {}     -- guids already in the group, so we only toast on arrival
local frame

local function isInteresting(person)
    if not person then return false end
    local tier = ns.Roster.EffectiveTier(person)
    if tier ~= "Neutral" then return true end
    if (person.note or "") ~= "" then return true end
    if next(person.tags) then return true end
    return false
end

local function ensureFrame()
    if frame then return frame end

    frame = CreateFrame("Frame", "PugRosterToast", UIParent)
    frame:SetSize(280, 64)
    frame:SetPoint("TOP", UIParent, "TOP", 0, -180)
    frame:SetFrameStrata("HIGH")
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    UI.Backdrop(frame, { 0.06, 0.06, 0.09, 0.95 })

    local stripe = frame:CreateTexture(nil, "ARTWORK")
    stripe:SetPoint("TOPLEFT")
    stripe:SetPoint("BOTTOMLEFT")
    stripe:SetWidth(3)
    frame.stripe = stripe

    frame.title = UI.Label(frame, "", 13)
    frame.title:SetPoint("TOPLEFT", 12, -8)
    frame.title:SetWidth(220)
    frame.title:SetWordWrap(false)

    frame.body = UI.Label(frame, "", 11, { 0.72, 0.72, 0.78 })
    frame.body:SetPoint("TOPLEFT", 12, -26)
    frame.body:SetWidth(250)
    frame.body:SetJustifyV("TOP")

    local close = UI.Button(frame, "x", 18, function() frame:Hide() end)
    close:SetPoint("TOPRIGHT", -4, -4)
    close:SetHeight(16)

    frame:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then frame:Hide() end
    end)
    frame:Hide()
    return frame
end

function JoinPopup.Show(person)
    if not ns.settings.showJoinPopup then return end
    local f = ensureFrame()

    local tier = ns.Roster.EffectiveTier(person)
    local color = ns.TIER_COLOR[tier] or ns.TIER_COLOR.Neutral
    local char = ns.Roster.MainCharacter(person)

    f.stripe:SetColorTexture(color.r, color.g, color.b, 0.9)
    f.title:SetText(string.format("%s  %s",
        ns.Colorize(ns.ShortName(person.name), char and ns.ClassColor(char.classFile)),
        ns.TierText(tier)))

    local bits = { string.format("%d runs together", ns.Roster.RunsTogether(person)) }
    local tags = {}
    for tag in pairs(person.tags) do tags[#tags + 1] = tag end
    table.sort(tags)
    if #tags > 0 then bits[#bits + 1] = table.concat(tags, ", ") end
    if (person.note or "") ~= "" then bits[#bits + 1] = '"' .. person.note:gsub("\n", " ") .. '"' end
    f.body:SetText(table.concat(bits, "\n"))

    f:Show()
    if f.timer then f.timer:Cancel() end
    f.timer = C_Timer.NewTimer(DURATION, function() f:Hide() end)
end

-- Called by RunTracker on every GROUP_ROSTER_UPDATE.
function JoinPopup.OnRosterUpdate()
    if not IsInGroup() then
        wipe(known)
        return
    end

    local me = UnitGUID("player")
    local current = {}

    for i = 1, 4 do
        local unit = "party" .. i
        if UnitExists(unit) then
            local guid = UnitGUID(unit)
            if guid and guid ~= me then
                current[guid] = true
                if not known[guid] then
                    local person = ns.Roster.PersonForGUID(guid)
                    if isInteresting(person) then JoinPopup.Show(person) end
                end
            end
        end
    end

    wipe(known)
    for guid in pairs(current) do known[guid] = true end
end
