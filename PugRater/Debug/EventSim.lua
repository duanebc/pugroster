-- Debug/EventSim.lua -- drives the addon's own handlers with synthetic payloads.
--
-- Two modes, both from the plan:
--
--   SimulateRun -- fires the real events (CHALLENGE_MODE_START, combat-log
--     subevents, GROUP_ROSTER_UPDATE, CHALLENGE_MODE_COMPLETED) in sequence, so
--     the whole capture pipeline is exercised end to end. This is the mode that
--     actually tests the addon.
--
--   SeedRuns -- writes finished run records straight into the database, for
--     bulk history when what you need is 50 runs to test rating, decay and the
--     roster rather than the capture path.

local ADDON, ns = ...

local EventSim = {}
ns.EventSim = EventSim

local MOB_GUID = "Creature-0-DEBUG-0-0-999999-0000DEADBE"

--------------------------------------------------------------------------------
-- Argument parsing
--------------------------------------------------------------------------------

-- /pugdebug run 12 Voidspire --disband
local function parseFlags(args)
    local flags = {}
    for i = 2, #args do
        local arg = args[i]
        local lower = arg:lower()
        if lower:sub(1, 2) == "--" then
            flags[lower:sub(3)] = true
        elseif tonumber(arg) then
            flags.level = tonumber(arg)
        else
            flags.dungeon = arg
        end
    end
    if flags.wipes then flags.wipes = 4 end
    return flags
end

--------------------------------------------------------------------------------
-- Combat log injection
--------------------------------------------------------------------------------

local function fireCombat(subevent, sourceGUID, sourceName, destGUID, destName, spellId, amount)
    ns.CombatLog.Handle(GetTime(), subevent, false,
        sourceGUID, sourceName, 0, 0,
        destGUID, destName, 0, 0,
        spellId, "Debug Spell", 1, amount)
end

-- Replay one player's whole contribution as combat-log events. Damage and
-- healing are collapsed into a handful of large hits rather than thousands of
-- small ones -- the tallies land in the same place.
local function replayPlayer(run, guid, info, stats)
    for _ = 1, stats.interrupts do
        fireCombat("SPELL_INTERRUPT", guid, info.name, MOB_GUID, "Training Dummy", 1766)
    end
    for _ = 1, stats.dispels do
        fireCombat("SPELL_DISPEL", guid, info.name, MOB_GUID, "Training Dummy", 527)
    end
    for _ = 1, stats.ccCasts do
        fireCombat("SPELL_AURA_APPLIED", guid, info.name, MOB_GUID, "Training Dummy", 853)
    end

    local chunks = 8
    if stats.damage > 0 then
        local per = math.floor(stats.damage / chunks)
        for _ = 1, chunks do
            fireCombat("SPELL_DAMAGE", guid, info.name, MOB_GUID, "Training Dummy", 100780, per)
        end
    end
    if stats.healing > 0 then
        local per = math.floor(stats.healing / chunks)
        for _ = 1, chunks do
            fireCombat("SPELL_HEAL", guid, info.name, guid, info.name, 2050, per)
        end
    end
end

--------------------------------------------------------------------------------
-- Live simulation
--------------------------------------------------------------------------------

local running = false

