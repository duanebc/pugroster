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
    -- The key the message is recruiting for. nil follows the selected template
    -- the way `message` does; `false` is an edit that cleared it, which nil
    -- cannot express -- without the distinction, choosing "(no dungeon)" would
    -- silently snap back to whatever the template had saved.
    keyMapID = nil,
    keyLevel = nil,
    entries  = {},
    selected = {},         -- [personId] = true, survives refreshes
    status   = "",
    logScrollX = 0,        -- how far the sent log is scrolled right
}

-- How many rows a dropdown may use before it wraps into another column. The
-- window is 580 tall and a row is 20, so this keeps even a full template list
-- inside it rather than clamped over the top of everything.
local MENU_ROWS = 14

-- Key levels offered in the level menu. Below +2 is not a keystone.
local LEVEL_MIN, LEVEL_MAX = 2, 30

-- Seeded from the roster panel: message exactly one person.
function panel.SeedWithPerson(person)
    state.filter = { match = "all", conditions = { { field = "name", op = "is", value = person.name } } }
    -- Asking to message one person is asking for them to be selected.
    wipe(state.selected)
    state.selected[person.id] = true
    state.status = ""
end

local function currentText()
    if state.message then return state.message end
    local t = ns.db.templates[state.template]
    return t and t.text or ""
end

-- The key in effect right now: the unsaved edit if there is one, otherwise
-- whatever the selected template carries. `false` means an edit cleared it, so
-- it collapses to nil rather than falling through to the template's value.
local function currentKey()
    local t = ns.db.templates[state.template]
    local mapID, level = state.keyMapID, state.keyLevel
    if mapID == nil then mapID = t and t.mapID end
    if level == nil then level = t and t.level end
    return mapID or nil, level or nil
end

-- Drop every unsaved edit and go back to showing the selected template as saved.
local function followTemplate()
    state.message  = nil
    state.keyMapID = nil
    state.keyLevel = nil
end

local function rebuildEntries()
    state.entries = ns.Sender.BuildRecipients(state.filter, currentText(),
                        ns.Templates.KeyContext(currentKey()))
    for _, entry in ipairs(state.entries) do
        entry.selected = state.selected[entry.person.id] and not entry.blocked or false
    end
    return state.entries
end

