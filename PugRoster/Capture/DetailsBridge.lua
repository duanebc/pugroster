-- Capture/DetailsBridge.lua -- enrichment from Details! Damage Meter.
--
-- Details used to be optional polish on top of our own combat-log tallies. On
-- Midnight it is the only source there is: COMBAT_LOG_EVENT_UNFILTERED is closed
-- to addons (see Capture/CombatLog.lua), so deaths, interrupts, dispels, damage
-- and healing all come from here or not at all.
--
-- Every call is feature-detected *per function* rather than per addon (Open risk
-- 3 in the plan): Details reshuffles its API between expansions, and a missing
-- method must degrade to zeroes rather than error out mid-run.
--
-- Matching is by GUID first. Details actors carry `.serial`, which is the GUID,
-- and `.nome`, which is the name -- and on Midnight a name can come back as a
-- secret value that cannot be compared or used as a table key. Names are the
-- fallback, not the primary key.
--
-- Bridge.Report() prints what Details actually answered. When enrichment comes
-- back empty that is the thing to run: guessing which assumption broke has a bad
-- track record here.

local ADDON, ns = ...

local Bridge = {}
ns.DetailsBridge = Bridge

-- Details attribute ids: plain numbers, and combat:GetContainer(id) is literally
-- `self[id]`.
--
-- Do NOT reach for `Details.atributo_damage` as a "named constant". It exists,
-- which makes it look like one, but it is the damage *actor class* metatable --
-- passing it to GetContainer indexes the combat object with a table, gets nil,
-- and enrichment then reports "no data" while Details is sitting there full of
-- it. The real named constants are the DETAILS_ATTRIBUTE_* globals, and they are
-- these same numbers.
local ATTR_DAMAGE  = DETAILS_ATTRIBUTE_DAMAGE or 1
local ATTR_HEALING = DETAILS_ATTRIBUTE_HEAL or 2
local ATTR_UTILITY = DETAILS_ATTRIBUTE_MISC or 4

local function details()
    local d = _G.Details
    return type(d) == "table" and d or nil
end

-- Whether we may use Details at all: loaded, and not switched off in Options.
function Bridge.IsAvailable()
    if not ns.settings or not ns.settings.useDetails then return false end
    local d = details()
    return d ~= nil and type(d.GetCurrentCombat) == "function"
end

--------------------------------------------------------------------------------
-- Segment selection
--------------------------------------------------------------------------------

local function usableCombat(combat)
    return type(combat) == "table" and type(combat.GetContainer) == "function" and combat or nil
end

-- How many actors a combat's damage container actually holds.
function Bridge.ActorCount(combat)
    local ok, container = pcall(combat.GetContainer, combat, ATTR_DAMAGE)
    if not ok or type(container) ~= "table" then return 0 end
    local n = 0
    for _ in ipairs(container._ActorTable or container) do n = n + 1 end
    return n
end

