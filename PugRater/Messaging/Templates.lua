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

local ADDON, ns = ...

local Templates = {}
ns.Templates = Templates

function Templates.List()
    return ns.db.templates
end

function Templates.Add(name, text)
    if not name or name == "" then return false end
    table.insert(ns.db.templates, { name = name, text = text or "" })
    return true
end

function Templates.Update(index, name, text)
    local t = ns.db.templates[index]
    if not t then return false end
    if name then t.name = name end
    if text then t.text = text end
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

function Templates.Preview(text, person, char)
    return Templates.Expand(text, Templates.RecipientContext(person, char), Templates.SenderContext())
end
