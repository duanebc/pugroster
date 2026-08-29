-- UI/Window.lua -- the main window, tab host and shared widgets.
--
-- Panels register a tab here and get a content frame plus a Refresh hook; they
-- never touch the frame plumbing. The widget helpers below are deliberately
-- hand-rolled rather than built on Blizzard's dropdown/scroll templates, which
-- have churned hard across recent expansions -- a self-contained popup menu and
-- a Faux scroll list are the two pieces least likely to break on patch day.

local ADDON, ns = ...

local UI = {}
ns.UI = UI

UI.ROW_HEIGHT = 22
UI.PAD = 12

local COLORS = {
    bg      = { 0.06, 0.06, 0.08, 0.94 },
    panel   = { 0.10, 0.10, 0.13, 0.90 },
    row     = { 1, 1, 1, 0.035 },
    rowAlt  = { 1, 1, 1, 0.00 },
    hover   = { 0.56, 0.37, 0.84, 0.25 },
    accent  = { 0.56, 0.37, 0.84 },
    header  = { 0.75, 0.72, 0.82 },
}
UI.COLORS = COLORS

--------------------------------------------------------------------------------
-- Primitives
--------------------------------------------------------------------------------

function UI.Backdrop(frame, color)
    local tex = frame:CreateTexture(nil, "BACKGROUND")
    tex:SetAllPoints()
    tex:SetColorTexture(unpack(color or COLORS.panel))
    frame.bgTexture = tex
    return tex
end

-- Section header: an accent-coloured caption, either at the top of a column or
-- spaced below whatever came before it.
function UI.Section(parent, anchor, text, dx)
    local fs = UI.Label(parent, text, 12, UI.COLORS.accent)
    if anchor then
        fs:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", dx or 0, -14)
    else
        fs:SetPoint("TOPLEFT", 14, -12)
    end
    return fs
end

function UI.Label(parent, text, size, color)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetFont(STANDARD_TEXT_FONT, size or 12, "")
    fs:SetText(text or "")
    fs:SetJustifyH("LEFT")
    if color then fs:SetTextColor(unpack(color)) end
    return fs
end

function UI.Button(parent, text, width, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(width or 90, 22)

    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.18, 0.16, 0.24, 0.9)
    b.bg = bg

    local label = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("CENTER")
    label:SetFont(STANDARD_TEXT_FONT, 12, "")
    label:SetText(text or "")
    b.label = label

    -- Hover repaints the background, so both handlers have to respect the
    -- disabled state or a mouseover would undo the dim.
    b:SetScript("OnEnter", function(self)
        if not self:IsEnabled() then return end
        self.bg:SetColorTexture(0.30, 0.24, 0.42, 0.95)
    end)
    b:SetScript("OnLeave", function(self)
        if not self:IsEnabled() then return end
        self.bg:SetColorTexture(self.isActive and 0.34 or 0.18, self.isActive and 0.26 or 0.16,
                                self.isActive and 0.48 or 0.24, 0.9)
    end)
    if onClick then b:SetScript("OnClick", onClick) end

    function b:SetActive(active)
        self.isActive = active
        self.bg:SetColorTexture(active and 0.34 or 0.18, active and 0.26 or 0.16, active and 0.48 or 0.24, 0.9)
    end

    -- Native Enable/Disable stops the click; the alpha is what makes it look
    -- stopped. Both halves matter -- a button that still looks live but does
    -- nothing is worse than one that looks dead.
    function b:SetEnabled(on)
        if on then self:Enable() else self:Disable() end
        self.label:SetAlpha(on and 1 or 0.35)
        self.bg:SetAlpha(on and 1 or 0.45)
    end

    function b:SetText(t) self.label:SetText(t) end

    return b
end

function UI.CheckBox(parent, text, getter, setter)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(22, 22)
    cb.text = cb:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    cb.text:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    cb.text:SetFont(STANDARD_TEXT_FONT, 12, "")
    cb.text:SetText(text or "")
    cb:SetChecked(getter and getter() or false)
    cb:SetScript("OnClick", function(self)
        if setter then setter(self:GetChecked() and true or false) end
        if ns.UI.Refresh then ns.UI.Refresh() end
    end)
    cb.Refresh = function(self) if getter then self:SetChecked(getter() and true or false) end end
    return cb