-- The combat object covering the key.
--
-- Preference order matters -- a Mythic+ key produces many segments plus one
-- combined segment, and only the combined one is the whole run -- but preference
-- is not the same as *readable*. Picking the first merely-usable candidate found
-- an overall segment that existed and was empty, and stopped there while the data
-- sat in another one. So: rank the candidates, then take the best one that has
-- anyone in it, and only fall back to an empty one if nothing has actors.
local function candidates(d)
    local out = {}

    local function add(combat, label, rank)
        if usableCombat(combat) then
            out[#out + 1] = { combat = combat, label = label, rank = rank }
        end
    end

    if type(d.GetCombatSegments) == "function" then
        local ok, segments = pcall(d.GetCombatSegments, d)
        if ok and type(segments) == "table" then
            for i, combat in ipairs(segments) do
                local isMythicOverall = false
                if type(combat) == "table" and type(combat.IsMythicDungeonOverall) == "function" then
                    local ok2, v = pcall(combat.IsMythicDungeonOverall, combat)
                    isMythicOverall = (ok2 and v) and true or false
                end
                add(combat, isMythicOverall and "mythic+" or ("segment " .. i),
                    isMythicOverall and 1 or 4)
            end
        end
    end

    for _, source in ipairs({
        { method = "GetOverallCombat", label = "overall", rank = 2 },
        { method = "GetCurrentCombat", label = "current", rank = 3 },
    }) do
        if type(d[source.method]) == "function" then
            local ok, combat = pcall(d[source.method], d)
            if ok then add(combat, source.label, source.rank) end
        end
    end

    table.sort(out, function(a, b) return a.rank < b.rank end)
    return out
end

-- Returns combat, label, or nil plus a reason.
--
-- "Every candidate is empty" is a different diagnosis from "the one I picked was
-- empty", and it usually is not a bug at all: Details holds its segments in
-- memory only, so a /reload or a logout throws them away. A run can therefore
-- only be pulled from Details during the same session it happened in.
local function runSegment(d)
    local list = candidates(d)
    if #list == 0 then return nil, nil, "Details exposes no combat segments" end

    for _, c in ipairs(list) do
        if Bridge.ActorCount(c.combat) > 0 then return c.combat, c.label end
    end

    return nil, nil, "Details has no combat data in this session. Its segments are "
        .. "held in memory and cleared by a reload or logout, so a run can only be "
        .. "read from Details before you reload."
end

--------------------------------------------------------------------------------
-- Harvest
--------------------------------------------------------------------------------

local function newTotals()
    return { list = {}, bySerial = {}, byName = {} }
end

-- Usable as a lookup key? Empty strings are not: Details leaves `serial` as ""
-- on actors it built without a GUID (its own code guards for exactly this at
-- container_actors.lua:573), and keying on "" would collapse every such actor
-- into one shared record -- five players merged into one, which then matches
-- nobody. Secrets are not usable either.
local function key(value)
    -- Secrets first, and that order is the whole point: comparing a secret string
    -- to "" raises "attempt to compare local 'value' (a secret string value)".
    -- The test written to keep secrets out was itself the thing that threw on
    -- one, which took down the entire read -- every player's numbers lost
    -- because one source had a withheld name.
    if ns.IsSecret(value) then return nil end
    if value == nil or value == "" then return nil end
    return value
end

-- One record per actor, reachable by GUID or by name.
local function recordFor(totals, serial, name)
    serial = key(serial)
    name = key(name)
    if not serial and not name then return nil end

    local rec = (serial and totals.bySerial[serial]) or (name and totals.byName[name])
    if not rec then
        rec = { serial = serial, name = name,
                damage = 0, healing = 0, interrupts = 0, dispels = 0, deaths = 0 }
        totals.list[#totals.list + 1] = rec
    end
    rec.serial = rec.serial or serial
    rec.name = rec.name or name
    if serial then totals.bySerial[serial] = rec end
    if name then totals.byName[name] = rec end
    return rec
end

local function eachActor(combat, attribute, fn)
    local ok, container = pcall(combat.GetContainer, combat, attribute)
    if not ok or type(container) ~= "table" then return 0 end

    local seen = 0
    -- Every actor, deliberately unfiltered.
    --
    -- Details has a `grupo` flag meaning "was in my group", which looks like the
    -- right filter and is not: it is set on Details' own actor-creation paths and
    -- does not survive into the merged overall segment, so filtering on it threw
    -- away all five players and reported "no group actors" on a segment that had
    -- everyone in it. We match on the run's own GUIDs afterwards, which is a
    -- stricter filter than Details' flag anyway -- enemies and pets simply never
    -- match one of our five.
    for _, actor in ipairs(container._ActorTable or container) do
        if type(actor) == "table" then
            seen = seen + 1
            fn(actor)
        end
    end
    return seen
end

-- Totals for the run's segment, or nil plus a reason.
function Bridge.GetSegmentTotals()
    local locks = Bridge.ActiveLocks()
    if #locks > 0 then
        -- Naming the restriction matters: Combat clears seconds after a pull,
        -- ChallengeMode holds until the key is finished and left behind.
        return nil, string.format("the server is withholding combat values right "
            .. "now (%s restriction active). They are released when it clears.",
            table.concat(locks, "+"))
    end

    local d = details()
    if not d then return nil, "Details is not loaded" end

    local combat, source, why = runSegment(d)
    if not combat then return nil, why or "Details has no readable combat segment" end

    local totals = newTotals()

    local function harvest(attribute, apply)
        eachActor(combat, attribute, function(actor)
            local rec = recordFor(totals, actor.serial, actor.nome)
            if rec then apply(rec, actor) end
        end)
    end

    harvest(ATTR_DAMAGE, function(rec, actor)
        rec.damage = math.floor(tonumber(actor.total) or 0)
    end)
    harvest(ATTR_HEALING, function(rec, actor)
        rec.healing = math.floor(tonumber(actor.total) or 0)
    end)
    -- The utility actor carries the counts our combat log used to tally.
    harvest(ATTR_UTILITY, function(rec, actor)
        rec.interrupts = math.floor(tonumber(actor.interrupt) or 0)
        rec.dispels    = math.floor(tonumber(actor.dispell) or 0)
    end)

    -- Deaths are a flat list, one entry per death, with the player's name in the
    -- third slot -- so counting the list is counting deaths.
    if type(combat.GetDeaths) == "function" then
        local ok, deaths = pcall(combat.GetDeaths, combat)
        if ok and type(deaths) == "table" then
            for _, death in ipairs(deaths) do
                local name = type(death) == "table" and ns.SafeGUID(death[3])
                local rec = name and totals.byName[name]
                if rec then rec.deaths = rec.deaths + 1 end
            end
        end
    end

    if #totals.list == 0 then
        return nil, string.format("Details' %s segment has no readable actors", source)
    end
    return totals, source
end

--------------------------------------------------------------------------------
-- Apply
--------------------------------------------------------------------------------

-- Fold Details' numbers into a run's observations. GUID first, name second. Only
-- non-zero values overwrite, so a segment that never saw a player cannot blank
-- out something we recorded ourselves on a client where the combat log works.
function Bridge.Enrich(run, preferType)
    if not run or not run.observations then return false, "no run" end

    -- The server first. Details is a display layer over the same data and its
    -- containers have been empty on this client throughout, so it is the fallback
    -- now rather than the source.
    -- Ask for the caller's preference, then the widest session, then each named
    -- session type in turn -- taking the first that actually matches somebody in
    -- this run rather than the first that merely returns data.
    --
    -- Fights ask for Current and are fine. A whole key asks for the widest
    -- session, and a session can be the widest and still match nobody: sources
    -- whose sourceGUID and name both come back secret are counted but cannot be
    -- identified, so the totals look present and pair with no observation. When
    -- that happens the narrower session is still worth asking before falling
    -- through to Details, which has been empty on this client throughout.
    local order = {}
    if preferType then order[#order + 1] = preferType end
    order[#order + 1] = false                                    -- widest
    if preferType ~= "Current" then order[#order + 1] = "Current" end
    if preferType ~= "Overall" then order[#order + 1] = "Overall" end

    local serverWhy
    for _, want in ipairs(order) do
        local server, why = Bridge.ServerTotals(want or nil)
        serverWhy = serverWhy or why
        if server then
        local matched = 0
        for guid, obs in pairs(run.observations) do
            -- GUID first: the server hands back sourceGUID, and our observations
            -- are keyed by GUID, so the two line up exactly. Name is the fallback
            -- for a source that arrived without one.
            local rec = (ns.SafeGUID(guid) and server[guid])
                or server.byName[obs.name or ""]
                or server.byName[ns.ShortName(obs.name or "")]
                or server[obs.name or ""]
                or server[ns.ShortName(obs.name or "")]
            if rec then
                if rec.damage     > 0 then obs.damage     = rec.damage end
                if rec.healing    > 0 then obs.healing    = rec.healing end
                if rec.interrupts > 0 then obs.interrupts = rec.interrupts end
                if rec.dispels    > 0 then obs.dispels    = rec.dispels end
                if rec.deaths     > 0 then obs.deaths     = rec.deaths end
                obs.statSource = "server"
                matched = matched + 1
            end
        end
        if matched > 0 then
            run.detailsEnriched = true
            run.detailsSegment = "server meter"
            return true
        end
        end
    end

    -- pcall'd. Details is third-party code reading a client that withholds most
    -- of what it wants, and an error in there was taking down the whole read --
    -- including the server result we had already computed. It is the fallback;
    -- it does not get to break the primary.
    local gotTotals, totals, source = pcall(Bridge.GetSegmentTotals)
    if not gotTotals then
        return false, (serverWhy and (serverWhy .. " / ") or "")
            .. "Details errored while reading: " .. tostring(totals)
    end
    if not totals then
        return false, (serverWhy and (serverWhy .. " / ") or "") .. tostring(source)
    end

    local matched = 0
    for guid, obs in pairs(run.observations) do
        local rec = (ns.SafeGUID(guid) and totals.bySerial[guid])
            or totals.byName[obs.name or ""]
            or totals.byName[ns.ShortName(obs.name or "")]
        if rec then
            if rec.damage     > 0 then obs.damage     = rec.damage end
            if rec.healing    > 0 then obs.healing    = rec.healing end
            if rec.interrupts > 0 then obs.interrupts = rec.interrupts end
            if rec.dispels    > 0 then obs.dispels    = rec.dispels end
            if rec.deaths     > 0 then obs.deaths     = rec.deaths end
            obs.statSource = "details"
            matched = matched + 1
        end
    end

    if matched == 0 then
        return false, string.format(
            "Details' %s segment has %d group actors, none matching this run's five",
            source, #totals.list)
    end

    run.detailsEnriched = true
    run.detailsSegment = source
    return true
end

-- Pull again for a run that is already filed. History offers this because
-- Details finishes building its combined Mythic+ segment slightly after
-- CHALLENGE_MODE_COMPLETED, and because a run captured before this bridge worked
-- can still be recovered while Details holds the segment in memory.
function Bridge.Repull(run)
    if not run then return false, "no run selected" end

    -- No Details gate. Enrich reads C_DamageMeter first and falls back to
    -- Details, and on this client the server meter is the only one that has ever
    -- answered -- so refusing here because Details is absent turned down the
    -- source that works on behalf of the one that does not. The gate is a
    -- leftover from when Details was the source rather than the fallback.
    --
    -- The server is also the reason this is worth trying at all after a reload:
    -- Details forgets its segments with the UI, the server's sessions do not.
    -- The error itself, not a label for it. "Details refused the read" was
    -- printed for every failure alike -- a Lua error inside Enrich, a withheld
    -- server, and a clean no-match -- so the one message that should have named
    -- the fault was the one that hid it.
    local ok, applied, why = pcall(Bridge.Enrich, run)
    if not ok then return false, "error while reading: " .. tostring(applied) end

    if not applied then
        -- Print the diagnostic on the spot. This path has failed for several
        -- unrelated reasons in a row, each invisible from the outside, and a
        -- bare "it didn't work" costs a round trip every time.
        ns.Print("|cffd9a441report follows -- this is what the server and Details answered:|r")
        for _, line in ipairs(Bridge.Report(run)) do ns.Print(line) end
        -- The commonest cause by far, and the one whose fix is "walk out".
        local locks = Bridge.ActiveLocks()
        if #locks > 0 then
            ns.Print("|cffd9a441" .. table.concat(locks, "+") .. " is still active|r"
                .. " -- the server has not released these numbers yet. Leave the"
                .. " dungeon and try again.")
        end
        return false, why or "no match"
    end

    ns.Rating.RecomputeAll()
    return true
end

--------------------------------------------------------------------------------
-- Blizzard's own damage meter
--
-- On Midnight the combat log is closed and Details no longer parses it. Instead
-- it reads C_DamageMeter, a server-side meter Blizzard added as the sanctioned
-- replacement: combat *sessions*, each with combatSources carrying a name and an
-- amountPerSecond. Everything Details shows comes from there.
--
-- Which means Details can only have data where Blizzard opened a session. It also
-- means the source's own state is worth reporting, because "Details has nothing"
-- and "the server recorded nothing" are different problems with different fixes.
--------------------------------------------------------------------------------

-- Reverse an Enum table so a raw id can be printed as its name.
local function enumNames(enumTable)
    local out = {}
    if type(enumTable) == "table" then
        for name, id in pairs(enumTable) do out[id] = name end
    end
    return out
end

-- The two axes of C_DamageMeter.GetCombatSessionFromType(sessionType, meterType).
-- meterType is the interesting one: Blizzard exposes Interrupts, Dispels and
-- Deaths alongside DamageDone and HealingDone -- everything a run record wants,
-- and more than Details surfaces through its containers.
function Bridge.SessionTypeNames() return enumNames(Enum and Enum.DamageMeterSessionType) end
function Bridge.MeterTypeNames()   return enumNames(Enum and Enum.DamageMeterType) end

function Bridge.ServerSessions()
    if type(C_DamageMeter) ~= "table"
        or type(C_DamageMeter.GetCombatSessionFromType) ~= "function" then
        return nil, "C_DamageMeter is not present on this client"
    end

    -- (sessionType, meterType). Details sweeps the same space, 0..1 by 0..10.
    local sessionNames, meterNames = Bridge.SessionTypeNames(), Bridge.MeterTypeNames()
    local found = {}
    for sessionType = 0, 1 do
        for meterType = 0, 10 do
            local ok, session = pcall(C_DamageMeter.GetCombatSessionFromType, sessionType, meterType)
            if ok and type(session) == "table" then
                found[#found + 1] = {
                    kind = sessionType, index = meterType, session = session,
                    kindName = sessionNames[sessionType] or ("type " .. sessionType),
                    meterName = meterNames[meterType] or ("meter " .. meterType),
                }
            end
        end
    end
    return found
end

-- Is the server withholding combat values right now?
--
-- This is the answer to why every read came back empty. C_DamageMeter has the
-- sessions and the sources all along -- 22 of them, five sources each -- but
-- while the Combat restriction is non-zero every `name` and `amountPerSecond`
-- is a *secret*: present, countable, unreadable. Details handles this by waiting
-- for combat to drop (its WaitServerDropCombat) before it reads anything, and so
-- must we. Reading during lockdown gets nothing no matter how correct the rest
-- of the code is.
-- Every restriction that withholds combat values, not just Combat.
--
-- Checking Combat alone is why four keys in a row filed empty while ordinary
-- dungeons on either side of them recorded all five players. A key runs under
-- the *ChallengeMode* restriction as well, and that one outlives the pull: when
-- CHALLENGE_MODE_COMPLETED fires, Combat has dropped and ChallengeMode has not.
-- So IsLocked said "go ahead", the read came back with sources whose names and
-- GUIDs were every one of them secret, nothing matched anybody, and the run was
-- filed with zeroes and no explanation.
--
-- The failure mode is the point: under-reporting the lock does not degrade the
-- read, it silently empties it. Over-reporting only makes the retry wait longer.
local LOCKING = { "Combat", "ChallengeMode", "Encounter", "PvPMatch" }

-- Which restrictions are active right now, as a list of names.
function Bridge.ActiveLocks()
    if type(C_RestrictedActions) ~= "table"
        or type(C_RestrictedActions.GetAddOnRestrictionState) ~= "function"
        or type(Enum) ~= "table" or type(Enum.AddOnRestrictionType) ~= "table" then
        return {}
    end
    local out = {}
    for _, name in ipairs(LOCKING) do
        local id = Enum.AddOnRestrictionType[name]
        if id then
            local ok, state = pcall(C_RestrictedActions.GetAddOnRestrictionState, id)
            if ok and state ~= nil and state ~= 0 then out[#out + 1] = name end
        end
    end
    return out
end

function Bridge.IsLocked()
    return #Bridge.ActiveLocks() > 0
end

-- Run `fn` once the server stops withholding, or give up after `timeout`.
function Bridge.WhenUnlocked(timeout, fn)
    if not Bridge.IsLocked() then return fn(true) end

    local waited = 0
    local ticker
    ticker = C_Timer.NewTicker(1, function()
        waited = waited + 1
        if not Bridge.IsLocked() then
            ticker:Cancel()
            fn(true)
        elseif waited >= (timeout or 90) then
            ticker:Cancel()
            fn(false)
        end
    end)
end

-- Whether the server is currently withholding combat data. During restricted
-- content it hands back secrets and only releases them when combat drops.
function Bridge.RestrictionState()
    if type(C_RestrictedActions) ~= "table"
        or type(C_RestrictedActions.GetAddOnRestrictionState) ~= "function"
        or type(Enum) ~= "table" or type(Enum.AddOnRestrictionType) ~= "table" then
        return nil
    end
    local out = {}
    for _, name in ipairs({ "Combat", "Encounter", "ChallengeMode", "PvPMatch", "Map" }) do
        local id = Enum.AddOnRestrictionType[name]
        if id then
            local ok, state = pcall(C_RestrictedActions.GetAddOnRestrictionState, id)
            out[#out + 1] = string.format("%s=%s", name, ok and tostring(state) or "?")
        end
    end
    return table.concat(out, " ")
end

--------------------------------------------------------------------------------
-- Reading the server meter directly
--
-- Details' containers come back empty on this client while C_DamageMeter has
-- every session, every source, every number. Details is a display layer we do not
-- need: the numbers it would show us are ours to read from the same place it
-- reads them, without depending on its internals surviving the next patch.
--
-- One session per meter type. `amountPerSecond` is what a source carries, so a
-- total is rate x elapsed; a count (interrupts, dispels, deaths) cannot be a rate,
-- so whichever field actually holds it is preferred when present.
--------------------------------------------------------------------------------

local METERS = {
    -- `count` meters are whole numbers and round; damage and healing truncate.
    { field = "damage",     names = { "DamageDone" }  },
    { field = "healing",    names = { "HealingDone" } },
    -- Aliases because the enum's spelling is the client's to change, and a
    -- meter we cannot name is a column of zeroes with no error to explain it.
    { field = "interrupts", names = { "Interrupts", "Interrupt" },        count = true },
    { field = "dispels",    names = { "Dispels", "Dispel", "Dispells" },  count = true },
    -- Deaths are counted by entry, not read from a field. The server reports one
    -- source per death -- carrying deathRecapID and deathTimeSeconds -- and
    -- leaves totalAmount at 0, so reading the value gives zero however the rest
    -- of the code behaves. Four deaths in a session is four entries.
    { field = "deaths", names = { "Deaths", "Death", "PlayerDeaths" },
      count = true, countEntries = true },
}

-- `totalAmount` is the exact figure for every meter: 34688769 damage, or 4
-- interrupts. `amountPerSecond` is the same thing divided by the segment length,
-- which is why damage looked right when multiplied back out and a count of 4 over
-- 446 seconds rounded to zero. Prefer the exact field; the rate is the fallback.
local COUNT_FIELDS = { "totalAmount", "amount", "count", "total", "value" }

-- A source's value for one meter, exact where the server gives one.
local function sourceValue(source, elapsed)
    for _, f in ipairs(COUNT_FIELDS) do
        local v = tonumber(source[f])
        if v and v > 0 then return v end
    end

    local rate = tonumber(source.amountPerSecond)
    if not rate then return nil end
    return rate * (elapsed or 0)
end

-- { [name] = { damage, healing, interrupts, dispels, deaths } }, or nil + reason.
--
-- `preferType` names the session type to favour ("Current" for the fight that
-- just ended, "Overall" for everything since the meter was reset). Without it the
-- widest session wins, which is right for a whole key and wrong for one pull.
function Bridge.ServerTotals(preferType)
    local locks = Bridge.ActiveLocks()
    if #locks > 0 then
        -- Naming the restriction matters: Combat clears seconds after a pull,
        -- ChallengeMode holds until the key is finished and left behind.
        return nil, string.format("the server is withholding combat values right "
            .. "now (%s restriction active). They are released when it clears.",
            table.concat(locks, "+"))
    end

    local sessions = Bridge.ServerSessions()
    if not sessions then return nil, "C_DamageMeter is not present on this client" end
    if #sessions == 0 then return nil, "the server has recorded no combat sessions" end

    local meterIds = {}
    for id, name in pairs(Bridge.MeterTypeNames()) do meterIds[name] = id end

    Bridge.missingMeters = {}
    Bridge.lastSources, Bridge.lastAnonymous = 0, 0

    -- Keyed by whichever identity the source carried; byName is a side index so
    -- an observation can be matched on either.
    local out = { byName = {} }
    local found = false
    local function rec(id)
        out[id] = out[id] or
            { damage = 0, healing = 0, interrupts = 0, dispels = 0, deaths = 0 }
        return out[id]
    end

    for _, meter in ipairs(METERS) do
        local wanted
        for _, n in ipairs(meter.names) do wanted = wanted or meterIds[n] end
        -- Worth knowing when a meter simply is not there under any name we know.
        if not wanted then Bridge.missingMeters[meter.field] = true end

        if wanted then
            local best
            for _, s in ipairs(sessions) do
                if s.index == wanted and type(s.session.combatSources) == "table" then
                    if preferType and s.kindName == preferType then
                        best = s
                        break
                    end
                    if not preferType and
                        (not best or #s.session.combatSources > #best.session.combatSources) then
                        best = s
                    end
                end
            end

            if best then
                local sess = best.session
                local elapsed = tonumber(sess.elapsedTime) or tonumber(sess.durationSeconds) or 0
                            for _, source in ipairs(sess.combatSources) do
                    -- Match on sourceGUID where the server offers one: it is an
                    -- exact identity, where a name has to be reconciled against
                    -- realm suffixes.
                    local guid, name = key(source.sourceGUID), key(source.name)
                    -- A source with neither identity readable is counted and then
                    -- dropped: it can never be paired with an observation. Worth
                    -- tallying, because "five sources, none identifiable" and
                    -- "no sources at all" look identical from the outside and
                    -- mean very different things.
                    Bridge.lastSources = (Bridge.lastSources or 0) + 1
                    if not (guid or name) then
                        Bridge.lastAnonymous = (Bridge.lastAnonymous or 0) + 1
                    end
                    if guid or name then
                        local r = rec(guid or name)
                        r.guid, r.name = guid or r.guid, name or r.name
                        if guid and name then out.byName[name] = r end

                        if meter.countEntries then
                            r[meter.field] = (r[meter.field] or 0) + 1
                            found = true
                        else
                            local v = sourceValue(source, elapsed)
                            if v then
                                r[meter.field] = meter.count
                                    and math.floor(v + 0.5) or math.floor(v)
                                found = true
                            end
                        end
                    end
                end
            end
        end
    end

    if not found then
        if (Bridge.lastAnonymous or 0) > 0 then
            return nil, string.format(
                "the server's sessions hold %d sources but %d have no readable "
                .. "name or GUID, so none can be matched to a player",
                Bridge.lastSources or 0, Bridge.lastAnonymous)
        end
        return nil, "the server's sessions carry no readable values"
    end
    return out
end

--------------------------------------------------------------------------------
-- Catching up after a reload
--
-- A /reload destroys every pending timer, so a run finished seconds earlier
-- never gets its retry and files with nothing. Details cannot help there -- its
-- segments die with the UI -- but C_DamageMeter is the *server's*, and its
-- sessions survive: the same 22 were there before and after a reload.
--
-- So a recent record with no stats is worth one more attempt at login. Bounded
-- to the last quarter hour on purpose: the server's Overall session spans
-- everything since it was last reset, so the further back a record is, the less
-- that session resembles it.
--------------------------------------------------------------------------------

local CATCHUP_WINDOW = 900

function Bridge.CatchUp()
    local now, pending = ns.Now(), {}

    local function consider(record)
        if record.debug or record.detailsEnriched then return end
        if (now - (record.endedAt or record.startedAt or 0)) > CATCHUP_WINDOW then return end
        pending[#pending + 1] = record
    end

    for _, run in ipairs(ns.db.runs or {}) do consider(run) end
    for _, fight in ipairs(ns.db.fights or {}) do consider(fight) end
    if #pending == 0 then return end

    Bridge.WhenUnlocked(120, function(unlocked)
        if not unlocked then return end

        local done = 0
        for _, record in ipairs(pending) do
            local ok, applied = pcall(Bridge.Enrich, record)
            if ok and applied then done = done + 1 end
        end

        if done > 0 then
            ns.Rating.RecomputeAll()
            if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
            ns.Print(string.format("filled in combat stats for %d recent %s.",
                done, done == 1 and "record" or "records"))
        end
    end)
end

ns.OnInit(function()
    -- After the client has settled: the meter is not queryable the instant the
    -- addon loads.
    C_Timer.After(8, function() pcall(Bridge.CatchUp) end)
end)

--------------------------------------------------------------------------------
-- Report
--
-- What Details actually answered, so a failure names its own cause instead of
-- being narrowed down by guesswork. Safe to run at any time.
--------------------------------------------------------------------------------

local function describe(value)
    if value == nil then return "nil" end
    if issecretvalue and issecretvalue(value) then return "<secret>" end
    return tostring(value)
end

-- Returns an array of lines. An array rather than one blob so callers print it
-- without having to split on newlines.
-- The meters PugRoster actually reads. Everything else is noise in a report.
local REPORTED_METERS = {
    DamageDone = true, HealingDone = true,
    Interrupts = true, Dispels = true, Deaths = true,
}

function Bridge.Report(run, onlyMeter)
    local out = {}
    local function line(fmt, ...) out[#out + 1] = string.format(fmt, ...) end

    -- Blizzard's meter first: it is the source Details itself reads, so if it is
    -- empty then nothing downstream can have data and Details is not at fault.
    local sessions, why = Bridge.ServerSessions()
    if not sessions then
        line("|cffff5555C_DamageMeter: %s|r", tostring(why))
    else
        line("C_DamageMeter sessions: %d   restrictions: %s",
            #sessions, tostring(Bridge.RestrictionState() or "n/a"))
        local shown, skipped = 0, 0
        for _, s in ipairs(sessions) do
            -- Only the meters we consume, so the block we need is never the one
            -- that got truncated away. `onlyMeter` narrows it further.
            local want = onlyMeter and (s.meterName:lower() == onlyMeter:lower())
                or (not onlyMeter and REPORTED_METERS[s.meterName])
            if not want then skipped = skipped + 1 end
            if want then
            shown = shown + 1
            local sess = s.session
            local sources = type(sess.combatSources) == "table" and #sess.combatSources or -1
            line("  [%s / %s] %s / %s  elapsed=%s sources=%d",
                s.kindName, s.meterName,
                describe(sess.sessionName), describe(sess.zoneName),
                describe(sess.elapsedTime or sess.durationSeconds), sources)
            if sources > 0 then
                -- Every field, not the two I guessed at. Damage and healing come
                -- through as a rate, but a count like Interrupts cannot -- so the
                -- field that carries it has to be found rather than assumed.
                local first = sess.combatSources[1]
                if type(first) == "table" then
                    local parts = {}
                    for k, v in pairs(first) do
                        if type(v) ~= "table" and type(v) ~= "function" then
                            parts[#parts + 1] = tostring(k) .. "=" .. describe(v)
                        end
                    end
                    table.sort(parts)
                    line("     source fields: %s", table.concat(parts, "  "))
                end
            end
            end
        end
        if skipped > 0 then line("  (%d other meters not shown)", skipped) end
    end

    local d = details()
    line("Details loaded: %s   useDetails setting: %s",
        d and "yes" or "|cffff5555no|r", tostring(ns.settings and ns.settings.useDetails))
    if not d then return out end

    line("GetCombatSegments: %s   GetOverallCombat: %s   GetCurrentCombat: %s",
        type(d.GetCombatSegments), type(d.GetOverallCombat), type(d.GetCurrentCombat))

    if type(d.GetCombatSegments) == "function" then
        local ok, segments = pcall(d.GetCombatSegments, d)
        if ok and type(segments) == "table" then
            line("segments: %d", #segments)
            for i, combat in ipairs(segments) do
                if i > 8 then line("  ... %d more", #segments - 8); break end
                local isM, isMO = "?", "?"
                if type(combat) == "table" and type(combat.IsMythicDungeonOverall) == "function" then
                    local _, v = pcall(combat.IsMythicDungeonOverall, combat)
                    isMO = tostring(v and true or false)
                    local _, v2 = pcall(combat.IsMythicDungeon, combat)
                    isM = tostring(v2 and true or false)
                end
                line("  [%d] mythic=%s mythicOverall=%s actors=%d", i, isM, isMO,
                    type(combat) == "table" and type(combat.GetContainer) == "function"
                        and Bridge.ActorCount(combat) or -1)
            end
        else
            line("segments: |cffff5555unreadable|r")
        end
    end

    -- Every candidate with its actor count, so "why that one" is answerable.
    for _, c in ipairs(candidates(d)) do
        line("  candidate: %-12s actors=%d", c.label, Bridge.ActorCount(c.combat))
    end

    local combat, source, why = runSegment(d)
    if not combat then
        line("|cffff5555chosen segment: none|r -- %s", tostring(why))
        return out
    end
    line("chosen segment: |cff5fd68f%s|r", source)

    local total, inGroup = 0, 0
    local ok, container = pcall(combat.GetContainer, combat, ATTR_DAMAGE)
    if not ok or type(container) ~= "table" then
        line("|cffff5555damage container: unreadable|r")
    else
        for _, actor in ipairs(container._ActorTable or container) do
            total = total + 1
            if type(actor) == "table" then
                if actor.grupo then inGroup = inGroup + 1 end
                if total <= 10 then
                    line("  actor: serial=%s nome=%s total=%s grupo=%s",
                        describe(actor.serial), describe(actor.nome),
                        describe(actor.total), tostring(actor.grupo and true or false))
                end
            end
        end
        line("damage container: %d actors, %d with grupo set", total, inGroup)
    end

    local server, serverWhy = Bridge.ServerTotals()
    if not server then
        line("|cffff5555server totals: %s|r", tostring(serverWhy))
    else
        local n = 0
        for id, r in pairs(server) do
            if id ~= "byName" and type(r) == "table" and r.damage then
                n = n + 1
                if n <= 6 then
                    line("  server: %-22s dmg %d  heal %d  kicks %d  disp %d  deaths %d",
                        tostring(r.name or id), r.damage, r.healing,
                        r.interrupts, r.dispels, r.deaths)
                end
            end
        end
        line("server totals: %d players", n)
        local missing = {}
        for field in pairs(Bridge.missingMeters or {}) do missing[#missing + 1] = field end
        if #missing > 0 then
            table.sort(missing)
            line("|cffd9a441no meter found for: %s|r", table.concat(missing, ", "))
        end
    end

    -- The harvest itself, end to end. This is the part that matters: it exercises
    -- exactly the path Enrich uses, so it can be run against a training dummy in
    -- seconds instead of waiting on a 30-minute key.
    local totals, why = Bridge.GetSegmentTotals()
    if not totals then
        line("|cffff5555harvest failed: %s|r", tostring(why))
    else
        line("harvest: %d actors with a usable key", #totals.list)
        for i, rec in ipairs(totals.list) do
            if i > 8 then line("  ... %d more", #totals.list - 8); break end
            line("  %s [%s]  dmg %s  heal %s  kicks %d  disp %d  deaths %d",
                tostring(rec.name), tostring(rec.serial),
                rec.damage, rec.healing, rec.interrupts, rec.dispels, rec.deaths)
        end

        -- Would the people you are grouped with right now match? That is the
        -- whole question, and it needs no run record to answer.
        local matched, group = 0, 0
        for _, unit in ipairs({ "player", "party1", "party2", "party3", "party4" }) do
            if UnitExists(unit) then
                group = group + 1
                local guid = ns.SafeGUID(UnitGUID(unit))
                local name, realm = UnitName(unit)
                local full = ns.FullName(name, realm)
                local hit = (guid and totals.bySerial[guid])
                    or totals.byName[full or ""] or totals.byName[name or ""]
                line("  group %s: %s -> %s", unit, tostring(full),
                    hit and "|cff5fd68fmatched|r" or "|cffff5555no match|r")
                if hit then matched = matched + 1 end
            end
        end
        line("current group: %d of %d matched", matched, group)
    end

    run = run or ns.db.runs[#ns.db.runs]
    if run and run.observations then
        line("run %s +%s observations:", tostring(run.dungeon), tostring(run.keyLevel))
        for guid, obs in pairs(run.observations) do
            line("  %s  guid=%s", describe(obs.name), describe(guid))
        end
    else
        line("no run to compare against")
    end

    return out
end
