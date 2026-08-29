-- UI/RunSummary.lua -- the group's numbers, in a window, once they exist.
--
-- The numbers are printed to chat when a run is recorded, which is no use with a
-- small chat frame: five players across seven columns is a table, and a table
-- read as scrolling text is not a table.
--
-- Timing is the whole reason this is not simply shown at the completion screen.
-- Damage and healing come from the server meter, and the server withholds them
-- while the ChallengeMode restriction is active -- which outlives the key itself
-- and clears when you leave. A window at completion would faithfully report a row
-- of zeroes. So it opens when a record is actually enriched, which is the first
-- moment there is anything to look at, and works the same for a key and for an
-- ordinary dungeon.

local ADDON, ns = ...
local UI = ns.UI

local RunSummary = {}
ns.RunSummary = RunSummary

local WIDTH, ROW_H = 726, 18

-- Wider than the History table on purpose: this window has the screen to itself
-- for a moment, so it can afford the columns the panel has to leave out.
--
-- Faction and spec ride inside the name cell as icons rather than taking columns
-- of their own. Both are recognised faster than they are read, and a spec name
-- is the widest text on the row for something a 14px glyph carries perfectly.
--
-- `def` is defensive cooldowns. The column is here and the data is not, yet:
-- groupmate spell ids come back secret on this client and the probe is still
-- deciding whether anything can be done about it. It reads "-" rather than "0",
-- because those are different claims -- "not tracked" against "tracked, none
-- used" -- and the whole point of the column is which one is true.
local COLS = {
    -- Symbols first, in a fixed-width cell of their own so the names below
    -- stay in a line whether or not a faction or spec is known.
    { key = "sym",     label = "",        x = 8,   width = 34,  align = "LEFT"  },
    { key = "name",    label = "name",    x = 44,  width = 164, align = "LEFT"  },
    { key = "role",    label = "role",    x = 212, width = 48,  align = "LEFT"  },
    { key = "ilvl",    label = "ilvl",    x = 262, width = 34,  align = "RIGHT" },
    { key = "deaths",  label = "deaths",  x = 300, width = 44,  align = "RIGHT" },
    { key = "kicks",   label = "kicks",   x = 346, width = 44,  align = "RIGHT" },
    { key = "disp",    label = "disp",    x = 392, width = 40,  align = "RIGHT" },
    { key = "def",     label = "def",     x = 434, width = 36,  align = "RIGHT" },
    { key = "dmg",     label = "dmg",     x = 472, width = 62,  align = "RIGHT" },
    { key = "dps",     label = "dps",     x = 536, width = 54,  align = "RIGHT" },
    { key = "heal",    label = "heal",    x = 592, width = 62,  align = "RIGHT" },
    { key = "hps",     label = "hps",     x = 656, width = 54,  align = "RIGHT" },
}

local frame

