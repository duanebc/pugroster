-- UI/RosterPanel.lua -- the sortable roster table, filter builder and detail pane.

local ADDON, ns = ...
local UI = ns.UI

local panel = {}
ns.RosterPanel = panel

local ROW_HEIGHT = 34
local DETAIL_WIDTH = 300

-- Rows a dropdown may use before it wraps into another column, and the most
-- people the link picker will list at once. Past that it says how many it left
-- out rather than drawing a menu taller than the screen and silently stopping
-- somewhere in the Gs.
local MENU_ROWS = 14
local LINK_MAX  = 30

-- Widths total under the list's ~584px so the last column is not clipped by the
-- scrollbar. Name and Spec gave up the room the LS-RIO column needed.
local COLUMNS = {
    { key = "name",  label = "Name",  width = 155 },
    { key = "role",  label = "Role",  width = 48 },
    { key = "spec",  label = "Spec",  width = 64 },
    { key = "ilvl",  label = "ilvl",  width = 42 },
    -- Three scores, narrowest question first: this character now, this character
    -- last season, and the best the whole account has managed in either. The
    -- third is the one that tells you who you are actually talking to when
    -- somebody brings an alt.
    { key = "rio",   label = "RIO",   width = 48 },
    { key = "rioPrev", label = "LS-RIO", width = 52 },
    { key = "mainRio", label = "M-RIO", width = 50 },
    { key = "tier",  label = "Tier",  width = 58 },
    { key = "runs",  label = "Runs",  width = 42 },
    { key = "last",  label = "Last",  width = 52 },
}

local state = {
    sortKey = "tier",
    sortAsc = false,
    filter  = nil,
    search  = "",        -- free-text name match, narrows whatever the filter left
    linkSearch = "",     -- narrows the "Same person as..." picker, which is
                         -- otherwise every person you have ever met

    selected = nil,      -- personId
    builder = { field = "tag", op = "has", value = "" },
}

-- Substring match on the person and on every character they are known by, so
-- searching a alt's name finds the person you filed them under. Case-insensitive
-- and plain: a name with a "-" in it is the normal case here, not a pattern.
-- Returns whether it matched, and -- when the hit came from one of their
-- characters rather than the person's own name -- which character it was. The
-- caller needs that second value: a person can be filed under one alt's name and
-- contain the character you actually searched for, and a row labelled "Unbroken"
-- is not a useful answer to "san".
local function personMatches(person, needle)
    needle = (needle or ""):lower()
    if needle == "" then return true end
    if (person.name or ""):lower():find(needle, 1, true) then return true end

    -- Alphabetically first of the matches rather than whichever `pairs` reaches
    -- first, so the same search twice shows the same name.
    local best
    for guid in pairs(person.characters or {}) do
        local c = ns.Roster.GetCharacter(guid)
        local cname = c and c.name
        if cname and cname:lower():find(needle, 1, true) then
            if not best or cname < best then best = cname end
        end
    end
    if best then return true, best end
    return false
end

local function matchesSearch(person) return personMatches(person, state.search) end

-- How a person reads in a picker: the name you know them by, and the character
-- behind it when those differ. Someone whose person record never got a real name
-- still shows their character, because "Person 24" identifies nobody.
local function personLabel(person)
    local c = ns.Roster.MainCharacter(person)
    if not c then return person.name or "?" end
    local short = ns.ShortName(c.name)
    if (person.name or "") == short then return c.name end
    return string.format("%s (%s)", person.name or "?", short)
end

-- The Send tab borrows this, so a filter built here can be messaged from there.
-- Declared after `state`: defined above it, the body would resolve `state` as a
-- nil global rather than this local.
function panel.CurrentFilter() return state.filter end

--------------------------------------------------------------------------------
-- Row data
--------------------------------------------------------------------------------

local TIER_ORDER = { Great = 4, Good = 3, Neutral = 2, Avoid = 1 }

