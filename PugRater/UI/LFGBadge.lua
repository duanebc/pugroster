-- UI/LFGBadge.lua -- tier colour on group-finder applicants.
--
-- Open risk 2 in the plan: the applicant list is Blizzard UI and may or may not
-- stay hookable and taint-safe. This file therefore does the minimum that can
-- possibly work and gives up loudly-but-harmlessly if the seam is gone:
--
--   * hooksecurefunc onto the applicant-member update, never a replacement,
--   * name/realm from the applicant API, resolved against our roster by name
--     (applicants have no GUID until they are in your group),
--   * a texture and a tooltip line, no layout changes, no secure frames touched.
--
-- If the hook target does not exist, tooltips still carry the rating -- that is
-- the documented fallback.

local ADDON, ns = ...

local LFGBadge = {}
ns.LFGBadge = LFGBadge

LFGBadge.available = false

local function personForApplicant(applicantID, memberIdx)
    if not C_LFGList or not C_LFGList.GetApplicantMemberInfo then return nil end
    local name = C_LFGList.GetApplicantMemberInfo(applicantID, memberIdx)
    if not name then return nil end

    local char = ns.Roster.FindCharacterByName(name)
    if not char then return nil end
    return ns.Roster.GetPerson(char.personId), char
end

local function decorate(memberFrame, applicantID, memberIdx)
    if not ns.settings.showLFGBadge or not memberFrame then return end

    local person = personForApplicant(applicantID, memberIdx)
    if not person then
        if memberFrame.pugRaterBadge then memberFrame.pugRaterBadge:Hide() end
        return
    end

    local tier = ns.Roster.EffectiveTier(person)
    if tier == "Neutral" and (person.note or "") == "" then
        if memberFrame.pugRaterBadge then memberFrame.pugRaterBadge:Hide() end
        return
    end

    local badge = memberFrame.pugRaterBadge
    if not badge then
        badge = memberFrame:CreateTexture(nil, "OVERLAY")
        badge:SetSize(4, 16)
        badge:SetPoint("LEFT", memberFrame, "LEFT", -6, 0)
        memberFrame.pugRaterBadge = badge
    end

    local color = ns.TIER_COLOR[tier] or ns.TIER_COLOR.Neutral
    badge:SetColorTexture(color.r, color.g, color.b, 0.95)
    badge:Show()

    -- The applicant rows reuse frames, so re-point the tooltip hook every time
    -- rather than only on creation.
    if not memberFrame.pugRaterHooked then
        memberFrame.pugRaterHooked = true
        memberFrame:HookScript("OnEnter", function(self)
            if not self.pugRaterPerson then return end
            if GameTooltip:IsShown() then
                local p = self.pugRaterPerson
                local t = ns.Roster.EffectiveTier(p)
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("|cff8f5fd6PugRater|r " .. t ..
                    string.format("  (%d runs together)", ns.Roster.RunsTogether(p)))
                if (p.note or "") ~= "" then
                    GameTooltip:AddLine('"' .. p.note:gsub("\n", " ") .. '"', 0.75, 0.75, 0.6, true)
                end
                GameTooltip:Show()
            end
        end)
    end
    memberFrame.pugRaterPerson = person
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
