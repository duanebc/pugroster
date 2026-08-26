-- UI/HistoryPanel.lua -- browsable run history: the run list, its group, its chat.

local ADDON, ns = ...
local UI = ns.UI

local panel = {}
ns.HistoryPanel = panel

local LIST_WIDTH = 250

local state = {
    selectedRun = nil,   -- run id
    personFilter = nil,  -- personId, set by the roster panel
}

-- Called from the roster panel: narrow the history to runs with this person.
function panel.FocusPerson(person)
    state.personFilter = person and person.id or nil
    state.selectedRun = nil
end

local function runsForView()
    local out = {}
    local guids
    if state.personFilter then
        local person = ns.Roster.GetPerson(state.personFilter)
        if person then guids = person.characters end
    end

    for i = #ns.db.runs, 1, -1 do   -- newest first
        local run = ns.db.runs[i]
        local include = true
        if guids then
            include = false
            for guid in pairs(guids) do
                if run.observations and run.observations[guid] then include = true; break end
            end
        end
        if include then out[#out + 1] = run end
    end
    return out
end

local function resultText(run)
    if run.disband then return "|cffff6666disbanded|r" end
    if not run.completed then return "|cffff6666abandoned|r" end
    if not run.timed then return "|cffd9a441over time|r" end
    return string.format("|cff5fd68ftimed +%d|r", run.upgrade or 1)
end

local function findRun(id)
    for _, run in ipairs(ns.db.runs) do
        if run.id == id then return run end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

local function build(page)
    -- Header / mode line
    local mode = UI.Label(page, "", 11, { 0.65, 0.62, 0.72 })
    mode:SetPoint("TOPLEFT", 10, -10)

    local clearBtn = UI.Button(page, "All runs", 80, function()
        state.personFilter = nil
        UI.Refresh()
    end)
    clearBtn:SetPoint("TOPRIGHT", -10, -8)

    -- Run list
    local runList = UI.ScrollList(page, 34, function(parent)
        local row = UI.MakeRow(parent)
        row.title = UI.Label(row, "", 12)
        row.title:SetPoint("TOPLEFT", 6, -3)
        row.sub = UI.Label(row, "", 10, { 0.6, 0.6, 0.68 })
        row.sub:SetPoint("TOPLEFT", 6, -18)
        row:SetScript("OnClick", function(self)
            state.selectedRun = self.run and self.run.id or nil
            UI.Refresh()
        end)
        return row
    end, function(row, run)
        row.run = run
        row.title:SetText(string.format("%s |cffffffff+%d|r", run.dungeon or "?", run.keyLevel or 0))
        row.sub:SetText(string.format("%s  %s", ns.FormatDate(run.endedAt or run.startedAt), resultText(run)))
        if state.selectedRun == run.id then
            row.stripe:SetColorTexture(0.36, 0.26, 0.50, 0.5)
        end
    end)
    runList:SetPoint("TOPLEFT", 8, -32)
    runList:SetPoint("BOTTOMLEFT", 8, 8)
    runList:SetWidth(LIST_WIDTH)

    -- Detail
    local detail = CreateFrame("Frame", nil, page)
    detail:SetPoint("TOPLEFT", runList, "TOPRIGHT", 8, 0)
    detail:SetPoint("BOTTOMRIGHT", -8, 8)
    UI.Backdrop(detail, { 0, 0, 0, 0.25 })

    local title = UI.Label(detail, "", 14, { 0.9, 0.88, 0.95 })
    title:SetPoint("TOPLEFT", 10, -10)

    local meta = UI.Label(detail, "", 11, { 0.7, 0.7, 0.76 })
    meta:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)

    local groupHeader = UI.Label(detail, "Group", 11, UI.COLORS.header)
    groupHeader:SetPoint("TOPLEFT", meta, "BOTTOMLEFT", 0, -10)

    -- Fixed pixel columns rather than padded strings: colour escape codes count
    -- toward string width, so %-22s on a coloured name never lines up.
    local GROUP_COLS = {
        { key = "name",   label = "name",   x = 6,   width = 150, align = "LEFT" },
        { key = "role",   label = "role",   x = 158, width = 56,  align = "LEFT" },
        { key = "deaths", label = "deaths", x = 214, width = 46,  align = "RIGHT" },
        { key = "kicks",  label = "kicks",  x = 262, width = 46,  align = "RIGHT" },
        { key = "disp",   label = "disp",   x = 310, width = 46,  align = "RIGHT" },
        { key = "dmg",    label = "dmg",    x = 358, width = 62,  align = "RIGHT" },
        { key = "heal",   label = "heal",   x = 422, width = 62,  align = "RIGHT" },
        { key = "flag",   label = "",       x = 488, width = 60,  align = "LEFT" },
    }

    local cols = CreateFrame("Frame", nil, detail)
    cols:SetPoint("TOPLEFT", groupHeader, "BOTTOMLEFT", 0, -3)
    cols:SetPoint("RIGHT", detail, "RIGHT", -8, 0)
    cols:SetHeight(12)
    for _, col in ipairs(GROUP_COLS) do
        local fs = UI.Label(cols, col.label, 10, { 0.5, 0.5, 0.58 })
        fs:SetPoint("TOPLEFT", col.x, 0)
        fs:SetWidth(col.width)
        fs:SetJustifyH(col.align)
    end

    local function short(n)
        return AbbreviateLargeNumbers and AbbreviateLargeNumbers(n or 0) or tostring(n or 0)
    end

    local groupList = UI.ScrollList(page, 20, function(parent)
        local row = UI.MakeRow(parent)
        row.cells = {}
        for _, col in ipairs(GROUP_COLS) do
            local fs = UI.Label(row, "", 11)
            fs:SetPoint("LEFT", col.x, 0)
            fs:SetWidth(col.width)
            fs:SetJustifyH(col.align)
            fs:SetWordWrap(false)
            row.cells[col.key] = fs
        end
        row:SetScript("OnClick", function(self)
            if self.obs then
                local char = ns.Roster.GetCharacter(self.obs.guid)
                if char then
                    ns.Print(string.format("%s -- score %.2f over %d runs (%s)",
                        char.name or "?", char.score or 0, char.runs or 0, char.autoTier or "Neutral"))
                end
            end
        end)
        return row
    end, function(row, obs)
        row.obs = obs
        row.cells.name:SetText(ns.Colorize(ns.ShortName(obs.name), ns.ClassColor(obs.classFile)))
        row.cells.role:SetText((obs.role or "-"):lower())
        row.cells.deaths:SetText(tostring(obs.deaths or 0))
        row.cells.kicks:SetText(tostring(obs.interrupts or 0))
        row.cells.disp:SetText(tostring(obs.dispels or 0))
        row.cells.dmg:SetText(short(obs.damage))
        row.cells.heal:SetText(short(obs.healing))
        row.cells.flag:SetText(obs.leftEarly and "|cffff6666left|r" or (obs.isPlayer and "|cff8f5fd6you|r" or ""))
    end)
    groupList:SetParent(detail)
    groupList:SetPoint("TOPLEFT", cols, "BOTTOMLEFT", 0, -2)
    groupList:SetPoint("RIGHT", detail, "RIGHT", -8, 0)
    groupList:SetHeight(120)

    local chatHeader = UI.Label(detail, "Chat", 11, UI.COLORS.header)
    chatHeader:SetPoint("TOPLEFT", groupList, "BOTTOMLEFT", 0, -8)

    local chatList = UI.ScrollList(page, 16, function(parent)
        local row = UI.MakeRow(parent)
        row.text = UI.Label(row, "", 11)
        row.text:SetPoint("LEFT", 6, 0)
        row.text:SetWordWrap(false)
        return row
    end, function(row, line)
        local prefix = line.whisper and "|cffff80ff[w]|r " or ""
        local char = line.guid and ns.Roster.GetCharacter(line.guid)
        local who = ns.ShortName(line.name or "?")
        row.text:SetText(string.format("%s%s: |cffd8d8dd%s|r", prefix,
            ns.Colorize(who, char and ns.ClassColor(char.classFile)), line.text or ""))
    end)
    chatList:SetParent(detail)
    chatList:SetPoint("TOPLEFT", chatHeader, "BOTTOMLEFT", 0, -2)
    chatList:SetPoint("BOTTOMRIGHT", detail, "BOTTOMRIGHT", -8, 8)

    local empty = UI.Label(detail, "", 12, { 0.55, 0.55, 0.62 })
    empty:SetPoint("TOPLEFT", 10, -10)

    page.Refresh = function()
        local runs = runsForView()

        if state.personFilter then
            local person = ns.Roster.GetPerson(state.personFilter)
            mode:SetText(string.format("runs with |cff9b7fd6%s|r (%d)", person and person.name or "?", #runs))
        else
            mode:SetText(string.format("%d runs recorded", #runs))
        end
        clearBtn:SetShown(state.personFilter ~= nil)

        runList:SetData(runs)

        if not state.selectedRun and runs[1] then state.selectedRun = runs[1].id end
        local run = state.selectedRun and findRun(state.selectedRun)

        local hasRun = run ~= nil
        title:SetShown(hasRun); meta:SetShown(hasRun); groupHeader:SetShown(hasRun)
        cols:SetShown(hasRun); chatHeader:SetShown(hasRun)
        groupList:SetShown(hasRun); chatList:SetShown(hasRun)

        if not hasRun then
            empty:SetText(#ns.db.runs == 0
                and "no runs yet. finish a key, or seed test data with /pugdebug seed 20."
                or "select a run.")
            return
        end
        empty:SetText("")

        title:SetText(string.format("%s |cffffffff+%d|r  %s", run.dungeon or "?", run.keyLevel or 0, resultText(run)))

        local bits = { ns.FormatDate(run.endedAt or run.startedAt) }
        bits[#bits + 1] = "time " .. ns.FormatDuration(run.elapsed)
        if run.par then
            bits[#bits + 1] = string.format("par %s (%s)", ns.FormatDuration(run.par), ns.FormatSigned(run.margin or 0))
        end
        if run.keyHolder then
            local holder = ns.Roster.GetCharacter(run.keyHolder)
            bits[#bits + 1] = "key: " .. (holder and ns.ShortName(holder.name) or "?")
        end
        if run.wipes and run.wipes > 0 then bits[#bits + 1] = run.wipes .. " wipes" end
        if run.debug then bits[#bits + 1] = "|cffd9a441simulated|r" end
        if run.detailsEnriched then bits[#bits + 1] = "details" end
        meta:SetText(table.concat(bits, "  -  "))

        local obsList = {}
        for _, obs in pairs(run.observations or {}) do obsList[#obsList + 1] = obs end
        table.sort(obsList, function(a, b)
            local ra = (a.role == "TANK" and 1) or (a.role == "HEALER" and 2) or 3
            local rb = (b.role == "TANK" and 1) or (b.role == "HEALER" and 2) or 3
            if ra ~= rb then return ra < rb end
            return (a.damage or 0) > (b.damage or 0)
        end)
        groupList:SetData(obsList)

        chatList:SetData(run.chat or {})
    end
end

ns.OnInit(function()
    UI.RegisterTab("History", 20, build)
end)
