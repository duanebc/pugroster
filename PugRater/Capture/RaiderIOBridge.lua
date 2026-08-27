-- Capture/RaiderIOBridge.lua -- live Mythic+ scores from the RaiderIO addon.
--
-- Scores used to come only from PugRater_Lookup.lua, which the Python companion
-- writes -- and the companion does not exist yet, which is why every RIO cell in
-- the roster was blank. The RaiderIO addon, if the player has it, already holds
-- the same numbers for anyone it has data on, so ask it directly.
--
-- Resolution order in Rating/Lookup: the live addon first, because it is current
-- and the companion file is a snapshot; the companion file second, so a machine
-- without RaiderIO still shows whatever the last sync produced.
--
-- Feature-detected per function, like DetailsBridge: RaiderIO's public surface is
-- a metatable proxy and it has reshuffled its profile shape before now.

local ADDON, ns = ...

local RIO = {}
ns.RaiderIOBridge = RIO

-- Profiles do not change within a frame and a roster redraw asks for dozens, so
-- results are memoised for a few seconds. Cleared on the events that mean the
-- data underneath actually moved.
local CACHE_SECONDS = 30
local cache = {}

function RIO.IsAvailable()
    local r = _G.RaiderIO
    return type(r) == "table" and type(r.GetProfile) == "function"
end

function RIO.ClearCache()
    wipe(cache)
end

-- current, previous -- either may be nil when RaiderIO has no data for them.
--
-- `fullName` is "Name-Realm"; RaiderIO wants the two halves separately, and
-- falls back to the player's own realm when the name carries none.
function RIO.Scores(fullName)
    if not RIO.IsAvailable() or not fullName or fullName == "" then return nil, nil end

    local hit = cache[fullName]
    if hit and (GetTime() - hit.t) < CACHE_SECONDS then
        return hit.current, hit.previous
    end

    local name, realm = fullName:match("^([^-]+)-(.+)$")
    if not name then
        name = fullName
        realm = GetNormalizedRealmName and GetNormalizedRealmName() or GetRealmName()
    end

    local ok, profile = pcall(_G.RaiderIO.GetProfile, name, realm)
    if not ok or type(profile) ~= "table" then
        cache[fullName] = { t = GetTime() }
        return nil, nil
    end

    local keystone = profile.mythicKeystoneProfile
    local current, previous
    if type(keystone) == "table" then
        -- currentScore is the headline number; mplusCurrent.score is the same
        -- value on builds that have not filled the shortcut in.
        current = tonumber(keystone.currentScore)
        if (not current or current == 0) and type(keystone.mplusCurrent) == "table" then
            current = tonumber(keystone.mplusCurrent.score)
        end
        if type(keystone.mplusPrevious) == "table" then
            previous = tonumber(keystone.mplusPrevious.score)
        end
    end

    if current == 0 then current = nil end
    if previous == 0 then previous = nil end

    cache[fullName] = { t = GetTime(), current = current, previous = previous }
    return current, previous
end

-- RaiderIO colours a previous-season score differently from a current one, which
-- is worth keeping: the two are not on the same scale.
function RIO.ScoreColor(score, isPrevious)
    local r = _G.RaiderIO
    if not score or score <= 0 or type(r) ~= "table" or type(r.GetScoreColor) ~= "function" then
        return nil
    end
    local ok, cr, cg, cb = pcall(r.GetScoreColor, score, isPrevious and true or false)
    if not ok or not cr then return nil end
    return { r = cr, g = cg, b = cb }
end

ns.OnInit(function()
    -- RaiderIO fills in as data providers load and as it looks players up, so a
    -- cache from before a group formed goes stale quickly.
    ns.RegisterEvent("GROUP_ROSTER_UPDATE", RIO.ClearCache)
    ns.RegisterEvent("PLAYER_ENTERING_WORLD", RIO.ClearCache)
end)