local function ensureFrame()
    if frame then return frame end

    frame = CreateFrame("Frame", "PugRosterRunSummary", UIParent)
    frame:SetSize(WIDTH, 200)
    frame:SetPoint("CENTER", 0, 120)
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true)
    UI.Backdrop(frame, { 0.08, 0.08, 0.11, 0.97 })
    frame:Hide()

    -- Movable, because it opens over whatever you are looking at when a key ends
    -- and the one thing worse than a window in the way is one you cannot move.
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)

    frame.title = UI.Label(frame, "", 13, { 0.9, 0.88, 0.95 })
    frame.title:SetPoint("TOPLEFT", 10, -9)

    frame.meta = UI.Label(frame, "", 10, { 0.62, 0.6, 0.7 })
    frame.meta:SetPoint("TOPLEFT", frame.title, "BOTTOMLEFT", 0, -2)

    local close = UI.Button(frame, "X", 22, function() frame:Hide() end)
    close:SetPoint("TOPRIGHT", -6, -6)
    close:SetHeight(20)

    -- Column headings.
    frame.head = {}
    for _, col in ipairs(COLS) do
        local fs = UI.Label(frame, col.label, 9, { 0.5, 0.5, 0.58 })
        fs:SetPoint("TOPLEFT", col.x, -46)
        fs:SetWidth(col.width)
        fs:SetJustifyH(col.align)
        frame.head[#frame.head + 1] = fs
    end

    frame.rows = {}
    return frame
end

local function rowAt(i)
    local f = ensureFrame()
    local row = f.rows[i]
    if row then return row end

    row = CreateFrame("Frame", nil, f)
    row:SetHeight(ROW_H)
    row:SetPoint("TOPLEFT", 0, -58 - (i - 1) * ROW_H)
    row:SetPoint("RIGHT", f, "RIGHT", 0, 0)
    row.cells = {}
    for _, col in ipairs(COLS) do
        local fs = UI.Label(row, "", 11)
        fs:SetPoint("LEFT", col.x, 0)
        fs:SetWidth(col.width)
        fs:SetJustifyH(col.align)
        fs:SetWordWrap(false)
        row.cells[col.key] = fs
    end
    f.rows[i] = row
    return row
end

-- Tank, healer, then damage: how you read a group rather than how you rank one.
local function ordered(record)
    local list = {}
    for _, obs in pairs(record.observations or {}) do list[#list + 1] = obs end
    table.sort(list, function(a, b)
        local ra = (a.role == "TANK" and 1) or (a.role == "HEALER" and 2) or 3
        local rb = (b.role == "TANK" and 1) or (b.role == "HEALER" and 2) or 3
        if ra ~= rb then return ra < rb end
        return (a.damage or 0) > (b.damage or 0)
    end)
    return list
end

function RunSummary.Show(record)
    if not record or not ns.settings.showRunSummary then return end
    local list = ordered(record)
    if #list == 0 then return end

    local f = ensureFrame()

    local title = record.dungeon or record.zone or "Run"
    if record.keyLevel then title = string.format("%s +%d", title, record.keyLevel) end
    f.title:SetText(title)

    local bits = {}
    if record.keyLevel then
        if record.disband then bits[#bits + 1] = "|cffff6666disbanded|r"
        elseif not record.completed then bits[#bits + 1] = "|cffff6666abandoned|r"
        elseif not record.timed then bits[#bits + 1] = "|cffd9a441over time|r"
        else bits[#bits + 1] = string.format("|cff5fd68ftimed +%d|r", record.upgrade or 1) end
    elseif record.content then
        bits[#bits + 1] = ns.CONTENT_LABEL[record.content] or record.content
    end
    local elapsed = record.elapsed or ((record.endedAt or 0) - (record.startedAt or 0))
    if elapsed and elapsed > 0 then
        bits[#bits + 1] = "time " .. ns.Span(elapsed)
    end
    f.meta:SetText(table.concat(bits, "  -  "))

    for i, obs in ipairs(list) do
        local row = rowAt(i)
        row.cells.sym:SetText(ns.GroupSymbols(obs))
        row.cells.name:SetText(ns.GroupNameCell(obs))
        row.cells.role:SetText(ns.RoleLabel(obs.role))
        row.cells.ilvl:SetText(obs.ilvl and tostring(obs.ilvl) or "-")
        row.cells.deaths:SetText(tostring(obs.deaths or 0))
        row.cells.kicks:SetText(tostring(obs.interrupts or 0))
        row.cells.disp:SetText(tostring(obs.dispels or 0))
        -- nil means the run predates defensive capture, or the client will not
        -- give it to us; 0 would claim nobody pressed anything.
        row.cells.def:SetText(obs.defensives and tostring(obs.defensives) or "-")
        row.cells.dmg:SetText(ns.FormatCount(obs.damage))
        row.cells.dps:SetText(ns.FormatCount(ns.PerSecond(obs.damage, record)))
        row.cells.heal:SetText(ns.FormatCount(obs.healing))
        row.cells.hps:SetText(ns.FormatCount(ns.PerSecond(obs.healing, record)))
        row:Show()
    end
    for i = #list + 1, #f.rows do f.rows[i]:Hide() end

    f:SetHeight(58 + #list * ROW_H + 10)
    f:Show()
end

function RunSummary.Hide()
    if frame then frame:Hide() end
end
