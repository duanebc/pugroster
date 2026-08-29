-- Capture/Defensives.lua -- how often each player used a major defensive.
--
-- Counted from auras, not casts, and that is not a compromise -- it is the only
-- thing this client permits. UNIT_SPELLCAST_SUCCEEDED does fire for party
-- members, but every groupmate spell id comes back secret, and handing that
-- secret id back to C_Spell.GetSpellInfo returns a secret name as well. Both
-- established by Debug/DefProbe: 246 groupmate casts, none readable.
--
-- Auras are a different matter. The same probe read 184 groupmate aura ids with
-- zero secrets, so what *landed* on somebody is legible even when what they cast
-- is not. For a defensive cooldown those are the same event, a moment apart.
--
-- Majors only. Ironfur appeared 102 times in one key beside Barkskin's 3: both
-- are defensives, but rotational mitigation and an emergency button are different
-- behaviours, and one column cannot hold both without making every Guardian druid
-- look ten times more careful than a rogue. Upkeep is deliberately absent from
-- the list below -- no Ironfur, Shield Block, Demon Spikes or Brew stacks.

local ADDON, ns = ...

local Defensives = {}
ns.Defensives = Defensives

-- Curated, and openly incomplete: a defensive that is missing reads as zero, so
-- the list is worth extending when something obvious is absent. Grouped by class
-- so a gap is easy to spot.
local DEFENSIVE_AURAS = {
    -- Death Knight
    [194679] = true,  -- Rune Tap
    [48792]  = true,  -- Icebound Fortitude
    [48707]  = true,  -- Anti-Magic Shell
    [55233]  = true,  -- Vampiric Blood
    [49028]  = true,  -- Dancing Rune Weapon
    [51052]  = true,  -- Anti-Magic Zone
    -- Demon Hunter
    [209258] = true,  -- Last Resort
    [198589] = true,  -- Blur
    [196718] = true,  -- Darkness
    [196555] = true,  -- Netherwalk
    [204021] = true,  -- Fiery Brand
    -- Druid
    [22812]  = true,  -- Barkskin
    [61336]  = true,  -- Survival Instincts
    [102342] = true,  -- Ironbark
    [102558] = true,  -- Incarnation: Guardian of Ursoc
    [22842]  = true,  -- Frenzied Regeneration
    -- Evoker
    [357170] = true,  -- Time Dilation
    [363916] = true,  -- Obsidian Scales
    [374348] = true,  -- Renewing Blaze
    [374227] = true,  -- Zephyr
    -- Hunter
    [53480]  = true,  -- Roar of Sacrifice
    [186265] = true,  -- Aspect of the Turtle
    [264735] = true,  -- Survival of the Fittest
    -- Mage
    [11426]  = true,  -- Ice Barrier
    [235450] = true,  -- Prismatic Barrier
    [235313] = true,  -- Blazing Barrier
    [414658] = true,  -- Ice Cold
    [45438]  = true,  -- Ice Block
    [110959] = true,  -- Greater Invisibility
    [110909] = true,  -- Alter Time
    -- Monk
    [322507] = true,  -- Celestial Brew
    [115203] = true,  -- Fortifying Brew
    [122278] = true,  -- Dampen Harm
    [122783] = true,  -- Diffuse Magic
    [122470] = true,  -- Touch of Karma
    [116849] = true,  -- Life Cocoon
    [115176] = true,  -- Zen Meditation
    -- Paladin
    [184662] = true,  -- Shield of Vengeance
    [204018] = true,  -- Blessing of Spellwarding
    [642]    = true,  -- Divine Shield
    [498]    = true,  -- Divine Protection
    [31850]  = true,  -- Ardent Defender
    [86659]  = true,  -- Guardian of Ancient Kings
    [1022]   = true,  -- Blessing of Protection
    [6940]   = true,  -- Blessing of Sacrifice
    [31821]  = true,  -- Aura Mastery
    -- Priest
    [271466] = true,  -- Luminous Barrier
    [586]    = true,  -- Fade
    [47585]  = true,  -- Dispersion
    [33206]  = true,  -- Pain Suppression
    [47788]  = true,  -- Guardian Spirit
    [19236]  = true,  -- Desperate Prayer
    [62618]  = true,  -- Power Word: Barrier
    -- Rogue
    [1966]   = true,  -- Feint
    [45182]  = true,  -- Cheating Death
    [31224]  = true,  -- Cloak of Shadows
    [5277]   = true,  -- Evasion
    [185311] = true,  -- Crimson Vial
    -- Shaman
    [409293] = true,  -- Burrow
    [8178]   = true,  -- Grounding Totem
    [108271] = true,  -- Astral Shift
    [98008]  = true,  -- Spirit Link Totem
    [198838] = true,  -- Earthen Wall Totem
    -- Warlock
    [212295] = true,  -- Nether Ward
    [6789]   = true,  -- Mortal Coil
    [104773] = true,  -- Unending Resolve
    [108416] = true,  -- Dark Pact
    -- Warrior
    [871]    = true,  -- Shield Wall
    [12975]  = true,  -- Last Stand
    [118038] = true,  -- Die by the Sword
    [97462]  = true,  -- Rallying Cry
    [23920]  = true,  -- Spell Reflection
    [184364] = true,  -- Enraged Regeneration
    -- Racials, which are defensives that no class block owns.
    [20594]  = true,  -- Stoneform
    [59544]  = true,  -- Gift of the Naaru
    [265221] = true,  -- Fireblood
}

