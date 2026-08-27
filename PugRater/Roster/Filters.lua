-- Roster/Filters.lua -- the filter builder and saved groups.
--
-- A filter is a plain table so it round-trips through SavedVariables and the
-- companion untouched:
--
--   { match = "all" | "any",
--     conditions = { { field = "tag", op = "has", value = "push" },
--                    { field = "ilvl", op = ">=", value = 640 } } }
--
-- Fields cover both manual and auto tags, so `role = healer AND ilvl >= 640 AND
-- tag = push` is one expression over one namespace.

local ADDON, ns = ...

local Filters = {}
ns.Filters = Filters

Filters.FIELDS = {
    { key = "tag",        label = "Tag",           type = "tag" },
    { key = "role",       label = "Role",          type = "enum", values = { "TANK", "HEALER", "DAMAGER" } },
    { key = "tier",       label = "Tier",          type = "enum", values = { "Great", "Good", "Neutral", "Avoid" } },
    { key = "class",      label = "Class",         type = "string" },
    { key = "ilvl",       label = "Item level",    type = "number" },
    { key = "rio",        label = "RIO score",     type = "number" },
    { key = "runs",       label = "Runs together", type = "number" },
    { key = "daysSince",  label = "Days since played with", type = "number" },
    { key = "name",       label = "Name contains", type = "string" },
}

Filters.OPS = {
    tag    = { "has", "lacks" },
    enum   = { "is", "is not" },
    string = { "contains", "is" },
    number = { ">=", "<=", "=" },
}

-- What a stored value should be shown as. The role field stores the client's
-- DAMAGER because that is what UnitGroupRolesAssigned returns and what every
-- comparison is against; nobody should have to read it that way.
function Filters.ValueLabel(field, value)
    if field == "role" then return ns.RoleLabel(value) end
    return tostring(value or "")
end

function Filters.FieldType(fieldKey)
    for _, f in ipairs(Filters.FIELDS) do
        if f.key == fieldKey then return f.type, f end
    end
    return "string"
end

function Filters.New()
    return { match = "all", conditions = {} }
end

--------------------------------------------------------------------------------
-- Value extraction
--------------------------------------------------------------------------------

local function personValue(person, field)
    local char = ns.Roster.MainCharacter(person)

    if field == "role" then
        return char and char.role
    elseif field == "tier" then
        return (ns.Roster.EffectiveTier(person))
    elseif field == "class" then
        return char and (char.classFile or char.class)
    elseif field == "ilvl" then
        return char and char.ilvl or 0
    elseif field == "rio" then
        local rio = char and select(1, ns.Lookup.RIO(char.guid))
        return rio or 0
    elseif field == "runs" then
        return ns.Roster.RunsTogether(person)
    elseif field == "daysSince" then
        local last = ns.Roster.LastPlayedWith(person)
        if not last then return math.huge end
        return math.floor((ns.Now() - last) / 86400)
    elseif field == "name" then
        return person.name or ""
    end
    return nil
end

local function compare(op, actual, expected)
    if op == ">=" then return (tonumber(actual) or 0) >= (tonumber(expected) or 0) end
    if op == "<=" then return (tonumber(actual) or 0) <= (tonumber(expected) or 0) end
    if op == "="  then return (tonumber(actual) or 0) == (tonumber(expected) or 0) end
    if op == "is" then return tostring(actual or ""):lower() == tostring(expected or ""):lower() end
    if op == "is not" then return tostring(actual or ""):lower() ~= tostring(expected or ""):lower() end
    if op == "contains" then
        return tostring(actual or ""):lower():find(tostring(expected or ""):lower(), 1, true) ~= nil
    end
    return false
end

function Filters.EvaluateCondition(person, cond)
    if not cond or not cond.field then return true end

    if cond.field == "tag" then
        local tags = ns.Roster.AllTagsFor(person)
        local has = tags[cond.value] ~= nil
        if cond.op == "lacks" then return not has end
        return has
    end

    return compare(cond.op, personValue(person, cond.field), cond.value)
end

function Filters.Matches(person, filter)
    if not filter or not filter.conditions or #filter.conditions == 0 then return true end

    if filter.match == "any" then
        for _, cond in ipairs(filter.conditions) do
            if Filters.EvaluateCondition(person, cond) then return true end
        end
        return false
    end

    for _, cond in ipairs(filter.conditions) do
        if not Filters.EvaluateCondition(person, cond) then return false end
    end
    return true
end