end

function UI.EditBox(parent, width, onEnter)
    local eb = CreateFrame("EditBox", nil, parent)
    eb:SetSize(width or 160, 22)
    eb:SetAutoFocus(false)
    eb:SetFont(STANDARD_TEXT_FONT, 12, "")
    eb:SetTextInsets(6, 6, 0, 0)
    UI.Backdrop(eb, { 0, 0, 0, 0.55 })
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    eb:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        if onEnter then onEnter(self:GetText()) end
    end)
    return eb
end

-- Multi-line box inside a scroll frame, for notes and template bodies.
function UI.MultiLineBox(parent, width, height, onChange)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(width, height)
    UI.Backdrop(container, { 0, 0, 0, 0.55 })

    local scroll = CreateFrame("ScrollFrame", nil, container, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 6, -4)
    scroll:SetPoint("BOTTOMRIGHT", -26, 4)

    local eb = CreateFrame("EditBox", nil, scroll)
    eb:SetMultiLine(true)
    eb:SetAutoFocus(false)
    eb:SetFont(STANDARD_TEXT_FONT, 12, "")
    eb:SetWidth(width - 36)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    if onChange then
        eb:SetScript("OnTextChanged", function(self, user) if user then onChange(self:GetText()) end end)
    end
    scroll:SetScrollChild(eb)

    container.editBox = eb
    return container
end

--------------------------------------------------------------------------------
-- Popup menu
--
-- A tiny self-contained replacement for UIDropDownMenu: one shared frame, a list
-- of { text, func, checked } entries, anchored to whatever opened it.
--------------------------------------------------------------------------------

local menu
local function ensureMenu()
    if menu then return menu end
    menu = CreateFrame("Frame", "PugRosterMenu", UIParent)
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    menu:SetClampedToScreen(true)
    UI.Backdrop(menu, { 0.08, 0.08, 0.11, 0.98 })
    menu:Hide()
    menu.rows = {}
    menu:SetScript("OnShow", function(self) self.opened = GetTime() end)

    -- Click-away close.
    local catcher = CreateFrame("Button", nil, UIParent)
    catcher:SetAllPoints(UIParent)
    catcher:SetFrameStrata("FULLSCREEN")
    catcher:Hide()
    catcher:SetScript("OnClick", function() menu:Hide() end)
    menu.catcher = catcher
    menu:HookScript("OnShow", function() catcher:Show() end)
    menu:HookScript("OnHide", function() catcher:Hide() end)
    return menu
end

