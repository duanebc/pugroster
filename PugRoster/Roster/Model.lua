-- Roster/Model.lua -- persons, characters, links and tags.
--
-- A *character* is one GUID: what we actually observe in a group. A *person* is
-- the human behind one or more characters. Every character gets a person on
-- first sight; BNet friends auto-link when the friends list exposes the mapping,
-- and anyone else can be linked by hand ("mark as same person").
--
-- Manual tags, notes, tier overrides and the do-not-message flag live on the
-- person. Auto-tags (role, spec, ilvl/RIO bracket, computed tier) are derived
-- from the character and never stored as tags -- they are computed on read so
-- they cannot drift out of date.

local ADDON, ns = ...

local Roster = {}
ns.Roster = Roster

--------------------------------------------------------------------------------
-- Characters
--------------------------------------------------------------------------------

function Roster.GetCharacter(guid)
    guid = ns.SafeGUID(guid)
    return guid and ns.db.characters[guid] or nil
end

-- Fetch or create, without claiming to have seen them. Use this when you need
-- the record itself rather than to record a sighting.
function Roster.EnsureCharacter(guid)
    return Roster.TouchCharacter(guid, {})
end

-- Create-or-update. `info` fields are only written when non-nil, so a partial
-- update (say, an inspect result carrying only spec/ilvl) never blanks out what
-- we already knew.
function Roster.TouchCharacter(guid, info)
    guid = ns.SafeGUID(guid)
    if not guid then return nil end
    info = info or {}

    local db = ns.db
    local char = db.characters[guid]
    if not char then
        char = {
            guid      = guid,
            firstSeen = ns.Now(),
            runs      = 0,
            autoTier  = "Neutral",
            score     = 0,
        }
        db.characters[guid] = char
    end

    for _, key in ipairs({ "name", "class", "classFile", "spec", "specName", "role",
                           -- Faction persists on the character so a record that
                           -- never learned it can still be drawn correctly.
                           "faction",
                           "ilvl", "bnetAccountID", "battleTag", "debug", "isSelf",
                           "fromFriendList" }) do
        if info[key] ~= nil then char[key] = info[key] end
    end
    -- Only a real sighting moves lastSeen. An empty info table means "give me
    -- the record" -- the rating pass does that for every character it scores --
    -- and stamping those as seen-just-now made the whole roster report the time
    -- of the last recompute instead of when you actually played with anyone.
    if info.lastSeen then
        char.lastSeen = info.lastSeen
    elseif next(info) ~= nil and not info.fromFriendList then
        char.lastSeen = ns.Now()
    end

    if not char.personId then
        Roster.AttachToPerson(guid)
    else
        -- The debug key may have just changed on an existing character.
        Roster.RefreshDebugFlag(Roster.GetPerson(char.personId))
    end

    return char
end

function Roster.CountCharacters()
    local n = 0
    for _ in pairs(ns.db.characters) do n = n + 1 end
    return n
end

-- Best-effort name lookup. Accepts "Name" or "Name-Realm"; a bare name matches
-- the most recently seen character with that name.
function Roster.FindCharacterByName(name)
    if not name or name == "" then return nil end
    local lower = name:lower()
    local best
    for guid, char in pairs(ns.db.characters) do
        local full = (char.name or ""):lower()
        if full == lower or ns.ShortName(full) == lower then
            if not best or (char.lastSeen or 0) > (best.lastSeen or 0) then best = char end
        end
    end
    return best
end

--------------------------------------------------------------------------------
-- Persons
--------------------------------------------------------------------------------

function Roster.GetPerson(personId)
    return personId and ns.db.persons[personId] or nil
end

function Roster.PersonForGUID(guid)
    local char = Roster.GetCharacter(guid)
    return char and Roster.GetPerson(char.personId) or nil
end

-- Every character this account has logged in on gets stamped isSelf, so a person
-- carrying any of them is us. The roster is a record of other people; a send
-- list that offers to whisper your own alt is just noise.
function Roster.MarkSelf()
    local guid = ns.SafeGUID(UnitGUID("player"))
    if not guid then return end
    local name, realm = UnitName("player")
    local class, classFile = UnitClass("player")
    Roster.TouchCharacter(guid, {
        name = ns.FullName(name, realm), class = class, classFile = classFile,
        isSelf = true,
    })
end

