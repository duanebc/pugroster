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

local function wipeAll()
    PugRaterDB = nil
    Debug.Print("database cleared. |cffffff00/reload|r to reinitialise.")
end

local function wipeFake()
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
        if not next(person.characters) then db.persons[id] = nil end
    end

    if db.activeRun and db.activeRun.debug then db.activeRun = nil end
    Debug._onlineIndex = nil

    ns.Rating.RecomputeAll()
    Debug.Print(string.format("removed %d simulated runs and %d simulated characters.",
        removedRuns, removedChars))
end

--------------------------------------------------------------------------------
-- Inspection
--------------------------------------------------------------------------------

local function showTier(name)
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

local function exportState()
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
    "  |cffffff00run|r [level] [dungeon] [--fail|--disband|--leave|--wipes] -- simulate one full key through the real event pipeline",
    "  |cffffff00seed|r [n] -- bulk-generate n historical runs for rating and decay testing",
    "  |cffffff00roster|r [n] -- seed persons, characters, tags and saved groups",
    "  |cffffff00online|r [on|off] -- fake a friends list so the Send tab has recipients",
    "  |cffffff00reply|r <name> <text> -- simulate a whisper back from someone you messaged",
    "  |cffffff00echo|r [on|off] -- intercept sends and print them locally (on by default)",
    "  |cffffff00tier|r <name> -- print the full rating breakdown",
    "  |cffffff00export|r -- dump the in-progress run",
    "  |cffffff00wipe|r [fake] -- clear everything, or only simulated records",
}

SLASH_PUGDEBUG1 = "/pugdebug"
SlashCmdList.PUGDEBUG = function(msg)
    local args = {}
    for word in (msg or ""):gmatch("%S+") do args[#args + 1] = word end
    local cmd = (args[1] or ""):lower()

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
        if args[2] then showTier(args[2]) else Debug.Print("usage: /pugdebug tier <name>") end

    elseif cmd == "export" then
        exportState()

    elseif cmd == "wipe" then
        if (args[2] or ""):lower() == "fake" then wipeFake() else wipeAll() end

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
