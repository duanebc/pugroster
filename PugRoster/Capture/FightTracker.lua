-- Capture/FightTracker.lua -- every fight that is not a Mythic+ key.
--
-- RunTracker owns keys, because a key has a shape worth modelling: a par time, an
-- upgrade level, a group that stays put. Everything else -- a raid, a heroic, a
-- delve, a battleground, a target dummy -- is just combat, and this file records
-- it.
--
-- One record per *visit*, not per pull. A heroic dungeon is one run that happens
-- to contain a dozen separate combats, and filing twelve history rows for it is
-- useless: the entry is the visit. Open-world combat has no visit to belong to,
-- so there each stretch of fighting in a zone is one record.
--
-- Pulls are read individually and then thrown away. Reading per pull is what
-- keeps the totals accurate -- the server's Overall session spans everything
-- since it was last reset, not this dungeon -- but *storing* each pull cost
-- twenty-five times what the totals do, and a breakdown is only worth having
-- while you are looking at it.
--
-- Stored in ns.db.fights, deliberately apart from ns.db.runs. Rating reads
-- db.runs, and a raid boss or a target dummy must never move a Mythic+ tier.

local ADDON, ns = ...

local FightTracker = {}
ns.FightTracker = FightTracker

-- Combat shorter than this is a stray mob, not a segment worth keeping.
local MIN_SECONDS = 5

-- How long after a key ends a pull in the same dungeon still belongs to it.
local KEY_TRAILING_GRACE = 180

-- How long a record stays open with no fighting before the next pull counts as a
-- new session. Generous on purpose: a break for a quest turn-in or a repair is
-- the same outing, and sixty seconds turned one afternoon in a delve into nine
-- separate history rows.
local IDLE_TIMEOUT = 1800

local current        -- the record being appended to
local pullStarted    -- GetTime() at the start of the combat in progress
-- Set while a boss is being fought. Nothing reads its contents any more, but the
-- encounter events still matter: they bound a segment, which is how a pull gets
-- read from the server's Current session even in a key that never leaves combat.
local pullEncounter

--------------------------------------------------------------------------------
-- Records
--------------------------------------------------------------------------------

local function zoneName()
    local name = GetInstanceInfo and select(1, GetInstanceInfo())
    if name and name ~= "" then return name end
    return GetZoneText() or "?"
end

local function newRecord(content)
    local record = {
        id        = ns.db.nextFightId or 1,
        content   = content,
        zone      = zoneName(),
        startedAt = ns.Now(),
        endedAt   = ns.Now(),
        elapsed   = 0,
        observations = {},
    }
    ns.db.nextFightId = record.id + 1
    table.insert(ns.db.fights, record)
    FightTracker.Trim()
    return record
end

-- Does the record in hand still cover where we are now?
-- Same content, same zone, and not idle for long enough to be a separate outing.
local function stillCurrent(record, content)
    if not record or record.content ~= content then return false end
    if record.zone ~= zoneName() then return false end
    return (ns.Now() - (record.endedAt or 0)) <= IDLE_TIMEOUT
end

local function observationFor(record, guid, info)
    local obs = record.observations[guid]
    if not obs then
        obs = {
            guid = guid,
            name = info and info.name, class = info and info.class,
            classFile = info and info.classFile,
            role = info and info.role ~= "NONE" and info.role or nil,
            isPlayer = info and info.isPlayer,
            deaths = 0, interrupts = 0, dispels = 0, damage = 0, healing = 0,
        }
        record.observations[guid] = obs
    end
    return obs
end

-- Roll a finished segment's numbers into the visit's totals. Summing is the only
-- honest way to get a visit total: the server's Overall session spans everything
-- since it was last reset, which is not the same as this dungeon.
local function accumulate(record, segment)
    for guid, seg in pairs(segment.observations) do
        local obs = observationFor(record, guid, seg)
        for _, field in ipairs({ "damage", "healing", "interrupts", "dispels", "deaths" }) do
            obs[field] = (obs[field] or 0) + (seg[field] or 0)
        end
    end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

