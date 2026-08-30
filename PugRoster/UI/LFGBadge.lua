-- UI/LFGBadge.lua -- tier colour on group-finder applicants.
--
-- Open risk 2 in the plan: the applicant list is Blizzard UI and may or may not
-- stay hookable and taint-safe. This file therefore does the minimum that can
-- possibly work and gives up loudly-but-harmlessly if the seam is gone:
--
--   * hooksecurefunc onto the applicant-member update, never a replacement,
--   * name/realm from the applicant API, resolved against our roster by name
--     (applicants have no GUID until they are in your group),
--   * every widget we draw is ours, parented to UIParent and merely *anchored*
--     to the applicant row.
--
-- That last point is the taint rule this file lives by. Inviting an applicant
-- is a protected call, so anything we leave behind on an applicant row can come
-- back as "PugRoster has been blocked from an action only available to the
-- Blizzard UI" the moment the player clicks Invite. So: no textures created on
-- Blizzard frames, no fields written to their frame tables, no scripts hooked
-- on them. Row -> overlay lives in a weak side table here instead, and the
-- overlay owns its own mouse region for the tooltip.
--
-- If the hook target does not exist, tooltips still carry the rating -- that is
-- the documented fallback.

local ADDON, ns = ...

local LFGBadge = {}
ns.LFGBadge = LFGBadge

LFGBadge.available = false

-- [applicant row] = our overlay. Weak keys so recycled rows do not pin us.
local overlays = setmetatable({}, { __mode = "k" })
local active = {}
local driver

local function personForApplicant(applicantID, memberIdx)
    if not C_LFGList or not C_LFGList.GetApplicantMemberInfo then return nil end
    local name = C_LFGList.GetApplicantMemberInfo(applicantID, memberIdx)
    if not name then return nil end

    local char = ns.Roster.FindCharacterByName(name)
    if not char then return nil end
    return ns.Roster.GetPerson(char.personId), char
end

local function overlayTooltip(self)
    local p = self.person
    if not p then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    local t = ns.Roster.EffectiveTier(p)
    GameTooltip:AddLine("|cff8f5fd6PugRoster|r " .. t)
    GameTooltip:AddLine(string.format("%d runs together", ns.Roster.RunsTogether(p)), 0.7, 0.7, 0.7)
    if (p.note or "") ~= "" then
        GameTooltip:AddLine('"' .. p.note:gsub("\n", " ") .. '"', 0.75, 0.75, 0.6, true)
    end
    GameTooltip:Show()
end

local function overlayFor(memberFrame)
    local badge = overlays[memberFrame]
    if badge then return badge end

    badge = CreateFrame("Frame", nil, UIParent)
    badge:SetSize(6, 16)
    badge:EnableMouse(true)
    badge.tex = badge:CreateTexture(nil, "OVERLAY")
    badge.tex:SetAllPoints()
    badge:SetScript("OnEnter", overlayTooltip)
    badge:SetScript("OnLeave", function() GameTooltip:Hide() end)
    badge:Hide()

    overlays[memberFrame] = badge
    return badge
end

-- The applicant rows are recycled and hidden without the update function being
-- called again, so nothing tells our overlays to go away. One throttled sweep
-- keeps them following their anchor instead of a per-overlay OnUpdate each.
local function ensureDriver()
    if driver then driver:Show(); return end
    driver = CreateFrame("Frame")
    local elapsed = 0
    driver:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + dt
        if elapsed < 0.1 then return end
        elapsed = 0
        local any = false
        for row, badge in pairs(active) do
            if ns.IsForbidden(row) or not row:IsVisible() then
                badge:Hide()
                active[row] = nil
            else
                any = true
            end
        end
        -- Stop once there is nothing to follow. The applicant list only exists
        -- while you are looking at group finder, and this frame was otherwise
        -- ticking for the rest of the session -- through every dungeon -- to
        -- sweep an empty table. decorate() starts it again when it is wanted.
        if not any then self:Hide() end
    end)
    driver:Hide()
end

local function decorate(memberFrame, applicantID, memberIdx)
    -- Same rule as the tooltip hook: never call a method on a Blizzard widget we
    -- have not cleared first, getters included.
    if not ns.settings.showLFGBadge or ns.IsForbidden(memberFrame) then return end
    ns.Trace("lfg:applicant")

    local badge = overlays[memberFrame]

    local person = personForApplicant(applicantID, memberIdx)
    if not person then
        if badge then badge:Hide(); active[memberFrame] = nil end
        return
    end

    local tier = ns.Roster.EffectiveTier(person)
    if tier == "Neutral" and (person.note or "") == "" then
        if badge then badge:Hide(); active[memberFrame] = nil end
        return
    end

    badge = badge or overlayFor(memberFrame)
    badge.person = person

    -- Re-anchor every pass: rows are reused for different applicants and can
    -- move between updates.
    badge:ClearAllPoints()
    badge:SetPoint("RIGHT", memberFrame, "LEFT", -2, 0)
    badge:SetFrameStrata(memberFrame:GetFrameStrata())
    badge:SetFrameLevel(memberFrame:GetFrameLevel() + 5)

    local color = ns.TIER_COLOR[tier] or ns.TIER_COLOR.Neutral
    badge.tex:SetColorTexture(color.r, color.g, color.b, 0.95)
    badge:Show()

    active[memberFrame] = badge
    ensureDriver()
end

function LFGBadge.HideAll()
    for row, badge in pairs(active) do
        badge:Hide()
        active[row] = nil
    end
end

ns.OnInit(function()
    -- Feature-detect the exact hook target. Blizzard has renamed this once
    -- already; if it is gone we simply stay disabled.
    local target = _G.LFGListApplicationViewer_UpdateApplicantMember
    if type(target) ~= "function" then return end

    local ok = pcall(hooksecurefunc, "LFGListApplicationViewer_UpdateApplicantMember",
        function(memberFrame, appID, memberIdx)
            pcall(decorate, memberFrame, appID, memberIdx)
        end)

    LFGBadge.available = ok and true or false
end)
