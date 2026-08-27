-- UI/RosterPanel.lua -- the sortable roster table, filter builder and detail pane.

local ADDON, ns = ...
local UI = ns.UI

local panel = {}
ns.RosterPanel = panel

local ROW_HEIGHT = 34
local DETAIL_WIDTH = 300

-- Widths total under the list's ~584px so the last column is not clipped by the
-- scrollbar. Name and Spec gave up the room the LS-RIO column needed.
local COLUMNS = {
    { key = "name",  label = "Name",  width = 175 },
    { key = "role",  label = "Role",  width = 56 },
    { key = "spec",  label = "Spec",  width = 74 },
    { key = "ilvl",  label = "ilvl",  width = 42 },
    { key = "rio",   label = "RIO",   width = 48 },
    { key = "rioPrev", label = "LS-RIO", width = 52 },
    { key = "tier",  label = "Tier",  width = 62 },
    { key = "runs",  label = "Runs",  width = 42 },
    { key = "last",  label = "Last",  width = 60 },
}

local state = {
    sortKey = "tier",
    sortAsc = false,
    filter  = nil,
    selected = nil,      -- personId
    builder = { field = "tag", op = "has", value = "" },
}

-- The Send tab borrows this, so a filter built here can be messaged from there.
-- Declared after `state`: defined above it, the body would resolve `state` as a
-- nil global rather than this local.
function panel.CurrentFilter() return state.filter end

--------------------------------------------------------------------------------
-- Row data
--------------------------------------------------------------------------------

local TIER_ORDER = { Great = 4, Good = 3, Neutral = 2, Avoid = 1 }

local function rowFor(person)
    local char = ns.Roster.MainCharacter(person)
    local tier, source = ns.Roster.EffectiveTier(person)
    local rio, rioPrev = 0, 0
    if char then rio, rioPrev = ns.Lookup.RIO(char.guid) end
    return {
        person = person,
        char   = char,
        name     = person.name or "?",
        fullName = (function()
            local c = ns.Roster.MainCharacter(person)
            return c and c.name or person.name or "?"
        end)(),
        role   = char and char.role or "",
        spec   = char and char.specName or "",
        ilvl   = char and char.ilvl or 0,
        rio     = rio or 0,
        rioPrev = rioPrev or 0,
        tier   = tier,
        tierSource = source,
        runs   = ns.Roster.RunsTogether(person),
        last   = ns.Roster.LastPlayedWith(person) or 0,
    }
end

