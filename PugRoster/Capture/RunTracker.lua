-- Capture/RunTracker.lua -- the Mythic+ run lifecycle.
--
-- Owns the in-progress run record and is the single writer of ns.db.runs.
-- The in-progress record lives in SavedVariables (db.activeRun) rather than in a
-- local, so a /reload in the middle of a key does not lose the run.
--
-- Run boundary, per §2 of the plan:
--   CHALLENGE_MODE_START ........ open a run
--   CHALLENGE_MODE_COMPLETED .... close it, timed or not
--   CHALLENGE_MODE_RESET ........ the key was restarted; the old attempt is
--                                 abandoned
--   left the instance / group ... abandoned or disbanded
--
-- All world-state reads go through the two context helpers at the top, which
-- give the debug event simulator a guarded seam to feed synthetic runs through
-- the identical code path.

local ADDON, ns = ...

local RunTracker = {}
ns.RunTracker = RunTracker

--------------------------------------------------------------------------------
-- World-state context (the debug seam)
--------------------------------------------------------------------------------

local function startContext()
    if ns.Debug and ns.Debug.StartContext then
        local ctx = ns.Debug.StartContext()
        if ctx then return ctx end
    end

    local mapID = C_ChallengeMode and C_ChallengeMode.GetActiveChallengeMapID and C_ChallengeMode.GetActiveChallengeMapID()
    if not mapID then return nil end

    local level, affixes = C_ChallengeMode.GetActiveKeystoneInfo()
    local name, _, timeLimit = C_ChallengeMode.GetMapUIInfo(mapID)

    return {
        mapID    = mapID,
        dungeon  = name or ("Map " .. tostring(mapID)),
        keyLevel = level or 0,
        affixes  = affixes or {},
        par      = timeLimit,
        seasonID = ns.Rating.CurrentSeason(),
        group    = RunTracker.SnapshotGroup(),
    }
end

local function completionContext()
    if ns.Debug and ns.Debug.CompletionContext then
        local ctx = ns.Debug.CompletionContext()
        if ctx then return ctx end
    end

    if not C_ChallengeMode then return nil end

    -- GetChallengeCompletionInfo returns one table and is what the client
    -- answers now; GetCompletionInfo is the deprecated positional form. It still
    -- returns the map, level and time, but onTime and keystoneUpgradeLevels come
    -- back empty -- which is how a +2 got filed as "over time" with the elapsed
    -- and par both correct beside it. Feature-detect, newest first.
    local mapID, level, timeMs, onTime, upgradeLevels

    if C_ChallengeMode.GetChallengeCompletionInfo then
        local info = C_ChallengeMode.GetChallengeCompletionInfo()
        if not info then return nil end
        mapID, level, timeMs = info.mapChallengeModeID, info.level, info.time
        onTime, upgradeLevels = info.onTime, info.keystoneUpgradeLevels
    elseif C_ChallengeMode.GetCompletionInfo then
        mapID, level, timeMs, onTime, upgradeLevels = C_ChallengeMode.GetCompletionInfo()
    else
        return nil
    end

    if not mapID then return nil end

    return {
        mapID    = mapID,
        keyLevel = level,
        elapsed  = timeMs and (timeMs / 1000) or nil,
        timed    = onTime and true or false,
        upgrade  = upgradeLevels or 0,
    }
end

--------------------------------------------------------------------------------
-- Group snapshot
--------------------------------------------------------------------------------

-- { [guid] = { name, class, classFile, role, ilvl, spec, specName } } for the
-- player plus up to four party members.
function RunTracker.SnapshotGroup()
    if ns.Debug and ns.Debug.GroupSnapshot then
        local g = ns.Debug.GroupSnapshot()
        if g then return g end
    end

    local out = {}
    local units = { "player", "party1", "party2", "party3", "party4" }
    for _, unit in ipairs(units) do
        if UnitExists(unit) then
            local guid = UnitGUID(unit)
            if guid then
                local name, realm = UnitName(unit)
                local class, classFile = UnitClass(unit)
                out[guid] = {
                    name      = ns.FullName(name, realm),
                    class     = class,
                    classFile = classFile,
                    role      = UnitGroupRolesAssigned(unit),
                    -- Captured here because it is only knowable while they are
                    -- standing next to you; nothing recovers it afterwards.
                    faction   = UnitFactionGroup and UnitFactionGroup(unit) or nil,
                    isPlayer  = (unit == "player") or nil,
                }
            end
        end
    end
    return out
end