-- Close whatever is open, if it lasted long enough to be worth a row.
--
-- Combat dropping is not the only boundary that matters. A well-played key chain
-- pulls and barely leaves combat, which would make the whole run one segment --
-- so a boss encounter starting or ending closes the current segment and opens
-- the next. That is the difference between "one 24-minute pull" and a list you
-- can find a specific boss fight in.
local function closeSegment()
    local started = pullStarted
    pullStarted = nil
    if not started then return end

    local elapsed = GetTime() - started
    if elapsed < MIN_SECONDS then return end

    -- A key's pulls belong to the key, and the key's totals come from one
    -- authoritative read at completion -- there is nothing for a pull to add
    -- except how long it lasted. That matters: a key's `elapsed` is wall clock
    -- including the running between packs, so dividing damage by it would report
    -- something well below anyone's actual DPS.
    local activeRun = ns.RunTracker.Active()
    if activeRun then
        activeRun.combatTime = (activeRun.combatTime or 0) + elapsed
        return
    end

    -- Nor does the trailing pull after a key ends, which arrives once the run is
    -- already closed and would otherwise file a duplicate record for the dungeon
    -- you have only just finished.
    local finished = ns.RunTracker.justFinished
    if finished and (GetTime() - (finished.at or 0)) <= KEY_TRAILING_GRACE
        and finished.dungeon == zoneName() then
        return
    end

    local content = ns.ContentType()
    if content == "world" and ns.IsTrainingDummy("target") then content = "dummy" end

    if not stillCurrent(current, content) then current = newRecord(content) end
    local record = current

    -- The segment is scratch. It exists to hold one pull's numbers long enough to
    -- read them from the server and fold them into the record's totals, and is
    -- then discarded -- storing every pull cost twenty-five times what the totals
    -- do, for a breakdown that is only worth having while it is on screen.
    --
    -- Its own group snapshot still matters: people join and leave a dungeon
    -- mid-visit, and a pull should credit whoever was actually there for it.
    local segment = {
        startedAt = ns.Now() - math.floor(elapsed),
        elapsed = elapsed,
        observations = {},
    }
    for guid, info in pairs(ns.RunTracker.SnapshotGroup() or {}) do
        segment.observations[guid] = {
            guid = guid, name = info.name, class = info.class,
            classFile = info.classFile,
            role = info.role ~= "NONE" and info.role or nil,
            isPlayer = info.isPlayer,
            deaths = 0, interrupts = 0, dispels = 0, damage = 0, healing = 0,
        }
    end

    record.endedAt = ns.Now()
    record.elapsed = (record.elapsed or 0) + elapsed
    record.combatTime = (record.combatTime or 0) + elapsed

    -- Read this pull, not the session total: the server's Current session is the
    -- combat that just ended, which is exactly this segment. Values are withheld
    -- until combat drops, so wait for that first.
    ns.DetailsBridge.WhenUnlocked(60, function(unlocked)
        if not unlocked then return end

        -- Retry rather than taking one shot: the server publishes the finished
        -- session a moment after combat drops, and how long is not ours to know.
        -- Reading too early is indistinguishable from having no data.
        local tries = 0
        local function attempt()
            tries = tries + 1
            local ok, applied, why = pcall(ns.DetailsBridge.Enrich, segment, "Current")

            if ok and applied then
                accumulate(record, segment)
                if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
                -- An ordinary dungeon is a fight, not a key, so it reaches the
                -- summary window through here rather than through RunTracker --
                -- a timewalking run has numbers worth reading too.
                if ns.RunSummary and record.content == "dungeon" then
                    ns.RunSummary.Show(record)
                end
                return
            end
            if tries < 4 then
                C_Timer.After(tries * 3, attempt)
            elseif ns.Debug and ns.Debug.verbose then
                ns.Debug.Print("segment not enriched:", tostring(ok and why or "error"))
            end
        end
        C_Timer.After(1, attempt)
    end)
end

--------------------------------------------------------------------------------

function FightTracker.Trim()
    local max = ns.settings.maxFightsInGame or 100
    while #ns.db.fights > max do table.remove(ns.db.fights, 1) end
    ns.Housekeeping.Enforce()
end

function FightTracker.Current() return current end

function FightTracker.Wipe()
    local n = #ns.db.fights
    wipe(ns.db.fights)
    current = nil
    return n
end

-- Open a segment. Safe to call when one is already open only via the boundary
-- helpers below, which close first.
local function openSegment(encounter)
    pullStarted = GetTime()
    pullEncounter = encounter
end

ns.OnInit(function()
    ns.RegisterEvent("PLAYER_REGEN_DISABLED", function() openSegment(nil) end)
    ns.RegisterEvent("PLAYER_REGEN_ENABLED", closeSegment)

    -- A boss is its own segment. The trash before it closes here rather than
    -- waiting for a combat drop that may never come.
    ns.RegisterEvent("ENCOUNTER_START", function(id, name)
        closeSegment()
        openSegment({ id = id, name = ns.SafeGUID(name) })
    end)

    ns.RegisterEvent("ENCOUNTER_END", function(id, name, _, _, success)
        pullEncounter = pullEncounter or { id = id, name = ns.SafeGUID(name) }
        pullEncounter.name = pullEncounter.name or ns.SafeGUID(name)
        pullEncounter.kill = (success == 1 or success == true)
        closeSegment()
        -- Still fighting after the boss: that is the next trash segment, and it
        -- started now rather than whenever combat began.
        if InCombatLockdown() then openSegment(nil) end
    end)
    -- Leaving an instance ends the visit; the next fight starts a new record.
    ns.RegisterEvent("PLAYER_ENTERING_WORLD", function() current = nil end)
end)