Defensives.SPELLS = DEFENSIVE_AURAS

--------------------------------------------------------------------------------
-- Counting
--------------------------------------------------------------------------------

-- Which record a count belongs to. A key while one is running, otherwise
-- whichever fight FightTracker has open -- the same split every other capture
-- module uses, so a defensive lands on the record its run does.
local function activeObservation(guid)
    local run = ns.RunTracker and ns.RunTracker.Active()
    if run and run.observations and run.observations[guid] then
        return run.observations[guid]
    end
    -- A fight's observations are only created when a pull ends, so during the
    -- first pull of a visit there is nothing to write to yet. Create it rather
    -- than dropping the count -- otherwise every defensive used before the first
    -- boss died was silently discarded, which is most of them in a short dungeon.
    if ns.FightTracker and ns.FightTracker.EnsureObservation
        and ns.FightTracker.Current and ns.FightTracker.Current() then
        return ns.FightTracker.EnsureObservation(guid)
    end
    return nil
end

local function credit(unit, spellID)
    if ns.IsSecret(spellID) then return end
    if not DEFENSIVE_AURAS[spellID] then return end

    local guid = ns.SafeGUID(UnitGUID(unit))
    if not guid then return end

    local obs = activeObservation(guid)
    if not obs then
        -- The one drop that leaves no trace anywhere: the aura was recognised
        -- but the record it belongs to has no row for this GUID. Counted, or a
        -- GUID that never matches looks exactly like a spell list that never
        -- matches.
        Defensives.stats.noObs = Defensives.stats.noObs + 1
        return
    end
    obs.defensives = (obs.defensives or 0) + 1
end

local function unitIsGroup(unit)
    if type(unit) ~= "string" then return false end
    return unit == "player" or unit:match("^party[1-4]$") ~= nil
end

-- Plain counters, so a column of zeroes can be explained rather than guessed at:
-- they separate "the capture never ran" from "it ran and nothing matched", which
-- look identical from the outside and want opposite fixes. Not persisted; they
-- answer a question about the session you are in. `/pugdebug defstats`.
-- Every point the count can be dropped gets its own counter, because a column of
-- zeroes has six possible causes and they want six different fixes. `raw` is
-- incremented before any guard, so "the event never fired" is finally
-- distinguishable from "it fired and was filtered".
--
-- Cumulative across reloads: seeded from the stored record at init and written
-- back by Persist. A run's evidence used to be destroyed by the reload done to
-- go and read it -- the counters started at zero on load and the next
-- PLAYER_ENTERING_WORLD wrote those zeros over the record.
Defensives.stats = {
    raw = 0,          -- UNIT_AURA reached the handler
    noRecord = 0,     -- ...but no run or fight was open
    notGroup = 0,     -- ...but the unit was not the player or a partymate
    updates = 0,      -- passed both guards
    examined = 0,     -- readable aura ids scanned
    secretIds = 0,    -- aura ids withheld by the client
    matched = 0,      -- transitions into a known defensive
    noObs = 0,        -- matched, but no observation to credit it to
    nilIds = 0,       -- aura tables that carried no spellId at all
    sessions = 0,
    scanStop = nil,   -- why the first aura scan stopped, verbatim
}

-- Auras seen on a groupmate that the list does not know, counted by id.
--
-- Three rounds of this feature were spent guessing which spells were missing.
-- The client knows, so it may as well say: run a dungeon, read the list, add
-- what belongs. Only groupmates, because your own buffs are not the gap.
--
-- Kept on the database rather than in a local, so it survives to disk on the
-- next reload and can be read straight out of SavedVariables. A chat window
-- holds about a screen of this; a dungeon produces several.
--
-- Recorded only in a development build. Debug/ is stripped from releases, so
-- ns.Debug is nil there and nobody else's database collects any of it.
-- Hard cap. Housekeeping measures the whole database against a 5MB budget and
-- trims *runs* when it is over, so debug data left to grow would quietly cost
-- history -- which is the one thing it must never do. A hundred and fifty
-- distinct auras is far more than a dungeon produces and about 10KB; past that,
-- counts on what is already known keep rising and nothing new is added.
local MAX_UNKNOWN = 150