local function newObservation(guid, info)
    return {
        guid      = guid,
        name      = info and info.name or "Unknown",
        class     = info and info.class,
        classFile = info and info.classFile,
        role      = info and info.role ~= "NONE" and info.role or nil,
        faction   = info and info.faction,
        spec      = info and info.spec,
        specName  = info and info.specName,
        ilvl      = info and info.ilvl,
        isPlayer  = info and info.isPlayer,
        deaths = 0, wipes = 0, interrupts = 0, dispels = 0, ccCasts = 0,
        avoidable = 0,
        -- Counted from auras rather than casts; see Capture/Defensives.lua.
        defensives = 0,
        damage = 0, healing = 0,
        joinedAt = ns.Now(),
    }
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function RunTracker.Active()
    return ns.db and ns.db.activeRun or nil
end

function RunTracker.IsActive()
    return RunTracker.Active() ~= nil
end

-- Who owned the key. The client does not hand us the slotting player, so this
-- is an honest best effort: if our own keystone matches the active map, it was
-- ours; otherwise it stays unknown and the history panel says so.
local function detectKeyHolder(mapID, level)
    -- Both sides of this comparison have to be challenge map IDs; ns.OwnedKeystone
    -- is what guarantees that.
    local ownedMap, ownedLevel = ns.OwnedKeystone()
    if ownedMap and ownedMap == mapID and (not level or ownedLevel == level) then
        return UnitGUID("player")
    end
    return nil
end

function RunTracker.StartRun(ctx)
    ctx = ctx or startContext()
    if not ctx then return nil end

    -- A start while one is already open means the previous attempt never closed.
    if RunTracker.Active() then
        RunTracker.Abandon("restarted")
    end

    local db = ns.db
    local run = {
        id        = db.nextRunId,
        mapID     = ctx.mapID,
        dungeon   = ctx.dungeon,
        keyLevel  = ctx.keyLevel or 0,
        affixes   = ctx.affixes or {},
        seasonID  = ctx.seasonID or ns.Rating.CurrentSeason(),
        startedAt = ctx.startedAt or ns.Now(),
        par       = ctx.par,
        keyHolder = ctx.keyHolder or detectKeyHolder(ctx.mapID, ctx.keyLevel),
        origin    = "self",   -- future shared-pool imports carry a different origin
        exported  = false,
        debug     = ctx.debug or nil,
        observations = {},
        chat      = {},
        wipes     = 0,
    }
    db.nextRunId = db.nextRunId + 1
    -- Remember the season we last saw a key in, so rating decay still works on
    -- a login where C_MythicPlus has not populated yet.
    if run.seasonID and run.seasonID > 0 then db.lastKnownSeason = run.seasonID end

    for guid, info in pairs(ctx.group or {}) do
        run.observations[guid] = newObservation(guid, info)
        ns.Roster.TouchCharacter(guid, {
            name = info.name, class = info.class, classFile = info.classFile,
            role = info.role, spec = info.spec, specName = info.specName,
            ilvl = info.ilvl, debug = ctx.debug or nil,
        })
    end

    db.activeRun = run
    ns.CombatLog.ResetWindow()

    if not ctx.debug then
        ns.Inspect.Start()
        ns.Inspect.QueueGroup()
    end

    ns.Print(string.format("tracking %s +%d.", run.dungeon or "?", run.keyLevel or 0))
    if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
    return run
end

-- Merge late-arriving detail (an inspect result) into the open run.
function RunTracker.UpdateObservation(guid, info)
    local run = RunTracker.Active()
    if not run or not guid or not info then return end
    local obs = run.observations[guid]
    if not obs then return end
    for _, key in ipairs({ "name", "class", "classFile", "role", "spec", "specName", "ilvl" }) do
        if info[key] ~= nil and info[key] ~= "NONE" then obs[key] = info[key] end
    end
end

-- Close the run out and file it. `result` carries whatever the caller knows:
-- completed/timed/upgrade/elapsed, or the abandon reason.
-- Standard Mythic+ upgrade thresholds: inside the par time is +1, inside 80% of
-- it is +2, inside 60% is +3.
local function upgradeForTime(elapsed, par)
    if not elapsed or not par or par <= 0 or elapsed > par then return 0 end
    if elapsed <= par * 0.6 then return 3 end
    if elapsed <= par * 0.8 then return 2 end
    return 1
end

-- Repair runs filed while the deprecated completion API was returning no onTime
-- and no upgrade level: a key completed comfortably inside par was stored as
-- "over time". Finishing inside par *is* the definition of timed, so anything
-- completed with time to spare gets corrected.
--
-- The upgrade level is derived from the thresholds rather than known, and our
-- elapsed can differ from the client's by a few seconds (death penalties land
-- differently), so a run close to a boundary is marked derived and the History
-- tab says so rather than asserting a number it cannot verify.
function RunTracker.RepairTimedFlags()
    local fixed = 0
    for _, run in ipairs(ns.db.runs) do
        if run.completed and not run.timed and not run.abandoned
            and run.par and run.par > 0 and run.elapsed and run.elapsed < run.par then
            run.timed = true
            run.upgrade = upgradeForTime(run.elapsed, run.par)
            run.upgradeDerived = true
            fixed = fixed + 1
        end
    end
    if fixed > 0 then ns.Rating.RecomputeAll() end
    return fixed