-- What the Name column says. It leads with the person, not with whichever
-- character we happened to see most recently: somebody with seven alts is still
-- one person you know by one name, and labelling his row "Nnkidu-Azshara"
-- because that is who he logged in on last leaves him unfindable under the name
-- you actually call him -- which is the opposite of a roster of people.
--
-- When the person and the character agree, which is the common case, this is
-- exactly what it always was: character name with a dimmed realm.
local function nameCell(item)
    local color = item.char and ns.ClassColor(item.char.classFile)
    local short = ns.ShortName(item.fullName)

    -- A search result names the character that matched. Otherwise searching for
    -- somebody by the name you know them by returns a row bearing an alt's name,
    -- which looks exactly like not finding them at all.
    if item.searchHit then
        local hit = ns.NameWithRealm(item.searchHit, color)
        local behind = item.personName
        if behind ~= "" and behind ~= ns.ShortName(item.searchHit) then
            hit = hit .. "|cff7f7f7f  " .. behind .. "|r"
        end
        return hit
    end

    -- Only lead with the person name when it is genuinely one of their own
    -- characters. A person created without a name carries a placeholder like
    -- "Person 24", and "Person 24 as Amycus" is worse than plain Amycus.
    local known, namedChar = false, nil
    if item.person then
        for guid in pairs(item.person.characters or {}) do
            local c = ns.Roster.GetCharacter(guid)
            if c and ns.ShortName(c.name) == item.personName then
                known, namedChar = true, c
                break
            end
        end
    end

    if not known or item.personName == "" or item.personName == short then
        return ns.NameWithRealm(item.fullName, color)
    end
    -- Realm is dropped rather than shown twice: the person and the character can
    -- sit on different realms, and both names plus both realms does not fit the
    -- column. The detail pane lists every character in full.
    -- Colour the name being drawn, not a different character's. `color` belongs
    -- to the main character -- the one after the "as" -- so using it here paints
    -- the person's name in someone else's class: a druid rendered mage blue
    -- because their mage alt was seen more recently.
    local personColor = (namedChar and ns.ClassColor(namedChar.classFile)) or color
    return (personColor and ns.Colorize(item.personName, personColor) or item.personName)
        .. "|cff7f7f7f as " .. short .. "|r"
end

-- The characters behind a person, deduplicated and ready to draw.
--
-- One character can hold two records: the Friend-<name>-<realm> stub the friends
-- list import creates, and the real Player-* GUID a run records. They are the
-- same character, and listing both is how the pane came to show nine rows for a
-- man with five alts -- half of them blank, because only one record ever carries
-- spec and item level. The fuller record wins.
local function recordWeight(r)
    return (r.classFile and 1 or 0) + (r.ilvl and 1 or 0)
        + (r.spec and 1 or 0) + (r.rio and 1 or 0)
end

local function characterRows(person)
    local byName = {}
    for guid in pairs(person.characters or {}) do
        local c = ns.Roster.GetCharacter(guid)
        if c and c.name then
            local rio = select(1, ns.Lookup.RIO(guid))
            local row = {
                name = c.name, classFile = c.classFile, spec = c.specName,
                ilvl = c.ilvl, rio = rio and rio > 0 and math.floor(rio) or nil,
            }
            local prev = byName[c.name]
            if not prev or recordWeight(row) > recordWeight(prev) then
                byName[c.name] = row
            end
        end
    end

    local out = {}
    for _, row in pairs(byName) do out[#out + 1] = row end
    -- By name, not by the drawn string: the old list sorted text that had
    -- already been wrapped in colour codes, so it was really sorting on escape
    -- sequences and the order looked arbitrary.
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

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
        personName = person.name or "",
        searchHit = select(2, personMatches(person, state.search)),
        role   = char and char.role or "",
        spec   = char and char.specName or "",
        ilvl   = char and char.ilvl or 0,
        rio     = rio or 0,
        rioPrev = rioPrev or 0,
        mainRio = ns.Roster.BestRIO(person),
        tier   = tier,
        tierSource = source,
        runs    = ns.Roster.RunsTogether(person),
        grouped = ns.Roster.TimesGrouped(person),
        last   = ns.Roster.LastPlayedWith(person) or 0,
    }
end