function Filters.Apply(filter, persons)
    local out = {}
    for _, person in ipairs(persons or ns.Roster.AllPersons()) do
        if Filters.Matches(person, filter) then out[#out + 1] = person end
    end
    return out
end

--------------------------------------------------------------------------------
-- Online suggestions
--------------------------------------------------------------------------------

-- Persons matching the filter who can be messaged, as
-- { person = person, character = char, online = { ... } | nil }.
--
-- `online` is nil when we cannot see their status. That is the normal case for
-- the people this addon is about: online-ness is only visible for Battle.net
-- friends, character friends and guildmates, and a cross-realm pug is none of
-- those. Restricting the list to the visibly-online therefore hid exactly the
-- players you kept a roster of in the first place -- so they are offered too,
-- marked, unless the setting says otherwise. A whisper to someone who is offline
-- fails harmlessly.
-- Why people did not make the list, so an empty Send tab can say what happened
-- rather than leaving you to guess. Reset on every call.
Filters.lastSkipped = { busy = 0, self = 0, offline = 0, nameless = 0, considered = 0 }

function Filters.OnlineMatches(filter)
    local index = ns.Roster.OnlineIndex()
    local includeUnknown = ns.settings.includeUnknownOnline
    local out = {}

    local skipped = { busy = 0, self = 0, offline = 0, nameless = 0, considered = 0 }
    Filters.lastSkipped = skipped

    for _, person in ipairs(Filters.Apply(filter)) do
        -- Never offer yourself. The guild roster and the friends list both
        -- include the player, so without this your own characters come back as
        -- "recipients" -- and on an account with nobody else online, they are
        -- the only ones that do.
        skipped.considered = skipped.considered + 1
        if ns.Roster.IsSelf(person) then
            skipped.self = skipped.self + 1
        else
            local bestChar, bestInfo, fallbackChar
            for guid in pairs(person.characters) do
                local char = ns.Roster.GetCharacter(guid)
                local info = char and char.name and index[char.name]
                if info then
                    -- Prefer a BNet match: it can be whispered on any character.
                    if not bestInfo or (info.bnet and not bestInfo.bnet) then
                        bestChar, bestInfo = char, info
                    end
                elseif char and char.name and not fallbackChar then
                    fallbackChar = char
                end
            end

            -- Someone mid-dungeon, mid-raid or in a battleground is not
            -- available, and an invite reaching them then is noise at the worst
            -- possible moment. Dropping them has to be a real drop: nulling the
            -- info would fall through to the unknown-status branch below and put
            -- them straight back on the list, which is the opposite of the point.
            local busy = bestInfo and ns.settings.skipBusyPlayers and bestInfo.busy

            if busy then
                skipped.busy = skipped.busy + 1
            elseif bestInfo then
                out[#out + 1] = { person = person, character = bestChar, online = bestInfo }
            elseif includeUnknown then
                local char = fallbackChar or ns.Roster.MainCharacter(person)
                if char and char.name then
                    out[#out + 1] = { person = person, character = char, online = nil }
                else
                    skipped.nameless = skipped.nameless + 1
                end
            else
                skipped.offline = skipped.offline + 1
            end
        end
    end

    table.sort(out, function(a, b) return (a.person.name or "") < (b.person.name or "") end)
    return out
end

--------------------------------------------------------------------------------
-- Saved groups
--------------------------------------------------------------------------------

function Filters.SaveGroup(name, filter)
    if not name or name == "" then return false end
    ns.db.savedGroups[name] = CopyTable(filter or Filters.New())
    return true
end

function Filters.GetGroup(name)
    local g = name and ns.db.savedGroups[name]
    return g and CopyTable(g) or nil
end

function Filters.DeleteGroup(name)
    if name then ns.db.savedGroups[name] = nil end
end

function Filters.ListGroups()
    return ns.SortedKeys(ns.db.savedGroups)
end

--------------------------------------------------------------------------------
-- Description
--------------------------------------------------------------------------------

function Filters.DescribeCondition(cond)
    if not cond then return "" end
    if cond.field == "tag" then
        return (cond.op == "lacks" and "not " or "") .. tostring(cond.value)
    end
    local _, def = Filters.FieldType(cond.field)
    return string.format("%s %s %s", def and def.label or cond.field, cond.op or "=",
        Filters.ValueLabel(cond.field, cond.value))
end

function Filters.Describe(filter)
    if not filter or not filter.conditions or #filter.conditions == 0 then
        return "everyone"
    end
    local parts = {}
    for _, cond in ipairs(filter.conditions) do
        parts[#parts + 1] = Filters.DescribeCondition(cond)
    end
    return table.concat(parts, filter.match == "any" and "  OR  " or "  AND  ")
end
