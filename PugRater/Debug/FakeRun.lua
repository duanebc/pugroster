-- Debug/FakeRun.lua -- synthetic but plausible run data.
--
-- Generates groups, per-player stats and chat that look enough like the real
-- thing to exercise the rating model, the roster and every panel. Nothing here
-- writes to the database; it only produces payloads for EventSim to feed
-- through the real handlers.

local ADDON, ns = ...

local FakeRun = {}
ns.FakeRun = FakeRun

--------------------------------------------------------------------------------
-- Pools
--------------------------------------------------------------------------------

local NAMES = {
    "Brakkus", "Sylvenne", "Torgald", "Mirelle", "Duskvane", "Kaelith", "Rothmar",
    "Ysolde", "Grimwick", "Nyxara", "Bahlvor", "Ellisande", "Krugor", "Thessaly",
    "Vandren", "Ophira", "Muldrek", "Saevithra", "Halgrim", "Zennara", "Corvain",
    "Pelloria", "Draggo", "Isilme", "Boraxen", "Winnowfell", "Skarn", "Tallowyn",
    "Vexmoor", "Ravenne", "Hodrick", "Elunara", "Fenwick", "Marisol", "Ozrik",
    "Quillon", "Brambleaf", "Nightra", "Storgan", "Velicia",
}

local REALMS = { "Area52", "Illidan", "Tichondrius", "Stormrage", "Frostmourne", "Draenor", "Silvermoon" }

local SPECS = {
    { class = "Warrior",      file = "WARRIOR",     spec = "Protection",   role = "TANK" },
    { class = "Paladin",      file = "PALADIN",     spec = "Protection",   role = "TANK" },
    { class = "Death Knight", file = "DEATHKNIGHT", spec = "Blood",        role = "TANK" },
    { class = "Druid",        file = "DRUID",       spec = "Guardian",     role = "TANK" },
    { class = "Monk",         file = "MONK",        spec = "Brewmaster",   role = "TANK" },
    { class = "Demon Hunter", file = "DEMONHUNTER", spec = "Vengeance",    role = "TANK" },

    { class = "Paladin",      file = "PALADIN",     spec = "Holy",         role = "HEALER" },
    { class = "Druid",        file = "DRUID",       spec = "Restoration",  role = "HEALER" },
    { class = "Priest",       file = "PRIEST",      spec = "Discipline",   role = "HEALER" },
    { class = "Priest",       file = "PRIEST",      spec = "Holy",         role = "HEALER" },
    { class = "Shaman",       file = "SHAMAN",      spec = "Restoration",  role = "HEALER" },
    { class = "Monk",         file = "MONK",        spec = "Mistweaver",   role = "HEALER" },
    { class = "Evoker",       file = "EVOKER",      spec = "Preservation", role = "HEALER" },

    { class = "Mage",         file = "MAGE",        spec = "Frost",        role = "DAMAGER" },
    { class = "Mage",         file = "MAGE",        spec = "Fire",         role = "DAMAGER" },
    { class = "Rogue",        file = "ROGUE",       spec = "Assassination", role = "DAMAGER" },
    { class = "Rogue",        file = "ROGUE",       spec = "Subtlety",     role = "DAMAGER" },
    { class = "Hunter",       file = "HUNTER",      spec = "Beast Mastery", role = "DAMAGER" },
    { class = "Hunter",       file = "HUNTER",      spec = "Marksmanship", role = "DAMAGER" },
    { class = "Warlock",      file = "WARLOCK",     spec = "Destruction",  role = "DAMAGER" },
    { class = "Warlock",      file = "WARLOCK",     spec = "Affliction",   role = "DAMAGER" },
    { class = "Shaman",       file = "SHAMAN",      spec = "Elemental",    role = "DAMAGER" },
    { class = "Druid",        file = "DRUID",       spec = "Balance",      role = "DAMAGER" },
    { class = "Warrior",      file = "WARRIOR",     spec = "Arms",         role = "DAMAGER" },
    { class = "Demon Hunter", file = "DEMONHUNTER", spec = "Havoc",        role = "DAMAGER" },
    { class = "Evoker",       file = "EVOKER",      spec = "Devastation",  role = "DAMAGER" },
    { class = "Death Knight", file = "DEATHKNIGHT", spec = "Unholy",       role = "DAMAGER" },
    { class = "Monk",         file = "MONK",        spec = "Windwalker",   role = "DAMAGER" },
}

local FALLBACK_DUNGEONS = {
    { id = 9001, name = "The Voidspire",       par = 32 * 60 },
    { id = 9002, name = "Sporefall Hollow",    par = 33 * 60 },
    { id = 9003, name = "The Dreamrift",       par = 30 * 60 },
    { id = 9004, name = "March on Quel'Danas", par = 35 * 60 },
    { id = 9005, name = "The Venomous Abyss",  par = 31 * 60 },
    { id = 9006, name = "Umbral Reliquary",    par = 34 * 60 },
    { id = 9007, name = "Sunwell Approach",    par = 36 * 60 },
    { id = 9008, name = "Hollowmoor Depths",   par = 30 * 60 },
}