local function unknownStore()
    if not ns.db then return nil end
    ns.db.debugDefUnknown = ns.db.debugDefUnknown or {}
    return ns.db.debugDefUnknown
end

function Defensives.Unknown() return (ns.db and ns.db.debugDefUnknown) or {} end

-- Throw it away. It is a note to whoever is reading the log, not a record.
function Defensives.ClearDebug()
    if not ns.db then return end
    ns.db.debugDefUnknown = nil
    ns.db.debugDefStats = nil
end

local function noteUnknown(id)
    local store = unknownStore()
    if not store then return end
    local key = tostring(id)
    local u = store[key]
    if u then u.count = u.count + 1; return end

    local n = 0
    for _ in pairs(store) do n = n + 1 end
    if n >= MAX_UNKNOWN then return end

    local name
    if C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, id)
        if ok and type(info) == "table" then name = info.name end
    end
    store[key] = { id = id, name = name, count = 1 }
end

-- What is currently up, keyed by GUID: [guid][spellID] = true, defensives only.
--
-- By GUID rather than by unit token, because a token is a slot and a slot changes
-- hands. Keying by "party2" meant wiping the whole table whenever the roster
-- changed -- and GROUP_ROSTER_UPDATE fires often in a dungeon, each time making
-- every defensive still ticking look newly applied. That inflates counts rather
-- than losing them, which is the more insidious direction: nobody notices a
-- number that is too high.
--
-- A GUID is the person. If party2 becomes somebody else, their auras simply have
-- nothing to compare against and start clean, with no wiping required.
local active = {}

-- Read the defensives on a unit right now.
--
-- Scanned rather than taken from the event's addedAuras, which looked like the
-- exact and cheap path and is neither: measured over one dungeon, 24 of 3867
-- aura updates carried an addedAuras list at all. The client sends a groupmate's
-- aura changes as full updates almost every time, so a capture built on that
-- field sees under one per cent of what happens.
--
-- `isFullUpdate` is still never read: it comes back a secret boolean, and a
-- secret cannot be tested for truth any more than it can be compared. Diffing
-- makes the question moot -- a full update and an incremental one produce the
-- same answer, because the answer comes from the unit rather than the payload.
local function currentDefensives(unit, out)
    wipe(out)
    if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then
        Defensives.stats.scanStop = Defensives.stats.scanStop
            or "C_UnitAuras.GetAuraDataByIndex is not available"
        return out
    end
    for i = 1, 60 do
        local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HELPFUL")
        -- Why the scan stopped, recorded once. The pcall exists so a restricted
        -- read cannot kill the handler, but it also swallowed the reason -- and
        -- "read nothing" and "read nothing because the call errors" look
        -- identical from the counters. First failure only: this runs twenty
        -- thousand times a session and the first answer is the answer.
        if not ok or type(aura) ~= "table" then
            local st = Defensives.stats
            if not st.scanStop then
                st.scanStop = ("slot %d: %s"):format(i,
                    (not ok) and ("error: " .. tostring(aura))
                            or ("returned " .. type(aura)))
            end
            break
        end
        local id = aura.spellId
        if id == nil then
            -- A table with no spellId: the read works but the field is gone.
            Defensives.stats.nilIds = (Defensives.stats.nilIds or 0) + 1
        end
        if id ~= nil and ns.IsSecret(id) then
            Defensives.stats.secretIds = Defensives.stats.secretIds + 1
        elseif id ~= nil then
            Defensives.stats.examined = Defensives.stats.examined + 1
            if DEFENSIVE_AURAS[id] then
                out[id] = true
            elseif unit ~= "player" and ns.Debug then
                -- Development builds only; see the note above.
                --
                -- pcall'd so bookkeeping can never kill the scan. This runs
                -- inside a pcall'd event handler, so anything raised here
                -- abandons the remaining aura slots for that unit -- and the
                -- first slot on a groupmate is always an unrecognised raid buff,
                -- so one raise would cost every defensive on all four of them.
                pcall(noteUnknown, id)
            end
        end
    end
    return out
end