local function buildRows()
    local rows = {}
    for _, person in ipairs(ns.Filters.Apply(state.filter)) do
        -- You are in your own runs, so you end up in your own roster. Rating
        -- yourself against yourself is meaningless, so leave yourself out.
        if not ns.Roster.IsSelf(person) and matchesSearch(person) then
            rows[#rows + 1] = rowFor(person)
        end
    end

    return UI.SortRows(rows, state.sortKey, state.sortAsc,
        { rank = { tier = TIER_ORDER }, tiebreak = "name" })
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

-- Select somebody from another tab. The caller switches tabs; this only decides
-- who the detail pane is showing.
function panel.SelectPerson(person)
    state.selected = person and person.id or nil
    -- The link filter belonged to whoever was selected before.
    state.linkSearch = ""
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

    -- Search sits on the right, away from the condition builder: it is a way to
    -- find one person, not another clause in the filter. It narrows whatever the
    -- filter has already left, which with the default empty filter means it
    -- searches everyone.
    local searchBox = UI.EditBox(bar, 170, function() UI.Refresh() end)
    searchBox:SetPoint("TOPRIGHT", 0, 0)
    searchBox:SetScript("OnTextChanged", function(self, user)
        if not user then return end
        state.search = self:GetText() or ""
        UI.Refresh()
    end)
    -- Escape clears rather than merely dropping focus, so a search you are done
    -- with does not quietly keep hiding the rest of the roster.
    searchBox:SetScript("OnEscapePressed", function(self)
        self:SetText("")
        state.search = ""
        self:ClearFocus()
        UI.Refresh()
    end)

    local searchLabel = UI.Label(bar, "Search", 11, { 0.65, 0.62, 0.72 })
    searchLabel:SetPoint("RIGHT", searchBox, "LEFT", -6, 0)

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

        -- Counted after the search, because the search is what the eye is
        -- actually looking at: a filter matching 40 people while one name is
        -- typed should not claim 40 are shown.
        local n = 0
        for _, person in ipairs(ns.Filters.Apply(state.filter)) do
            if matchesSearch(person) then n = n + 1 end
        end
        desc:SetText(string.format("|cff9b7fd6%d|r shown  -  %s%s", n,
            ns.Filters.Describe(state.filter),
            (state.search or "") ~= "" and ("  -  matching \"" .. state.search .. "\"") or ""))
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

    -- A bounded list, not one growing label. The old version was a single
    -- FontString that got taller with every alt, and friendBtn, the link row and
    -- the tier breakdown were all anchored beneath it -- so a person with nine
    -- characters pushed the buttons into each other and shoved the breakdown off
    -- the bottom of the window entirely. Fixed height here makes everything
    -- below it deterministic, and the list scrolls when there are more.
    local CHAR_ROWS, CHAR_ROW_H = 4, 14
    local CHAR_COLS = {
        { key = "name", label = "name", x = 2,   width = 150, align = "LEFT"  },
        { key = "ilvl", label = "ilvl", x = 154, width = 34,  align = "RIGHT" },
        { key = "rio",  label = "rio",  x = 192, width = 46,  align = "RIGHT" },
    }

    local charsHeader = CreateFrame("Frame", nil, d)
    charsHeader:SetPoint("TOPLEFT", charsLabel, "BOTTOMLEFT", 0, -2)
    charsHeader:SetPoint("RIGHT", d, "RIGHT", -8, 0)
    charsHeader:SetHeight(11)
    for _, col in ipairs(CHAR_COLS) do
        local fs = UI.Label(charsHeader, col.label, 9, { 0.5, 0.5, 0.58 })
        fs:SetPoint("LEFT", col.x, 0)
        fs:SetWidth(col.width)
        fs:SetJustifyH(col.align)
    end

    local charsList = UI.ScrollList(d, CHAR_ROW_H, function(parent)
        local row = UI.MakeRow(parent)
        row.cells = {}
        for _, col in ipairs(CHAR_COLS) do
            local fs = UI.Label(row, "", 10)
            fs:SetPoint("LEFT", col.x, 0)
            fs:SetWidth(col.width)
            fs:SetJustifyH(col.align)
            fs:SetWordWrap(false)
            row.cells[col.key] = fs
        end
        return row
    end, function(row, item)
        -- Class colour on the character half, realm dimmed behind it, the same
        -- treatment the roster's own Name column gets.
        row.cells.name:SetText(ns.NameWithRealm(item.name, ns.ClassColor(item.classFile)))
        row.cells.ilvl:SetText(item.ilvl and tostring(item.ilvl) or "-")
        row.cells.rio:SetText(item.rio and tostring(item.rio) or "-")
    end)
    charsList:SetPoint("TOPLEFT", charsHeader, "BOTTOMLEFT", 0, -2)
    charsList:SetPoint("RIGHT", d, "RIGHT", -8, 0)
    charsList:SetHeight(CHAR_ROWS * CHAR_ROW_H)
    local chars = charsList   -- what the widgets below anchor to

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
        if char and char.name then ns.Roster.AddFriendByName(char.name) end
    end)
    friendBtn:SetPoint("TOPLEFT", chars, "BOTTOMLEFT", -2, -6)
    friendBtn:SetHeight(18)

    -- Linking used to offer every person you had ever met in one column. At 179
    -- people that menu is 3,500px tall, so SetClampedToScreen showed roughly A
    -- to G and there was no way to reach anyone further down the alphabet. It
    -- needs narrowing before it is a list at all.
    -- Shares the row with Add friend rather than taking one of its own: the pane
    -- has to fit a note, the characters, two button rows and a tier breakdown
    -- inside 500px, and every line this block spends is one the breakdown does
    -- not get.
    local linkBox = UI.EditBox(d, 170, function() UI.Refresh() end)
    linkBox:SetPoint("LEFT", friendBtn, "RIGHT", 6, 0)
    linkBox:SetScript("OnTextChanged", function(self, user)
        if not user then return end
        state.linkSearch = self:GetText() or ""
        UI.Refresh()
    end)
    linkBox:SetScript("OnEscapePressed", function(self)
        self:SetText(""); state.linkSearch = ""; self:ClearFocus(); UI.Refresh()
    end)
    d.linkBox = linkBox

    -- The hint sits inside the box rather than on a line below it, for the same
    -- reason: no vertical budget. Hidden as soon as there is anything to read.
    local linkHint = UI.Label(linkBox, "find someone to link...", 10, { 0.4, 0.4, 0.47 })
    linkHint:SetPoint("LEFT", 6, 0)
    d.linkHint = linkHint

    local linkBtn = UI.MenuButton(d, 130, function() return "Same person as..." end, function()
        local person = ns.Roster.GetPerson(state.selected)
        local myChar = ns.Roster.MainCharacter(person)
        if not myChar then return {} end

        local needle = state.linkSearch or ""
        local cands = {}
        for _, other in ipairs(ns.Roster.AllPersons()) do   -- already sorted by name
            if other.id ~= person.id and personMatches(other, needle) then
                local oc = ns.Roster.MainCharacter(other)
                if oc then cands[#cands + 1] = { person = other, char = oc } end
            end
        end

        local entries = {}
        for i = 1, math.min(#cands, LINK_MAX) do
            local cand = cands[i]
            entries[#entries + 1] = { text = personLabel(cand.person), func = function()
                -- You chose this one, so it is marked as yours and no repair
                -- will undo it.
                ns.Roster.LinkCharacters(myChar.guid, cand.char.guid, "manual")
                -- The filter was for finding this one person; keeping it would
                -- silently narrow the next link too.
                state.linkSearch = ""
                UI.Refresh()
            end }
        end

        if #cands > LINK_MAX then
            entries[#entries + 1] = { text = string.format(
                "|cff8a8a95%d more -- type a name to narrow|r", #cands - LINK_MAX) }
        end
        if #entries == 0 then
            entries[1] = { text = needle ~= ""
                and string.format("(nobody matching \"%s\")", needle)
                or "(nobody else known)" }
        end
        return entries
    end, MENU_ROWS)
    linkBtn:SetPoint("TOPLEFT", chars, "BOTTOMLEFT", 0, -34)

    local unlinkBtn = UI.Button(d, "Unlink main", 130, function()
        local person = ns.Roster.GetPerson(state.selected)
        local char = ns.Roster.MainCharacter(person)
        if char then ns.Roster.UnlinkCharacter(char.guid); UI.Refresh() end
    end)
    unlinkBtn:SetPoint("LEFT", linkBtn, "RIGHT", 6, 0)

    local whyLabel = UI.Label(d, "Why this tier", 11, UI.COLORS.header)
    whyLabel:SetPoint("TOPLEFT", linkBtn, "BOTTOMLEFT", 0, -10)

    -- Bounded top and bottom so it can never grow past the Message row the way
    -- it did as a plain label -- a breakdown of several runs simply drew off the
    -- bottom of the window, where there was no way to reach it. Anchored above
    -- the buttons by pixels rather than to msgBtn, which is built after this.
    local whyList = UI.ScrollList(d, 12, function(parent)
        local row = CreateFrame("Frame", nil, parent)
        row.text = UI.Label(row, "", 10, { 0.7, 0.7, 0.76 })
        row.text:SetPoint("LEFT", 2, 0)
        row.text:SetPoint("RIGHT", -2, 0)
        row.text:SetJustifyH("LEFT")
        row.text:SetWordWrap(false)
        return row
    end, function(row, item)
        row.text:SetText(tostring(item))
    end)
    whyList:SetPoint("TOPLEFT", whyLabel, "BOTTOMLEFT", 0, -4)
    whyList:SetPoint("RIGHT", d, "RIGHT", -8, 0)
    whyList:SetPoint("BOTTOM", d, "BOTTOM", 0, 40)

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
            charsList:SetData({})
            whyList:SetData({})
            note.editBox:SetText("")
            if not d.linkBox:HasFocus() then d.linkBox:SetText(state.linkSearch or "") end
            d.linkHint:SetShown((d.linkBox:GetText() or "") == "")
            return
        end

        -- Cleared when the selection changes, so the box has to follow it back.
        if not d.linkBox:HasFocus() and d.linkBox:GetText() ~= (state.linkSearch or "") then
            d.linkBox:SetText(state.linkSearch or "")
        end
        -- Outside the focus guard: the placeholder has to disappear on the first
        -- keystroke, which is exactly when the box does have focus.
        d.linkHint:SetShown((d.linkBox:GetText() or "") == "")

        local char = ns.Roster.MainCharacter(person)
        name:SetText(ns.NameWithRealm(char and char.name or person.name,
            char and ns.ClassColor(char.classFile)) .. ns.SimTag(person))
        sub:SetText(string.format("%d runs together  -  last %s",
            ns.Roster.RunsTogether(person), ns.TimeAgo(ns.Roster.LastPlayedWith(person))))

        tierBtn:Refresh()

        if note.editBox:GetText() ~= (person.note or "") and not note.editBox:HasFocus() then
            note.editBox:SetText(person.note or "")
        end

        charsList:SetData(characterRows(person))

        local breakdown = char and ns.Rating.Breakdown(char.guid)
        if breakdown and breakdown.runs > 0 then
            local out = { string.format("score %.2f over %d runs -> %s",
                breakdown.score, breakdown.runs, breakdown.tier) }
            -- Every run, not the last four. The list scrolls now, so there is no
            -- reason to hide the older ones -- newest first, since that is the
            -- one you are asking about.
            for i = #breakdown.lines, 1, -1 do
                local line = breakdown.lines[i]
                out[#out + 1] = string.format("  %s  %+.2f (w %.2f)", line.header, line.value, line.weight)
            end
            whyList:SetData(out)
        else
            -- "No runs" is only half the story when there is shared history that
            -- simply is not keystone history, and the difference is the whole
            -- reason the tier has not moved.
            local grouped = ns.Roster.TimesGrouped(person)
            if grouped > 0 then
                whyList:SetData({
                    string.format("no keystone runs yet -- but %d session%s together",
                        grouped, grouped == 1 and "" or "s"),
                    "in other content. Normal dungeons, delves and raids are",
                    "recorded, but they never rate anyone.",
                })
            else
                whyList:SetData({ "no runs recorded yet" })
            end
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

    local sortBar = UI.SortHeader(header, COLUMNS, state, UI.Refresh)
    sortBar:SetPoint("TOPLEFT", 0, 0)
    sortBar:SetPoint("TOPRIGHT", 0, 0)
    header.sortBar = sortBar

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
            -- A link filter belongs to the person you were looking at, not to
            -- the next one you click.
            state.linkSearch = ""
            UI.Refresh()
        end)
        return row
    end, function(row, item)
        row.item = item
        row.cells.name:SetText(nameCell(item) .. ns.SimTag(item.person))
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

        -- Coloured on the current-season scale whichever season it came from:
        -- it is one number answering "how high has this account been", and two
        -- scales for one column would only invite reading it as two things.
        if item.mainRio > 0 then
            local c = ns.RaiderIOBridge.ScoreColor(item.mainRio)
            local text = tostring(math.floor(item.mainRio))
            row.cells.mainRio:SetText(c and ns.Colorize(text, c) or text)
        else
            row.cells.mainRio:SetText("-")
        end

        row.cells.tier:SetText(ns.TierText(item.tier) .. (item.tierSource == "override" and "*" or ""))
        -- Keys and everything else, side by side: "0 +2" is somebody you have
        -- run two normal dungeons and no keys with. Only the first number feeds
        -- the tier, so they cannot share one figure.
        row.cells.runs:SetText(tostring(item.runs)
            .. ((item.grouped or 0) > 0
                and ns.Colorize(" +" .. item.grouped, { r = 0.55, g = 0.55, b = 0.62 }) or ""))
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
        sortBar:Refresh()
        local rows = buildRows()
        list:SetData(rows)
        detail.Refresh()
        if #rows == 0 then
            empty:SetText(next(ns.db.characters)
                and ((state.search or "") ~= ""
                    and string.format("nobody matching \"%s\".", state.search)
                    or "no one matches this filter.")
                or "no runs recorded yet -- finish a key (or try /pugdebug seed 20).")
        else
            empty:SetText("")
        end
    end
end

ns.OnInit(function()
    UI.RegisterTab("Roster", 10, build)
end)
