-- Messaging/Templates.lua -- saved message templates and placeholder expansion.
--
-- Placeholders are resolved per recipient, so one template produces a
-- personalised line for everyone in a send batch.
--
--   {name}        recipient short name
--   {fullname}    recipient Name-Realm
--   {key}         my keystone as "+15 Dungeon"
--   {dungeon}     my keystone dungeon
--   {mykeylevel}  my keystone level
--   {tier}        the tier I have them at
--   {runs}        runs we have done together
--   {me}          my own character name
--
-- The {key}/{dungeon}/{mykeylevel} group is always the keystone in my own bags.
-- A template can also carry a key it is recruiting *for*, which is a different
-- thing entirely -- "I have +12 Halls, want to run your +15 Dawnbreaker?" needs
-- both in one sentence -- so that one gets its own group, stored on the template:
--
--   {keydungeon}  the dungeon this template is for
--   {keylevel}    that key's level as "+15"
--   {keyname}     the two together, "+15 Dawnbreaker"

local ADDON, ns = ...

local Templates = {}
ns.Templates = Templates

function Templates.List()
    return ns.db.templates
end

function Templates.Add(name, text, mapID, level)
    if not name or name == "" then return false end
    table.insert(ns.db.templates, {
        name = name, text = text or "", mapID = mapID, level = level,
    })
    return true
end

-- `name` and `text` keep the "nil leaves it alone" contract callers rely on, but
-- the key cannot: clearing the dungeon back to none is a thing you have to be
-- able to do, and a nil-means-skip guard would make it unexpressible. So the key
-- is always written, and a caller updating only the text passes the key it
-- already had.
function Templates.Update(index, name, text, mapID, level)
    local t = ns.db.templates[index]
    if not t then return false end
    if name then t.name = name end
    if text then t.text = text end
    t.mapID = mapID
    t.level = level
    return true
end

function Templates.Delete(index)
    if ns.db.templates[index] then
        table.remove(ns.db.templates, index)
        return true
    end
    return false
end

function Templates.ByName(name)
    for _, t in ipairs(ns.db.templates) do
        if t.name == name then return t end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Context
--------------------------------------------------------------------------------

-- Everything that does not depend on the recipient, resolved once per batch.
function Templates.SenderContext()
    local ctx = {
        me         = UnitName("player") or "?",
        mykeylevel = "",
        dungeon    = "",
        key        = "",
    }

    local mapID, level = ns.OwnedKeystone()
    if mapID then
        -- An unnamed dungeon stays empty rather than becoming "map 2859": Expand
        -- leaves empty values as a visible {dungeon} in the preview, which is
        -- what we want a raw ID to look like -- not something we whisper at a
        -- real person.
        ctx.dungeon    = ns.DungeonName(mapID) or ""
        ctx.mykeylevel = level and ("+" .. level) or ""
        ctx.key        = (ctx.mykeylevel .. " " .. ctx.dungeon):match("^%s*(.-)%s*$")
    end

    return ctx
end

-- The key a template is recruiting for. Unset parts stay empty strings so Expand
-- falls through and leaves a visible {keydungeon} in the preview -- the same way
-- a missing keystone leaves {dungeon} visible in SenderContext. A half-written
-- sentence should look half-written before it is whispered at a real person, not
-- read as a fluent line with a hole where the dungeon should be.
function Templates.KeyContext(mapID, level)
    local ctx = {
        keydungeon = mapID and (ns.DungeonName(mapID) or "") or "",
        keylevel   = level and ("+" .. level) or "",
    }
    ctx.keyname = (ctx.keylevel .. " " .. ctx.keydungeon):match("^%s*(.-)%s*$")
    return ctx
end

function Templates.RecipientContext(person, char)
    local tier = ns.Roster.EffectiveTier(person)
    return {
        name     = ns.ShortName(char and char.name or person and person.name),
        fullname = char and char.name or person and person.name or "?",
        tier     = tier,
        runs     = tostring(ns.Roster.RunsTogether(person)),
    }
end

-- Expand `text` against a merged context. Unknown placeholders are left intact
-- so a typo is visible in the preview rather than silently swallowed.
function Templates.Expand(text, ...)
    if not text then return "" end
    local contexts = { ... }

    return (text:gsub("{(%w+)}", function(key)
        for _, ctx in ipairs(contexts) do
            local v = ctx and ctx[key]
            if v ~= nil and v ~= "" then return tostring(v) end
        end
        return "{" .. key .. "}"
    end))
end

function Templates.Preview(text, person, char, keyCtx)
    return Templates.Expand(text, Templates.RecipientContext(person, char),
                            Templates.SenderContext(), keyCtx)
end
