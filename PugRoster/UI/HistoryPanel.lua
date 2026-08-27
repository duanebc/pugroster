-- UI/HistoryPanel.lua -- browsable run history: the run list, its group, its chat.

local ADDON, ns = ...
local UI = ns.UI

local panel = {}
ns.HistoryPanel = panel

local LIST_WIDTH = 250

local state = {
    selectedRun = nil,     -- "run:<id>" or "fight:<id>"
    personFilter = nil,    -- personId, set by the roster panel
    contentFilter = nil,   -- nil = everything
}

-- Keys and fights live in separate stores -- Rating reads only the keys -- so
-- History has to merge them for display. A stable key across both is what lets
-- one selection and one filter cover the pair.
local function recordKey(record)
    return (record.keyLevel and "run:" or "fight:") .. tostring(record.id)
end

local function contentOf(record)
    return record.content or "mythic+"
end

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

    local function consider(record)
        if state.contentFilter and contentOf(record) ~= state.contentFilter then return end
        if guids then
            local hit = false
            for guid in pairs(guids) do
                if record.observations and record.observations[guid] then hit = true; break end
            end
            if not hit then return end
        end
        out[#out + 1] = record
    end

    for _, run in ipairs(ns.db.runs) do consider(run) end
    for _, fight in ipairs(ns.db.fights or {}) do consider(fight) end

    -- Newest first across both stores.
    table.sort(out, function(a, b)
        return (a.endedAt or a.startedAt or 0) > (b.endedAt or b.startedAt or 0)
    end)
    return out
end

local function resultText(run)
    -- A fight has no outcome to report, so it says what kind of content it was.
    if not run.keyLevel then
        return "|cff9b7fd6" .. (ns.CONTENT_LABEL[contentOf(run)] or contentOf(run)) .. "|r"
    end
    if run.disband then return "|cffff6666disbanded|r" end
    if not run.completed then return "|cffff6666abandoned|r" end
    if not run.timed then return "|cffd9a441over time|r" end
    -- A derived level came from the par thresholds rather than the client, and
    -- our elapsed can sit a few seconds either side of a boundary, so mark it
    -- instead of asserting a number we did not get told.
    return string.format("|cff5fd68ftimed +%d|r%s", run.upgrade or 1,
        run.upgradeDerived and "|cff7f7f7f?|r" or "")
end

-- Remove a record from whichever store owns it. A key feeds the rating pass and
-- a fight does not, so only a key deletion needs a recompute.
local function deleteRecord(record)
    if not record then return false end
    local store = record.keyLevel and ns.db.runs or ns.db.fights
    for i, r in ipairs(store or {}) do
        if r == record then
            table.remove(store, i)
            if record.keyLevel then ns.Rating.RecomputeAll() end
            return true
        end
    end
    return false
end

local function findRun(key)
    if not key then return nil end
    for _, run in ipairs(ns.db.runs) do
        if recordKey(run) == key then return run end
    end
    for _, fight in ipairs(ns.db.fights or {}) do
        if recordKey(fight) == key then return fight end
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

    -- Content filter. Only offers types that are actually present, so the menu
    -- reflects what you have done rather than everything the game contains.
    local contentBtn = UI.MenuButton(page, 130,
        function()
            return state.contentFilter
                and (ns.CONTENT_LABEL[state.contentFilter] or state.contentFilter)
                or "All content"
        end,
        function()
            local present = {}
            for _, run in ipairs(ns.db.runs) do present[contentOf(run)] = true end
            for _, f in ipairs(ns.db.fights or {}) do present[contentOf(f)] = true end

            local entries = { { text = "All content", checked = state.contentFilter == nil,
                func = function() state.contentFilter = nil; UI.Refresh() end } }
            for _, kind in ipairs(ns.CONTENT_TYPES) do
                if present[kind] then
                    entries[#entries + 1] = {
                        text = ns.CONTENT_LABEL[kind] or kind,
                        checked = state.contentFilter == kind,
                        func = function() state.contentFilter = kind; UI.Refresh() end,
                    }
                end
            end
            return entries
        end)
    contentBtn:SetPoint("RIGHT", clearBtn, "LEFT", -6, 0)
    contentBtn:SetHeight(20)

    -- Run list
    local runList = UI.ScrollList(page, 34, function(parent)
        local row = UI.MakeRow(parent)
        row.title = UI.Label(row, "", 12)
        row.title:SetPoint("TOPLEFT", 6, -3)
        row.sub = UI.Label(row, "", 10, { 0.6, 0.6, 0.68 })
        row.sub:SetPoint("TOPLEFT", 6, -18)
        row:SetScript("OnClick", function(self)
            state.selectedRun = self.run and recordKey(self.run) or nil
            UI.Refresh()
        end)
        return row
    end, function(row, run)
        row.run = run
        if run.keyLevel then
            row.title:SetText(string.format("%s |cffffffff+%d|r", run.dungeon or "?", run.keyLevel))
        else
            row.title:SetText(string.format("%s |cff7f7f7f%s|r",
                run.zone or "?", ns.FormatDuration(run.elapsed)))
        end
        row.sub:SetText(string.format("%s  %s", ns.FormatDate(run.endedAt or run.startedAt), resultText(run)))
        if state.selectedRun == recordKey(run) then
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
        { key = "name",   label = "name",   x = 6,   width = 184, align = "LEFT" },
        { key = "role",   label = "role",   x = 192, width = 50,  align = "LEFT" },
        { key = "deaths", label = "deaths", x = 242, width = 44,  align = "RIGHT" },
        { key = "kicks",  label = "kicks",  x = 288, width = 44,  align = "RIGHT" },
        { key = "disp",   label = "disp",   x = 334, width = 44,  align = "RIGHT" },
        { key = "dmg",    label = "dmg",    x = 380, width = 60,  align = "RIGHT" },
        { key = "dps",    label = "dps",    x = 442, width = 54,  align = "RIGHT" },
        { key = "heal",   label = "heal",   x = 498, width = 60,  align = "RIGHT" },
        { key = "hps",    label = "hps",    x = 560, width = 54,  align = "RIGHT" },
        { key = "flag",   label = "",       x = 616, width = 56,  align = "LEFT" },
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
        return ns.FormatCount(n)
    end

    -- The row renderer needs the record its rows belong to, for the rate columns.
    -- Refresh's own `run` local is out of scope by the time rows are drawn.
    local shownRecord

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
                    ns.Print(string.format("%s -- score %.2f over %d runs%s (%s)",
                        char.name or "?", char.score or 0, char.runs or 0,
                        (char.grouped or 0) > 0
                            and string.format(" and %d other session%s", char.grouped,
                                              char.grouped == 1 and "" or "s") or "",
                        char.autoTier or "Neutral"))
                end
            end
        end)
        return row
    end, function(row, obs)
        row.obs = obs
        row.cells.name:SetText(ns.NameWithRealm(obs.name, ns.ClassColor(obs.classFile)))
        row.cells.role:SetText(ns.RoleLabel(obs.role))
        row.cells.deaths:SetText(tostring(obs.deaths or 0))
        row.cells.kicks:SetText(tostring(obs.interrupts or 0))
        row.cells.disp:SetText(tostring(obs.dispels or 0))
        row.cells.dmg:SetText(short(obs.damage))
        row.cells.dps:SetText(short(ns.PerSecond(obs.damage, shownRecord)))
        row.cells.heal:SetText(short(obs.healing))
        row.cells.hps:SetText(short(ns.PerSecond(obs.healing, shownRecord)))
        row.cells.flag:SetText(obs.leftEarly and "|cffff6666left|r" or (obs.isPlayer and "|cff8f5fd6you|r" or ""))
    end)
    groupList:SetParent(detail)
    groupList:SetPoint("TOPLEFT", cols, "BOTTOMLEFT", 0, -2)
    groupList:SetPoint("RIGHT", detail, "RIGHT", -8, 0)
    groupList:SetHeight(120)

    -- Details assembles its combined Mythic+ segment slightly after the key ends,
    -- and a run captured before the bridge worked can still be recovered while
    -- Details holds the segment in memory. Both are worth one button.
    local repullBtn = UI.Button(detail, "Pull from Details", 140, function()
        local run = state.selectedRun and findRun(state.selectedRun)
        if not run then return end
        local ok, why = ns.DetailsBridge.Repull(run)
        ns.Print(ok and "pulled this run's numbers from Details."
            or ("could not pull from Details: " .. (why or "unknown")))
        UI.Refresh()
    end)
    repullBtn:SetPoint("TOPLEFT", groupList, "BOTTOMLEFT", 0, -6)
    repullBtn:SetHeight(18)

    -- Click twice to confirm, the same as the database wipe on the Debug tab, and
    -- for the same reason: a deletion is not undoable and a StaticPopup is
    -- Blizzard UI this addon has learned to keep away from.
    local deleteArmed, armedFor = false, nil
    local function disarmDelete(btn)
        deleteArmed, armedFor = false, nil
        btn:SetText("Delete")
    end

    local deleteBtn = UI.Button(detail, "Delete", 90, function(self)
        local run = state.selectedRun and findRun(state.selectedRun)
        if not run then return end

        if not deleteArmed then
            deleteArmed, armedFor = true, state.selectedRun
            self:SetText("|cffff5555confirm|r")
            C_Timer.After(4, function() disarmDelete(self) end)
            return
        end

        disarmDelete(self)
        if deleteRecord(run) then
            state.selectedRun = nil
            ns.Print("deleted that record.")
        end
        UI.Refresh()
    end)
    deleteBtn:SetPoint("LEFT", repullBtn, "RIGHT", 6, 0)
    deleteBtn:SetHeight(18)

    local chatHeader = UI.Label(detail, "Chat", 11, UI.COLORS.header)
    chatHeader:SetPoint("TOPLEFT", repullBtn, "BOTTOMLEFT", 0, -8)

    local chatList = UI.ScrollList(page, 16, function(parent)
        local row = UI.MakeRow(parent)
        row.text = UI.Label(row, "", 11)
        row.text:SetPoint("LEFT", 6, 0)
        row.text:SetWordWrap(false)
        return row
    end, function(row, line)
        local prefix = line.whisper and "|cffff80ff[w]|r " or ""
        local char = line.guid and ns.Roster.GetCharacter(line.guid)
        local who = line.name and ns.ShortName(line.name)
            or (line.secret and "|cff7f7f7fsomeone|r" or "?")
        local body = line.text
            or (line.secret and "|cff7f7f7f(hidden by the client)|r"
                or "|cff7f7f7f(not captured)|r")
        row.text:SetText(string.format("%s%s: |cffd8d8dd%s|r", prefix,
            line.name and ns.Colorize(who, char and ns.ClassColor(char.classFile)) or who,
            body))
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
            mode:SetText(string.format("%d recorded", #runs))
        end
        clearBtn:SetShown(state.personFilter ~= nil)

        runList:SetData(runs)

        -- The selection can point at a record the current filter hides, so
        -- confirm it is still on screen before keeping it.
        local visible = false
        for _, r in ipairs(runs) do
            if recordKey(r) == state.selectedRun then visible = true; break end
        end
        if not visible then state.selectedRun = runs[1] and recordKey(runs[1]) or nil end

        local run = state.selectedRun and findRun(state.selectedRun)

        local hasRun = run ~= nil

        -- Midnight hands other players' chat text over as a secret value, so a
        -- run can hold lines whose content we can never display. A header over an
        -- empty box is worse than no section: hide the lot unless at least one
        -- line actually has text. Options carries the explanation.
        local chat = (hasRun and run.chat) or {}
        local readable = 0
        for _, l in ipairs(chat) do if l.text then readable = readable + 1 end end
        local hasChat = hasRun and readable > 0
        title:SetShown(hasRun); meta:SetShown(hasRun); groupHeader:SetShown(hasRun)
        cols:SetShown(hasRun); chatHeader:SetShown(hasChat)
        groupList:SetShown(hasRun); chatList:SetShown(hasChat)
        repullBtn:SetShown(hasRun and not run.debug and ns.DetailsBridge.IsAvailable())
        deleteBtn:SetShown(hasRun)
        -- Arming is per record: selecting a different one must not leave a
        -- confirm primed against something you are no longer looking at.
        if deleteArmed and state.selectedRun ~= armedFor then disarmDelete(deleteBtn) end

        if not hasRun then
            if state.contentFilter and (#ns.db.runs > 0 or #(ns.db.fights or {}) > 0) then
                empty:SetText("nothing recorded for that content type yet.")
            elseif #ns.db.runs == 0 and #(ns.db.fights or {}) == 0 then
                empty:SetText("nothing recorded yet. Any fight lasting more than a few "
                    .. "seconds is kept -- a target dummy is the quickest way to see one.")
            else
                empty:SetText("select a run.")
            end
            return
        end
        empty:SetText("")

        if run.keyLevel then
            title:SetText(string.format("%s |cffffffff+%d|r  %s",
                run.dungeon or "?", run.keyLevel, resultText(run)))
        else
            title:SetText(string.format("%s  %s", run.zone or "?", resultText(run)))
        end

        local bits = { ns.FormatDate(run.endedAt or run.startedAt) }
        bits[#bits + 1] = "time " .. ns.FormatDuration(run.elapsed)
        -- Only worth saying when it differs: for a fight the two are the same,
        -- for a key the gap is the running between packs, and it is what the dps
        -- column divides by.
        if run.combatTime and math.abs(run.combatTime - (run.elapsed or 0)) > 5 then
            bits[#bits + 1] = "in combat " .. ns.FormatDuration(run.combatTime)
        end
        if not run.keyLevel then
            bits[#bits + 1] = ns.CONTENT_LABEL[contentOf(run)] or contentOf(run)
        end
        if run.par then
            bits[#bits + 1] = string.format("par %s (%s)", ns.FormatDuration(run.par), ns.FormatSigned(run.margin or 0))
        end
        if run.keyHolder then
            local holder = ns.Roster.GetCharacter(run.keyHolder)
            bits[#bits + 1] = "key: " .. (holder and ns.ShortName(holder.name) or "?")
        end
        if run.wipes and run.wipes > 0 then bits[#bits + 1] = run.wipes .. " wipes" end
        -- Say the count even when it is zero: an empty chat pane otherwise cannot
        -- be told apart from a chat pane that failed to draw.
        if readable > 0 then bits[#bits + 1] = string.format("%d chat", readable) end
        if run.debug then bits[#bits + 1] = "|cffd9a441simulated|r" end
        if run.detailsEnriched then
            bits[#bits + 1] = "details" .. (run.detailsSegment and (" (" .. run.detailsSegment .. ")") or "")
        end
        meta:SetText(table.concat(bits, "  -  "))

        shownRecord = run

        local obsList = {}
        for _, obs in pairs(run.observations or {}) do obsList[#obsList + 1] = obs end
        table.sort(obsList, function(a, b)
            local ra = (a.role == "TANK" and 1) or (a.role == "HEALER" and 2) or 3
            local rb = (b.role == "TANK" and 1) or (b.role == "HEALER" and 2) or 3
            if ra ~= rb then return ra < rb end
            return (a.damage or 0) > (b.damage or 0)
        end)
        groupList:SetData(obsList)

        chatList:SetData(chat)
    end
end

ns.OnInit(function()
    UI.RegisterTab("History", 20, build)
end)
