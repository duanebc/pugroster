-- Debug/DefProbe.lua -- which API, if any, can still see defensive cooldowns.
--
-- Counting defensives would normally mean SPELL_CAST_SUCCESS out of
-- COMBAT_LOG_EVENT_UNFILTERED, and Midnight closed that to addons -- see the
-- build gate in Capture/CombatLog.lua. Three candidates remain and none of them
-- can be checked from outside the game, so this asks the client directly and
-- prints what it actually answers.
--
-- It lives under Debug/, and only there, because two of the three answers can
-- only be had by registering an event -- and if such a registration turns out to
-- be a protected action, the client replies with the blocked-action popup rather
-- than an error there is any way to catch. .pkgmeta strips this whole folder from
-- every release build, so the experiment can never run on somebody else's client.
-- `/pugdebug popup off` silences the dialog if one appears.
--
-- Three questions, in the order we would rather have the answer:
--
--   1. Does the server meter already carry it? Authoritative, no spell list to
--      maintain, no restriction to work around, and it inherits the post-hoc
--      enrichment path DetailsBridge already has.
--   2. Does UNIT_SPELLCAST_SUCCEEDED fire for party members, readably?
--   3. Does UNIT_AURA, as the fallback for defensives that are auras not casts?
--
-- "Fires" and "readable" are different questions on this client. Midnight hands
-- back secret values from events that still fire -- Capture/ChatLog.lua handles
-- exactly that shape for chat text -- so both are asked separately.

local ADDON, ns = ...

local DefProbe = {}
ns.DefProbe = DefProbe

local WATCH_SECONDS = 20

local function line(fmt, ...)
    ns.Print("   " .. (select("#", ...) > 0 and string.format(fmt, ...) or fmt))
end

local function yn(v) return v and "|cff40d060yes|r" or "|cffff5555no|r" end

--------------------------------------------------------------------------------
-- 1. The server meter
--------------------------------------------------------------------------------

-- Every meter type the client knows, not just the five DetailsBridge consumes.
-- Bridge.Report deliberately filters its output down to those five so the block
-- you need is never the one that got truncated away; here the unfiltered list is
-- the entire point.
function DefProbe.MeterTypes()
    ns.Print("|cff8f5fd61. C_DamageMeter meter types|r")

    local names = ns.DetailsBridge and ns.DetailsBridge.MeterTypeNames()
    if type(names) ~= "table" or next(names) == nil then
        line("|cffff5555Enum.DamageMeterType is absent or empty on this client|r")
        return
    end

    local ids = {}
    for id in pairs(names) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        line("%2d  %s", id, tostring(names[id]))
    end

    -- Which of them actually return a session right now, and how many sources
    -- each carries. A meter that names itself but never has sources is not a
    -- route to anything.
    local sessions, why = ns.DetailsBridge.ServerSessions()
    if not sessions then
        line("|cffff5555sessions: %s|r", tostring(why))
        return
    end

    ns.Print(string.format("|cff8f5fd6   live sessions (restriction: %s)|r",
        tostring(ns.DetailsBridge.RestrictionState() or "n/a")))
    if #sessions == 0 then
        line("none -- run this just after a pull, not on a loading screen")
    end
    for _, s in ipairs(sessions) do
        local sess = s.session
        local sources = type(sess.combatSources) == "table" and #sess.combatSources or -1
        line("[%s / %s] sources=%d", tostring(s.kindName), tostring(s.meterName), sources)
    end

    line("|cffd9a441look for a damage-taken, absorb or mitigation meter above|r")
end

--------------------------------------------------------------------------------
-- 2 and 3. The event watchers
--
-- A private frame rather than ns.RegisterEvent. Every event routed through
-- FireEvent drops a breadcrumb in ns.Trace, and a party in combat produces far
-- too many spellcast events for that ring to survive -- the same reason
-- Capture/CombatLog.lua keeps its own frame.
--------------------------------------------------------------------------------

local watcher
local seen

local function unitIsGroup(unit)
    if type(unit) ~= "string" then return false end
    return unit == "player" or unit:match("^party[1-4]$") ~= nil
end