-- `maxRows` wraps a long list into columns instead of one strip taller than the
-- screen: a +2..+30 level list is thirty entries, and SetClampedToScreen would
-- only slide that up over the window rather than make it readable. Callers that
-- leave it unset get the single column they have always had.
function UI.ShowMenu(anchor, entries, width, maxRows)
    local m = ensureMenu()
    width = width or 160

    -- Rows are pooled across every menu in the addon, and a point set on the
    -- previous opening is additive rather than replaced. A single column got away
    -- with it because entry i always landed at the same height; with columns in
    -- play, entry i moves, so the old points have to go.
    for _, row in ipairs(m.rows) do row:ClearAllPoints(); row:Hide() end

    local GAP      = 4
    local colWidth = width - 8
    local rows    = math.max(1, maxRows and math.min(maxRows, #entries) or #entries)
    local columns = math.max(1, math.ceil(#entries / rows))
    -- Spread evenly once the column count is known: thirty entries at fourteen
    -- rows is three columns, and 10/10/10 reads better than 14/14/2.
    rows = math.ceil(#entries / columns)

    for i, entry in ipairs(entries) do
        local row = m.rows[i]
        if not row then
            row = CreateFrame("Button", nil, m)
            row:SetHeight(20)
            row.label = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            row.label:SetPoint("LEFT", 8, 0)
            row.label:SetFont(STANDARD_TEXT_FONT, 12, "")
            row.hl = row:CreateTexture(nil, "HIGHLIGHT")
            row.hl:SetAllPoints()
            row.hl:SetColorTexture(unpack(COLORS.hover))
            m.rows[i] = row
        end
        -- Column-major: the list reads top to bottom, then wraps to the next
        -- column, so +2..+16 is one column and +17..+30 the next.
        local col = math.floor((i - 1) / rows)
        row:SetPoint("TOPLEFT", 4 + col * (colWidth + GAP), -4 - ((i - 1) % rows) * 20)
        row:SetWidth(colWidth)
        row.label:SetText((entry.checked and "|cff9b7fd6*|r " or "") .. (entry.text or ""))
        row:SetScript("OnClick", function()
            m:Hide()
            if entry.func then entry.func() end
        end)
        row:Show()
    end

    m:SetSize(8 + columns * colWidth + (columns - 1) * GAP, rows * 20 + 8)
    m:ClearAllPoints()
    m:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
    m:Show()
end

function UI.HideMenu()
    if menu then menu:Hide() end
end

-- A button that opens a menu and shows the current value.
function UI.MenuButton(parent, width, getLabel, buildEntries, maxRows)
    local b = UI.Button(parent, getLabel and getLabel() or "", width)
    b:SetScript("OnClick", function(self)
        UI.ShowMenu(self, buildEntries() or {}, width, maxRows)
    end)
    b.Refresh = function(self) if getLabel then self:SetText(getLabel()) end end
    return b
end

-- A horizontal scrollbar for content that is too wide rather than too tall.
--
-- The scroll lists handle vertical overflow; nothing handled horizontal, so a
-- long line simply drew past the edge of the window. `range` is how far there is
-- to scroll, and setting it to zero hides the bar -- a control for something that
-- fits is worse than none.
function UI.HScrollBar(parent, onChange)
    local bar = CreateFrame("Slider", nil, parent, "UISliderTemplate")
    bar:SetOrientation("HORIZONTAL")
    bar:SetHeight(12)
    bar:SetMinMaxValues(0, 0)
    bar:SetValueStep(8)
    bar:SetObeyStepOnDrag(true)
    bar:SetValue(0)
    bar:SetScript("OnValueChanged", function(self, value)
        if onChange then onChange(math.floor(value + 0.5)) end
    end)

    function bar:SetRange(range)
        range = math.max(0, math.floor(range or 0))
        self:SetMinMaxValues(0, range)
        if self:GetValue() > range then self:SetValue(range) end
        self:SetShown(range > 0)
    end

    bar:SetRange(0)
    return bar
end

--------------------------------------------------------------------------------
-- Scroll list
--
-- Fixed row pool, recycled on scroll. `createRow(parent)` builds one row frame;
-- `updateRow(row, item, index)` fills it. Callers only ever hand it an array.
--------------------------------------------------------------------------------

local scrollSerial = 0

function UI.ScrollList(parent, rowHeight, createRow, updateRow)
    local list = CreateFrame("Frame", nil, parent)
    rowHeight = rowHeight or UI.ROW_HEIGHT

    -- FauxScrollFrame_Update looks its scroll bar up by global name
    -- ("$parentScrollBar"), so the frame itself has to be named.
    scrollSerial = scrollSerial + 1
    local scroll = CreateFrame("ScrollFrame", "PugRosterScrollList" .. scrollSerial, list, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", -26, 0)

    list.rows = {}
    list.data = {}

    local function update()
        local numRows = math.max(1, math.floor(list:GetHeight() / rowHeight))
        local offset = FauxScrollFrame_GetOffset(scroll)

        for i = 1, numRows do
            local row = list.rows[i]
            if not row then
                row = createRow(list)
                row:SetHeight(rowHeight)
                row:SetPoint("TOPLEFT", 0, -(i - 1) * rowHeight)
                row:SetPoint("RIGHT", scroll, "RIGHT", 0, 0)
                list.rows[i] = row
            end

            local item = list.data[i + offset]
            if item then
                if row.stripe then
                    row.stripe:SetColorTexture(unpack((i + offset) % 2 == 0 and COLORS.row or COLORS.rowAlt))
                end
                updateRow(row, item, i + offset)
                row:Show()
            else
                row:Hide()
            end
        end

        FauxScrollFrame_Update(scroll, #list.data, numRows, rowHeight)
    end

    scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, rowHeight, update)
    end)

    function list:SetData(data)
        self.data = data or {}
        update()
    end

    function list:Refresh() update() end

    list:SetScript("OnSizeChanged", function() update() end)
    return list
end

-- Standard row shell: background stripe plus hover highlight.
--------------------------------------------------------------------------------
-- Sortable columns
--
-- Every table in the addon wants the same two things: a header row you can click
-- and a comparator that copes with the columns actually being sorted -- numbers
-- with gaps in them, tiers that rank rather than alphabetise, and a stable
-- tiebreak so equal rows do not shuffle between refreshes.
--------------------------------------------------------------------------------

-- `opts.rank` maps a column key to a value order (tiers are Great..Avoid, not
-- alphabetical). `opts.tiebreak` names the column that breaks ties, so a table
-- sorted by a column full of zeroes still has a stable order.
function UI.SortRows(rows, key, asc, opts)
    if not key then return rows end
    opts = opts or {}
    local rank = opts.rank and opts.rank[key]
    local tie = opts.tiebreak
    -- `opts.value` reads the sort value for a column, for tables whose column
    -- keys are not field names -- "kicks" over obs.interrupts -- or whose columns
    -- are computed rather than stored, like a rate over a stored total.
    local get = opts.value or function(row, k) return row[k] end

    table.sort(rows, function(a, b)
        local x, y = get(a, key), get(b, key)
        if rank then x, y = rank[x] or 0, rank[y] or 0 end

        -- A missing number is zero, not the string "nil". Sorting item level
        -- with two people missing one should not file them under N.
        if x == nil and type(y) == "number" then x = 0 end
        if y == nil and type(x) == "number" then y = 0 end

        if x == y then
            if tie then return tostring(get(a, tie) or "") < tostring(get(b, tie) or "") end
            return false
        end
        if type(x) == "number" and type(y) == "number" then
            if asc then return x < y else return x > y end
        end
        x, y = tostring(x), tostring(y)
        if asc then return x < y else return x > y end
    end)
    return rows
end

-- A clickable header. `columns` is the same array the rows are drawn from, so
-- the two cannot drift; a column with no `key` is a label and does not sort.
-- Widths lay out left to right unless a column carries its own `x`.
function UI.SortHeader(parent, columns, state, onChange)
    local header = CreateFrame("Frame", nil, parent)
    header:SetHeight(20)
    header.buttons = {}

    local x = 0
    for _, col in ipairs(columns) do
        local b = UI.Button(header, col.label or "", col.width or 60, nil)
        b:SetPoint("LEFT", col.x or x, 0)
        b:SetHeight(18)
        b.bg:SetColorTexture(0, 0, 0, 0)
        b.col = col

        -- Header alignment has to match the cells beneath it, or a right-aligned
        -- number sits under a centred word.
        if col.align then
            b.label:ClearAllPoints()
            b.label:SetPoint(col.align == "RIGHT" and "RIGHT" or "LEFT",
                col.align == "RIGHT" and -2 or 2, 0)
            b.label:SetJustifyH(col.align)
        end

        -- `nosort` is for a column that has a key because its cells need one, but
        -- nothing meaningful to order by -- a flag, an icon, a marker.
        if col.key and not col.nosort then
            b:SetScript("OnClick", function()
                if state.sortKey == col.key then
                    state.sortAsc = not state.sortAsc
                else
                    -- A fresh column starts descending: every numeric column
                    -- here is one where "most" is the interesting end.
                    state.sortKey, state.sortAsc = col.key, false
                end
                if onChange then onChange() end
            end)
            b:SetScript("OnEnter", function(self) self.label:SetTextColor(1, 1, 1) end)
            b:SetScript("OnLeave", function() header:Refresh() end)
        end

        header.buttons[#header.buttons + 1] = b
        x = x + (col.width or 0)
    end

    function header:Refresh()
        for _, b in ipairs(self.buttons) do
            local active = b.col.key and not b.col.nosort and state.sortKey == b.col.key
            b.label:SetText((b.col.label or "")
                .. (active and (state.sortAsc and " |cff9b7fd6^|r" or " |cff9b7fd6v|r") or ""))
            if active then
                b.label:SetTextColor(0.92, 0.88, 1)
            else
                b.label:SetTextColor(unpack(COLORS.header))
            end
        end
    end

    header:Refresh()
    return header
end

function UI.MakeRow(parent)
    local row = CreateFrame("Button", nil, parent)
    row.stripe = row:CreateTexture(nil, "BACKGROUND")
    row.stripe:SetAllPoints()
    row.stripe:SetColorTexture(unpack(COLORS.rowAlt))
    row.hl = row:CreateTexture(nil, "HIGHLIGHT")
    row.hl:SetAllPoints()
    row.hl:SetColorTexture(unpack(COLORS.hover))
    return row
end

--------------------------------------------------------------------------------
-- Tag chips
--------------------------------------------------------------------------------

-- Lay out tag chips left to right inside `parent`, recycling frames.
-- `onClick(tag)` fires when a chip is clicked -- the roster panel uses it to add
-- the tag to the active filter.
function UI.LayoutChips(parent, tags, maxWidth, onClick)
    parent.chips = parent.chips or {}
    for _, chip in ipairs(parent.chips) do chip:Hide() end

    local x, i = 0, 0
    for _, entry in ipairs(tags) do
        local tag, kind = entry.tag, entry.kind
        i = i + 1
        local chip = parent.chips[i]
        if not chip then
            chip = CreateFrame("Button", nil, parent)
            chip:SetHeight(15)
            chip.bg = chip:CreateTexture(nil, "BACKGROUND")
            chip.bg:SetAllPoints()
            chip.label = chip:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            chip.label:SetPoint("CENTER")
            chip.label:SetFont(STANDARD_TEXT_FONT, 10, "")
            parent.chips[i] = chip
        end

        chip.label:SetText(tag)
        local w = chip.label:GetStringWidth() + 10
        if x + w > maxWidth then
            chip:Hide()
            -- Signal that more tags exist than fit.
            if i > 1 then
                local last = parent.chips[i - 1]
                last.label:SetText(last.label:GetText() .. " ...")
            end
            break
        end

        chip:SetWidth(w)
        chip:ClearAllPoints()
        chip:SetPoint("LEFT", parent, "LEFT", x, 0)
        if kind == "auto" then
            chip.bg:SetColorTexture(0.20, 0.22, 0.28, 0.85)
            chip.label:SetTextColor(0.68, 0.72, 0.80)
        else
            chip.bg:SetColorTexture(0.32, 0.24, 0.44, 0.9)
            chip.label:SetTextColor(0.88, 0.82, 0.96)
        end
        chip:SetScript("OnClick", onClick and function() onClick(tag, kind) end or nil)
        chip:Show()
        x = x + w + 4
    end
end

-- Manual tags first, then auto, each alphabetical.
function UI.ChipList(person)
    local combined = ns.Roster.AllTagsFor(person)
    local manual, auto = {}, {}
    for tag, kind in pairs(combined) do
        table.insert(kind == "manual" and manual or auto, tag)
    end
    table.sort(manual); table.sort(auto)

    local out = {}
    for _, tag in ipairs(manual) do out[#out + 1] = { tag = tag, kind = "manual" } end
    for _, tag in ipairs(auto) do out[#out + 1] = { tag = tag, kind = "auto" } end
    return out
end

--------------------------------------------------------------------------------
-- Window and tabs
--------------------------------------------------------------------------------

local tabs = {}       -- { name, order, builder, frame }
local frame

function UI.RegisterTab(name, order, builder)
    table.insert(tabs, { name = name, order = order or 100, builder = builder })
    table.sort(tabs, function(a, b) return a.order < b.order end)
end

local function buildWindow()
    if frame then return frame end

    frame = CreateFrame("Frame", "PugRosterFrame", UIParent)
    -- 1000 rather than 920: the roster shows Name-Realm, and a realm name needs
    -- the room. Clamped to screen, so a small display still gets a usable frame.
    frame:SetSize(1000, 580)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("HIGH")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetClampedToScreen(true)
    UI.Backdrop(frame, COLORS.bg)

    -- ESC-to-close, handled here rather than through UISpecialFrames. Putting
    -- our frame name in that table hands an addon-owned string to
    -- CloseSpecialWindows(), which Blizzard calls from the game-menu path; the
    -- taint then travels with whatever the menu does next. Owning the keypress
    -- keeps all of it on our side.
    frame:EnableKeyboard(true)
    frame:SetPropagateKeyboardInput(true)
    frame:SetScript("OnKeyDown", function(self, key)
        -- SetPropagateKeyboardInput is refused in combat, so in combat we leave
        -- propagation alone and simply do not swallow the key.
        if InCombatLockdown() then return end
        if key == "ESCAPE" then
            self:SetPropagateKeyboardInput(false)
            self:Hide()
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)
    frame:HookScript("OnShow", function(self)
        if not InCombatLockdown() then self:SetPropagateKeyboardInput(true) end
    end)

    local title = UI.Label(frame, "PugRoster", 15, COLORS.accent)
    title:SetPoint("TOPLEFT", UI.PAD, -10)

    local version = UI.Label(frame, ns.addonVersion, 10, { 0.5, 0.5, 0.55 })
    version:SetPoint("LEFT", title, "RIGHT", 6, -1)

    local close = UI.Button(frame, "X", 24, function() frame:Hide() end)
    close:SetPoint("TOPRIGHT", -UI.PAD, -8)

    -- Tab strip
    local strip = CreateFrame("Frame", nil, frame)
    strip:SetPoint("TOPLEFT", UI.PAD, -34)
    strip:SetPoint("TOPRIGHT", -UI.PAD, -34)
    strip:SetHeight(24)
    frame.tabButtons = {}

    local x = 0
    for _, tab in ipairs(tabs) do
        local b = UI.Button(strip, tab.name, 96, function() UI.Show(tab.name) end)
        b:SetPoint("LEFT", x, 0)
        frame.tabButtons[tab.name] = b
        x = x + 98
    end

    -- Content area
    local content = CreateFrame("Frame", nil, frame)
    content:SetPoint("TOPLEFT", UI.PAD, -62)
    content:SetPoint("BOTTOMRIGHT", -UI.PAD, UI.PAD)
    UI.Backdrop(content, COLORS.panel)
    frame.content = content

    for _, tab in ipairs(tabs) do
        local page = CreateFrame("Frame", nil, content)
        page:SetAllPoints()
        page:Hide()
        tab.frame = page
        local ok, err = pcall(tab.builder, page)
        if not ok then ns.Print("|cffff5555tab error|r", tab.name, err) end
    end

    frame:SetScript("OnHide", function() UI.HideMenu() end)
    return frame
end

function UI.Show(tabName)
    buildWindow()
    frame:Show()

    local target = tabName or UI.currentTab or (tabs[1] and tabs[1].name)
    for _, tab in ipairs(tabs) do
        local active = tab.name == target
        if tab.frame then tab.frame:SetShown(active) end
        local b = frame.tabButtons[tab.name]
        if b then b:SetActive(active) end
        if active then UI.currentTab = tab.name end
    end
    UI.Refresh()
end

function UI.Hide()
    if frame then frame:Hide() end
end

function UI.Toggle(tabName)
    buildWindow()
    if frame:IsShown() and (not tabName or tabName == UI.currentTab) then
        frame:Hide()
    else
        UI.Show(tabName)
    end
end

function UI.IsShown()
    return frame and frame:IsShown()
end

-- Refresh whichever tab is visible. Panels expose page.Refresh.
function UI.Refresh()
    if not frame or not frame:IsShown() then return end
    for _, tab in ipairs(tabs) do
        if tab.frame and tab.frame:IsShown() and tab.frame.Refresh then
            local ok, err = pcall(tab.frame.Refresh)
            if not ok then ns.Print("|cffff5555refresh error|r", tab.name, err) end
        end
    end
end
