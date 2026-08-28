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

local function note(bucket, unit, id, secret)
    local b = seen[bucket]
    b.events = b.events + 1
    if unitIsGroup(unit) then b.group = b.group + 1 end
    if secret then
        b.secret = b.secret + 1
    elseif id then
        b.readable = b.readable + 1
        if not b.sample and unitIsGroup(unit) then
            b.sample = string.format("%s cast %s", tostring(unit), tostring(id))
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

local function report()
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
    end

    -- The verdict, so the answer is not left as an exercise.
    ns.Print("|cff8f5fd6verdict|r")
    if seen.cast.readable > 0 and seen.cast.group > 0 then
        line("|cff40d060UNIT_SPELLCAST_SUCCEEDED works -- a spell list can count casts|r")
    elseif seen.cast.group > 0 then
        line("|cffd9a441spellcast fires for the group but the ids are secret|r")
    else
        line("|cffff5555no usable spellcast data|r")
    end
    if seen.aura.readable > 0 then
        line("|cff40d060UNIT_AURA is readable -- usable as the fallback|r")
    end
    line("if a damage-taken meter appeared in step 1, prefer that over both.")

    watcher:UnregisterAllEvents()
    watcher:SetScript("OnEvent", nil)
end

-- Watch both events for a fixed window. Bounded on purpose: this is a question
-- being asked once, not a capture that should outlive its answer.
function DefProbe.Watch(seconds)
    seconds = tonumber(seconds) or WATCH_SECONDS

    seen = {
        cast = { events = 0, group = 0, readable = 0, secret = 0 },
        aura = { events = 0, group = 0, readable = 0, secret = 0 },
    }

    watcher = watcher or CreateFrame("Frame")
    watcher:SetScript("OnEvent", function(...) pcall(onEvent, ...) end)
    watcher:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    watcher:RegisterEvent("UNIT_AURA")

    ns.Print(string.format("|cff8f5fd6watching for %d seconds|r -- pull something "
        .. "and press defensives, your own and a groupmate's", seconds))
    C_Timer.After(seconds, function() pcall(report) end)
end

function DefProbe.Run(seconds)
    ns.Print("|cff8f5fd6PugRoster defensive-capture probe|r")
    DefProbe.MeterTypes()
    DefProbe.Watch(seconds)
end
