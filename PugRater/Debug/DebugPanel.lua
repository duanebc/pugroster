-- Debug/DebugPanel.lua -- every development affordance in one pane.
--
-- This is the UI half of /pugdebug. It calls the same functions the slash router
-- does, so there is one implementation of each action and two ways to reach it.
--
-- The whole file sits inside the #@debug@ block and .pkgmeta ignores Debug/, so
-- a released build contains no debug UI at all -- not hidden, absent. Nothing in
-- production references this file: the tab appears because the file registers
-- it, and disappears because the file is gone.
--
-- Master switch: when debug mode is off the addon behaves as a released build,
-- so every control here greys out. The one exception is "Remove all test data",
-- which stays live -- disabling it would trap seeded records in the database
-- with no way to clear them from the UI.

local ADDON, ns = ...
local UI = ns.UI

local panel = {}
ns.DebugPanel = panel

local COLUMN = 300

--------------------------------------------------------------------------------
-- Forbidden/blocked capture
--
-- Core does the recording, because the only legal way to see a forbidden action
-- is to hook StaticPopup_Show -- registering for ADDON_ACTION_FORBIDDEN is
-- itself a forbidden action, and an addon that tries it spends the rest of the
-- session reporting its own registration. This file only renders what Core
-- collected, so the capture is running whether or not the tab was ever opened.
--
-- Each entry pairs the refused function with ns.TraceLog's breadcrumbs: a
-- refusal 3ms after "tooltip:unit" is a tooltip-hook refusal. The event is
-- dispatched at a frame boundary rather than inside the offending call, so a
-- traceback would show the dispatch and nothing useful -- the breadcrumb trail
-- is what survives.
--------------------------------------------------------------------------------

function panel.CaptureText()
    local log = ns.ForbiddenLog()
    if #log == 0 then
        return "Nothing captured yet.\n\n"
            .. "Reproduce the popup. Each refusal is logged here with the "
            .. "function that was refused and what PugRater was doing in the "
            .. "moments before it, newest first."
    end

    local out = {}
    for i, c in ipairs(log) do
        out[#out + 1] = string.format("%d. %s   (%s)\n%s",
            i, c.func, ns.TimeAgo(c.when), c.trace)
    end
    return table.concat(out, "\n\n")
end

function panel.ClearCaptures()
    wipe(ns.ForbiddenLog())
end

--------------------------------------------------------------------------------
-- Layout helpers
--
-- Options.lua binds its check/number helpers to ns.settings; these bind to
-- arbitrary getters, because most of what this pane edits is transient state
-- rather than a saved setting.
--------------------------------------------------------------------------------

local function below(widget, anchor, dy, dx)
    widget:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", dx or 0, dy or -6)
    return widget
end

local function hint(parent, anchor, text)
    local fs = UI.Label(parent, text, 10, { 0.45, 0.45, 0.52 })
    fs:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 4, -3)
    fs:SetWidth(COLUMN - 24)
    fs:SetJustifyH("LEFT")
    return fs
end

-- A numeric entry box holding its own value rather than a setting.
local function counter(parent, anchor, default, dx)
    local box = UI.EditBox(parent, 44)
    box:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", dx or 0, -6)
    box:SetNumeric(true)
    box:SetText(tostring(default))
    box.Value = function(self, lo, hi)
        local v = tonumber(self:GetText()) or default
        return math.min(math.max(math.floor(v), lo), hi)
    end
    return box
end

--------------------------------------------------------------------------------
-- The pane
--------------------------------------------------------------------------------

