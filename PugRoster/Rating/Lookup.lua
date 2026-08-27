-- Rating/Lookup.lua -- read side of the companion-generated data file.
--
-- PugRoster_Lookup.lua is written by the Python companion and loaded from the
-- .toc. It is pure enrichment: refined tiers, Raider.IO scores for this and the
-- previous season, and person links the companion worked out offline. Its
-- absence must never break the addon, so every read goes through here.

local ADDON, ns = ...

local Lookup = {}
ns.Lookup = Lookup

-- The read has to stay lazy: PugRoster_Lookup.lua is loaded after this file, so
-- there is nothing to cache at file scope. Worth knowing that reading a global
-- an addon created taints the calling stack -- harmless here, but it is why the
-- combat-log registration is deliberately not made from the OnInit chain.
local function data()
    local t = _G.PugRosterLookup
    return type(t) == "table" and t or nil
end

function Lookup.IsPresent()
    return data() ~= nil
end

function Lookup.GeneratedAt()
    local d = data()
    return d and d.generated or nil
end

function Lookup.Season()
    local d = data()
    return d and d.season or nil
end

-- Refined record for one character GUID: { tier, score, rioCurrent, rioPrevious }.
function Lookup.Get(guid)
    local d = data()
    guid = ns.SafeGUID(guid)
    if not d or not guid then return nil end
    local chars = d.characters
    return chars and chars[guid] or nil
end

-- current, previous. The live RaiderIO addon wins when it has an answer: the
-- companion file is a snapshot and may be days old, or -- as it is today --
-- absent entirely, which is why every RIO cell used to read "-".
function Lookup.RIO(guid)
    local char = ns.Roster.GetCharacter(guid)
    if char and char.name and ns.RaiderIOBridge.IsAvailable() then
        local current, previous = ns.RaiderIOBridge.Scores(char.name)
        if current or previous then return current, previous end
    end

    local rec = Lookup.Get(guid)
    if not rec then return nil, nil end
    return rec.rioCurrent, rec.rioPrevious
end

-- Apply the links the companion discovered. Safe to call repeatedly; linking
-- two characters already on the same person is a no-op.
function Lookup.ApplyLinks()
    local d = data()
    if not d or type(d.links) ~= "table" then return 0 end
    local applied = 0
    for _, pair in ipairs(d.links) do
        local a, b = pair[1], pair[2]
        if a and b and ns.Roster.GetCharacter(a) and ns.Roster.GetCharacter(b) then
            if ns.Roster.LinkCharacters(a, b) then applied = applied + 1 end
        end
    end
    return applied
end

ns.OnInit(function()
    if Lookup.IsPresent() then
        Lookup.ApplyLinks()
    end
end)
