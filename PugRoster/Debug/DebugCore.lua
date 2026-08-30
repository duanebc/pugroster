-- Debug/DebugCore.lua -- the /pugdebug command router and shared debug state.
--
-- Everything under Debug/ exists so the addon can be developed without running a
-- 30-minute key per iteration. Fake data is flagged `debug = true` on every
-- record it creates, so the companion can skip it and `/pugdebug wipe fake` can
-- remove exactly the synthetic rows.

local ADDON, ns = ...

local Debug = {}
ns.Debug = Debug

Debug.verbose = false

function Debug.Print(...)
    ns.Print("|cffd9a441[debug]|r", ...)
end

--------------------------------------------------------------------------------
-- The master switch
--
-- Off means "behave like a released build". Production code only ever reaches
-- debug functionality through `if ns.Debug and ns.Debug.X then`, so switching
-- off is not a matter of adding checks over there -- it is a matter of clearing
-- every seam over here. With EchoSend, EchoInvite and _onlineIndex nil, the real
-- send path, the real friends list and the real block rules are what run.
--
-- The flag lives on the database root rather than in ns.settings, so no debug
-- key ever appears in the production defaults table. Absent means on.
--------------------------------------------------------------------------------

function Debug.IsEnabled()
    return ns.db and ns.db.debugEnabled ~= false
end

function Debug.SetEnabled(on)
    on = on and true or false
    ns.db.debugEnabled = on

    if on then
        -- Restore what was remembered rather than forcing echo on. Turning debug
        -- mode back on should not quietly stop your messages being sent.
        ns.EchoSender.SetEnabled(ns.db.debugEcho == true)
    else
        -- Both seams have to end up nil. EchoSender refuses to re-arm while we
        -- are off, so this cannot be undone by toggling echo.
        ns.EchoSender.SetEnabled(false)
        ns.FakeRoster.SetOnline(false)
    end

    Debug.Print("debug mode", on and "|cff5fd68fon|r"
        or "|cffff6666off|r -- the addon now behaves as a released build does.")
    if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
end

--------------------------------------------------------------------------------
-- Seams used by production code
--
-- RunTracker asks for these before touching the live API, and Sender routes
-- through EchoSend. They return nil unless a simulation has armed them, so the
-- real code paths are untouched when nothing is being faked.
--------------------------------------------------------------------------------

function Debug.StartContext()      return Debug._startContext end
function Debug.CompletionContext() return Debug._completionContext end
function Debug.GroupSnapshot()     return Debug._groupSnapshot end
function Debug.OnlineIndex()       return Debug._onlineIndex end

--------------------------------------------------------------------------------
-- Wipes
--------------------------------------------------------------------------------

function Debug.WipeAll()
    PugRosterDB = nil
    Debug.Print("database cleared. |cffffff00/reload|r to reinitialise.")
end

function Debug.HasFakeData()
    local db = ns.db
    for _, run in ipairs(db.runs) do if run.debug then return true end end
    for _, char in pairs(db.characters) do if char.debug then return true end end
    for _, group in pairs(db.savedGroups) do if group.debug then return true end end
    for _, rec in ipairs(db.sentLog) do if rec.debug then return true end end
    return (db.activeRun and db.activeRun.debug) and true or false
end

function Debug.WipeFake()
    local db = ns.db
    local removedRuns = 0

    for i = #db.runs, 1, -1 do
        if db.runs[i].debug then
            table.remove(db.runs, i)
            removedRuns = removedRuns + 1
        end
    end

    local removedChars = 0
    for guid, char in pairs(db.characters) do
        if char.debug then
            local person = ns.Roster.GetPerson(char.personId)
            if person then person.characters[guid] = nil end
            db.characters[guid] = nil
            removedChars = removedChars + 1
        end
    end

    for id, person in pairs(db.persons) do
        if person.debug or not next(person.characters) then db.persons[id] = nil end
    end

    -- Everything else a seed touches. These are not roster records, so nothing
    -- else would ever collect them.
    local removedGroups = 0
    for name, group in pairs(db.savedGroups) do
        if group.debug then db.savedGroups[name] = nil; removedGroups = removedGroups + 1 end
    end

    local removedSends = 0
    for i = #db.sentLog, 1, -1 do
        if db.sentLog[i].debug then
            table.remove(db.sentLog, i)
            removedSends = removedSends + 1
        end
    end

    if db.activeRun and db.activeRun.debug then db.activeRun = nil end
    Debug._onlineIndex = nil

    ns.Rating.RecomputeAll()
    Debug.Print(string.format(
        "removed %d simulated runs, %d characters, %d saved groups and %d sent-log entries.",
        removedRuns, removedChars, removedGroups, removedSends))