end

function RunTracker.Finalize(run, result)
    run = run or RunTracker.Active()
    if not run then return nil end
    result = result or {}

    run.endedAt   = ns.Now()
    run.completed = result.completed and true or false
    run.timed     = result.timed and true or false
    run.upgrade   = result.upgrade or 0
    run.abandoned = result.abandoned and true or false
    run.disband   = result.disband and true or false
    run.reason    = result.reason

    run.elapsed = result.elapsed or (run.endedAt - (run.startedAt or run.endedAt))
    if run.par and run.par > 0 then
        run.margin = run.par - run.elapsed  -- positive = finished under par
    end

    run._wipeCounted = nil

    -- Not gated on the Details setting: the numbers come from Blizzard's own
    -- meter now, and Details is only the fallback. Attempted here in case the
    -- server has already released them, and again below once it has.
    if not run.debug then
        pcall(ns.DetailsBridge.Enrich, run)
    end

    -- The last pull of a key finishes *after* CHALLENGE_MODE_COMPLETED, so by the
    -- time combat drops there is no active run and FightTracker would file a
    -- second, near-duplicate record for the same dungeon. It needs to know a key
    -- just ended here; it does not need the run itself.
    RunTracker.justFinished = { at = GetTime(), dungeon = run.dungeon }

    ns.db.activeRun = nil
    ns.Inspect.Stop()

    table.insert(ns.db.runs, run)
    RunTracker.TrimHistory()
    ns.Housekeeping.Enforce()

    if not run.debug then
        -- Details assembles its combined Mythic+ segment a moment after
        -- CHALLENGE_MODE_COMPLETED, so the read above can come back empty or
        -- partial. The run is already filed by now, so this just fills it in.
        -- History has a manual "Pull from Details" for when even this is early.
        -- This is the only chance. Details holds its segments in memory, so a
        -- reload or logout discards them and the run can never be enriched
        -- afterwards -- "Pull from Details" only works in the same session.
        --
        -- So retry rather than taking one shot: Details assembles its combined
        -- Mythic+ segment some time after CHALLENGE_MODE_COMPLETED, and how long
        -- is not ours to know.
        -- Wait for the server to stop withholding before trying at all. While
        -- the Combat restriction is active every value C_DamageMeter holds is a
        -- secret, so a read during lockdown returns nothing however correct the
        -- rest of the code is -- and the end of a key is exactly when you are
        -- still in combat.
        local attempts, delays = 0, { 5, 15, 30, 60 }
        local function attempt()
            attempts = attempts + 1
            local ok, applied, why = pcall(ns.DetailsBridge.Enrich, run)

            if ok and applied then
                ns.Rating.RecomputeAll()
                if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
                -- Say so. Silence is indistinguishable from failure, and this
                -- path has been silently failing for most of its life.
                ns.Print("recorded this run's combat stats.")
                -- Now, not at completion: this is the first moment the
                -- numbers exist to put in a window.
                if ns.RunSummary then ns.RunSummary.Show(run) end
                return
            end

            if delays[attempts + 1] then
                C_Timer.After(delays[attempts + 1] - delays[attempts], attempt)
                return
            end

            -- Never fail quietly. A run filed with every stat at zero and no
            -- explanation is how this went unnoticed across several keys.
            -- `ok and why or "..."` collapsed three different outcomes into one
            -- sentence: a thrown error, a withheld server, and a clean no-match
            -- all printed "Details refused the read". Name which actually
            -- happened -- when the call errors, `applied` carries the message.
            ns.Print("|cffd9a441could not read this run:|r",
                tostring(not ok and ("error while reading: " .. tostring(applied))
                    or why or "no source had numbers for these five players")
                .. " Try |cffffff00Pull from Details|r on the History tab before "
                .. "you reload -- Details forgets the run when you do.")
        end
        -- Ten minutes, not two. The restriction that matters here is
        -- ChallengeMode, and it outlives the key: it is still active while the
        -- group stands in the finished dungeon deciding what to do next, and
        -- clears when you actually leave. Two minutes expired inside the
        -- instance every time, and the ladder then read a meter that was still
        -- withholding and filed the run with zeroes.
        ns.DetailsBridge.WhenUnlocked(600, function(unlocked)
            if not unlocked then
                ns.Print("|cffd9a441ten minutes on and the server is still"
                    .. " withholding this run's numbers|r ("
                    .. table.concat(ns.DetailsBridge.ActiveLocks(), "+")
                    .. "). Try |cffffff00Pull from Details|r once you have left"
                    .. " the dungeon.")
                return
            end
            C_Timer.After(delays[1], attempt)
        end)
    end

    for guid, obs in pairs(run.observations) do
        ns.Roster.TouchCharacter(guid, {
            name = obs.name, class = obs.class, classFile = obs.classFile,
            role = obs.role, spec = obs.spec, specName = obs.specName,
            ilvl = obs.ilvl, debug = run.debug,
        })
    end

    ns.Rating.RecomputeAll()

    local summary
    if run.completed then
        summary = run.timed and string.format("timed +%d", run.upgrade) or "over time"
    else
        summary = run.disband and "disbanded" or "abandoned"
    end
    ns.Print(string.format("recorded %s +%d (%s).", run.dungeon or "?", run.keyLevel or 0, summary))

    if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
    return run