-- Spell names, so the log reads as "Shield Wall" rather than 871. The eventual
-- DEFENSIVE_SPELLS table has to be written from something, and a list of what
-- five real players actually pressed in a real key beats one assembled from
-- memory -- that is half of what these runs are for.
local function spellName(id)
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(id)
        if type(info) == "table" and info.name then return info.name end
    end
    if GetSpellInfo then
        local name = GetSpellInfo(id)
        if name then return name end
    end
    return nil
end

local function note(bucket, unit, id, secret)
    local b = seen[bucket]
    b.events = b.events + 1
    if unitIsGroup(unit) then
        b.group = b.group + 1
        -- Per unit, counted whether or not the id was readable. Without this a
        -- groupmate whose casts come back secret looks exactly like a groupmate
        -- who cast nothing, and those two answers send the feature down
        -- different roads -- one to a spell list, the other to the server meter.
        local u = b.units[unit]
        if not u then
            u = { unit = unit, events = 0, readable = 0, secret = 0 }
            b.units[unit] = u
        end
        u.events = u.events + 1
        if secret then u.secret = u.secret + 1
        elseif id then u.readable = u.readable + 1 end
    end
    if secret then
        b.secret = b.secret + 1
    elseif id then
        b.readable = b.readable + 1
        if not b.sample and unitIsGroup(unit) then
            b.sample = string.format("%s cast %s", tostring(unit), tostring(id))
        end
        -- Every distinct spell, with who cast it and how often. Counts alone
        -- prove the event fires; this is what says whether the thing it fires
        -- for is a defensive at all.
        if unitIsGroup(unit) then
            local s = b.spells[id]
            if not s then
                s = { id = id, name = spellName(id), count = 0, units = {} }
                b.spells[id] = s
                b.spellCount = b.spellCount + 1
            end
            s.count = s.count + 1
            s.units[unit] = (s.units[unit] or 0) + 1
        end
    end
end

local function onEvent(_, event, unit, arg2, arg3)
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        -- (unitTarget, castGUID, spellID)
        local spellID = arg3
        note("cast", unit, ns.IsSecret(spellID) and nil or spellID, ns.IsSecret(spellID))

    elseif event == "UNIT_AURA" then
        if not unitIsGroup(unit) then
            seen.aura.events = seen.aura.events + 1
            return
        end
        seen.aura.events = seen.aura.events + 1
        seen.aura.group = seen.aura.group + 1
        -- One read is enough to learn whether aura data is legible at all.
        local aura = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex
            and C_UnitAuras.GetAuraDataByIndex(unit, 1, "HELPFUL")
        if type(aura) == "table" then
            local id = aura.spellId
            if ns.IsSecret(id) then
                seen.aura.secret = seen.aura.secret + 1
            elseif id then
                seen.aura.readable = seen.aura.readable + 1
                seen.aura.sample = seen.aura.sample
                    or string.format("%s has %s", tostring(unit), tostring(id))
            end
        end
    end
end