function EventSim.SimulateRun(args)
    if running then
        ns.Debug.Print("a simulated run is already playing out.")
        return
    end
    if ns.RunTracker.IsActive() then
        ns.Debug.Print("a run is already being tracked -- finish or /reload first.")
        return
    end

    local flags = parseFlags(args or {})
    local spec = ns.FakeRun.MakeRun(flags)
    local Debug = ns.Debug
    running = true

    -- Arm the seams RunTracker reads instead of the live API.
    Debug._startContext = {
        mapID    = spec.mapID,
        dungeon  = spec.dungeon,
        keyLevel = spec.keyLevel,
        affixes  = spec.affixes,
        par      = spec.par,
        seasonID = spec.seasonID,
        group    = spec.group,
        debug    = true,
    }
    Debug._groupSnapshot = spec.group

    ns.Debug.Print(string.format("simulating %s +%d...", spec.dungeon, spec.keyLevel))
    ns.FireEvent("CHALLENGE_MODE_START")
    Debug._startContext = nil

    local chat = ns.FakeRun.MakeChat(spec)
    local step = 0
    local function schedule(delay, fn)
        step = step + delay
        C_Timer.After(step, fn)
    end

    -- Chat trickles in over the run, interleaved with the combat tallies.
    for i, line in ipairs(chat) do
        schedule(0.12, function()
            if line.channel == "party" then
                ns.FireEvent("CHAT_MSG_PARTY", line.text, ns.ShortName(line.name),
                    nil, nil, nil, nil, nil, nil, nil, nil, nil, line.guid)
            else
                ns.FireEvent("CHAT_MSG_WHISPER", line.text, ns.ShortName(line.name),
                    nil, nil, nil, nil, nil, nil, nil, nil, nil, line.guid)
            end
        end)
        if i == math.floor(#chat / 2) then
            schedule(0.2, function()
                for guid, info in pairs(spec.group) do
                    replayPlayer(spec, guid, info, spec.stats[guid])
                end
            end)
        end
    end

    -- Deaths last, so the wipe detector sees them clustered the way it would in
    -- a real pull.
    schedule(0.3, function()
        for guid, info in pairs(spec.group) do
            for _ = 1, spec.stats[guid].deaths do
                fireCombat("UNIT_DIED", nil, nil, guid, info.name)
            end
        end
    end)

    if spec.leaver then
        schedule(0.4, function()
            local reduced = {}
            for guid, info in pairs(spec.group) do
                if guid ~= spec.leaver then reduced[guid] = info end
            end
            Debug._groupSnapshot = reduced
            ns.FireEvent("GROUP_ROSTER_UPDATE")
        end)
    end

    schedule(0.5, function()
        if spec.completed then
            Debug._completionContext = {
                mapID    = spec.mapID,
                keyLevel = spec.keyLevel,
                elapsed  = spec.elapsed,
                timed    = spec.timed,
                upgrade  = spec.upgrade or 0,
            }
            ns.FireEvent("CHALLENGE_MODE_COMPLETED")
            Debug._completionContext = nil
        else
            -- Abandon path: RunTracker decides disband vs. abandon from who is
            -- left in the group, so drop everyone but us first when disbanding.
            if spec.disband then
                Debug._groupSnapshot = { [UnitGUID("player") or "self"] = spec.group[UnitGUID("player")] or {} }
                ns.FireEvent("GROUP_ROSTER_UPDATE")
            end
            ns.FireEvent("CHALLENGE_MODE_RESET")
        end

        Debug._groupSnapshot = nil
        running = false
        if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
    end)
end

--------------------------------------------------------------------------------
-- Bulk seeding
--------------------------------------------------------------------------------

-- Build a finished run record directly. Same shape RunTracker.Finalize writes.
local function bakeRun(spec, endedAt)
    local run = {
        id        = ns.db.nextRunId,
        mapID     = spec.mapID,
        dungeon   = spec.dungeon,
        keyLevel  = spec.keyLevel,
        affixes   = spec.affixes,
        seasonID  = spec.seasonID,
        par       = spec.par,
        startedAt = endedAt - math.floor(spec.elapsed),
        endedAt   = endedAt,
        elapsed   = math.floor(spec.elapsed),
        completed = spec.completed and true or false,
        timed     = spec.timed and true or false,
        upgrade   = spec.upgrade or 0,
        abandoned = spec.abandoned and true or false,
        disband   = spec.disband and true or false,
        wipes     = spec.wipes,
        origin    = "self",
        exported  = false,
        debug     = true,
        observations = {},
        chat      = {},
    }
    ns.db.nextRunId = run.id + 1
    run.margin = run.par and (run.par - run.elapsed) or nil

    for guid, info in pairs(spec.group) do
        local stats = spec.stats[guid]
        run.observations[guid] = {
            guid = guid, name = info.name, class = info.class, classFile = info.classFile,
            role = info.role, spec = info.spec, specName = info.specName, ilvl = info.ilvl,
            isPlayer = info.isPlayer,
            deaths = stats.deaths, wipes = spec.wipes, interrupts = stats.interrupts,
            dispels = stats.dispels, ccCasts = stats.ccCasts,
            damage = stats.damage, healing = stats.healing,
            leftEarly = (guid == spec.leaver) or nil,
        }
        ns.Roster.TouchCharacter(guid, {
            name = info.name, class = info.class, classFile = info.classFile,
            role = info.role, spec = info.spec, specName = info.specName,
            ilvl = info.ilvl, lastSeen = endedAt, debug = true,
        })
    end

    for _, line in ipairs(ns.FakeRun.MakeChat(spec)) do
        table.insert(run.chat, {
            t = endedAt, guid = line.guid, name = line.name,
            channel = line.channel, text = line.text,
            whisper = line.channel:find("whisper", 1, true) and true or nil,
        })
    end

    return run
end

function EventSim.SeedRuns(count)
    count = math.min(math.max(count or 20, 1), 300)
    local season = ns.Rating.CurrentSeason()
    local now = ns.Now()

    for i = 1, count do
        -- Spread the history back over roughly four months, and put the oldest
        -- fifth in the previous season so the decay weighting is exercised.
        local ageDays = math.floor((i / count) * 120)
        local endedAt = now - (ageDays * 86400) - math.random(0, 40000)
        local flags = {}
        if i <= count / 5 then flags.seasonID = math.max(0, season - 1) end

        local spec = ns.FakeRun.MakeRun(flags)
        table.insert(ns.db.runs, bakeRun(spec, endedAt))
    end

    table.sort(ns.db.runs, function(a, b)
        return (a.endedAt or a.startedAt or 0) < (b.endedAt or b.startedAt or 0)
    end)

    local rated = ns.Rating.RecomputeAll()
    ns.Debug.Print(string.format("seeded %d runs across %d characters. |cffffff00/pr|r to browse.",
        count, rated))
end
