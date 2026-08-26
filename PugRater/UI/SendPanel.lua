-- UI/SendPanel.lua -- tag messaging: pick a group, preview, send with stagger.
--
-- The preview is the whole point of this panel. Nothing is sent until the list
-- of exact names and exact expanded messages has been on screen, and blocked
-- recipients stay visible with their reason rather than quietly disappearing.

local ADDON, ns = ...
local UI = ns.UI

local panel = {}
ns.SendPanel = panel

local EDITOR_WIDTH = 300

local state = {
    filter   = nil,
    template = 1,
    message  = nil,        -- nil = follow the selected template
    entries  = {},
    deselected = {},       -- [personId] = true, survives refreshes
    status   = "",
}

-- Seeded from the roster panel: message exactly one person.
function panel.SeedWithPerson(person)
    state.filter = { match = "all", conditions = { { field = "name", op = "is", value = person.name } } }
    wipe(state.deselected)
    state.status = ""
end

local function currentText()
    if state.message then return state.message end
    local t = ns.db.templates[state.template]
    return t and t.text or ""
end

local function rebuildEntries()
    state.entries = ns.Sender.BuildRecipients(state.filter, currentText())
    for _, entry in ipairs(state.entries) do
        if state.deselected[entry.person.id] then entry.selected = false end
    end
    return state.entries
end

local function selectedCount()
    local n = 0
    for _, e in ipairs(state.entries) do
        if e.selected and not e.blocked then n = n + 1 end
    end
    return n
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