-- What the aura API returns for a unit, right now, in words. The counters say
-- the scan reads nothing; this says what "nothing" is, without waiting for
-- another dungeon to fill a counter in.
function Defensives.Probe(unit)
    unit = unit or "player"
    local out = {}
    if not C_UnitAuras then return { "C_UnitAuras does not exist" } end
    if not C_UnitAuras.GetAuraDataByIndex then
        return { "C_UnitAuras exists but GetAuraDataByIndex does not" }
    end
    if not UnitExists(unit) then return { unit .. " does not exist" } end
    for i = 1, 5 do
        local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HELPFUL")
        if not ok then
            out[#out + 1] = ("slot %d: call failed -- %s"):format(i, tostring(aura))
            break
        elseif type(aura) ~= "table" then
            out[#out + 1] = ("slot %d: returned %s (scan stops here)")
                :format(i, type(aura))
            break
        else
            local id = aura.spellId
            local shown
            if id == nil then shown = "spellId is nil"
            elseif ns.IsSecret(id) then shown = "spellId is secret"
            else shown = ("spellId %s%s"):format(tostring(id),
                DEFENSIVE_AURAS[id] and " (a tracked defensive)" or "")
            end
            out[#out + 1] = ("slot %d: %s"):format(i, shown)
        end
    end
    if #out == 0 then out[1] = "no slots returned anything" end
    return out
end

local scratch = {}

local function onAura(unit)
    if not unitIsGroup(unit) then
        Defensives.stats.notGroup = Defensives.stats.notGroup + 1
        return
    end
    Defensives.stats.updates = Defensives.stats.updates + 1

    local guid = ns.SafeGUID(UnitGUID(unit))
    if not guid then return end

    local now = currentDefensives(unit, scratch)
    local was = active[guid]
    if not was then was = {}; active[guid] = was end

    -- Count the transitions into "up". Re-reading the same aura on the next
    -- update is not a second use of it, and that is the whole reason the previous
    -- set is kept.
    for id in pairs(now) do
        if not was[id] then
            Defensives.stats.matched = Defensives.stats.matched + 1
            credit(unit, id)
        end
    end

    wipe(was)
    for id in pairs(now) do was[id] = true end
end

-- Only between visits. Keyed by GUID, the table needs no clearing when the roster
-- changes -- and clearing it then was what let a still-ticking defensive be
-- counted a second time.
function Defensives.Reset()
    wipe(active)
end

-- Mirror the counters onto the database so they survive a reload as well.
-- Counters are not a debug-build luxury: they are the only evidence of why a
-- column of zeroes is zero, and they must be written even where Debug/ is
-- stripped. Only the unknown-aura list stays development-only.
function Defensives.Persist()
    if not ns.db then return end
    local st = Defensives.stats
    ns.db.debugDefStats = {
        raw = st.raw, noRecord = st.noRecord, notGroup = st.notGroup,
        updates = st.updates, examined = st.examined,
        secretIds = st.secretIds, matched = st.matched, noObs = st.noObs,
        nilIds = st.nilIds, scanStop = st.scanStop,
        sessions = st.sessions,
        at = ns.Now(),
    }
end

ns.OnInit(function()
    -- A fresh login drops whatever the last session collected, the same rule the
    -- simulated data follows. It exists to be read once and then acted on; a
    -- reload keeps it, because that is how it gets to disk to be read at all.
    -- IsLoggedIn() is false during the first login's ADDON_LOADED and true on a
    -- reload, which is exactly the distinction wanted.
    if not IsLoggedIn() then Defensives.ClearDebug() end

    -- Carry the stored counters forward, so what a dungeon proved is still there
    -- after the reload done to go and read it. Persist then only ever writes a
    -- superset of what is already on disk.
    local stored = ns.db and ns.db.debugDefStats
    if stored then
        for _, k in ipairs({ "raw", "noRecord", "notGroup", "updates", "examined",
                             "secretIds", "matched", "noObs", "nilIds", "sessions" }) do
            Defensives.stats[k] = tonumber(stored[k]) or 0
        end
    end
    Defensives.stats.sessions = Defensives.stats.sessions + 1

    ns.RegisterEvent("PLAYER_ENTERING_WORLD", function()
        Defensives.Persist()
        Defensives.Reset()
    end)

    ns.RegisterEvent("UNIT_AURA", function(unit, updateInfo)
        -- Only while something is being recorded. Outside a run this fires
        -- constantly for no purpose, and the guard is one table lookup.
        Defensives.stats.raw = Defensives.stats.raw + 1
        local run = ns.RunTracker and ns.RunTracker.Active()
        local fight = ns.FightTracker and ns.FightTracker.Current and ns.FightTracker.Current()
        if not run and not fight then
            Defensives.stats.noRecord = Defensives.stats.noRecord + 1
            return
        end
        onAura(unit)
    end)
end)