-- Already on the character friends list? Offline friends are listed too, so this
-- is a membership test, not an online test.
function Roster.IsFriend(fullName)
    if not fullName or not (C_FriendList and C_FriendList.GetNumFriends) then return false end
    local target = fullName:lower()
    for i = 1, C_FriendList.GetNumFriends() do
        local info = C_FriendList.GetFriendInfoByIndex(i)
        local name = info and info.name and ns.FullName(info.name)
        if name and name:lower() == target then return true end
    end
    return false
end

-- Add a character to the friends list by "Name-Realm". Adding a friend is what
-- makes somebody's online status visible, which is otherwise only knowable for
-- Battle.net friends, character friends and guildmates -- so it is worth
-- offering wherever a character is shown, not only in the roster.
--
-- The server answers asynchronously and refuses with "Player not found" for a
-- character who is not currently online, so this checks the friends list a moment
-- later and reports what actually happened rather than claiming success.
function Roster.AddFriendByName(name)
    if ns.IsSecret(name) then return false end
    if not name or name == "" then return false end

    if not (C_FriendList and C_FriendList.AddFriend) then
        ns.Print("this client has no AddFriend API. Use |cffffff00/friend "
            .. name .. "|r")
        return false
    end

    C_FriendList.AddFriend(name)
    C_Timer.After(2, function()
        if Roster.IsFriend(name) then
            ns.Print("added |cff9b7fd6" .. name .. "|r to your friends list.")
        else
            ns.Print(string.format("could not add %s. The server only accepts a "
                .. "friend request while that character is online -- try again "
                .. "when they are.", name))
        end
        if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
    end)
    return true
end

-- The BattleTag we have written down for a person, if any.
--
-- This is the roster's identity. It is stable and account-unique, which
-- bnetAccountID turned out not to be, so it decides both what may be linked and
-- what a repair is allowed to keep.
--
-- It answers for a limited set on purpose: the client exposes a BattleTag for
-- people already on your friends list and for nobody else, so a pug never has
-- one. That is a floor on how much grouping can be justified, not a gap to fill
-- by guessing -- guessing is what produced the damage this replaced.
function Roster.BattleTagFor(person)
    if not person then return nil end
    for guid in pairs(person.characters or {}) do
        local char = Roster.GetCharacter(guid)
        local tag = char and char.battleTag
        if tag and not ns.IsSecret(tag) and tag ~= "" then return tag end
    end
    return nil
end

function Roster.IsSelf(person)
    if not person then return false end
    for guid in pairs(person.characters) do
        local char = Roster.GetCharacter(guid)
        if char and char.isSelf then return true end
    end
    return false
end

local function newPerson(displayName)
    local db = ns.db
    local id = db.nextPersonId
    db.nextPersonId = id + 1
    db.persons[id] = {
        id           = id,
        name         = displayName or ("Person " .. id),
        characters   = {},
        tags         = {},
        note         = "",
        tierOverride = nil,
        created      = ns.Now(),
    }
    return db.persons[id]
end

-- A person is test data only while every character under them is. Linking a
-- real alt onto a seeded main makes the whole person real, which is what
-- `/pugdebug wipe fake` and the companion importer both need to see.
function Roster.RefreshDebugFlag(person)
    if not person then return end
    local any = false
    for guid in pairs(person.characters) do
        local c = Roster.GetCharacter(guid)
        if c then
            any = true
            if not c.debug then person.debug = nil; return end
        end
    end
    person.debug = any or nil
end

-- Attach a character to a person: an existing one when `personId` is given,
-- otherwise a fresh person named after the character.
function Roster.AttachToPerson(guid, personId)
    local char = Roster.GetCharacter(guid)
    if not char then return nil end

    local person = personId and Roster.GetPerson(personId)
    if not person then
        person = newPerson(char.name and ns.ShortName(char.name) or nil)
    end

    local previous
    if char.personId and char.personId ~= person.id then
        previous = Roster.GetPerson(char.personId)
        if previous then previous.characters[guid] = nil end
    end

    char.personId = person.id
    person.characters[guid] = true
    if not person.name or person.name:match("^Person %d+$") then
        person.name = ns.ShortName(char.name or person.name)
    end
    Roster.RefreshDebugFlag(person)
    Roster.RefreshDebugFlag(previous)
    return person
end