local function build(page)
    local Debug = ns.Debug
    local controls = {}      -- everything the master switch greys out

    local function track(widget)
        controls[#controls + 1] = widget
        return widget
    end

    ----------------------------------------------------------------------------
    -- Left column
    ----------------------------------------------------------------------------
    local left = CreateFrame("Frame", nil, page)
    left:SetPoint("TOPLEFT", 0, 0)
    left:SetSize(COLUMN, 500)

    local master = UI.CheckBox(left, "Debug mode enabled",
        function() return Debug.IsEnabled() end,
        function(v) Debug.SetEnabled(v) end)
    master:SetPoint("TOPLEFT", 14, -12)
    local masterHint = hint(left, master,
        "Off makes PugRater behave exactly as a released build does: no echo, no "
        .. "fake friends list, no /pugdebug commands, simulated people blocked "
        .. "from real sends.")

    local gen = UI.Section(left, masterHint, "Generate", -4)

    local genAll = track(UI.Button(left, "Generate all test data", 180, function()
        ns.FakeRoster.Seed(12)
        ns.EventSim.SeedRuns(50)
        ns.FakeRoster.SetOnline(true)
        ns.EchoSender.SetEnabled(true)
        UI.Refresh()
    end))
    below(genAll, gen, -6, 4)

    local peopleBox = track(counter(left, genAll, 12, 4))
    local seedRoster = track(UI.Button(left, "Seed roster", 110, function()
        ns.FakeRoster.Seed(peopleBox:Value(1, 24))
        UI.Refresh()
    end))
    seedRoster:SetPoint("LEFT", peopleBox, "RIGHT", 6, 0)
    local peopleHint = hint(left, peopleBox, "people (max 24 -- the recurring cast is 24 strong)")

    local runsBox = track(counter(left, peopleHint, 50, 0))
    local seedRuns = track(UI.Button(left, "Seed history", 110, function()
        ns.EventSim.SeedRuns(runsBox:Value(1, 300))
        UI.Refresh()
    end))
    seedRuns:SetPoint("LEFT", runsBox, "RIGHT", 6, 0)
    local runsHint = hint(left, runsBox, "finished runs written straight to history (max 300)")

    -- One simulated key: level, dungeon, outcome flags.
    local levelBox = track(counter(left, runsHint, 12, 0))

    local chosenDungeon
    local dungeonBtn = track(UI.MenuButton(left, 150,
        function() return chosenDungeon or "random dungeon" end,
        function()
            local entries = { { text = "random dungeon", func = function()
                chosenDungeon = nil
                UI.Refresh()
            end } }
            for _, d in ipairs(ns.FakeRun.Dungeons()) do
                entries[#entries + 1] = { text = d.name, func = function()
                    chosenDungeon = d.name
                    UI.Refresh()
                end }
            end
            return entries
        end))
    dungeonBtn:SetPoint("LEFT", levelBox, "RIGHT", 6, 0)

    local flags = { fail = false, disband = false, leave = false }
    local function flagCheck(label, key, anchor)
        local cb = track(UI.CheckBox(left, label,
            function() return flags[key] end,
            function(v) flags[key] = v end))
        cb:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
        return cb
    end

    local failCb    = flagCheck("not completed", "fail", levelBox)
    local disbandCb = flagCheck("group disbanded", "disband", failCb)
    local leaveCb   = flagCheck("someone leaves early", "leave", disbandCb)

    local wipesBox = track(counter(left, leaveCb, 0, 0))
    local runBtn = track(UI.Button(left, "Simulate run", 130, function()
        local wipes = wipesBox:Value(0, 20)
        ns.EventSim.Run({
            level   = levelBox:Value(2, 40),
            dungeon = chosenDungeon,
            fail    = flags.fail or nil,
            disband = flags.disband or nil,
            leave   = flags.leave or nil,
            wipes   = wipes > 0 and wipes or nil,
        })
        UI.Refresh()
    end))
    runBtn:SetPoint("LEFT", wipesBox, "RIGHT", 6, 0)
    local wipesHint = hint(left, wipesBox, "wipes (0 = let the outcome decide)")

    local onlineCb = track(UI.CheckBox(left, "Fake friends list",
        function() return Debug._onlineIndex ~= nil end,
        function(v) ns.FakeRoster.SetOnline(v) end))
    onlineCb:SetPoint("TOPLEFT", wipesHint, "BOTTOMLEFT", -4, -8)
    local onlineHint = hint(left, onlineCb,
        "Only indexes simulated characters, so seed a roster first or it is empty.")

    local rem = UI.Section(left, onlineHint, "Remove", -4)

    -- Deliberately NOT tracked: this one stays usable with debug mode off, so
    -- seeded records can always be cleared.
    local wipeFakeBtn = UI.Button(left, "Remove all test data", 160, function()
        Debug.WipeFake()
        UI.Refresh()
    end)
    below(wipeFakeBtn, rem, -6, 4)

    -- Click twice to confirm, rather than a StaticPopup. Given the trouble this
    -- addon has had with Blizzard widgets, new UI stays on our own frames.
    local wipeArmed = false
    local wipeAllBtn = track(UI.Button(left, "Wipe entire database", 160, function(self)
        if not wipeArmed then
            wipeArmed = true
            self:SetText("click again to confirm")
            C_Timer.After(4, function()
                wipeArmed = false
                self:SetText("Wipe entire database")
            end)
            return
        end
        wipeArmed = false
        self:SetText("Wipe entire database")
        Debug.WipeAll()
    end))
    below(wipeAllBtn, wipeFakeBtn, -6, 0)
    hint(left, wipeAllBtn, "Everything, real runs included. Needs a /reload afterwards.")

    ----------------------------------------------------------------------------
    -- Right column
    ----------------------------------------------------------------------------
    local right = CreateFrame("Frame", nil, page)
    right:SetPoint("TOPLEFT", COLUMN + 10, 0)
    right:SetPoint("BOTTOMRIGHT", 0, 0)

    local sandbox = UI.Section(right, nil, "Messaging sandbox")

    local echoCb = track(UI.CheckBox(right, "Echo sends (nothing is whispered)",
        function() return ns.EchoSender.IsEnabled() end,
        function(v) ns.EchoSender.SetEnabled(v) end))
    below(echoCb, sandbox, -4, 0)

    local replyName = track(UI.EditBox(right, 110))
    below(replyName, echoCb, -6, 0)
    local replyText = track(UI.EditBox(right, 190))
    replyText:SetPoint("LEFT", replyName, "RIGHT", 6, 0)

    local replyBtn = track(UI.Button(right, "Simulate reply", 120, function()
        local who, what = replyName:GetText(), replyText:GetText()
        if who == "" or what == "" then
            Debug.Print("enter a name and a reply first.")
            return
        end
        ns.EchoSender.SimulateReply(who, what)
        UI.Refresh()
    end))
    below(replyBtn, replyName, -6, 0)
    local replyHint = hint(right, replyBtn,
        "Name, then what they whisper back. Only works once you have messaged "
        .. "them from the Send tab.")

    local inspect = UI.Section(right, replyHint, "Inspect", -4)

    local tierName = track(UI.EditBox(right, 140))
    below(tierName, inspect, -4, 4)
    local tierBtn = track(UI.Button(right, "Tier breakdown", 130, function()
        if tierName:GetText() == "" then
            Debug.Print("enter a character name first.")
            return
        end
        Debug.TierBreakdown(tierName:GetText())
    end))
    tierBtn:SetPoint("LEFT", tierName, "RIGHT", 6, 0)

    local detailsBtn = track(UI.Button(right, "Details report", 130, function()
        for _, line in ipairs(ns.DetailsBridge.Report()) do ns.Print(line) end
    end))
    detailsBtn:SetPoint("LEFT", tierBtn, "RIGHT", 6, 0)

    local exportBtn = track(UI.Button(right, "Export in-progress run", 170, function()
        Debug.ExportState()
    end))
    below(exportBtn, tierName, -6, -4)

    local verboseCb = track(UI.CheckBox(right, "Verbose logging",
        function() return Debug.verbose end,
        function(v) Debug.verbose = v end))
    below(verboseCb, exportBtn, -6, 0)

    local taint = UI.Section(right, verboseCb, "Taint", -4)

    -- Neither of these is tracked: hunting a forbidden call is exactly what you
    -- do with debug mode off, since off is the shape a released build has.
    local popupCb = UI.CheckBox(right, "Blocked-action popup",
        function() return Debug.PopupEnabled() end,
        function(v) Debug.SetPopup(v) end)
    below(popupCb, taint, -4, 0)

    local taintBtn = UI.Button(right, "Taint log on", 110, function()
        local ok = pcall(SetCVar, "taintLog", "2")
        if ok then
            Debug.Print("taint logging on. Log: |cffffff00_retail_\\Logs\\taint.log|r."
                .. " |cffffff00/console taintLog 0|r when you are done.")
        else
            Debug.Print("could not set the CVar. Run |cffffff00/console taintLog 2|r"
                .. " then |cffffff00/reload|r.")
        end
    end)
    below(taintBtn, popupCb, -6, 0)

    local clearBtn = UI.Button(right, "Clear captures", 110, function()
        panel.ClearCaptures()
        UI.Refresh()
    end)
    clearBtn:SetPoint("LEFT", taintBtn, "RIGHT", 6, 0)

    local capture = UI.MultiLineBox(right, COLUMN + 190, 130)
    capture:SetPoint("TOPLEFT", taintBtn, "BOTTOMLEFT", 0, -6)

    local counts = UI.Label(right, "", 11, { 0.65, 0.62, 0.72 })
    counts:SetPoint("TOPLEFT", capture, "BOTTOMLEFT", 4, -8)
    counts:SetWidth(COLUMN + 190)
    counts:SetJustifyH("LEFT")

    ----------------------------------------------------------------------------
    local checkboxes = { master, failCb, disbandCb, leaveCb, onlineCb, echoCb,
                         verboseCb, popupCb }

    page.Refresh = function()
        local on = Debug.IsEnabled()

        for _, cb in ipairs(checkboxes) do cb:Refresh() end
        dungeonBtn:Refresh()

        for _, widget in ipairs(controls) do
            if widget.SetEnabled then
                widget:SetEnabled(on)
            elseif on then widget:Enable() else widget:Disable() end
            -- Our own buttons dim their own label and background; anything else
            -- needs the frame alpha, and doing both would double-dim.
            if not widget.label then widget:SetAlpha(on and 1 or 0.4) end
        end
        master:SetEnabled(true)
        master:SetAlpha(1)

        -- A simulated run plays out over a few seconds of timers and refuses to
        -- re-enter, so say so on the button rather than in chat.
        if on and ns.EventSim.IsRunning() then
            runBtn:SetEnabled(false)
            runBtn:SetText("simulating...")
        else
            runBtn:SetText("Simulate run")
        end

        if not capture.editBox:HasFocus() then
            capture.editBox:SetText(panel.CaptureText())
            capture.editBox:SetCursorPosition(0)
        end

        local simRuns, simChars, simPersons, simGroups, groups = 0, 0, 0, 0, 0
        for _, run in ipairs(ns.db.runs) do if run.debug then simRuns = simRuns + 1 end end
        for _, c in pairs(ns.db.characters) do if c.debug then simChars = simChars + 1 end end
        for _, p in pairs(ns.db.persons) do if p.debug then simPersons = simPersons + 1 end end
        for _, g in pairs(ns.db.savedGroups) do
            groups = groups + 1
            if g.debug then simGroups = simGroups + 1 end
        end

        counts:SetText(string.format(
            "|cff8f5fd6Database|r   runs %d (%d simulated)   characters %d (%d)   "
            .. "people %d (%d)   saved groups %d (%d)",
            #ns.db.runs, simRuns, ns.Roster.CountCharacters(), simChars,
            #ns.Roster.AllPersons(), simPersons, groups, simGroups))
    end
end

ns.OnInit(function()
    UI.RegisterTab("Debug", 50, build)
end)