-- Echo mode is on by default in a development build: EchoSender replaces the
-- dispatch, prints the message locally, and nothing leaves the client -- while
-- the queue, cooldown and sent log all behave exactly as a real send would. That
-- is how a message can be reported sent and never arrive, so the Send tab has to
-- say so in more than one place. Feature-detected, so a released build (which has
-- no Debug/ at all) never shows any of it.
local function echoing()
    return ns.EchoSender and ns.EchoSender.IsEnabled() and true or false
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
            state.filter = nil; wipe(state.selected); UI.Refresh() end } }

        -- The Roster tab has the filter builder; this tab only had saved groups,
        -- so a filter you had just built there did nothing here until you saved
        -- it. Borrow it directly.
        local rosterFilter = ns.RosterPanel and ns.RosterPanel.CurrentFilter()
        if rosterFilter and rosterFilter.conditions and #rosterFilter.conditions > 0 then
            entries[#entries + 1] = {
                text = "Roster filter: " .. ns.Filters.Describe(rosterFilter):sub(1, 30),
                func = function()
                    state.filter = rosterFilter
                    wipe(state.selected)
                    UI.Refresh()
                end,
            }
        end

        for _, name in ipairs(ns.Filters.ListGroups()) do
            entries[#entries + 1] = { text = name, func = function()
                state.filter = ns.Filters.GetGroup(name); wipe(state.selected); UI.Refresh() end }
        end
        if #entries == 1 then
            entries[#entries + 1] = { text = "(save groups in the Roster tab)" }
        end
        return entries
    end)
    groupBtn:SetPoint("TOPLEFT", 10, -10)

    local refreshBtn = UI.Button(page, "Refresh online", 110, function() UI.Refresh() end)
    refreshBtn:SetPoint("LEFT", groupBtn, "RIGHT", 6, 0)

    -- Both buttons are no-ops when every match is blocked, which looks exactly
    -- like a dead button. Say what happened instead of leaving the list to
    -- explain itself.
    local function reportNothingSelectable()
        if #state.entries > 0 and selectedCount() == 0 then
            ns.Print(string.format("nothing selectable: all %d matches are blocked.", #state.entries))
        end
    end

    local selectAll = UI.Button(page, "Select all", 90, function()
        for _, e in ipairs(state.entries) do
            if not e.blocked then state.selected[e.person.id] = true end
        end
        UI.Refresh()
        reportNothingSelectable()
    end)
    selectAll:SetPoint("LEFT", refreshBtn, "RIGHT", 6, 0)

    local selectNone = UI.Button(page, "Select none", 90, function()
        wipe(state.selected)
        UI.Refresh()
    end)
    selectNone:SetPoint("LEFT", selectAll, "RIGHT", 6, 0)

    -- The re-message cooldown is a courtesy guard against pestering people, so
    -- there has to be a way to lift it for someone you actually need to reach.
    -- It applies to whoever is listed right now, so filter first to narrow it.
    local clearCd = UI.Button(page, "Clear cooldowns", 120, function()
        local cleared = 0
        for _, e in ipairs(state.entries) do
            if ns.Sender.ClearCooldown(e.person) then cleared = cleared + 1 end
        end
        UI.Refresh()
        ns.Print(cleared > 0
            and string.format("cleared the message cooldown for %d listed %s.",
                cleared, cleared == 1 and "person" or "people")
            or "no one listed was on cooldown.")
    end)
    clearCd:SetPoint("LEFT", selectNone, "RIGHT", 6, 0)

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
                followTemplate()
                editor.HideNameRow()
                UI.Refresh()
            end }
        end
        entries[#entries + 1] = { text = "---" }
        entries[#entries + 1] = { text = "Save current text as new...", func = function()
            editor.ShowNameRow()
        end }
        local cur = ns.db.templates[state.template]
        if cur then
            entries[#entries + 1] = { text = "Overwrite: " .. cur.name, func = function()
                -- The key rides along with the text: overwriting is the only way
                -- to change the dungeon and level a saved template carries.
                local mapID, level = currentKey()
                ns.Templates.Update(state.template, nil, currentText(), mapID, level)
                followTemplate()
                ns.Print("template updated:", cur.name)
                UI.Refresh()
            end }
            entries[#entries + 1] = { text = "Delete: " .. cur.name, func = function()
                ns.Templates.Delete(state.template)
                state.template = 1
                followTemplate()
                editor.HideNameRow()
                UI.Refresh()
            end }
        end
        return entries
    end, MENU_ROWS)
    tplBtn:SetPoint("TOPLEFT", tplLabel, "BOTTOMLEFT", 0, -4)

    ----------------------------------------------------------------------------
    -- Naming a new template
    --
    -- Enter used to be the only way to commit this, with nothing on screen saying
    -- so, and clicking anywhere else threw the typed name away without a word.
    -- Save and Cancel share the row with the box because the row lives in the gap
    -- between the template button and the body -- a second row would be drawn on
    -- top of the body box.
    ----------------------------------------------------------------------------
    local BTN_W  = 54
    local NAME_W = EDITOR_WIDTH - 20 - (BTN_W + 4) * 2

    local nameBox, saveBtn, cancelBtn

    local function commitName(text)
        if text and text ~= "" then
            local mapID, level = currentKey()
            ns.Templates.Add(text, currentText(), mapID, level)
            state.template = #ns.db.templates
            followTemplate()
            ns.Print("template saved:", text)
        end
        editor.HideNameRow()
        UI.Refresh()
    end

    nameBox = UI.EditBox(editor, NAME_W, commitName)
    nameBox:SetPoint("TOPLEFT", tplBtn, "BOTTOMLEFT", 0, -4)

    saveBtn = UI.Button(editor, "Save", BTN_W, function() commitName(nameBox:GetText()) end)
    saveBtn:SetPoint("LEFT", nameBox, "RIGHT", 4, 0)

    cancelBtn = UI.Button(editor, "Cancel", BTN_W, function()
        editor.HideNameRow()
        UI.Refresh()
    end)
    cancelBtn:SetPoint("LEFT", saveBtn, "RIGHT", 4, 0)

    -- The row stays up until Save or Cancel is clicked. Dismissing it when the
    -- box loses focus would look tidier and be unusable: clicking Save is itself
    -- a focus loss, so the button would vanish before its click landed.
    function editor.ShowNameRow()
        nameBox:SetText("")
        nameBox:Show(); saveBtn:Show(); cancelBtn:Show()
        nameBox:SetFocus()
    end

    function editor.HideNameRow()
        nameBox:SetText("")
        nameBox:ClearFocus()
        nameBox:Hide(); saveBtn:Hide(); cancelBtn:Hide()
    end

    editor.HideNameRow()

    local body = UI.MultiLineBox(editor, EDITOR_WIDTH - 20, 90, function(text)
        state.message = text
        UI.Refresh()
    end)
    body:SetPoint("TOPLEFT", tplBtn, "BOTTOMLEFT", 0, -30)

    local hint = UI.Label(editor,
        "{name} {key} {dungeon} {mykeylevel} {tier} {runs} {me}\n"
        .. "{keydungeon} {keylevel} {keyname} -- the key below",
        10, { 0.5, 0.5, 0.58 })
    hint:SetPoint("TOPLEFT", body, "BOTTOMLEFT", 2, -4)
    hint:SetWidth(EDITOR_WIDTH - 20)

    ----------------------------------------------------------------------------
    -- The key this template is recruiting for
    --
    -- Saved on the template, so picking "LFM +15 Dawnbreaker" brings its dungeon
    -- and level back with it. Distinct from {key}/{dungeon}/{mykeylevel}, which
    -- are always the keystone actually sitting in your bags.
    ----------------------------------------------------------------------------
    local keyLabel = UI.Label(editor, "Key for this template", 11, UI.COLORS.header)
    keyLabel:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", -2, -10)

    local dungeonBtn = UI.MenuButton(editor, EDITOR_WIDTH - 20, function()
        local mapID = currentKey()
        return mapID and (ns.DungeonName(mapID) or "(unknown dungeon)") or "(no dungeon)"
    end, function()
        local cur = currentKey()
        local entries = { { text = "(no dungeon)", checked = cur == nil, func = function()
            state.keyMapID = false
            UI.Refresh()
        end } }

        local dungeons = ns.SeasonDungeons()
        if #dungeons == 0 then
            -- The map table is empty until the client sends it, which can be
            -- several seconds after login. Saying so beats an empty menu that
            -- reads as a broken addon.
            entries[#entries + 1] = { text = "|cff8a8a95dungeon list not loaded yet|r" }
        end
        for _, d in ipairs(dungeons) do
            entries[#entries + 1] = { text = d.name, checked = cur == d.id, func = function()
                state.keyMapID = d.id
                UI.Refresh()
            end }
        end
        return entries
    end, MENU_ROWS)
    dungeonBtn:SetPoint("TOPLEFT", keyLabel, "BOTTOMLEFT", 0, -4)

    local levelBtn = UI.MenuButton(editor, EDITOR_WIDTH - 20, function()
        local _, level = currentKey()
        return level and ("+" .. level) or "(no level)"
    end, function()
        local _, cur = currentKey()
        local entries = { { text = "(no level)", checked = cur == nil, func = function()
            state.keyLevel = false
            UI.Refresh()
        end } }
        for lvl = LEVEL_MIN, LEVEL_MAX do
            entries[#entries + 1] = { text = "+" .. lvl, checked = cur == lvl, func = function()
                state.keyLevel = lvl
                UI.Refresh()
            end }
        end
        return entries
    end, MENU_ROWS)
    levelBtn:SetPoint("TOPLEFT", dungeonBtn, "BOTTOMLEFT", 0, -4)

    local logLabel = UI.Label(editor, "Recently sent", 11, UI.COLORS.header)
    logLabel:SetPoint("TOPLEFT", levelBtn, "BOTTOMLEFT", 0, -10)

    local logList = UI.ScrollList(page, 16, function(parent)
        local row = UI.MakeRow(parent)
        row.text = UI.Label(row, "", 10, { 0.7, 0.7, 0.76 })
        row.text:SetWordWrap(false)
        row.text:SetJustifyH("LEFT")
        -- Clicking a sent line opens a whisper to whoever it went to. The chat
        -- notification carries a player link for the same reason; this is the
        -- same affordance where you are already looking.
        row:SetScript("OnClick", function(self)
            local name = self.rec and self.rec.name
            if not name or ns.IsSecret(name) then return end
            if ChatFrame_SendTell then
                ChatFrame_SendTell(name)
            else
                ns.Print("whisper", ns.PlayerLink(name))
            end
        end)
        return row
    end, function(row, rec)
        row.rec = rec
        row.text:SetText(string.format("|cff8a8a95%s|r %s: %s",
            date("%H:%M", rec.t), ns.ShortName(rec.name or "?"), rec.text or ""))

        -- Anchored on both sides so the line is bounded by the row rather than
        -- drawn at its natural width, which is how a long message ended up
        -- painted across the game outside the addon entirely. The left edge
        -- carries the horizontal scroll offset; the list clips what runs past it.
        row.text:ClearAllPoints()
        row.text:SetPoint("LEFT", row, "LEFT", 6 - state.logScrollX, 0)
        row.text:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    end)
    -- Frames do not clip their children by default, so without this the scrolled
    -- text would spill out of the left edge instead of disappearing under it.
    logList:SetClipsChildren(true)
    logList:SetParent(editor)
    logList:SetPoint("TOPLEFT", logLabel, "BOTTOMLEFT", -4, -2)
    logList:SetPoint("BOTTOMRIGHT", editor, "BOTTOMRIGHT", -8, 56)

    local logScroll = UI.HScrollBar(editor, function(value)
        state.logScrollX = value
        logList:Refresh()
    end)
    logScroll:SetPoint("TOPLEFT", logList, "BOTTOMLEFT", 4, -4)
    logScroll:SetPoint("RIGHT", logList, "RIGHT", -26, 0)

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
                state.status = echoing()
                    and "|cffd9a441echoed -- nothing was really sent.|r"
                    or "send complete."
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
                state.selected[entry.person.id] = true
            else
                state.selected[entry.person.id] = nil
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

        local full = char and char.name or entry.person.name
        local label = (ns.TIER_ICON[tier] or "") .. " "
            .. ns.NameWithRealm(full, char and ns.ClassColor(char.classFile))
            .. ns.SimTag(entry.person)
        -- Absence first. `entry.online` is nil for anyone whose status we cannot
        -- see, which is most of the roster -- testing it last means the branches
        -- above it index a nil.
        if not entry.online then
            -- Not "offline": we genuinely cannot see.
            label = label .. " |cff7f7f7fstatus unknown|r"
        elseif entry.online.busy then
            label = label .. " |cffd9a441" .. tostring(entry.online.busy) .. "|r"
        elseif entry.online.bnet then
            label = label .. " |cff82c5ffBN|r"
        end
        row.name:SetText(label)

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
        dungeonBtn:Refresh(); levelBtn:Refresh()

        if not body.editBox:HasFocus() and body.editBox:GetText() ~= currentText() then
            body.editBox:SetText(currentText())
        end

        local entries = rebuildEntries()
        recipients:SetData(entries)

        local blocked = 0
        for _, e in ipairs(entries) do if e.blocked then blocked = blocked + 1 end end
        local known = 0
        for _, e in ipairs(entries) do if e.online then known = known + 1 end end

        summary:SetText(string.format("%d recipient%s (%d confirmed online)  -  "
            .. "|cff9b7fd6%d selected|r%s%s",
            #entries, #entries == 1 and "" or "s", known, selectedCount(),
            blocked > 0 and string.format("  -  %d blocked", blocked) or "",
            echoing() and "   |cffd9a441ECHO MODE: nothing is actually sent|r" or ""))

        sendBtn:SetText(ns.Sender.IsSending() and "Cancel"
            or ((echoing() and "Echo to " or "Send to ") .. selectedCount()))
        status:SetText(state.status or "")

        local log = {}
        local src = ns.Sender.SentLog()
        for i = #src, math.max(1, #src - 60), -1 do log[#log + 1] = src[i] end
        logList:SetData(log)

        -- How far there is to scroll: the widest line, less the space it has.
        -- Measured off a real row so the font and size match what is drawn.
        local widest = 0
        for _, row in ipairs(logList.rows or {}) do
            if row:IsShown() and row.text then
                local w = row.text.GetUnboundedStringWidth
                    and row.text:GetUnboundedStringWidth()
                    or row.text:GetStringWidth()
                if w and w > widest then widest = w end
            end
        end
        logScroll:SetRange(widest - (logList:GetWidth() - 40))

        -- An empty list has several possible causes and they need different
        -- fixes, so say which one happened rather than one generic line.
        if #entries > 0 then
            empty:SetText("")
        else
            local s = ns.Filters.lastSkipped or {}
            local bits = {}
            if (s.considered or 0) == 0 then
                bits[#bits + 1] = "no one in the roster matches this filter"
            else
                bits[#bits + 1] = string.format("%d people considered", s.considered)
            end
            if (s.busy or 0) > 0 then
                bits[#bits + 1] = string.format("|cffd9a441%d busy in a dungeon, raid or "
                    .. "battleground|r (Options -> Messaging to include them)", s.busy)
            end
            if (s.self or 0) > 0 then
                bits[#bits + 1] = string.format("%d of your own characters", s.self)
            end
            if (s.offline or 0) > 0 then
                bits[#bits + 1] = string.format("|cffd9a441%d not confirmed online|r "
                    .. "(Options -> Messaging to offer them anyway)", s.offline)
            end
            if (s.nameless or 0) > 0 then
                bits[#bits + 1] = string.format("%d with no character name", s.nameless)
            end
            empty:SetText(table.concat(bits, "\n"))
        end
    end
end

ns.OnInit(function()
    UI.RegisterTab("Send", 30, build)
end)
