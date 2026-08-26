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
    return guid and ns.db.characters[guid] or nil
end

-- Create-or-update. `info` fields are only written when non-nil, so a partial
-- update (say, an inspect result carrying only spec/ilvl) never blanks out what
-- we already knew.
function Roster.TouchCharacter(guid, info)
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

    for _, key in ipairs({ "name", "class", "classFile", "spec", "specName", "role", "ilvl", "bnetAccountID", "debug" }) do
        if info[key] ~= nil then char[key] = info[key] end
    end
    char.lastSeen = info.lastSeen or ns.Now()

    if not char.personId then
        Roster.AttachToPerson(guid)
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

-- Attach a character to a person: an existing one when `personId` is given,
-- otherwise a fresh person named after the character.
function Roster.AttachToPerson(guid, personId)
    local char = Roster.GetCharacter(guid)
    if not char then return nil end

    local person = personId and Roster.GetPerson(personId)
    if not person then
        person = newPerson(char.name and ns.ShortName(char.name) or nil)
    end

    if char.personId and char.personId ~= person.id then
        local old = Roster.GetPerson(char.personId)
        if old then old.characters[guid] = nil end
    end

    char.personId = person.id
    person.characters[guid] = true
    if not person.name or person.name:match("^Person %d+$") then
        person.name = ns.ShortName(char.name or person.name)
    end
    return person
end

-- Merge the person behind `guidB` into the person behind `guidA`. Tags and
-- notes union; a tier override on either side survives (A wins on conflict).
function Roster.LinkCharacters(guidA, guidB)
    local a, b = Roster.GetCharacter(guidA), Roster.GetCharacter(guidB)
    if not a or not b then return false, "unknown character" end
    if a.personId == b.personId then return true end

    local keep = Roster.GetPerson(a.personId)
    local merge = Roster.GetPerson(b.personId)
    if not keep or not merge then return false, "unknown person" end

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
-- Online status and BNet linking
--------------------------------------------------------------------------------

-- Map of "Name-Realm" -> { online = true, bnet = accountID or nil }.
-- Rebuilt on demand; the friends list is cheap to walk and always current.
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
        if game and game.isOnline and game.clientProgram == BNET_CLIENT_WOW and game.characterName then
            local full = ns.FullName(game.characterName, game.realmName and game.realmName:gsub("%s+", ""))
            if full then
                index[full] = { online = true, bnet = acct.bnetAccountID, battleTag = acct.battleTag }
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
            end
        end
    end

    if IsInGuild and IsInGuild() then
        local total = GetNumGuildMembers and select(1, GetNumGuildMembers()) or 0
        for i = 1, total do
            local name, _, _, _, _, _, _, _, online = GetGuildRosterInfo(i)
            if name and online then
                index[name] = index[name] or { online = true }
                index[name].online = true
                index[name].guild = true
            end
        end
    end

    return index
end

-- Fold whatever the friends list currently exposes back into our characters:
-- records the BNet account ID, and links two characters that share one.
function Roster.SyncBNetLinks()
    local byAccount = {}
    local linked = 0

    local numBN = BNGetNumFriends and BNGetNumFriends() or 0
    for i = 1, numBN do
        local acct = C_BattleNet and C_BattleNet.GetFriendAccountInfo(i)
        local game = acct and acct.gameAccountInfo
        if game and game.isOnline and game.clientProgram == BNET_CLIENT_WOW and game.characterName then
            local full = ns.FullName(game.characterName, game.realmName and game.realmName:gsub("%s+", ""))
            for guid, char in pairs(ns.db.characters) do
                if char.name == full then
                    char.bnetAccountID = acct.bnetAccountID
                    local prev = byAccount[acct.bnetAccountID]
                    if prev and prev ~= guid then
                        if Roster.LinkCharacters(prev, guid) then linked = linked + 1 end
                    else
                        byAccount[acct.bnetAccountID] = guid
                    end
                end
            end
        end
    end

    -- Characters we already know the account for still deserve linking, even
    -- when their owner is offline right now.
    local seen = {}
    for guid, char in pairs(ns.db.characters) do
        local acct = char.bnetAccountID
        if acct then
            if seen[acct] and seen[acct] ~= guid then
                if Roster.LinkCharacters(seen[acct], guid) then linked = linked + 1 end
            else
                seen[acct] = guid
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
