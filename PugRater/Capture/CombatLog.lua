-- Capture/CombatLog.lua -- deaths, interrupts, dispels, CC and damage/healing.
--
-- Only runs while a key is in progress, and only tallies events whose source or
-- destination is one of the five GUIDs in the run. Combat log volume in a M+
-- pull is large, so the hot path bails out on the very first check.
--
-- Open risk 1 in the plan: if Blizzard restricts other players' combat log data
-- this season, these tallies quietly come back as zero rather than erroring, and
-- DetailsBridge is the fallback for damage/healing. Rating already treats every
-- per-player stat as a *relative* adjustment, so an all-zero run still scores
-- correctly on outcome alone.

local ADDON, ns = ...

local CombatLog = {}
ns.CombatLog = CombatLog

-- Curated crowd-control aura list. Deliberately short and high-signal: the
-- point is "did this player contribute control", not a complete CC census.
local CC_SPELLS = {
    [853]    = true,  -- Hammer of Justice
    [2094]   = true,  -- Blind
    [5211]   = true,  -- Mighty Bash
    [6770]   = true,  -- Sap
    [8122]   = true,  -- Psychic Scream
    [51514]  = true,  -- Hex
    [118]    = true,  -- Polymorph
    [605]    = true,  -- Mind Control
    [710]    = true,  -- Banish
    [3355]   = true,  -- Freezing Trap
    [115078] = true,  -- Paralysis
    [187650] = true,  -- Freezing Trap (rank 2)
    [207167] = true,  -- Blinding Sleet
    [211881] = true,  -- Fel Eruption
    [30283]  = true,  -- Shadowfury
    [31661]  = true,  -- Dragons Breath
    [99]     = true,  -- Incapacitating Roar
    [179057] = true,  -- Chaos Nova
    [119381] = true,  -- Leg Sweep
    [107570] = true,  -- Storm Bolt
    [108194] = true,  -- Asphyxiate
    [46968]  = true,  -- Shockwave
}
CombatLog.CC_SPELLS = CC_SPELLS

local DAMAGE_EVENTS = {
    SPELL_DAMAGE = true, SPELL_PERIODIC_DAMAGE = true, RANGE_DAMAGE = true,
    SWING_DAMAGE = true, SPELL_BUILDING_DAMAGE = true, DAMAGE_SHIELD = true,
    DAMAGE_SPLIT = true, ENVIRONMENTAL_DAMAGE = false,
}

local HEAL_EVENTS = { SPELL_HEAL = true, SPELL_PERIODIC_HEAL = true }

-- A "wipe" here means most of the group died inside a short window.
local WIPE_WINDOW = 12
local WIPE_MIN_DEATHS = 3
local recentDeaths = {}

local function noteDeath(run, guid, now)
    local obs = run.observations[guid]
    if not obs then return end
    obs.deaths = (obs.deaths or 0) + 1

    -- Trim the sliding window, then decide whether this death completed a wipe.
    for i = #recentDeaths, 1, -1 do
        if now - recentDeaths[i].t > WIPE_WINDOW then table.remove(recentDeaths, i) end
    end
    table.insert(recentDeaths, { guid = guid, t = now })

    local distinct = {}
    local count = 0
    for _, d in ipairs(recentDeaths) do
        if not distinct[d.guid] then distinct[d.guid] = true; count = count + 1 end
    end

    if count >= WIPE_MIN_DEATHS and not run._wipeCounted then
        run._wipeCounted = true
        run.wipes = (run.wipes or 0) + 1
        for _, o in pairs(run.observations) do
            if not o.leftEarly then o.wipes = (o.wipes or 0) + 1 end
        end
    elseif count < WIPE_MIN_DEATHS then
        run._wipeCounted = false
    end
end

-- The whole subevent handler, taking explicit arguments rather than reading the
-- combat log directly. The live event handler below unpacks
-- CombatLogGetCurrentEventInfo() into this; the debug event simulator calls it
-- with synthetic payloads, so both travel identical logic.
function CombatLog.Handle(timestamp, subevent, _, sourceGUID, sourceName, _, _,
                          destGUID, destName, _, _, spellId, spellName, _, extra)
    local run = ns.RunTracker.Active()
    if not run then return end

    local obsSource = sourceGUID and run.observations[sourceGUID]
    local obsDest   = destGUID and run.observations[destGUID]

    if subevent == "UNIT_DIED" then
        if obsDest then noteDeath(run, destGUID, timestamp or GetTime()) end
        return
    end

    if not obsSource then
        -- Nothing else we track is credited to a non-groupmate.
        return
    end

    if subevent == "SPELL_INTERRUPT" then
        obsSource.interrupts = (obsSource.interrupts or 0) + 1
    elseif subevent == "SPELL_DISPEL" or subevent == "SPELL_STOLEN" then
        obsSource.dispels = (obsSource.dispels or 0) + 1
    elseif subevent == "SPELL_AURA_APPLIED" and spellId and CC_SPELLS[spellId] then
        -- Only count CC landed on something that is not a groupmate.
        if not obsDest then
            obsSource.ccCasts = (obsSource.ccCasts or 0) + 1
        end
    elseif DAMAGE_EVENTS[subevent] then
        -- Friendly fire and damage onto groupmates is not contribution.
        if not obsDest then
            local amount = tonumber(extra) or 0
            obsSource.damage = (obsSource.damage or 0) + amount
        end
    elseif HEAL_EVENTS[subevent] then
        local amount = tonumber(extra) or 0
        obsSource.healing = (obsSource.healing or 0) + amount
    end
end

local function onCombatLogEvent()
    local run = ns.RunTracker.Active()
    if not run then return end

    local timestamp, subevent, hideCaster, sourceGUID, sourceName, sourceFlags, sourceRaidFlags,
          destGUID, destName, destFlags, destRaidFlags, arg12, arg13, arg14, arg15 = CombatLogGetCurrentEventInfo()

    -- SWING_DAMAGE has no spell payload: its amount is the first extra arg,
    -- where spell events carry spellId/spellName/school first.
    if subevent == "SWING_DAMAGE" then
        CombatLog.Handle(timestamp, subevent, hideCaster, sourceGUID, sourceName, sourceFlags,
                         sourceRaidFlags, destGUID, destName, destFlags, destRaidFlags,
                         nil, nil, nil, arg12)
    else
        CombatLog.Handle(timestamp, subevent, hideCaster, sourceGUID, sourceName, sourceFlags,
                         sourceRaidFlags, destGUID, destName, destFlags, destRaidFlags,
                         arg12, arg13, arg14, arg15)
    end
end

function CombatLog.ResetWindow()
    wipe(recentDeaths)
end

ns.OnInit(function()
    ns.RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED", onCombatLogEvent)
end)