local function buildRows()
    local rows = {}
    for _, person in ipairs(ns.Filters.Apply(state.filter)) do
        -- You are in your own runs, so you end up in your own roster. Rating
        -- yourself against yourself is meaningless, so leave yourself out.
        if not ns.Roster.IsSelf(person) then
            rows[#rows + 1] = rowFor(person)
        end
    end

    local key, asc = state.sortKey, state.sortAsc
    table.sort(rows, function(a, b)
        local x, y = a[key], b[key]
        if key == "tier" then x, y = TIER_ORDER[a.tier] or 0, TIER_ORDER[b.tier] or 0 end
        if x == y then return (a.name or "") < (b.name or "") end
        if type(x) == "number" and type(y) == "number" then
            if asc then return x < y else return x > y end
        end
        x, y = tostring(x), tostring(y)
        if asc then return x < y else return x > y end
    end)
    return rows
end

--------------------------------------------------------------------------------
-- Filter bar
--------------------------------------------------------------------------------

local function addCondition()
    local b = state.builder
    if (b.value or "") == "" then
        ns.Print("enter a value for the condition first.")
        return
    end
    state.filter = state.filter or ns.Filters.New()

    local value = b.value
    if ns.Filters.FieldType(b.field) == "number" then value = tonumber(value) or 0 end
    table.insert(state.filter.conditions, { field = b.field, op = b.op, value = value })
    UI.Refresh()
end

function panel.AddTagToFilter(tag)
    state.filter = state.filter or ns.Filters.New()
    for _, cond in ipairs(state.filter.conditions) do
        if cond.field == "tag" and cond.value == tag then return end
    end
    table.insert(state.filter.conditions, { field = "tag", op = "has", value = tag })
    UI.Refresh()
end

local function buildFilterBar(parent, page)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetPoint("TOPLEFT", 8, -8)
    bar:SetPoint("TOPRIGHT", -8, -8)
    bar:SetHeight(52)

    local fieldBtn = UI.MenuButton(bar, 110,
        function()
            local _, def = ns.Filters.FieldType(state.builder.field)
            return def and def.label or state.builder.field
        end,
        function()
            local entries = {}
            for _, f in ipairs(ns.Filters.FIELDS) do
                entries[#entries + 1] = {
                    text = f.label,
                    checked = state.builder.field == f.key,
                    func = function()
                        state.builder.field = f.key
                        state.builder.op = ns.Filters.OPS[f.type][1]
                        state.builder.value = ""
                        UI.Refresh()
                    end,
                }
            end
            return entries
        end)
    fieldBtn:SetPoint("TOPLEFT", 0, 0)

    local opBtn = UI.MenuButton(bar, 70,
        function() return state.builder.op end,
        function()
            local entries = {}
            local t = ns.Filters.FieldType(state.builder.field)
            for _, op in ipairs(ns.Filters.OPS[t] or {}) do
                entries[#entries + 1] = {
                    text = op, checked = state.builder.op == op,
                    func = function() state.builder.op = op; UI.Refresh() end,
                }
            end
            return entries
        end)
    opBtn:SetPoint("LEFT", fieldBtn, "RIGHT", 4, 0)

    -- Value: a menu for tag/enum fields, a typed box for everything else.
    local valueBtn = UI.MenuButton(bar, 150,
        function()
            if state.builder.value == "" then return "choose..." end
            return ns.Filters.ValueLabel(state.builder.field, state.builder.value)
        end,
        function()
            local entries = {}
            local t, def = ns.Filters.FieldType(state.builder.field)
            local values = t == "tag" and ns.Roster.AllTags() or (def and def.values) or {}
            for _, v in ipairs(values) do
                entries[#entries + 1] = {
                    -- Label for reading, value for matching.
                    text = ns.Filters.ValueLabel(state.builder.field, v),
                    checked = state.builder.value == v,
                    func = function() state.builder.value = v; UI.Refresh() end,
                }
            end
            if #entries == 0 then entries[1] = { text = "(no values yet)" } end
            return entries
        end)
    valueBtn:SetPoint("LEFT", opBtn, "RIGHT", 4, 0)

    local valueBox = UI.EditBox(bar, 150, function() addCondition() end)
    valueBox:SetPoint("LEFT", opBtn, "RIGHT", 4, 0)
    valueBox:SetScript("OnTextChanged", function(self) state.builder.value = self:GetText() end)

    local addBtn = UI.Button(bar, "Add", 50, addCondition)
    addBtn:SetPoint("LEFT", valueBtn, "RIGHT", 4, 0)

    local matchBtn = UI.MenuButton(bar, 60,
        function() return state.filter and state.filter.match or "all" end,
        function()
            return {
                { text = "all", func = function()
                    state.filter = state.filter or ns.Filters.New()
                    state.filter.match = "all"; UI.Refresh() end },
                { text = "any", func = function()
                    state.filter = state.filter or ns.Filters.New()
                    state.filter.match = "any"; UI.Refresh() end },
            }
        end)
    matchBtn:SetPoint("LEFT", addBtn, "RIGHT", 10, 0)

    local clearBtn = UI.Button(bar, "Clear", 55, function()
        state.filter = nil
        UI.Refresh()
    end)
    clearBtn:SetPoint("LEFT", matchBtn, "RIGHT", 4, 0)

    local groupBtn = UI.MenuButton(bar, 110,
        function() return "Saved groups" end,
        function()
            local entries = {}
            for _, name in ipairs(ns.Filters.ListGroups()) do
                entries[#entries + 1] = {
                    text = name,
                    func = function() state.filter = ns.Filters.GetGroup(name); UI.Refresh() end,
                }
            end
            if #entries > 0 then entries[#entries + 1] = { text = "---" } end
            entries[#entries + 1] = { text = "Save current as...", func = function()
                page.saveBox:Show(); page.saveBox:SetFocus()
            end }
            for _, name in ipairs(ns.Filters.ListGroups()) do
                entries[#entries + 1] = { text = "Delete: " .. name, func = function()
                    ns.Filters.DeleteGroup(name); UI.Refresh()
                end }
            end
            return entries
        end)
    groupBtn:SetPoint("LEFT", clearBtn, "RIGHT", 4, 0)

    local saveBox = UI.EditBox(bar, 150, function(text)
        if text and text ~= "" then
            ns.Filters.SaveGroup(text, state.filter or ns.Filters.New())
            ns.Print("saved group", text)
        end
        page.saveBox:SetText("")
        page.saveBox:Hide()
        UI.Refresh()
    end)
    saveBox:SetPoint("LEFT", groupBtn, "RIGHT", 4, 0)
    saveBox:Hide()
    page.saveBox = saveBox

    local desc = UI.Label(bar, "", 11, { 0.65, 0.62, 0.72 })
    desc:SetPoint("TOPLEFT", fieldBtn, "BOTTOMLEFT", 2, -6)
    desc:SetPoint("RIGHT", bar, "RIGHT", -4, 0)

    bar.Refresh = function()
        fieldBtn:Refresh(); opBtn:Refresh(); valueBtn:Refresh(); matchBtn:Refresh()
        local t = ns.Filters.FieldType(state.builder.field)
        local useMenu = (t == "tag" or t == "enum")
        valueBtn:SetShown(useMenu)
        valueBox:SetShown(not useMenu)
        addBtn:ClearAllPoints()
        addBtn:SetPoint("LEFT", useMenu and valueBtn or valueBox, "RIGHT", 4, 0)

        local n = #ns.Filters.Apply(state.filter)
        desc:SetText(string.format("|cff9b7fd6%d|r shown  -  %s", n, ns.Filters.Describe(state.filter)))
    end

    return bar
end

--------------------------------------------------------------------------------
-- Detail pane
--------------------------------------------------------------------------------

local function buildDetail(parent)
    local d = CreateFrame("Frame", nil, parent)
    d:SetWidth(DETAIL_WIDTH)
    UI.Backdrop(d, { 0, 0, 0, 0.25 })

    local name = UI.Label(d, "", 14, { 0.9, 0.88, 0.95 })
    name:SetPoint("TOPLEFT", 10, -10)

    local sub = UI.Label(d, "", 11, { 0.6, 0.6, 0.68 })
    sub:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -3)

    local tierBtn = UI.MenuButton(d, 130, function()
        local person = ns.Roster.GetPerson(state.selected)
        if not person then return "Tier" end
        local tier, source = ns.Roster.EffectiveTier(person)
        return string.format("%s (%s)", tier, source)
    end, function()
        local person = ns.Roster.GetPerson(state.selected)
        local entries = { { text = "auto (clear override)", func = function()
            ns.Roster.SetTierOverride(person, nil); UI.Refresh() end } }
        for _, tier in ipairs(ns.TIERS) do
            entries[#entries + 1] = { text = "override: " .. tier, func = function()
                ns.Roster.SetTierOverride(person, tier); UI.Refresh() end }
        end
        return entries
    end)
    tierBtn:SetPoint("TOPLEFT", sub, "BOTTOMLEFT", 0, -8)

    local tagBtn = UI.MenuButton(d, 130, function() return "Tags..." end, function()
        local person = ns.Roster.GetPerson(state.selected)
        if not person then return {} end
        local byCat, order = ns.Roster.TagsByCategory()
        local entries = {}
        for _, cat in ipairs(order) do
            entries[#entries + 1] = { text = "|cff7a7a88" .. cat .. "|r" }
            for _, tag in ipairs(byCat[cat]) do
                entries[#entries + 1] = {
                    text = tag, checked = ns.Roster.HasTag(person, tag),
                    func = function() ns.Roster.ToggleTag(person, tag); UI.Refresh() end,
                }
            end
        end
        return entries
    end)
    tagBtn:SetPoint("LEFT", tierBtn, "RIGHT", 6, 0)

    local newTag = UI.EditBox(d, DETAIL_WIDTH - 20, function(text)
        local person = ns.Roster.GetPerson(state.selected)
        if person and text and text ~= "" then
            ns.Roster.AddTag(person, text)
            ns.Print("tagged", person.name, "as", text)
        end
        UI.Refresh()
    end)
    newTag:SetPoint("TOPLEFT", tierBtn, "BOTTOMLEFT", 0, -8)

    local newTagHint = UI.Label(d, "add a custom tag, enter to apply", 10, { 0.45, 0.45, 0.52 })
    newTagHint:SetPoint("TOPLEFT", newTag, "BOTTOMLEFT", 2, -2)

    local noteLabel = UI.Label(d, "Note", 11, UI.COLORS.header)
    noteLabel:SetPoint("TOPLEFT", newTagHint, "BOTTOMLEFT", -2, -8)

    local note = UI.MultiLineBox(d, DETAIL_WIDTH - 20, 70, function(text)
        local person = ns.Roster.GetPerson(state.selected)
        if person then ns.Roster.SetNote(person, text) end
    end)
    note:SetPoint("TOPLEFT", noteLabel, "BOTTOMLEFT", 0, -4)

    local charsLabel = UI.Label(d, "Characters", 11, UI.COLORS.header)
    charsLabel:SetPoint("TOPLEFT", note, "BOTTOMLEFT", 0, -8)

    local chars = UI.Label(d, "", 11, { 0.75, 0.75, 0.8 })
    chars:SetPoint("TOPLEFT", charsLabel, "BOTTOMLEFT", 0, -4)
    chars:SetWidth(DETAIL_WIDTH - 20)
    chars:SetJustifyV("TOP")

    -- Adding a friend is what makes someone's online status visible, which is
    -- otherwise only knowable for Battle.net friends, character friends and
    -- guildmates. Always add by "Name-Realm": cross-realm friends are ordinary in
    -- retail, and the realm is part of the identity anyway.
    --
    -- The server answers asynchronously and refuses with "Player not found" for a
    -- character that is not currently online, so check the friends list a moment
    -- later and report what actually happened rather than claiming success.
    local friendBtn = UI.Button(d, "Add friend", 100, function()
        local person = ns.Roster.GetPerson(state.selected)
        local char = person and ns.Roster.MainCharacter(person)
        if not char or not char.name then return end

        if not (C_FriendList and C_FriendList.AddFriend) then
            ns.Print("this client has no AddFriend API. Use |cffffff00/friend "
                .. char.name .. "|r")
            return
        end

        C_FriendList.AddFriend(char.name)
        C_Timer.After(2, function()
            if ns.Roster.IsFriend(char.name) then
                ns.Print("added |cff9b7fd6" .. char.name .. "|r to your friends list.")
            else
                ns.Print(string.format("could not add %s. The server only accepts a "
                    .. "friend request while that character is online -- try again "
                    .. "when they are.", char.name))
            end
            UI.Refresh()
        end)
    end)
    friendBtn:SetPoint("TOPLEFT", chars, "BOTTOMLEFT", -2, -6)
    friendBtn:SetHeight(18)

    local linkBtn = UI.MenuButton(d, 130, function() return "Same person as..." end, function()
        local person = ns.Roster.GetPerson(state.selected)
        local myChar = ns.Roster.MainCharacter(person)
        if not myChar then return {} end
        local entries = {}
        for _, other in ipairs(ns.Roster.AllPersons()) do
            if other.id ~= person.id then
                local oc = ns.Roster.MainCharacter(other)
                if oc then
                    entries[#entries + 1] = { text = other.name, func = function()
                        ns.Roster.LinkCharacters(myChar.guid, oc.guid)
                        UI.Refresh()
                    end }
                end
            end
        end
        if #entries == 0 then entries[1] = { text = "(nobody else known)" } end
        return entries
    end)
    linkBtn:SetPoint("TOPLEFT", chars, "BOTTOMLEFT", 0, -60)

    local unlinkBtn = UI.Button(d, "Unlink main", 130, function()
        local person = ns.Roster.GetPerson(state.selected)
        local char = ns.Roster.MainCharacter(person)
        if char then ns.Roster.UnlinkCharacter(char.guid); UI.Refresh() end
    end)
    unlinkBtn:SetPoint("LEFT", linkBtn, "RIGHT", 6, 0)

    local whyLabel = UI.Label(d, "Why this tier", 11, UI.COLORS.header)
    whyLabel:SetPoint("TOPLEFT", linkBtn, "BOTTOMLEFT", 0, -10)

    local why = UI.Label(d, "", 10, { 0.7, 0.7, 0.76 })
    why:SetPoint("TOPLEFT", whyLabel, "BOTTOMLEFT", 0, -4)
    why:SetWidth(DETAIL_WIDTH - 20)
    why:SetJustifyV("TOP")

    local msgBtn = UI.Button(d, "Message", 90, function()
        local person = ns.Roster.GetPerson(state.selected)
        if person then
            ns.SendPanel.SeedWithPerson(person)
            UI.Show("Send")
        end
    end)
    msgBtn:SetPoint("BOTTOMLEFT", 10, 10)

    local histBtn = UI.Button(d, "History", 90, function()
        local person = ns.Roster.GetPerson(state.selected)
        if person then
            ns.HistoryPanel.FocusPerson(person)
            UI.Show("History")
        end
    end)
    histBtn:SetPoint("LEFT", msgBtn, "RIGHT", 6, 0)

    d.Refresh = function()
        local person = ns.Roster.GetPerson(state.selected)
        if not person then
            name:SetText("|cff6a6a75select someone|r")
            sub:SetText("")
            chars:SetText("")
            why:SetText("")
            note.editBox:SetText("")
            return
        end

        local char = ns.Roster.MainCharacter(person)
        name:SetText(ns.NameWithRealm(char and char.name or person.name,
            char and ns.ClassColor(char.classFile)) .. ns.SimTag(person))
        sub:SetText(string.format("%d runs together  -  last %s",
            ns.Roster.RunsTogether(person), ns.TimeAgo(ns.Roster.LastPlayedWith(person))))

        tierBtn:Refresh()

        if note.editBox:GetText() ~= (person.note or "") and not note.editBox:HasFocus() then
            note.editBox:SetText(person.note or "")
        end

        local lines = {}
        for guid in pairs(person.characters) do
            local c = ns.Roster.GetCharacter(guid)
            if c then
                local rio = select(1, ns.Lookup.RIO(guid))
                lines[#lines + 1] = string.format("%s  %s%s%s",
                    ns.Colorize(c.name or "?", ns.ClassColor(c.classFile)),
                    c.specName or "",
                    c.ilvl and (" " .. c.ilvl) or "",
                    rio and rio > 0 and ("  rio " .. math.floor(rio)) or "")
            end
        end
        table.sort(lines)
        chars:SetText(table.concat(lines, "\n"))

        local breakdown = char and ns.Rating.Breakdown(char.guid)
        if breakdown and breakdown.runs > 0 then
            local out = { string.format("score %.2f over %d runs -> %s",
                breakdown.score, breakdown.runs, breakdown.tier) }
            for i = #breakdown.lines, math.max(1, #breakdown.lines - 3), -1 do
                local line = breakdown.lines[i]
                out[#out + 1] = string.format("  %s  %+.2f (w %.2f)", line.header, line.value, line.weight)
            end
            why:SetText(table.concat(out, "\n"))
        else
            why:SetText("no runs recorded yet")
        end
    end

    return d
end

--------------------------------------------------------------------------------
-- Panel
--------------------------------------------------------------------------------

local function build(page)
    local filterBar = buildFilterBar(page, page)
    local detail = buildDetail(page)
    detail:SetPoint("TOPRIGHT", -8, -66)
    detail:SetPoint("BOTTOMRIGHT", -8, 8)

    -- Column headers
    local header = CreateFrame("Frame", nil, page)
    header:SetPoint("TOPLEFT", 8, -66)
    header:SetPoint("TOPRIGHT", detail, "TOPLEFT", -8, 0)
    header:SetHeight(20)

    local x = 0
    for _, col in ipairs(COLUMNS) do
        local b = UI.Button(header, col.label, col.width, nil)
        b:SetPoint("LEFT", x, 0)
        b:SetHeight(18)
        b.label:SetTextColor(unpack(UI.COLORS.header))
        b.bg:SetColorTexture(0, 0, 0, 0)
        b:SetScript("OnClick", function()
            if state.sortKey == col.key then state.sortAsc = not state.sortAsc
            else state.sortKey, state.sortAsc = col.key, false end
            UI.Refresh()
        end)
        b:SetScript("OnEnter", function(self) self.label:SetTextColor(1, 1, 1) end)
        b:SetScript("OnLeave", function(self) self.label:SetTextColor(unpack(UI.COLORS.header)) end)
        x = x + col.width
    end

    local list = UI.ScrollList(page, ROW_HEIGHT, function(parent)
        local row = UI.MakeRow(parent)

        row.cells = {}
        local cx = 0
        for _, col in ipairs(COLUMNS) do
            local fs = UI.Label(row, "", 12)
            fs:SetPoint("TOPLEFT", cx + 2, -3)
            fs:SetWidth(col.width - 4)
            fs:SetWordWrap(false)
            row.cells[col.key] = fs
            cx = cx + col.width
        end

        row.chipArea = CreateFrame("Frame", nil, row)
        row.chipArea:SetPoint("TOPLEFT", 2, -19)
        row.chipArea:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row.chipArea:SetHeight(15)

        row:SetScript("OnClick", function(self)
            state.selected = self.item and self.item.person.id or nil
            UI.Refresh()
        end)
        return row
    end, function(row, item)
        row.item = item
        row.cells.name:SetText(ns.NameWithRealm(item.fullName,
            item.char and ns.ClassColor(item.char.classFile)) .. ns.SimTag(item.person))
        row.cells.role:SetText(ns.RoleLabel(item.role))
        row.cells.spec:SetText(item.spec ~= "" and item.spec or "-")
        row.cells.ilvl:SetText(item.ilvl > 0 and tostring(item.ilvl) or "-")
        row.cells.rio:SetText(item.rio > 0 and tostring(math.floor(item.rio)) or "-")
        -- Last season is on a different scale from this one, so it carries
        -- RaiderIO's own previous-season colour rather than sitting in the same
        -- white as the current score.
        if item.rioPrev > 0 then
            local c = ns.RaiderIOBridge.ScoreColor(item.rioPrev, true)
            local text = tostring(math.floor(item.rioPrev))
            row.cells.rioPrev:SetText(c and ns.Colorize(text, c) or text)
        else
            row.cells.rioPrev:SetText("-")
        end
        row.cells.tier:SetText(ns.TierText(item.tier) .. (item.tierSource == "override" and "*" or ""))
        row.cells.runs:SetText(tostring(item.runs))
        row.cells.last:SetText(item.last > 0 and ns.TimeAgo(item.last) or "-")

        UI.LayoutChips(row.chipArea, UI.ChipList(item.person),
            row.chipArea:GetWidth() > 0 and row.chipArea:GetWidth() or 400,
            function(tag) panel.AddTagToFilter(tag) end)

        if state.selected == item.person.id then
            row.stripe:SetColorTexture(0.36, 0.26, 0.50, 0.5)
        end
    end)
    list:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -2)
    list:SetPoint("BOTTOMRIGHT", detail, "BOTTOMLEFT", -8, 8)

    local empty = UI.Label(page, "", 12, { 0.55, 0.55, 0.62 })
    empty:SetPoint("TOPLEFT", list, "TOPLEFT", 8, -8)

    page.Refresh = function()
        filterBar.Refresh()
        local rows = buildRows()
        list:SetData(rows)
        detail.Refresh()
        if #rows == 0 then
            empty:SetText(next(ns.db.characters)
                and "no one matches this filter."
                or "no runs recorded yet -- finish a key (or try /pugdebug seed 20).")
        else
            empty:SetText("")
        end
    end
end

ns.OnInit(function()
    UI.RegisterTab("Roster", 10, build)
end)
