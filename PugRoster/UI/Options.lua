-- UI/Options.lua -- settings, tag management and data tools.

local ADDON, ns = ...
local UI = ns.UI

local panel = {}
ns.OptionsPanel = panel

local COLUMN = 300

local function check(parent, anchor, label, key)
    local cb = UI.CheckBox(parent, label,
        function() return ns.settings[key] end,
        function(v) ns.settings[key] = v end)
    cb:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
    return cb
end

-- Label plus a small numeric entry box.
local function number(parent, anchor, label, key, isFloat)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(COLUMN - 20, 22)
    holder:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -6)

    local box = UI.EditBox(holder, 56)
    box:SetPoint("LEFT", 4, 0)
    box:SetNumeric(not isFloat)
    box:SetScript("OnEnterPressed", function(self)
        local v = tonumber(self:GetText())
        if v then ns.settings[key] = v end
        self:ClearFocus()
        UI.Refresh()
    end)

    local fs = UI.Label(holder, label, 12)
    fs:SetPoint("LEFT", box, "RIGHT", 8, 0)

    holder.Refresh = function()
        if not box:HasFocus() then
            box:SetText(tostring(ns.settings[key] or 0))
        end
    end
    return holder
end

local function build(page)
    ----------------------------------------------------------------------------
    -- Left column
    ----------------------------------------------------------------------------
    local left = CreateFrame("Frame", nil, page)
    left:SetPoint("TOPLEFT", 0, 0)
    left:SetSize(COLUMN, 500)

    local refreshables = {}

    local capture = UI.Section(left, nil, "Capture")
    local c1 = check(left, capture, "Log party and instance chat", "captureChat")
    local c2 = check(left, c1, "Log whispers with groupmates", "captureWhispers")
    local c3 = check(left, c2, "Inspect groupmates for spec/ilvl", "inspectGroupmates")
    local c4 = check(left, c3, "Use Details when installed", "useDetails")
    local n1 = number(left, c4, "chat lines kept per run", "chatLinesPerRun")
    refreshables[#refreshables + 1] = n1

    local display = UI.Section(left, n1, "Display")
    local d1 = check(left, display, "Tier on player tooltips", "showTooltip")
    local d2 = check(left, d1, "Popup when a rated player joins", "showJoinPopup")
    local d3 = check(left, d2, "Badge applicants in group finder", "showLFGBadge")

    local rating = UI.Section(left, d3, "Rating")
    local r1 = check(left, rating, "Prefer companion refined tiers", "preferRefined")
    local n2 = number(left, r1, "runs before leaving Neutral", "minRunsForTier")
    local n3 = number(left, n2, "weight: previous season", "seasonDecay", true)
    local n4 = number(left, n3, "weight: older seasons", "olderDecay", true)
    refreshables[#refreshables + 1] = n2
    refreshables[#refreshables + 1] = n3
    refreshables[#refreshables + 1] = n4

    ----------------------------------------------------------------------------
    -- Right column
    ----------------------------------------------------------------------------
    local right = CreateFrame("Frame", nil, page)
    right:SetPoint("TOPLEFT", COLUMN, 0)
    right:SetPoint("BOTTOMRIGHT", 0, 0)

    local messaging = UI.Section(right, nil, "Messaging")
    local m1 = check(right, messaging, "Prefer Battle.net whispers", "preferBNet")
    local m2 = check(right, m1, "Offer people whose status is unknown", "includeUnknownOnline")
    local m3 = check(right, m2, "Skip people already in a dungeon or raid", "skipBusyPlayers")
    local n5 = number(right, m3, "seconds between sends", "sendStagger", true)
    local n6 = number(right, n5, "seconds before re-messaging someone", "messageCooldownSeconds")
    local n6b = number(right, n6, "messages kept in Recently sent", "maxSentLog")
    refreshables[#refreshables + 1] = n5
    refreshables[#refreshables + 1] = n6
    refreshables[#refreshables + 1] = n6b

    local data = UI.Section(right, n6b, "Data")
    local n7 = number(right, data, "keys kept in game", "maxRunsInGame")
    local n8 = number(right, n7, "other fights kept", "maxFightsInGame")
    local n9 = number(right, n8, "maximum saved data (MB)", "maxStorageMB")
    refreshables[#refreshables + 1] = n7
    refreshables[#refreshables + 1] = n8
    refreshables[#refreshables + 1] = n9

    local companion = UI.Label(right, "", 11, { 0.65, 0.62, 0.72 })
    companion:SetPoint("TOPLEFT", n9, "BOTTOMLEFT", 4, -8)
    companion:SetWidth(COLUMN - 20)
    companion:SetJustifyV("TOP")

    local rateBtn = UI.Button(right, "Recompute tiers", 130, function()
        local n = ns.Rating.RecomputeAll()
        ns.Print("recomputed", n, "characters.")
    end)
    rateBtn:SetPoint("TOPLEFT", companion, "BOTTOMLEFT", -4, -30)

    local linkBtn = UI.Button(right, "Sync BNet links", 130, function()
        local n = ns.Roster.SyncBNetLinks()
        ns.Print("linked", n, "characters by Battle.net account.")
        UI.Refresh()
    end)
    linkBtn:SetPoint("LEFT", rateBtn, "RIGHT", 6, 0)

    ----------------------------------------------------------------------------
    -- Tag manager
    ----------------------------------------------------------------------------
    local tagLabel = UI.Label(right, "Tags", 12, UI.COLORS.accent)
    tagLabel:SetPoint("TOPLEFT", rateBtn, "BOTTOMLEFT", 0, -14)

    local newTag = UI.EditBox(right, 180, function(text)
        if text and text ~= "" then
            ns.Roster.EnsureTag(text, "Custom")
            ns.Print("tag created:", text)
        end
        UI.Refresh()
    end)
    newTag:SetPoint("TOPLEFT", tagLabel, "BOTTOMLEFT", 4, -4)

    local newTagHint = UI.Label(right, "type a name and press enter", 10, { 0.45, 0.45, 0.52 })
    newTagHint:SetPoint("LEFT", newTag, "RIGHT", 8, 0)

    local tagList = UI.ScrollList(right, 18, function(parent)
        local row = UI.MakeRow(parent)
        row.text = UI.Label(row, "", 11)
        row.text:SetPoint("LEFT", 6, 0)
        row.del = UI.Button(row, "x", 18, function()
            if row.tag then
                ns.Roster.DeleteTag(row.tag)
                UI.Refresh()
            end
        end)
        row.del:SetPoint("RIGHT", -4, 0)
        row.del:SetHeight(15)
        return row
    end, function(row, item)
        row.tag = item.tag
        local uses = 0
        for _, person in pairs(ns.db.persons) do
            if person.tags[item.tag] then uses = uses + 1 end
        end
        row.text:SetText(string.format("%s |cff6a6a75%s - %d|r", item.tag, item.category, uses))
    end)
    tagList:SetPoint("TOPLEFT", newTag, "BOTTOMLEFT", -4, -6)
    tagList:SetPoint("BOTTOMRIGHT", right, "BOTTOMRIGHT", -8, 8)

    ----------------------------------------------------------------------------
    page.Refresh = function()
        for _, r in ipairs(refreshables) do r.Refresh() end
        for _, cb in ipairs({ c1, c2, c3, c4, d1, d2, d3, r1, m1, m2, m3 }) do cb:Refresh() end

        local runs, chars = #ns.db.runs, ns.Roster.CountCharacters()
        local unexported = 0
        for _, run in ipairs(ns.db.runs) do
            if not run.exported then unexported = unexported + 1 end
        end

        local lookup
        if ns.Lookup.IsPresent() and ns.Lookup.GeneratedAt() then
            lookup = "companion data from " .. ns.FormatDate(ns.Lookup.GeneratedAt())
        else
            lookup = "no companion data yet (run |cffffff00pugroster all|r)"
        end

        -- Whether the combat log is reachable at all is not a preference, but it
        -- decides what a run record can contain, so it belongs next to the counts.
        local chat = ns.ChatLog.textWithheld
            and "|cffd9a441chat log: this client withholds other players' text|r"
            or "chat log: capturing party, instance and whisper lines"

        local cleu = ns.CombatLog.available
            and "combat log: capturing deaths, interrupts, dispels and CC"
            or "|cffd9a441combat log: unavailable on this client|r - outcome and "
                .. "Details still recorded, per-player combat tallies are not"

        -- What it costs to keep. Measured rather than estimated: the limit above
        -- is only a limit if the number beside it is true.
        local size = ns.MeasureDB()
        local budget = ns.Housekeeping.Budget()
        local store = string.format("%d records, %s saved of %d MB",
            size.records,
            size.bytes >= 1048576
                and string.format("%.2f MB", size.bytes / 1048576)
                or string.format("%d KB", math.floor(size.bytes / 1024)),
            math.floor(budget / 1048576))
        if budget > 0 and size.bytes > budget * 0.8 then
            store = "|cffd9a441" .. store .. "|r"
        end

        companion:SetText(string.format(
            "%d runs, %d characters, %d persons\n%s\n%d runs awaiting export\n%s\n%s\n%s",
            runs, chars, #ns.Roster.AllPersons(), store, unexported, cleu, chat, lookup))

        local tags = {}
        for tag, info in pairs(ns.db.tags) do
            tags[#tags + 1] = { tag = tag, category = info.category or "Custom" }
        end
        table.sort(tags, function(a, b)
            if a.category ~= b.category then return a.category < b.category end
            return a.tag < b.tag
        end)
        tagList:SetData(tags)
    end
end

ns.OnInit(function()
    UI.RegisterTab("Options", 40, build)
end)