local function build(page)
    ----------------------------------------------------------------------------
    -- Top bar: who to message
    ----------------------------------------------------------------------------
    local groupBtn = UI.MenuButton(page, 160, function()
        return state.filter and ns.Filters.Describe(state.filter):sub(1, 22) or "everyone online"
    end, function()
        local entries = { { text = "everyone online", func = function()
            state.filter = nil; wipe(state.deselected); UI.Refresh() end } }
        for _, name in ipairs(ns.Filters.ListGroups()) do
            entries[#entries + 1] = { text = name, func = function()
                state.filter = ns.Filters.GetGroup(name); wipe(state.deselected); UI.Refresh() end }
        end
        if #entries == 1 then
            entries[#entries + 1] = { text = "(save groups in the Roster tab)" }
        end
        return entries
    end)
    groupBtn:SetPoint("TOPLEFT", 10, -10)

    local refreshBtn = UI.Button(page, "Refresh online", 110, function() UI.Refresh() end)
    refreshBtn:SetPoint("LEFT", groupBtn, "RIGHT", 6, 0)

    local selectAll = UI.Button(page, "Select all", 90, function()
        wipe(state.deselected)
        UI.Refresh()
    end)
    selectAll:SetPoint("LEFT", refreshBtn, "RIGHT", 6, 0)

    local selectNone = UI.Button(page, "Select none", 90, function()
        for _, e in ipairs(state.entries) do state.deselected[e.person.id] = true end
        UI.Refresh()
    end)
    selectNone:SetPoint("LEFT", selectAll, "RIGHT", 6, 0)

    local summary = UI.Label(page, "", 11, { 0.65, 0.62, 0.72 })
    summary:SetPoint("TOPLEFT", groupBtn, "BOTTOMLEFT", 2, -6)

    ----------------------------------------------------------------------------
    -- Template editor
    ----------------------------------------------------------------------------
    local editor = CreateFrame("Frame", nil, page)
    editor:SetWidth(EDITOR_WIDTH)
    editor:SetPoint("TOPRIGHT", -8, -56)
    editor:SetPoint("BOTTOMRIGHT", -8, 8)
    UI.Backdrop(editor, { 0, 0, 0, 0.25 })

    local tplLabel = UI.Label(editor, "Template", 11, UI.COLORS.header)
    tplLabel:SetPoint("TOPLEFT", 10, -10)

    local tplBtn = UI.MenuButton(editor, EDITOR_WIDTH - 20, function()
        local t = ns.db.templates[state.template]
        return t and t.name or "(none)"
    end, function()
        local entries = {}
        for i, t in ipairs(ns.db.templates) do
            entries[#entries + 1] = { text = t.name, checked = state.template == i, func = function()
                state.template = i
                state.message = nil
                UI.Refresh()
            end }
        end
        entries[#entries + 1] = { text = "---" }
        entries[#entries + 1] = { text = "Save current text as new...", func = function()
            editor.nameBox:Show(); editor.nameBox:SetFocus()
        end }
        local cur = ns.db.templates[state.template]
        if cur then
            entries[#entries + 1] = { text = "Overwrite: " .. cur.name, func = function()
                ns.Templates.Update(state.template, nil, currentText())
                state.message = nil
                ns.Print("template updated:", cur.name)
                UI.Refresh()
            end }
            entries[#entries + 1] = { text = "Delete: " .. cur.name, func = function()
                ns.Templates.Delete(state.template)
                state.template = 1
                state.message = nil
                UI.Refresh()
            end }
        end
        return entries
    end)
    tplBtn:SetPoint("TOPLEFT", tplLabel, "BOTTOMLEFT", 0, -4)

    local nameBox = UI.EditBox(editor, EDITOR_WIDTH - 20, function(text)
        if text and text ~= "" then
            ns.Templates.Add(text, currentText())
            state.template = #ns.db.templates
            state.message = nil
            ns.Print("template saved:", text)
        end
        editor.nameBox:SetText("")
        editor.nameBox:Hide()
        UI.Refresh()
    end)
    nameBox:SetPoint("TOPLEFT", tplBtn, "BOTTOMLEFT", 0, -4)
    nameBox:Hide()
    editor.nameBox = nameBox

    local body = UI.MultiLineBox(editor, EDITOR_WIDTH - 20, 90, function(text)
        state.message = text
        UI.Refresh()
    end)
    body:SetPoint("TOPLEFT", tplBtn, "BOTTOMLEFT", 0, -30)

    local hint = UI.Label(editor, "{name} {key} {dungeon} {mykeylevel} {tier} {runs} {me}", 10, { 0.5, 0.5, 0.58 })
    hint:SetPoint("TOPLEFT", body, "BOTTOMLEFT", 2, -4)
    hint:SetWidth(EDITOR_WIDTH - 20)

    local logLabel = UI.Label(editor, "Recently sent", 11, UI.COLORS.header)
    logLabel:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", -2, -10)

    local logList = UI.ScrollList(page, 16, function(parent)
        local row = UI.MakeRow(parent)
        row.text = UI.Label(row, "", 10, { 0.7, 0.7, 0.76 })
        row.text:SetPoint("LEFT", 6, 0)
        row.text:SetWordWrap(false)
        return row
    end, function(row, rec)
        row.text:SetText(string.format("|cff8a8a95%s|r %s: %s",
            date("%H:%M", rec.t), ns.ShortName(rec.name or "?"), rec.text or ""))
    end)
    logList:SetParent(editor)
    logList:SetPoint("TOPLEFT", logLabel, "BOTTOMLEFT", -4, -2)
    logList:SetPoint("BOTTOMRIGHT", editor, "BOTTOMRIGHT", -8, 40)

    local sendBtn = UI.Button(editor, "Send", 120, function()
        local count = selectedCount()
        if count == 0 then
            ns.Print("nothing selected.")
            return
        end
        if ns.Sender.IsSending() then
            ns.Sender.Cancel()
            state.status = "cancelled."
            UI.Refresh()
            return
        end

        local queued, err = ns.Sender.SendBatch(state.entries, function(what, entry, remaining)
            if what == "done" then
                state.status = "send complete."
            elseif entry then
                state.status = string.format("%s %s (%d left)", what, ns.ShortName(entry.person.name), remaining)
            end
            UI.Refresh()
        end)
        if queued == 0 then
            ns.Print(err or "nothing to send.")
        else
            state.status = string.format("sending to %d...", queued)
        end
        UI.Refresh()
    end)
    sendBtn:SetPoint("BOTTOMLEFT", 10, 10)

    local status = UI.Label(editor, "", 10, { 0.7, 0.66, 0.8 })
    status:SetPoint("LEFT", sendBtn, "RIGHT", 8, 0)
    status:SetWidth(EDITOR_WIDTH - 145)

    ----------------------------------------------------------------------------
    -- Recipient list
    ----------------------------------------------------------------------------
    local recipients = UI.ScrollList(page, 34, function(parent)
        local row = UI.MakeRow(parent)

        row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
        row.check:SetSize(20, 20)
        row.check:SetPoint("LEFT", 4, 0)
        row.check:SetScript("OnClick", function(self)
            local entry = row.entry
            if not entry then return end
            if self:GetChecked() then
                state.deselected[entry.person.id] = nil
            else
                state.deselected[entry.person.id] = true
            end
            UI.Refresh()
        end)

        row.name = UI.Label(row, "", 12)
        row.name:SetPoint("TOPLEFT", 28, -3)
        row.name:SetWidth(150)
        row.name:SetWordWrap(false)

        row.msg = UI.Label(row, "", 10, { 0.68, 0.68, 0.74 })
        row.msg:SetPoint("TOPLEFT", 28, -18)
        row.msg:SetPoint("RIGHT", row, "RIGHT", -170, 0)
        row.msg:SetWordWrap(false)

        row.reply = UI.Label(row, "", 10, { 0.6, 0.85, 0.7 })
        row.reply:SetPoint("TOPRIGHT", -110, -3)
        row.reply:SetWidth(180)
        row.reply:SetJustifyH("RIGHT")
        row.reply:SetWordWrap(false)

        row.yes = UI.Button(row, "y", 20, function()
            if row.entry then ns.Replies.Mark(row.entry.person, "yes") end
        end)
        row.yes:SetPoint("TOPRIGHT", -84, -6)
        row.yes:SetHeight(18)

        row.no = UI.Button(row, "n", 20, function()
            if row.entry then ns.Replies.Mark(row.entry.person, "no") end
        end)
        row.no:SetPoint("LEFT", row.yes, "RIGHT", 2, 0)

        row.invite = UI.Button(row, "invite", 52, function()
            if row.entry then
                ns.Replies.Invite(row.entry.person)
                ns.Print("invited", ns.ShortName(row.entry.person.name))
            end
        end)
        row.invite:SetPoint("LEFT", row.no, "RIGHT", 2, 0)
        row.invite:SetHeight(18)

        return row
    end, function(row, entry)
        row.entry = entry
        local char = entry.character
        local tier = ns.Roster.EffectiveTier(entry.person)

        row.check:SetChecked(entry.selected and not entry.blocked)
        row.check:SetEnabled(not entry.blocked)

        local label = string.format("%s %s", ns.TIER_ICON[tier] or "", ns.ShortName(entry.person.name))
        if entry.online and entry.online.bnet then label = label .. " |cff82c5ffBN|r" end
        row.name:SetText(ns.Colorize(label, char and ns.ClassColor(char.classFile)))

        if entry.blocked then
            row.msg:SetText("|cffff8080blocked:|r " .. entry.blocked)
            row.name:SetAlpha(0.5)
            row.msg:SetAlpha(0.8)
        else
            row.msg:SetText(entry.message or "")
            row.name:SetAlpha(1)
            row.msg:SetAlpha(1)
        end

        local reply = ns.Replies.Get(entry.person)
        if reply and reply.reply then
            local mark = reply.marked == "yes" and "|cff5fd68f[y]|r "
                      or reply.marked == "no" and "|cffff6666[n]|r " or ""
            row.reply:SetText(mark .. "|cffffffff" .. reply.reply.text .. "|r")
            row.yes:Show(); row.no:Show(); row.invite:Show()
        else
            row.reply:SetText("")
            row.yes:Hide(); row.no:Hide()
            row.invite:SetShown(reply ~= nil)
        end
    end)
    recipients:SetPoint("TOPLEFT", 8, -56)
    recipients:SetPoint("BOTTOMRIGHT", editor, "BOTTOMLEFT", -8, 8)

    local empty = UI.Label(page, "", 12, { 0.55, 0.55, 0.62 })
    empty:SetPoint("TOPLEFT", recipients, "TOPLEFT", 8, -8)
    empty:SetWidth(400)

    ----------------------------------------------------------------------------
    page.Refresh = function()
        groupBtn:Refresh(); tplBtn:Refresh()

        if not body.editBox:HasFocus() and body.editBox:GetText() ~= currentText() then
            body.editBox:SetText(currentText())
        end

        local entries = rebuildEntries()
        recipients:SetData(entries)

        local blocked = 0
        for _, e in ipairs(entries) do if e.blocked then blocked = blocked + 1 end end
        summary:SetText(string.format("%d online match%s  -  |cff9b7fd6%d selected|r%s",
            #entries, #entries == 1 and "" or "es", selectedCount(),
            blocked > 0 and string.format("  -  %d blocked", blocked) or ""))

        sendBtn:SetText(ns.Sender.IsSending() and "Cancel" or ("Send to " .. selectedCount()))
        status:SetText(state.status or "")

        local log = {}
        local src = ns.Sender.SentLog()
        for i = #src, math.max(1, #src - 60), -1 do log[#log + 1] = src[i] end
        logList:SetData(log)

        empty:SetText(#entries == 0
            and "nobody online matches. try a different group, or |cffffff00/pugdebug roster|r for test data."
            or "")
    end
end

ns.OnInit(function()
    UI.RegisterTab("Send", 30, build)
end)