-- Merge the person behind `guidB` into the person behind `guidA`. Tags and
-- notes union; a tier override on either side survives (A wins on conflict).
function Roster.LinkCharacters(guidA, guidB, linkedBy)
    local a, b = Roster.GetCharacter(guidA), Roster.GetCharacter(guidB)
    if not a or not b then return false, "unknown character" end
    if a.personId == b.personId then return true end

    -- The one thing that can prove a merge wrong, checked before it happens.
    -- A BattleTag is stable and account-unique, so two of them disagreeing means
    -- these are two people however they came to be here.
    local tagA, tagB = Roster.BattleTagFor(Roster.GetPerson(a.personId)),
                       Roster.BattleTagFor(Roster.GetPerson(b.personId))
    if tagA and tagB and not ns.IsSecret(tagA) and not ns.IsSecret(tagB)
        and tagA ~= tagB then
        return false, "different Battle.net accounts"
    end

    local keep = Roster.GetPerson(a.personId)
    local merge = Roster.GetPerson(b.personId)
    if not keep or not merge then return false, "unknown person" end

    -- How this grouping was arrived at, so a later repair can tell a link you
    -- made from one the addon guessed. There was no such marker, which is the
    -- only reason the previous repair had to throw manual links away.
    -- "manual" is the stronger claim and survives being merged into.
    if linkedBy == "manual" or merge.linkedBy == "manual" then
        keep.linkedBy = "manual"
    else
        keep.linkedBy = keep.linkedBy or linkedBy or merge.linkedBy
    end

    for tag in pairs(merge.tags) do keep.tags[tag] = true end
    if (merge.note or "") ~= "" then
        keep.note = ((keep.note or "") ~= "" and (keep.note .. "\n") or "") .. merge.note
    end
    keep.tierOverride = keep.tierOverride or merge.tierOverride
    keep.lastMessaged = math.max(keep.lastMessaged or 0, merge.lastMessaged or 0)

    for guid in pairs(merge.characters) do
        local c = Roster.GetCharacter(guid)
        if c then
            c.personId = keep.id
            keep.characters[guid] = true
        end
    end

    ns.db.persons[merge.id] = nil
    Roster.RefreshDebugFlag(keep)
    return true
end

-- Split a character back out onto a person of its own.
function Roster.UnlinkCharacter(guid)
    local char = Roster.GetCharacter(guid)
    if not char then return false end
    local old = Roster.GetPerson(char.personId)
    if old then old.characters[guid] = nil end
    char.personId = nil
    Roster.AttachToPerson(guid)
    return true
end