end

--------------------------------------------------------------------------------
-- Inspection
--------------------------------------------------------------------------------

function Debug.TierBreakdown(name)
    local char = ns.Roster.FindCharacterByName(name)
    if not char then
        Debug.Print("no character known as", name)
        return
    end

    local b = ns.Rating.Breakdown(char.guid)
    Debug.Print(string.format("%s -- %s (score %.3f over %d runs, total weight %.2f)",
        char.name or "?", b.tier, b.score, b.runs, b.weight))

    for _, line in ipairs(b.lines) do
        ns.Print(string.format("  |cffb9a4d6%s|r  run %+.2f  x weight %.2f  (decay %.2f)",
            line.header, line.value, line.weight, line.decay))
        for _, part in ipairs(line.parts) do
            ns.Print(string.format("      %-42s %+.3f", part.label, part.value))
        end
    end

    local person = ns.Roster.GetPerson(char.personId)
    if person then
        local tier, source = ns.Roster.EffectiveTier(person)
        ns.Print(string.format("  effective: |cffffffff%s|r (from %s)", tier, source))
    end
end

function Debug.ExportState()
    local run = ns.RunTracker.Active()
    if not run then
        Debug.Print("no run in progress. recorded runs:", #ns.db.runs)
        return
    end

    Debug.Print(string.format("active: %s +%d, started %s%s",
        run.dungeon or "?", run.keyLevel or 0, ns.FormatDate(run.startedAt),
        run.debug and " (simulated)" or ""))
    for guid, obs in pairs(run.observations) do
        ns.Print(string.format("  %-24s %-7s deaths %d  kicks %d  disp %d  dmg %s%s",
            ns.ShortName(obs.name), (obs.role or "-"):lower(),
            obs.deaths or 0, obs.interrupts or 0, obs.dispels or 0,
            AbbreviateLargeNumbers and AbbreviateLargeNumbers(obs.damage or 0) or (obs.damage or 0),
            obs.leftEarly and "  LEFT" or ""))
    end
    ns.Print(string.format("  %d chat lines captured", #(run.chat or {})))
end

--------------------------------------------------------------------------------
-- Router
--------------------------------------------------------------------------------

local USAGE = {
    "|cff8f5fd6/pugdebug|r commands:",
    "  |cffffff00on|r|off -- master switch; off makes the addon behave as a released build",
    "  |cffffff00run|r [level] [dungeon] [--fail|--disband|--leave|--wipes] -- simulate one full key through the real event pipeline",
    "  |cffffff00seed|r [n] -- bulk-generate n historical runs for rating and decay testing",
    "  |cffffff00roster|r [n] -- seed persons, characters, tags and saved groups",
    "  |cffffff00online|r [on|off] -- fake a friends list so the Send tab has recipients",
    "  |cffffff00reply|r <name> <text> -- simulate a whisper back from someone you messaged",
    "  |cffffff00echo|r [on|off] -- intercept sends and print them locally (on by default)",
    "  |cffffff00tier|r <name> -- print the full rating breakdown",
    "  |cffffff00export|r -- dump the in-progress run",
    "  |cffffff00details|r [meter] -- what the server and Details answer; name a meter (deaths, interrupts) to narrow it",
    "  |cffffff00defprobe|r [seconds] -- which API can still see defensive cooldowns, over a fixed window",
    "  |cffffff00defprobe start|r/|cffffff00stop|r -- the same, open-ended, for a whole key; |cffffff00show|r lists runs, |cffffff00clear|r drops them",
    "  |cffffff00defstats|r [clear] -- what the defensive capture saw, and which auras it did not recognise",
    "  |cffffff00defprobe verbose|r -- runs record quietly by default; this prints the report as it finishes",
    "  |cffffff00wipe|r [fake] -- clear everything, or only simulated records",
    "  |cffffff00popup|r [on|off] -- show or silence the blocked-action popup while debugging",
}

--------------------------------------------------------------------------------
-- Session lifetime
--
-- Simulated data is a session tool, not history. It has to survive a /reload --
-- resuming a key across one is a feature that needs testing -- but it must never
-- age into the database, so a fresh login drops whatever last session left
-- behind. IsLoggedIn() is false during the initial login's ADDON_LOADED and true
-- on a reload, which is exactly the distinction we need.
--------------------------------------------------------------------------------

ns.OnInit(function()
    if IsLoggedIn() then return end
    if not Debug.HasFakeData() then return end
    Debug.Print("clearing last session's simulated data.")
    Debug.WipeFake()
end)

--------------------------------------------------------------------------------
-- Blocked-action popup
--------------------------------------------------------------------------------

-- UIParent owns the "disable this addon and reload" popup. Silencing it while
-- hunting a forbidden call is reasonable -- Core still records the refused
-- function by hooking StaticPopup_Show -- but it hides the popup for every
-- addon, so it is deliberate, on by default, and dev builds only.
--
-- One-way: unregistering is ordinary, but re-registering those two events is
-- itself a forbidden action and would raise the very popup it is meant to
-- restore. A /reload is what brings it back.
function Debug.PopupEnabled()
    return Debug._popup ~= false
end

function Debug.SetPopup(on)
    if on then
        if Debug._popup == false then
            Debug.Print("the popup comes back on |cffffff00/reload|r -- re-registering"
                .. " those events is itself a forbidden action.")
        end
        return
    end

    Debug._popup = false
    UIParent:UnregisterEvent("ADDON_ACTION_FORBIDDEN")
    UIParent:UnregisterEvent("ADDON_ACTION_BLOCKED")
    Debug.Print("blocked-action popup |cffff6666off|r for every addon until"
        .. " |cffffff00/reload|r. Refusals are still recorded on the Debug tab.")
end

SLASH_PUGDEBUG1 = "/pugdebug"
SlashCmdList.PUGDEBUG = function(msg)
    local args = {}
    for word in (msg or ""):gmatch("%S+") do args[#args + 1] = word end
    local cmd = (args[1] or ""):lower()

    if cmd == "on" or cmd == "off" then
        Debug.SetEnabled(cmd == "on")
        return
    end

    -- Everything else is a development action, and development actions are
    -- exactly what "behave like a released build" has to switch off.
    if not Debug.IsEnabled() then
        Debug.Print("debug mode is off. |cffffff00/pugdebug on|r to re-enable.")
        return
    end

    if cmd == "run" then
        ns.EventSim.SimulateRun(args)

    elseif cmd == "seed" then
        local n = tonumber(args[2]) or 20
        ns.EventSim.SeedRuns(n)

    elseif cmd == "roster" then
        ns.FakeRoster.Seed(tonumber(args[2]) or 12)

    elseif cmd == "online" then
        local on = (args[2] or "on"):lower() ~= "off"
        ns.FakeRoster.SetOnline(on)

    elseif cmd == "reply" then
        local name = args[2]
        local text = table.concat(args, " ", 3)
        if not name or text == "" then
            Debug.Print("usage: /pugdebug reply <name> <text>")
        else
            ns.EchoSender.SimulateReply(name, text)
        end

    elseif cmd == "echo" then
        ns.EchoSender.SetEnabled((args[2] or "on"):lower() ~= "off")

    elseif cmd == "tier" then
        if args[2] then Debug.TierBreakdown(args[2]) else Debug.Print("usage: /pugdebug tier <name>") end

    elseif cmd == "export" then
        Debug.ExportState()

    elseif cmd == "details" then
        Debug.Print("Details report:")
        for _, line in ipairs(ns.DetailsBridge.Report(nil, args[2])) do ns.Print(line) end

    elseif cmd == "defprobe" then
        local sub = (args[2] or ""):lower()
        if sub == "show" then ns.DefProbe.Show()
        elseif sub == "clear" then ns.DefProbe.Clear()
        elseif sub == "start" then ns.DefProbe.Start()
        elseif sub == "stop" then ns.DefProbe.Stop()
        elseif sub == "verbose" then
            ns.DefProbe.verbose = not ns.DefProbe.verbose
            Debug.Print("defprobe chatter", ns.DefProbe.verbose and "on" or "off")
        else ns.DefProbe.Run(args[2]) end

    elseif cmd == "wipe" then
        if (args[2] or ""):lower() == "fake" then Debug.WipeFake() else Debug.WipeAll() end

    elseif cmd == "popup" then
        Debug.SetPopup((args[2] or "on"):lower() ~= "off")

    elseif cmd == "verbose" then
        Debug.verbose = not Debug.verbose
        Debug.Print("verbose", Debug.verbose and "on" or "off")

    else
        for _, line in ipairs(USAGE) do ns.Print(line) end
    end
end

ns.OnInit(function()
    Debug.Print("development build. |cffffff00/pugdebug|r for simulation commands.")
end)