end

function RunTracker.Abandon(reason)
    local run = RunTracker.Active()
    if not run then return end

    -- If everyone but us is already gone, this was a disband rather than us
    -- walking out on the group -- the rating model treats them differently.
    local others, present = 0, 0
    local me = UnitGUID("player")
    for guid, obs in pairs(run.observations) do
        if guid ~= me then
            others = others + 1
            if not obs.leftEarly then present = present + 1 end
        end
    end
    local disband = others > 0 and present <= 1

    return RunTracker.Finalize(run, {
        completed = false,
        abandoned = true,
        disband   = disband,
        reason    = reason,
    })
end

function RunTracker.TrimHistory()
    local max = ns.settings.maxRunsInGame or 400
    local runs = ns.db.runs
    -- Never drop a run the companion has not seen yet: the in-game store is a
    -- capture buffer, and losing an unexported run loses it for good.
    while #runs > max do
        local oldest = runs[1]
        if not oldest or not oldest.exported then break end
        table.remove(runs, 1)
    end
end

--------------------------------------------------------------------------------
-- Roster churn
--------------------------------------------------------------------------------

local function onRosterUpdate()
    local run = RunTracker.Active()
    if not run then
        if ns.JoinPopup then ns.JoinPopup.OnRosterUpdate() end
        return
    end

    local current = RunTracker.SnapshotGroup()

    -- Anyone in the run record who is no longer in the group left early.
    for guid, obs in pairs(run.observations) do
        if not current[guid] and not obs.leftEarly then
            obs.leftEarly = true
            obs.leftAt = ns.Now()
            ns.Print(ns.ShortName(obs.name), "left the group mid-run.")
        end
    end

    -- Backfills are rare but legal (a replacement invited after a death).
    for guid, info in pairs(current) do
        if not run.observations[guid] then
            run.observations[guid] = newObservation(guid, info)
            run.observations[guid].joinedLate = true
            ns.Roster.TouchCharacter(guid, info)
            ns.Inspect.Queue(guid)
        end
    end

    if ns.JoinPopup then ns.JoinPopup.OnRosterUpdate() end
end

--------------------------------------------------------------------------------
-- Recovery after /reload or zoning out
--------------------------------------------------------------------------------

local function verifyStillRunning()
    local run = RunTracker.Active()
    if not run or run.debug then return end

    local active = C_ChallengeMode and C_ChallengeMode.GetActiveChallengeMapID and C_ChallengeMode.GetActiveChallengeMapID()
    if active then
        -- Still in the key: a /reload happened. Pick the inspect queue back up.
        ns.Inspect.Start()
        ns.Inspect.QueueGroup()
        return
    end

    RunTracker.Abandon("left the instance")
end

ns.OnInit(function()
    -- One-time repair for records filed before the completion API was fixed.
    local fixed = RunTracker.RepairTimedFlags()
    if fixed > 0 then
        ns.Print(string.format("corrected %d run%s that were filed as over time but "
            .. "finished inside par.", fixed, fixed == 1 and "" or "s"))
    end

    ns.RegisterEvent("CHALLENGE_MODE_START", function() RunTracker.StartRun() end)

    ns.RegisterEvent("CHALLENGE_MODE_COMPLETED", function()
        local run = RunTracker.Active()
        if not run then return end
        local ctx = completionContext() or {}
        RunTracker.Finalize(run, {
            completed = true,
            timed     = ctx.timed,
            upgrade   = ctx.upgrade,
            elapsed   = ctx.elapsed,
        })
    end)

    ns.RegisterEvent("CHALLENGE_MODE_RESET", function()
        if RunTracker.IsActive() then RunTracker.Abandon("key reset") end
    end)

    ns.RegisterEvent("GROUP_ROSTER_UPDATE", onRosterUpdate)

    ns.RegisterEvent("PLAYER_ENTERING_WORLD", function()
        if RunTracker.IsActive() then
            -- Zone transitions settle a few seconds after the event fires, so
            -- do not judge an in-progress run on the instant it arrives.
            C_Timer.After(6, verifyStillRunning)
        end
    end)
end)