local CHATTER = {
    open   = { "hi", "hey all", "sup", "invite for {name}?", "ready when you are", "one sec, food" },
    pull   = { "pulling", "big pull incoming", "lust here?", "kick rotation on the casters", "cc the adds pls" },
    death  = { "oof", "my bad", "sorry, missed the dodge", "brez?", "np keep going", "that hurt" },
    timer  = { "we good on timer?", "3 min ahead", "tight but doable", "need to skip this pack" },
    good   = { "gg", "nice one", "clean run", "ty all", "great kicks" },
    bad    = { "this is rough", "im gonna have to go after this", "sorry guys, key is dead", "one more wipe and im out" },
    leave  = { "sorry, gotta run", "irl, sorry", "gg im out" },
}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function pick(list)
    return list[math.random(#list)]
end

local function shuffled(list)
    local out = {}
    for i, v in ipairs(list) do out[i] = v end
    for i = #out, 2, -1 do
        local j = math.random(i)
        out[i], out[j] = out[j], out[i]
    end
    return out
end

-- Stable-ish GUIDs so repeated seeding produces repeat groupmates -- which is
-- the whole point: a rating model needs the same people to show up again.
local guidCounter = 0
function FakeRun.GUID(seed)
    if seed then return string.format("Player-DEBUG-%08X", seed) end
    guidCounter = guidCounter + 1
    return string.format("Player-DEBUG-%08X", guidCounter)
end

function FakeRun.Dungeons()
    if C_ChallengeMode and C_ChallengeMode.GetMapTable then
        local ok, maps = pcall(C_ChallengeMode.GetMapTable)
        if ok and type(maps) == "table" and #maps > 0 then
            local out = {}
            for _, mapID in ipairs(maps) do
                local name, _, timeLimit = C_ChallengeMode.GetMapUIInfo(mapID)
                if name then
                    out[#out + 1] = { id = mapID, name = name, par = timeLimit or 32 * 60 }
                end
            end
            if #out > 0 then return out end
        end
    end
    return FALLBACK_DUNGEONS
end

function FakeRun.FindDungeon(nameFragment)
    local dungeons = FakeRun.Dungeons()
    if not nameFragment then return pick(dungeons) end
    local frag = nameFragment:lower()
    for _, d in ipairs(dungeons) do
        if d.name:lower():find(frag, 1, true) then return d end
    end
    return pick(dungeons)
end

--------------------------------------------------------------------------------
-- People
--------------------------------------------------------------------------------

-- A pool of recurring characters, created once per session and reused, so
-- seeded history builds up per-person run counts instead of 200 strangers.
local pool

function FakeRun.Pool(size)
    if pool and #pool >= (size or 0) then return pool end
    pool = {}
    local names = shuffled(NAMES)
    for i = 1, math.min(size or 24, #names) do
        local spec = SPECS[((i - 1) % #SPECS) + 1]
        pool[i] = {
            guid      = FakeRun.GUID(1000 + i),
            name      = names[i] .. "-" .. REALMS[((i - 1) % #REALMS) + 1],
            class     = spec.class,
            classFile = spec.file,
            spec      = 1000 + i,
            specName  = spec.spec,
            role      = spec.role,
            ilvl      = 630 + math.random(0, 30),
            -- A hidden skill value drives the generated stats, so "good"
            -- players really do read as good once the model runs.
            skill     = math.random(),
        }
    end
    return pool
end

function FakeRun.ResetPool()
    pool = nil
end

-- Group of five: the real player plus four from the pool, one tank, one healer.
function FakeRun.MakeGroup()
    local p = FakeRun.Pool(24)
    local tanks, healers, dps = {}, {}, {}
    for _, c in ipairs(p) do
        if c.role == "TANK" then tanks[#tanks + 1] = c
        elseif c.role == "HEALER" then healers[#healers + 1] = c
        else dps[#dps + 1] = c end
    end

    local chosen = { pick(tanks), pick(healers) }
    local shuffledDps = shuffled(dps)
    for i = 1, 3 do chosen[#chosen + 1] = shuffledDps[i] end

    local group = {}
    local myGuid = UnitGUID("player") or FakeRun.GUID(1)
    local myName, myRealm = UnitName("player")
    local myClass, myClassFile = UnitClass("player")

    group[myGuid] = {
        name      = ns.FullName(myName or "You", myRealm),
        class     = myClass or "Rogue",
        classFile = myClassFile or "ROGUE",
        role      = UnitGroupRolesAssigned and UnitGroupRolesAssigned("player") or "DAMAGER",
        isPlayer  = true,
        skill     = 0.7,
    }
    if not group[myGuid].role or group[myGuid].role == "NONE" then
        group[myGuid].role = "DAMAGER"
    end

    -- Four generated members alongside the player. `chosen` is ordered
    -- tank, healer, dps, dps, dps, so taking the first four keeps the role
    -- spread sane whatever the player happens to be playing.
    local slots = 4
    for _, c in ipairs(chosen) do
        if slots == 0 then break end
        if c and not group[c.guid] then
            group[c.guid] = {
                name = c.name, class = c.class, classFile = c.classFile,
                role = c.role, spec = c.spec, specName = c.specName,
                ilvl = c.ilvl, skill = c.skill,
            }
            slots = slots - 1
        end
    end

    return group
end

--------------------------------------------------------------------------------
-- Run shape
--------------------------------------------------------------------------------

-- flags: fail, disband, leave, wipes, timed, level, dungeon
function FakeRun.MakeRun(flags)
    flags = flags or {}
    local dungeon = FakeRun.FindDungeon(flags.dungeon)
    local level = flags.level or math.random(4, 16)
    local group = flags.group or FakeRun.MakeGroup()

    local run = {
        mapID    = dungeon.id,
        dungeon  = dungeon.name,
        keyLevel = level,
        par      = dungeon.par,
        affixes  = { 9, 10, 152 },
        seasonID = flags.seasonID or ns.Rating.CurrentSeason(),
        group    = group,
        debug    = true,
    }

    -- Outcome. Harder keys fail more often; flags force the interesting cases.
    local difficulty = ns.Clamp((level - 2) / 18, 0, 1)
    local roll = math.random()

    if flags.fail then
        run.completed, run.timed, run.abandoned = false, false, true
    elseif flags.disband then
        run.completed, run.timed, run.abandoned, run.disband = false, false, true, true
    elseif roll < 0.10 + difficulty * 0.20 then
        run.completed, run.timed, run.abandoned = false, false, true
        run.disband = math.random() < 0.4
    elseif roll < 0.35 + difficulty * 0.25 then
        run.completed, run.timed = true, false
    else
        run.completed, run.timed = true, true
        run.upgrade = (math.random() < 0.15 and 3) or (math.random() < 0.35 and 2) or 1
    end

    if run.completed and run.timed then
        run.elapsed = dungeon.par * (0.70 + math.random() * 0.28)
    elseif run.completed then
        run.elapsed = dungeon.par * (1.02 + math.random() * 0.25)
    else
        run.elapsed = dungeon.par * (0.2 + math.random() * 0.5)
    end

    run.wipes = flags.wipes or (run.completed and (run.timed and math.random(0, 1) or math.random(1, 3))
                                or math.random(2, 5))

    -- Per-player stats, driven by hidden skill and the run outcome.
    run.stats = {}
    for guid, info in pairs(group) do
        local skill = info.skill or 0.5
        local pressure = (run.timed and 0.6 or 1.0) + difficulty
        local deaths = math.max(0, math.floor((1.8 - skill * 1.6) * pressure * (0.5 + math.random())))
        local kicks = math.floor(skill * 12 * (0.5 + math.random()))
        local dispels = info.role == "HEALER" and math.floor(skill * 8 * math.random()) or math.floor(skill * 2 * math.random())

        local damage, healing = 0, 0
        if info.role == "DAMAGER" then
            damage = math.floor((40e6 + skill * 60e6) * (0.8 + math.random() * 0.4) * (level / 10))
            healing = math.floor(damage * 0.03)
        elseif info.role == "HEALER" then
            healing = math.floor((50e6 + skill * 50e6) * (0.8 + math.random() * 0.4) * (level / 10))
            damage = math.floor(healing * 0.15)
        else
            damage = math.floor((25e6 + skill * 25e6) * (0.8 + math.random() * 0.4) * (level / 10))
        end

        run.stats[guid] = {
            deaths = deaths, interrupts = kicks, dispels = dispels,
            ccCasts = math.floor(skill * 5 * math.random()),
            damage = damage, healing = healing,
        }
    end

    -- Someone leaving early: forced by flag, otherwise likely on a dead key.
    if flags.leave or (not run.completed and math.random() < 0.5) then
        local candidates = {}
        local me = UnitGUID("player")
        for guid in pairs(group) do
            if guid ~= me then candidates[#candidates + 1] = guid end
        end
        if #candidates > 0 then run.leaver = pick(candidates) end
    end

    return run
end

--------------------------------------------------------------------------------
-- Chat
--------------------------------------------------------------------------------

function FakeRun.MakeChat(run)
    local lines = {}
    local speakers = {}
    for guid, info in pairs(run.group) do speakers[#speakers + 1] = { guid = guid, info = info } end

    local function say(bucket, who)
        who = who or pick(speakers)
        lines[#lines + 1] = {
            guid    = who.guid,
            name    = who.info.name,
            channel = math.random() < 0.12 and "whisper-in" or "party",
            text    = pick(CHATTER[bucket]),
        }
    end

    for _ = 1, math.random(2, 3) do say("open") end
    for _ = 1, math.random(2, 5) do say("pull") end
    for _ = 1, (run.wipes or 0) + 1 do say("death") end
    if math.random() < 0.6 then say("timer") end

    if run.leaver then
        local who
        for _, s in ipairs(speakers) do if s.guid == run.leaver then who = s end end
        say("bad", who)
        say("leave", who)
    elseif run.completed and run.timed then
        for _ = 1, math.random(1, 3) do say("good") end
    else
        for _ = 1, math.random(1, 2) do say("bad") end
    end

    return lines
end