-- Which units were actually seen, in unit order. This is the line that answers
-- the only question a solo run cannot: whether party1-4 are visible at all.
local function unitList(bucket)
    local out = {}
    for _, u in pairs(bucket.units or {}) do out[#out + 1] = u end
    table.sort(out, function(a, b) return a.unit < b.unit end)
    return out
end

-- Distinct spells seen, commonest first, as a sorted array. Declared above
-- store() rather than beside report(), because store() calls it -- a local
-- defined later is a nil global from up here, not a forward reference.
local function spellList(bucket)
    local out = {}
    for _, s in pairs(bucket.spells or {}) do
        local units = {}
        for unit, n in pairs(s.units) do units[#units + 1] = { unit = unit, count = n } end
        table.sort(units, function(a, b) return a.unit < b.unit end)
        out[#out + 1] = { id = s.id, name = s.name, count = s.count, units = units }
    end
    table.sort(out, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return (a.name or tostring(a.id)) < (b.name or tostring(b.id))
    end)
    return out
end

-- Keep every run, not just the last thing printed to a chat frame that scrolls.
-- The whole point of running this with a group is comparing several attempts --
-- a spellcast that fires for one friend and not another is the finding -- and a
-- result you cannot re-read is a result you have to go and get again.
--
-- On the database root rather than in ns.settings, the way debugEcho is, so no
-- debug key ever reaches the production defaults table. Debug/ is stripped from
-- released builds, so nothing outside development ever writes here.
local function store(verdict)
    if not ns.db then return end
    ns.db.debugProbe = ns.db.debugProbe or {}

    local meters = {}
    local names = ns.DetailsBridge and ns.DetailsBridge.MeterTypeNames()
    if type(names) == "table" then
        for id, n in pairs(names) do meters[#meters + 1] = { id = id, name = n } end
        table.sort(meters, function(a, b) return a.id < b.id end)
    end

    local sessions = {}
    local found = ns.DetailsBridge and ns.DetailsBridge.ServerSessions()
    for _, s in ipairs(found or {}) do
        local sess = s.session
        sessions[#sessions + 1] = {
            kind = tostring(s.kindName), meter = tostring(s.meterName),
            sources = type(sess.combatSources) == "table" and #sess.combatSources or -1,
        }
    end

    table.insert(ns.db.debugProbe, {
        at        = ns.Now(),
        zone      = GetZoneText and GetZoneText() or nil,
        groupSize = GetNumGroupMembers and GetNumGroupMembers() or 0,
        seconds   = seen.seconds,
        meters    = meters,
        sessions  = sessions,
        elapsed   = seen.elapsed,
        cast      = { events = seen.cast.events, group = seen.cast.group,
                      readable = seen.cast.readable, secret = seen.cast.secret,
                      sample = seen.cast.sample, spells = spellList(seen.cast),
                      units = unitList(seen.cast) },
        aura      = { events = seen.aura.events, group = seen.aura.group,
                      readable = seen.aura.readable, secret = seen.aura.secret,
                      sample = seen.aura.sample, spells = spellList(seen.aura),
                      units = unitList(seen.aura) },
        verdict   = verdict,
    })
    -- The reload is not a formality. SavedVariables are written on reload or
    -- logout and at no other time, so a run that is only in memory is a run that
    -- is not on disk yet -- which is exactly how a probe session gets done twice.
    ns.Print(string.format("|cff8f5fd6saved as run %d|r -- |cffffff00/pugdebug defprobe show|r"
        .. " to read them back, |cffffff00/reload|r to write them to disk",
        #ns.db.debugProbe))
end

local function report()
    seen.done = true
    seen.elapsed = ns.Now() - (seen.startedAt or ns.Now())

    for _, b in ipairs({
        { key = "cast", label = "2. UNIT_SPELLCAST_SUCCEEDED" },
        { key = "aura", label = "3. UNIT_AURA" },
    }) do
        local s = seen[b.key]
        ns.Print("|cff8f5fd6" .. b.label .. "|r")
        line("fired at all:        %s  (%d event%s)", yn(s.events > 0), s.events,
            s.events == 1 and "" or "s")
        line("fired for the group: %s  (%d)", yn(s.group > 0), s.group)
        line("ids readable:        %s  (%d readable, %d secret)",
            yn(s.readable > 0), s.readable, s.secret)
        if s.sample then line("sample:              %s", s.sample) end

        local units = unitList(s)
        if #units > 0 then
            local bits = {}
            for _, u in ipairs(units) do
                bits[#bits + 1] = string.format("%s %d/%dsec", u.unit, u.readable, u.secret)
            end
            line("by unit (read/secret): %s", table.concat(bits, "  "))
        end
        if #units <= 1 and (GetNumGroupMembers and GetNumGroupMembers() or 0) > 1 then
            line("|cffd9a441only one unit seen while grouped -- groupmates cast nothing,|r")
            line("|cffd9a441or their casts are invisible. Re-run while they are pressing.|r")
        end

        local spells = spellList(s)
        if #spells > 0 then
            line("distinct spells:     %d", #spells)
            for i = 1, math.min(#spells, 12) do
                local sp = spells[i]
                local who = {}
                for _, u in ipairs(sp.units) do
                    who[#who + 1] = string.format("%s x%d", u.unit, u.count)
                end
                line("   %-28s %3d  (%s)",
                    (sp.name or "?") .. " [" .. sp.id .. "]", sp.count,
                    table.concat(who, ", "))
            end
            if #spells > 12 then line("   ... and %d more, all saved", #spells - 12) end
        end
    end

    -- The verdict, so the answer is not left as an exercise.
    local verdict
    if seen.cast.readable > 0 and seen.cast.group > 0 then
        verdict = "spellcast works -- a spell list can count casts"
    elseif seen.cast.group > 0 then
        verdict = "spellcast fires for the group but the ids are secret"
    else
        verdict = "no usable spellcast data"
    end
    if seen.aura.readable > 0 then
        verdict = verdict .. "; UNIT_AURA readable as fallback"
    end

    ns.Print("|cff8f5fd6verdict|r")
    line(verdict)
    line("if a damage-taken meter appeared in step 1, prefer that over both.")

    watcher:UnregisterAllEvents()
    watcher:SetScript("OnEvent", nil)

    store(verdict)
end

-- What every run so far found, so several attempts can be compared without
-- having kept the chat frame open.
function DefProbe.Show()
    local runs = ns.db and ns.db.debugProbe
    if type(runs) ~= "table" or #runs == 0 then
        ns.Print("no probe runs stored yet -- |cffffff00/pugdebug defprobe|r records one")
        return
    end
    ns.Print(string.format("|cff8f5fd6%d probe run%s|r", #runs, #runs == 1 and "" or "s"))
    for i, r in ipairs(runs) do
        line("%d. %s  group=%d  %ds", i, tostring(r.zone or "?"),
            tonumber(r.groupSize) or 0, tonumber(r.seconds) or 0)
        line("   cast: %d events, %d group, %d readable, %d secret",
            r.cast.events, r.cast.group, r.cast.readable, r.cast.secret)
        line("   aura: %d events, %d group, %d readable, %d secret",
            r.aura.events, r.aura.group, r.aura.readable, r.aura.secret)
        line("   %s", tostring(r.verdict))
    end
end

function DefProbe.Clear()
    if ns.db then ns.db.debugProbe = nil end
    ns.Print("probe runs cleared")
end

-- Watch both events for a fixed window. Bounded on purpose: this is a question
-- being asked once, not a capture that should outlive its answer.
function DefProbe.Watch(seconds)
    seconds = tonumber(seconds) or WATCH_SECONDS

    seen = {
        seconds   = seconds,
        startedAt = ns.Now(),
        cast = { events = 0, group = 0, readable = 0, secret = 0,
                 spells = {}, spellCount = 0, units = {} },
        aura = { events = 0, group = 0, readable = 0, secret = 0,
                 spells = {}, spellCount = 0, units = {} },
    }

    watcher = watcher or CreateFrame("Frame")
    watcher:SetScript("OnEvent", function(...) pcall(onEvent, ...) end)
    watcher:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    watcher:RegisterEvent("UNIT_AURA")

    if seconds > 0 then
        ns.Print(string.format("|cff8f5fd6watching for %d seconds|r -- pull something "
            .. "and press defensives, your own and a groupmate's", seconds))
        -- Guarded: stopping early already reported, and a timer that fires
        -- afterwards must not report the same run twice.
        C_Timer.After(seconds, function()
            if seen and not seen.done then pcall(report) end
        end)
    else
        ns.Print("|cff8f5fd6watching until |cffffff00/pugdebug defprobe stop|r|cff8f5fd6|r "
            .. "-- run a whole key if you like")
    end
end

function DefProbe.Run(seconds)
    ns.Print("|cff8f5fd6PugRoster defensive-capture probe|r")
    DefProbe.MeterTypes()
    DefProbe.Watch(seconds)
end

-- Open-ended, for a whole dungeon. A fixed window is enough to prove the event
-- fires; it is not enough to see what five people actually press over a key,
-- which is the list the feature has to be built from.
function DefProbe.Start()
    ns.Print("|cff8f5fd6PugRoster defensive-capture probe|r")
    DefProbe.MeterTypes()
    DefProbe.Watch(0)
end

function DefProbe.Stop()
    if not seen or seen.done then
        ns.Print("nothing is being watched -- |cffffff00/pugdebug defprobe start|r")
        return
    end
    report()
end