function Roster.AllPersons()
    local list = {}
    for _, person in pairs(ns.db.persons) do
        if next(person.characters) then list[#list + 1] = person end
    end
    table.sort(list, function(x, y) return (x.name or "") < (y.name or "") end)
    return list
end

-- Which character a person should be *known* by, as opposed to which one they
-- are on right now.
--
-- A person was named after whichever character happened to create the record and
-- then never renamed, so a five-alt player ended up filed under the alt he last
-- logged in on. That is the cause behind four separate faults: a roster row
-- bearing a stranger's name, a search for "san" answering "Unbroken", a join
-- toast announcing somebody unrecognisable, and a detail pane that looked like it
-- had linked the wrong people. Each was patched where it showed; this is the
-- thing that was actually wrong.
--
-- The character you have run with most is the one you know them by -- not the
-- newest, which changes every time they swap alts, and not the first, which is an
-- accident of when you met. Ties fall to shared sessions, then to who was seen
-- most recently, then to the name itself so the answer is stable across refreshes
-- rather than depending on `pairs` order.
local function betterKnown(c, best)
    if not best then return true end
    local cr, br = c.runs or 0, best.runs or 0
    if cr ~= br then return cr > br end
    local cg, bg = c.grouped or 0, best.grouped or 0
    if cg ~= bg then return cg > bg end
    local cs, bs = c.lastSeen or 0, best.lastSeen or 0
    if cs ~= bs then return cs > bs end
    return (c.name or "") < (best.name or "")
end

function Roster.BestKnownCharacter(person)
    if not person then return nil end
    local best
    for guid in pairs(person.characters or {}) do
        local c = Roster.GetCharacter(guid)
        if c and c.name and betterKnown(c, best) then best = c end
    end
    return best
end

-- Returns true when the name changed. Safe to call repeatedly.
function Roster.RefreshPersonName(person)
    if not person then return false end
    local c = Roster.BestKnownCharacter(person)
    local short = c and ns.ShortName(c.name)
    if not short or short == "" or short == "?" then return false end
    if person.name == short then return false end
    person.name = short
    return true
end

-- The character we show for a person: most recently seen.
function Roster.MainCharacter(person)
    if not person then return nil end
    local best
    for guid in pairs(person.characters) do
        local c = Roster.GetCharacter(guid)
        if c and (not best or (c.lastSeen or 0) > (best.lastSeen or 0)) then best = c end
    end
    return best
end

function Roster.RunsTogether(person)
    if not person then return 0 end
    local total = 0
    for guid in pairs(person.characters) do
        local c = Roster.GetCharacter(guid)
        if c then total = total + (c.runs or 0) end
    end
    return total
end

-- Sessions together that were not keystone runs -- normal dungeons, delves,
-- raids. Kept separate from RunsTogether on purpose: this number is for showing
-- people, never for rating them.
function Roster.TimesGrouped(person)
    if not person then return 0 end
    local total = 0
    for guid in pairs(person.characters) do
        local c = Roster.GetCharacter(guid)
        if c then total = total + (c.grouped or 0) end
    end
    return total
end

-- The best Raider.IO score anywhere on the account: every linked character,
-- this season and last, whichever is highest.
--
-- The per-character score answers "how good is this character", which is not the
-- question you ask when somebody brings an alt. Their main is what tells you
-- what they can actually do, and last season counts because a player who pushed
-- hard and has not started this one has not forgotten how.
function Roster.BestRIO(person)
    if not person then return 0 end
    local best = 0
    for guid in pairs(person.characters or {}) do
        local current, previous = ns.Lookup.RIO(guid)
        if (current or 0) > best then best = current end
        if (previous or 0) > best then best = previous end
    end
    return best
end

function Roster.LastPlayedWith(person)
    if not person then return nil end
    local latest
    for guid in pairs(person.characters) do
        local c = Roster.GetCharacter(guid)
        if c and c.lastSeen and (not latest or c.lastSeen > latest) then latest = c.lastSeen end
    end
    return latest
end

--------------------------------------------------------------------------------
-- Tier resolution
--
-- Three sources, in priority order: a manual override always wins; then the
-- companion's refined tier when it is enabled and newer than our local pass;
-- then the in-game provisional tier. The UI shows which one it used.
--------------------------------------------------------------------------------

function Roster.EffectiveTier(person)
    if not person then return "Neutral", "auto" end
    if person.tierOverride then return person.tierOverride, "override" end

    local char = Roster.MainCharacter(person)
    if not char then return "Neutral", "auto" end

    if ns.settings.preferRefined then
        local refined = ns.Lookup and ns.Lookup.Get(char.guid)
        if refined and refined.tier then return refined.tier, "refined" end
    end
    return char.autoTier or "Neutral", "auto"
end

function Roster.SetTierOverride(person, tier)
    if not person then return end
    if tier == nil or tier == "auto" then
        person.tierOverride = nil
    else
        person.tierOverride = tier
    end
end

function Roster.SetNote(person, note)
    if person then person.note = note or "" end
end

function Roster.SetNoteByName(name, note)
    local char = Roster.FindCharacterByName(name)
    if not char then return false end
    Roster.SetNote(Roster.GetPerson(char.personId), note)
    return true
end

--------------------------------------------------------------------------------
-- Tags
--------------------------------------------------------------------------------

function Roster.EnsureTag(tag, category)
    if not tag or tag == "" then return false end
    if not ns.db.tags[tag] then
        ns.db.tags[tag] = { category = category or "Custom" }
    end
    return true
end

function Roster.AddTag(person, tag)
    if not person or not tag or tag == "" then return false end
    Roster.EnsureTag(tag)
    person.tags[tag] = true
    return true
end

function Roster.RemoveTag(person, tag)
    if person and tag then person.tags[tag] = nil end
end

function Roster.ToggleTag(person, tag)
    if not person then return end
    if person.tags[tag] then person.tags[tag] = nil else Roster.AddTag(person, tag) end
end

function Roster.HasTag(person, tag)
    return person and person.tags[tag] and true or false
end

function Roster.DeleteTag(tag)
    ns.db.tags[tag] = nil
    for _, person in pairs(ns.db.persons) do person.tags[tag] = nil end
end

function Roster.AllTags()
    return ns.SortedKeys(ns.db.tags)
end

function Roster.TagsByCategory()
    local out, order = {}, {}
    for tag, info in pairs(ns.db.tags) do
        local cat = info.category or "Custom"
        if not out[cat] then out[cat] = {}; order[#order + 1] = cat end
        table.insert(out[cat], tag)
    end
    table.sort(order)
    for _, list in pairs(out) do table.sort(list) end
    return out, order
end

function Roster.IsDoNotMessage(person)
    return Roster.HasTag(person, ns.DO_NOT_MESSAGE_TAG)
end

--------------------------------------------------------------------------------
-- Auto-tags
--
-- Derived, read-only, never persisted. Filters treat them exactly like manual
-- tags so "role:healer AND push" is a single expression.
--------------------------------------------------------------------------------

local function ilvlBracket(ilvl)
    if not ilvl or ilvl <= 0 then return nil end
    return "ilvl " .. (math.floor(ilvl / 10) * 10) .. "+"
end

local function rioBracket(score)
    if not score or score <= 0 then return nil end
    if score >= 3000 then return "rio 3000+" end
    if score >= 2500 then return "rio 2500+" end
    if score >= 2000 then return "rio 2000+" end
    if score >= 1000 then return "rio 1000+" end
    return "rio <1000"
end

function Roster.AutoTags(person)
    local tags = {}
    local char = Roster.MainCharacter(person)
    if not char then return tags end

    if char.role then tags["role:" .. char.role:lower()] = true end
    if char.specName then tags["spec:" .. char.specName:lower()] = true end
    if char.classFile then tags["class:" .. char.classFile:lower()] = true end

    local b = ilvlBracket(char.ilvl)
    if b then tags[b] = true end

    local refined = ns.Lookup and ns.Lookup.Get(char.guid)
    local rio = refined and (refined.rioCurrent or refined.rio)
    local rb = rioBracket(rio)
    if rb then tags[rb] = true end

    local tier = Roster.EffectiveTier(person)
    tags["tier:" .. tier:lower()] = true

    -- Derived, not manual: whether they are on your friends list is a fact about
    -- the client, and it changes without anyone editing a tag.
    for guid in pairs(person.characters) do
        local c = Roster.GetCharacter(guid)
        if c and c.fromFriendList then tags["existing_friend"] = true; break end
    end

    return tags
end

-- Manual + auto, for filter evaluation and tag-chip rendering.
function Roster.AllTagsFor(person)
    local combined = {}
    if person then
        for tag in pairs(person.tags) do combined[tag] = "manual" end
        for tag in pairs(Roster.AutoTags(person)) do
            if not combined[tag] then combined[tag] = "auto" end
        end
    end
    return combined
end

--------------------------------------------------------------------------------
-- Friends list import
--
-- The roster is a record of people you have run with, which leaves out the ones
-- you already know -- exactly the people worth bringing along. So everyone on the
-- friends list is imported and carries the `existing_friend` auto-tag.
--
-- Imported rather than "seen": these are created without touching lastSeen,
-- because being on a friends list is not an occasion of having played together
-- and the roster's Last column has to keep meaning that.
--------------------------------------------------------------------------------

function Roster.ImportFriends()
    local imported = 0

    local function take(fullName, extra)
        if not fullName or fullName == "" then return end
        local existing = Roster.FindCharacterByName(fullName)
        local guid = existing and existing.guid

        -- Without a GUID there is nothing to key a character on, so a friend we
        -- have never met is remembered under a name-derived id until we do.
        guid = guid or ("Friend-" .. fullName:lower())

        -- Name first: EnsureCharacter attaches the character to a person and
        -- names that person after it, so creating the record before the name is
        -- known leaves a roster full of people called "Person".
        local existingRecord = Roster.GetCharacter(guid)
        local char = existingRecord
            or Roster.TouchCharacter(guid, { name = fullName, fromFriendList = true })
        if not char then return end
        char.name = char.name or fullName
        char.fromFriendList = true
        for k, v in pairs(extra or {}) do
            if v ~= nil and char[k] == nil then char[k] = v end
        end
        imported = imported + 1
    end

    if C_FriendList and C_FriendList.GetNumFriends then
        for i = 1, C_FriendList.GetNumFriends() do
            local info = C_FriendList.GetFriendInfoByIndex(i)
            if info and info.name then
                take(ns.FullName(info.name), { classFile = info.className })
            end
        end
    end

    if BNGetNumFriends and C_BattleNet then
        for i = 1, BNGetNumFriends() do
            local acct = C_BattleNet.GetFriendAccountInfo(i)
            local game = acct and acct.gameAccountInfo
            if game and game.clientProgram == BNET_CLIENT_WOW and game.characterName then
                take(ns.FullName(game.characterName,
                        game.realmName and game.realmName:gsub("%s+", "")),
                    { bnetAccountID = acct.bnetAccountID })
            end
        end
    end

    return imported
end

--------------------------------------------------------------------------------
-- Online status and BNet linking
--------------------------------------------------------------------------------

-- Instance names we can enumerate, so a friend's reported location can be
-- recognised as content rather than a city.
--
-- Best effort, and honest about it: the client will enumerate current-season
-- Mythic+ dungeons and every battleground, but there is no cheap list of every
-- raid, so a raid is inferred from the difficulty wording the client itself uses
-- in rich presence. What this misses is a friend who is free being left out of
-- the list -- never someone busy being offered.
local instanceNames

local function buildInstanceNames()
    local out = { dungeon = {}, pvp = {} }

    if C_ChallengeMode and C_ChallengeMode.GetMapTable then
        local ok, maps = pcall(C_ChallengeMode.GetMapTable)
        if ok and type(maps) == "table" then
            for _, id in ipairs(maps) do
                local name = ns.DungeonName(id)
                if name then out.dungeon[name:lower()] = true end
            end
        end
    end

    -- Both halves feature-detected. Checking the count function and then calling
    -- a different one that does not exist on this client is what took the Send
    -- tab down with "attempt to call a nil value".
    if type(GetNumBattlegroundTypes) == "function"
        and type(GetBattlegroundInfo) == "function" then
        for i = 1, GetNumBattlegroundTypes() do
            local name = GetBattlegroundInfo(i)
            if type(name) == "string" and name ~= "" then
                out.pvp[name:lower()] = true
            end
        end
    end

    return out
end

function Roster.RefreshInstanceNames()
    -- Wrapped: this is a convenience that decides whether to hide somebody from
    -- a list. It must never be the reason a panel fails to draw.
    local ok, built = pcall(buildInstanceNames)
    instanceNames = ok and built or { dungeon = {}, pvp = {} }
end

-- "dungeon" | "raid" | "pvp" | nil, from wherever the client says they are.
function Roster.ActivityFor(where)
    -- IsSecret first: comparing a secret string to "" raises rather than
    -- returning false, so the guard has to reject it before it touches it.
    if ns.IsSecret(where) then return nil end
    if not where or where == "" then return nil end
    if not instanceNames then Roster.RefreshInstanceNames() end

    local lower = where:lower()
    for name in pairs(instanceNames.dungeon) do
        if lower:find(name, 1, true) then return "dungeon" end
    end
    for name in pairs(instanceNames.pvp) do
        if lower:find(name, 1, true) then return "pvp" end
    end

    -- Rich presence spells out the difficulty for instanced content, which is
    -- what catches raids and the dungeons the map table does not list.
    for _, marker in ipairs({ RAID, MYTHIC_DUNGEON, PLAYER_DIFFICULTY6,
                              PLAYER_DIFFICULTY2, PLAYER_DIFFICULTY1,
                              ARENA, BATTLEGROUND }) do
        if type(marker) == "string" and marker ~= ""
            and lower:find(marker:lower(), 1, true) then
            if marker == ARENA or marker == BATTLEGROUND then return "pvp" end
            if marker == RAID then return "raid" end
            return "dungeon"
        end
    end

    return nil
end

-- Map of "Name-Realm" -> { online = true, bnet = accountID or nil }.
-- Rebuilt on demand; the friends list is cheap to walk and always current.
-- Is this friends-list game account safe to read, and a WoW character?
--
-- Every field here can come back secret, and a secret raises on a boolean test
-- just as it does on a comparison -- `if game.isOnline` is as dangerous as
-- `name == ""`. So secrecy is checked before anything is tested, and a record
-- with any withheld field is skipped whole rather than half-read.
local function usableGameAccount(game)
    if not game then return false end
    if ns.IsSecret(game.isOnline) or ns.IsSecret(game.clientProgram)
        or ns.IsSecret(game.characterName) then
        return false
    end
    return (game.isOnline and game.clientProgram == BNET_CLIENT_WOW
        and game.characterName) and true or false
end

function Roster.OnlineIndex()
    -- Debug builds can stand in a synthetic friends list so the send panel has
    -- recipients without anyone real being online.
    if ns.Debug and ns.Debug.OnlineIndex then
        local fake = ns.Debug.OnlineIndex()
        if fake then return fake end
    end

    local index = {}

    local numBN = BNGetNumFriends and BNGetNumFriends() or 0
    for i = 1, numBN do
        local acct = C_BattleNet and C_BattleNet.GetFriendAccountInfo(i)
        local game = acct and acct.gameAccountInfo
        if usableGameAccount(game) then
            local full = ns.FullName(game.characterName, game.realmName and game.realmName:gsub("%s+", ""))
            if full then
                index[full] = { online = true, bnet = acct.bnetAccountID,
                    battleTag = acct.battleTag,
                    busy = Roster.ActivityFor(game.richPresence) }
            end
        end
    end

    local numFriends = C_FriendList and C_FriendList.GetNumFriends() or 0
    for i = 1, numFriends do
        local info = C_FriendList.GetFriendInfoByIndex(i)
        if info and info.connected and info.name then
            local full = ns.FullName(info.name)
            if full then
                index[full] = index[full] or { online = true }
                index[full].online = true
                index[full].busy = index[full].busy or Roster.ActivityFor(info.area)
                if info.dnd then index[full].busy = index[full].busy or "busy" end
            end
        end
    end

    if IsInGuild and IsInGuild() then
        local total = GetNumGuildMembers and select(1, GetNumGuildMembers()) or 0
        for i = 1, total do
            local name, _, _, _, _, zone, _, _, online = GetGuildRosterInfo(i)
            if name and online then
                index[name] = index[name] or { online = true }
                index[name].online = true
                index[name].guild = true
                index[name].busy = index[name].busy or Roster.ActivityFor(zone)
            end
        end
    end

    return index
end

-- Undo groupings that nothing vouches for.
--
-- The old repair, RebuildPersonsFromAccounts, regrouped by bnetAccountID -- the
-- very value now known to be unstable between sessions -- so running it would
-- have entrenched the damage rather than undone it. This replaces it.
--
-- A grouping is kept only when something stands behind it:
--   * every character in it shares one BattleTag, which is stable and account
--     unique; or
--   * you made it yourself (linkedBy == "manual").
-- Everything else is dissolved into one person per character.
--
-- Nothing is lost by dissolving. Runs, item level, tier and history live on the
-- character; only the claim that two characters are one person goes, along with
-- the numbers derived from it. Person-level note, tags and tier override follow
-- the character with the most runs, because they have to go somewhere and that
-- is the one you actually know.
--
-- `apply` false reports what it would do and changes nothing.
function Roster.UngroupUnverified(apply)
    local plan = { groups = 0, characters = 0, kept = 0, keptManual = 0, details = {} }

    for _, person in pairs(ns.db.persons) do
        local guids = {}
        for guid in pairs(person.characters or {}) do guids[#guids + 1] = guid end
        if #guids > 1 then
            if person.linkedBy == "manual" then
                plan.kept = plan.kept + 1
                plan.keptManual = plan.keptManual + 1
            else
                -- One shared tag across every character is the only automatic
                -- justification left. A group where some characters have a tag
                -- and others have none is not justified: the untagged ones are
                -- there on the strength of an account ID.
                local tag, sameTag = nil, true
                for _, guid in ipairs(guids) do
                    local c = Roster.GetCharacter(guid)
                    local t = c and c.battleTag
                    if not t or ns.IsSecret(t) or t == "" then sameTag = false break end
                    if tag and t ~= tag then sameTag = false break end
                    tag = t
                end
                if sameTag and tag then
                    plan.kept = plan.kept + 1
                else
                    plan.groups = plan.groups + 1
                    plan.characters = plan.characters + #guids
                    plan.details[#plan.details + 1] = {
                        id = person.id, name = person.name, count = #guids,
                    }
                end
            end
        end
    end

    if not apply then return plan end

    -- Collected first, then applied: AttachToPerson edits ns.db.persons, and
    -- rearranging a table while iterating it is how you miss half of them.
    local doomed = {}
    for _, d in ipairs(plan.details) do doomed[#doomed + 1] = d.id end

    for _, personId in ipairs(doomed) do
        local person = Roster.GetPerson(personId)
        if person then
            local guids = {}
            for guid in pairs(person.characters) do guids[#guids + 1] = guid end

            -- Whoever you have played with most inherits anything hand-set.
            local heir, heirRuns = nil, -1
            for _, guid in ipairs(guids) do
                local c = Roster.GetCharacter(guid)
                local runs = (c and tonumber(c.runs)) or 0
                if runs > heirRuns then heir, heirRuns = guid, runs end
            end
            local note, tags = person.note, person.tags
            local tierOverride, lastMessaged = person.tierOverride, person.lastMessaged

            for _, guid in ipairs(guids) do
                person.characters[guid] = nil
                local fresh = Roster.AttachToPerson(guid)
                if fresh and guid == heir then
                    fresh.note = note
                    fresh.tierOverride = tierOverride
                    fresh.lastMessaged = lastMessaged
                    if tags then
                        for tag in pairs(tags) do fresh.tags[tag] = true end
                    end
                end
            end
            if not next(person.characters) then ns.db.persons[person.id] = nil end
        end
    end

    if plan.characters > 0 and ns.Rating and ns.Rating.RecomputeAll then
        ns.Rating.RecomputeAll()
    end
    return plan
end

-- Fold whatever the friends list currently exposes back into our characters:
-- records the account ID and the BattleTag, and links characters that share a
-- *BattleTag*.
--
-- It used to link on bnetAccountID, which is not stable between sessions. The
-- proof is in the database it produced: the same character name sitting under
-- two adjacent account IDs -- Drakowolf under 690 and 364, Chinahunter under 254
-- and 253, Averelle under 111 and 112 -- which can only happen if one real
-- account was handed a different number on a different day. That splits one
-- person across several records, and would eventually merge two people when a
-- released number is handed out again. See docs/roster-identity-repair.md.
--
-- The account ID is still recorded, because two things want it and both are
-- session-scoped, which is what it actually is: the online index, rebuilt on
-- every call, and matching an incoming Battle.net whisper to a character. It is
-- no longer anybody's identity.
function Roster.SyncBNetLinks()
    local byTag = {}
    local linked = 0

    local numBN = BNGetNumFriends and BNGetNumFriends() or 0
    for i = 1, numBN do
        local acct = C_BattleNet and C_BattleNet.GetFriendAccountInfo(i)
        local game = acct and acct.gameAccountInfo
        if usableGameAccount(game) then
            -- Only when the friends list actually told us the realm. Without it
            -- ns.FullName falls back to *our* realm, so a friend on an unknown
            -- realm becomes "Name-OurRealm" and can collide with a completely
            -- different character of that name -- which then gets stamped with
            -- this account and, in the next loop, linked to everybody else on it.
            local realm = game.realmName and game.realmName:gsub("%s+", "")
            local full = (realm and realm ~= "")
                and ns.FullName(game.characterName, realm) or nil
            for guid, char in pairs(ns.db.characters) do
                -- `full` can be nil when a name is withheld, and `char.name` can
                -- be nil on a stub; nil == nil would then match every one of them
                -- at once and merge the lot.
                if full and char.name == full
                    -- Never reassign a character that already belongs to another
                    -- account. Two accounts claiming one name is a collision, not
                    -- a correction, and overwriting is how unrelated people ended
                    -- up merged into a single person.
                    and (char.bnetAccountID == nil
                         or char.bnetAccountID == acct.bnetAccountID) then
                    char.bnetAccountID = acct.bnetAccountID
                    -- Written down whenever the client offers one, because it
                    -- is the identity everything else now rests on, and it is
                    -- offered only while they are on your friends list -- gone
                    -- for good the moment they come off it unless it was
                    -- recorded while it was there.
                    if acct.battleTag and not ns.IsSecret(acct.battleTag) then
                        char.battleTag = acct.battleTag
                    end
                    local tag = char.battleTag
                    if tag and not ns.IsSecret(tag) and tag ~= "" then
                        local prev = byTag[tag]
                        if prev and prev ~= guid then
                            if Roster.LinkCharacters(prev, guid, "battletag") then
                                linked = linked + 1
                            end
                        else
                            byTag[tag] = guid
                        end
                    end
                end
            end
        end
    end

    -- Characters whose tag we already wrote down still deserve linking, even
    -- when their owner is offline right now. On the tag, for the same reason:
    -- an account ID from a previous session means nothing today.
    local seen = {}
    for guid, char in pairs(ns.db.characters) do
        local tag = char.battleTag
        if tag and not ns.IsSecret(tag) and tag ~= "" then
            if seen[tag] and seen[tag] ~= guid then
                if Roster.LinkCharacters(seen[tag], guid, "battletag") then
                    linked = linked + 1
                end
            else
                seen[tag] = guid
            end
        end
    end

    return linked
end

ns.OnInit(function()
    -- Friends-list data is only meaningful once we are in the world, and the
    -- account mapping is online-only, so re-sync opportunistically.
    ns.RegisterEvent("BN_FRIEND_INFO_CHANGED", function() Roster.SyncBNetLinks() end)
    ns.RegisterEvent("FRIENDLIST_UPDATE", function() Roster.SyncBNetLinks() end)
end)

ns.OnInit(function()
    -- Stamped on every login, so the set of "my characters" grows as alts are
    -- played rather than depending on having been in a key on them.
    Roster.MarkSelf()
    ns.RegisterEvent("PLAYER_ENTERING_WORLD", function()
        Roster.MarkSelf()
        Roster.RefreshInstanceNames()
        Roster.ImportFriends()
    end)
    ns.RegisterEvent("FRIENDLIST_UPDATE", Roster.ImportFriends)
    ns.RegisterEvent("BN_FRIEND_INFO_CHANGED", Roster.ImportFriends)
end)
