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
    [48792]  = true,  -- Icebound Fortitude
    [48707]  = true,  -- Anti-Magic Shell
    [55233]  = true,  -- Vampiric Blood
    [49028]  = true,  -- Dancing Rune Weapon
    [51052]  = true,  -- Anti-Magic Zone
    -- Demon Hunter
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
    [363916] = true,  -- Obsidian Scales
    [374348] = true,  -- Renewing Blaze
    [374227] = true,  -- Zephyr
    -- Hunter
    [186265] = true,  -- Aspect of the Turtle
    [264735] = true,  -- Survival of the Fittest
    -- Mage
    [45438]  = true,  -- Ice Block
    [110959] = true,  -- Greater Invisibility
    [110909] = true,  -- Alter Time
    -- Monk
    [115203] = true,  -- Fortifying Brew
    [122278] = true,  -- Dampen Harm
    [122783] = true,  -- Diffuse Magic
    [122470] = true,  -- Touch of Karma
    [116849] = true,  -- Life Cocoon
    [115176] = true,  -- Zen Meditation
    -- Paladin
    [642]    = true,  -- Divine Shield
    [498]    = true,  -- Divine Protection
    [31850]  = true,  -- Ardent Defender
    [86659]  = true,  -- Guardian of Ancient Kings
    [1022]   = true,  -- Blessing of Protection
    [6940]   = true,  -- Blessing of Sacrifice
    [31821]  = true,  -- Aura Mastery
    -- Priest
    [47585]  = true,  -- Dispersion
    [33206]  = true,  -- Pain Suppression
    [47788]  = true,  -- Guardian Spirit
    [19236]  = true,  -- Desperate Prayer
    [62618]  = true,  -- Power Word: Barrier
    -- Rogue
    [31224]  = true,  -- Cloak of Shadows
    [5277]   = true,  -- Evasion
    [185311] = true,  -- Crimson Vial
    -- Shaman
    [108271] = true,  -- Astral Shift
    [98008]  = true,  -- Spirit Link Totem
    [198838] = true,  -- Earthen Wall Totem
    -- Warlock
    [104773] = true,  -- Unending Resolve
    [108416] = true,  -- Dark Pact
    -- Warrior
    [871]    = true,  -- Shield Wall
    [12975]  = true,  -- Last Stand
    [118038] = true,  -- Die by the Sword
    [97462]  = true,  -- Rallying Cry
    [23920]  = true,  -- Spell Reflection
    [184364] = true,  -- Enraged Regeneration
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
    if not obs then return end
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
Defensives.stats = { updates = 0, examined = 0, matched = 0, secretIds = 0 }

-- What is currently up, per unit: [unit][spellID] = true, defensives only.
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
    if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return out end
    for i = 1, 60 do
        local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HELPFUL")
        if not ok or type(aura) ~= "table" then break end
        local id = aura.spellId
        if id ~= nil and ns.IsSecret(id) then
            Defensives.stats.secretIds = Defensives.stats.secretIds + 1
        elseif id ~= nil then
            Defensives.stats.examined = Defensives.stats.examined + 1
            if DEFENSIVE_AURAS[id] then out[id] = true end
        end
    end
    return out
end

local scratch = {}

local function onAura(unit)
    if not unitIsGroup(unit) then return end
    Defensives.stats.updates = Defensives.stats.updates + 1

    local now = currentDefensives(unit, scratch)
    local was = active[unit]
    if not was then was = {}; active[unit] = was end

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

-- A unit token is a slot, not a person: party2 is somebody else after a leave, so
-- their auras must not read as still up. Cleared on roster changes and when a
-- record closes.
function Defensives.Reset()
    wipe(active)
end

ns.OnInit(function()
    -- party2 is a different person after somebody leaves; their defensives are
    -- not still up just because the token is still there.
    ns.RegisterEvent("GROUP_ROSTER_UPDATE", Defensives.Reset)
    ns.RegisterEvent("PLAYER_ENTERING_WORLD", Defensives.Reset)

    ns.RegisterEvent("UNIT_AURA", function(unit, updateInfo)
        -- Only while something is being recorded. Outside a run this fires
        -- constantly for no purpose, and the guard is one table lookup.
        local run = ns.RunTracker and ns.RunTracker.Active()
        local fight = ns.FightTracker and ns.FightTracker.Current and ns.FightTracker.Current()
        if not run and not fight then return end
        onAura(unit)
    end)
end)
