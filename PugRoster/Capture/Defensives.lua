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
    local fight = ns.FightTracker and ns.FightTracker.Current and ns.FightTracker.Current()
    if fight and fight.observations and fight.observations[guid] then
        return fight.observations[guid]
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

-- The event's own payload is the cheap path and the accurate one. `addedAuras`
-- is exactly the set that just landed, so there is nothing to diff and no risk of
-- counting an aura twice because something else about the unit changed.
--
-- A full update carries no addedAuras and means "re-read everything", which
-- happens on zoning and on joining. Those are not new applications, so nothing is
-- counted for them -- otherwise walking into a dungeon would credit everybody
-- with whatever they happened to be wearing.
local function onAura(unit, updateInfo)
    if not unitIsGroup(unit) then return end
    if type(updateInfo) ~= "table" then return end

    -- `isFullUpdate` is deliberately never read.
    --
    -- It comes back a *secret boolean*, and a secret cannot be tested for truth
    -- any more than it can be compared -- `if updateInfo.isFullUpdate then`
    -- raises "attempt to perform boolean test on a secret boolean value". Same
    -- trap as comparing a secret string to "": the danger is touching the value
    -- at all, not the particular operator.
    --
    -- No matter: a full update carries no addedAuras, so the absence of that
    -- list is the same signal, arrived at without asking a forbidden question.
    local added = updateInfo.addedAuras
    if ns.IsSecret(added) or type(added) ~= "table" then return end

    for _, aura in ipairs(added) do
        if type(aura) == "table" then
            local id = aura.spellId
            if id ~= nil and not ns.IsSecret(id) then credit(unit, id) end
        end
    end
end

ns.OnInit(function()
    ns.RegisterEvent("UNIT_AURA", function(unit, updateInfo)
        -- Only while something is being recorded. Outside a run this fires
        -- constantly for no purpose, and the guard is one table lookup.
        local run = ns.RunTracker and ns.RunTracker.Active()
        local fight = ns.FightTracker and ns.FightTracker.Current and ns.FightTracker.Current()
        if not run and not fight then return end
        onAura(unit, updateInfo)
    end)
end)
