-- Core.lua -- addon namespace, saved variables, event dispatch, shared helpers.
--
-- Everything else in PugRoster hangs off the `ns` table created here, which is
-- also published as the global `PugRoster` so the optional Debug/ folder (and
-- anyone poking at it from /run) can feature-detect against it.

local ADDON, ns = ...
_G.PugRoster = ns

ns.name = ADDON
ns.addonVersion = C_AddOns and C_AddOns.GetAddOnMetadata(ADDON, "Version") or "dev"

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

ns.TIERS = { "Great", "Good", "Neutral", "Avoid" }

ns.TIER_COLOR = {
    Great   = { r = 0.00, g = 0.90, b = 0.45 },
    Good    = { r = 0.45, g = 0.75, b = 1.00 },
    Neutral = { r = 0.75, g = 0.75, b = 0.75 },
    Avoid   = { r = 1.00, g = 0.30, b = 0.30 },
}

ns.TIER_ICON = { Great = "|cff00e673++|r", Good = "|cff73bfff+|r", Neutral = "", Avoid = "|cffff4d4d!|r" }

-- Default manual tag categories. Users may add tags to any category, and may
-- add categories outright; these only seed the fresh-install tag list.
ns.DEFAULT_TAGS = {
    { name = "IRL friend",     category = "Relationship" },
    { name = "guild",          category = "Relationship" },
    { name = "met-in-pug",     category = "Relationship" },
    { name = "do-not-message", category = "Relationship" },
    { name = "push",           category = "Play style" },
    { name = "chill",          category = "Play style" },
    { name = "learning",       category = "Play style" },
    { name = "weeknights",     category = "Availability" },
    { name = "weekends",       category = "Availability" },
    { name = "voice",          category = "Voice" },
    { name = "no voice",       category = "Voice" },
    { name = "Discord",        category = "Voice" },
}

ns.DO_NOT_MESSAGE_TAG = "do-not-message"

-- Content types, in the order the History filter offers them.
ns.CONTENT_TYPES = { "mythic+", "dungeon", "raid", "delve", "pvp", "dummy", "world" }

ns.CONTENT_LABEL = {
    ["mythic+"] = "Mythic+",
    dungeon     = "Dungeons",
    raid        = "Raids",
    delve       = "Delves",
    pvp         = "PvP",
    dummy       = "Target dummies",
    world       = "Open world",
}

-- Delves report as scenarios; this difficulty id is what separates them.
local DELVE_DIFFICULTY = 208

-- What kind of content is the player in right now?
function ns.ContentType()
    if C_ChallengeMode and C_ChallengeMode.IsChallengeModeActive
        and C_ChallengeMode.IsChallengeModeActive() then
        return "mythic+"
    end

    local _, instanceType, difficultyID = GetInstanceInfo()
    if instanceType == "party" then return "dungeon" end
    if instanceType == "raid" then return "raid" end
    if instanceType == "arena" or instanceType == "pvp" then return "pvp" end
    if instanceType == "scenario" then
        return difficultyID == DELVE_DIFFICULTY and "delve" or "dungeon"
    end
    return "world"
end

-- Training dummies are open-world combat that is really a test, so they are
-- worth separating: they are the only content you can produce on demand, which
-- makes them the fast way to check that capture works at all.
function ns.IsTrainingDummy(unit)
    if not unit or not UnitExists(unit) then return false end
    local name = UnitName(unit)
    if not name or ns.IsSecret(name) then return false end
    return name:lower():find("dummy", 1, true) ~= nil
end

ns.DEFAULTS = {
    settings = {
        -- Rating
        minRunsForTier       = 2,     -- runs together before leaving Neutral
        seasonDecay          = 0.50,  -- weight applied to the previous season
        olderDecay           = 0.25,  -- weight applied to anything older
        preferRefined        = true,  -- use companion tiers when newer than local
        -- Capture
        captureChat          = true,
        captureWhispers      = true,
        chatLinesPerRun      = 400,   -- hard cap so a chatty run cannot bloat SV
        inspectGroupmates    = true,
        useDetails           = true,  -- only when Details is actually loaded
        -- Display
        showTooltip          = true,
        showJoinPopup        = true,
        showLFGBadge         = true,
        -- Messaging
        sendStagger          = 1.5,   -- seconds between whispers
        messageCooldownSeconds = 300,
        preferBNet           = true,
        maxSentLog           = 20,    -- messages kept in "Recently sent"
        -- We can only see that someone is online if they are a Battle.net
        -- friend, a character friend, or a guildmate. A cross-realm pug is none
        -- of those, so restricting the send list to the visibly-online hides
        -- exactly the people this addon exists to keep track of. Offer them
        -- anyway, marked; a whisper to someone offline just fails harmlessly.
        includeUnknownOnline = true,
        -- Someone already in a dungeon, raid or battleground is not available,
        -- and whispering them an invite is noise at the worst moment.
        skipBusyPlayers      = true,
        -- Housekeeping
        maxRunsInGame        = 400,   -- oldest exported runs trimmed past this
        maxFightsInGame      = 100,   -- non-key fights are a rolling window
        -- A hard ceiling on the whole database, not a cap on any one thing.
        -- SavedVariables is read and written whole at every login.
        maxStorageMB         = 5,
    },
}

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------

local function copyDefaults(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            copyDefaults(dst[k], v)
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
    return dst
end
ns.copyDefaults = copyDefaults

function ns.Print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    DEFAULT_CHAT_FRAME:AddMessage("|cff8f5fd6PugRoster|r " .. table.concat(parts, " "))
end

function ns.Round(v, places)
    local m = 10 ^ (places or 0)
    return math.floor((v or 0) * m + 0.5) / m
end

function ns.Clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi else return v end
end

--------------------------------------------------------------------------------
-- Trace ring
--
-- ADDON_ACTION_FORBIDDEN is raised by the client and dispatched as an ordinary
-- event, which means the handler runs at a frame boundary rather than inside the
-- offending call -- a traceback taken there shows the event dispatch and nothing
-- useful. What does survive is a record of what we were doing just before, so
-- every place PugRoster is entered from Blizzard's side drops a breadcrumb here
-- and the debug panel prints the last few next to each refusal.
--
-- One table write on a 24-slot ring; cheap enough to leave on always, and the
-- ring is the only thing that turns "some addon did something" into "our unit
-- tooltip hook ran 3ms earlier".
--------------------------------------------------------------------------------

local TRACE_SIZE = 24
local trace, traceAt = {}, 0

function ns.Trace(tag)
    traceAt = traceAt % TRACE_SIZE + 1
    local slot = trace[traceAt]
    if slot then
        slot.tag, slot.t = tag, GetTime()
    else
        trace[traceAt] = { tag = tag, t = GetTime() }
    end
end

-- Newest first, as { tag, ago } pairs.
function ns.TraceLog()
    local now, out = GetTime(), {}
    for i = 0, TRACE_SIZE - 1 do
        local slot = trace[(traceAt - i - 1) % TRACE_SIZE + 1]
        if slot and slot.tag then
            out[#out + 1] = { tag = slot.tag, ago = now - slot.t }
        end
    end
    return out
end

--------------------------------------------------------------------------------
-- Secret values
--
-- Midnight hands some values back "secret": you may pass one around, but you may
-- not compare it, print it, or use it as a table key. Indexing with one throws
-- "attempted to index a table that cannot be indexed with secret keys", which is
-- how it first showed up here -- a chat event's sender GUID reaching
-- Roster.GetCharacter and taking the History tab down with it.
--
-- Sender GUIDs from chat events are secret; UnitGUID on your own group is not,
-- which is why the roster fills in correctly and only the chat lines break. Any
-- GUID heading for a table lookup or for SavedVariables goes through here first.
--------------------------------------------------------------------------------

function ns.IsSecret(value)
    return value ~= nil and issecretvalue and issecretvalue(value) and true or false
end

-- nil for anything we must not touch, the value itself otherwise.
function ns.SafeGUID(guid)
    if guid == nil or ns.IsSecret(guid) then return nil end
    return guid
end

--------------------------------------------------------------------------------
-- Forbidden widgets
--
-- Blizzard marks some frames and tooltips forbidden to addons -- restricted
-- nameplate units, protected UI built for the secure path. Calling *any* method
-- on one, including a harmless getter like GetUnit, fires ADDON_ACTION_FORBIDDEN
-- and gives the player the "disable this addon and reload" popup. IsForbidden is
-- the one method that is always safe to call, so it is the gate every hook that
-- receives a Blizzard widget has to pass through first.
--------------------------------------------------------------------------------

-- Display marker for a seeded record. Test data has to be recognisable at a
-- glance or it is only a matter of time before someone messages a name that
-- does not exist.
function ns.SimTag(record)
    return (record and record.debug) and " |cff7f7f7f[sim]|r" or ""
end

function ns.IsForbidden(widget)
    if not widget then return true end
    if type(widget.IsForbidden) ~= "function" then return false end
    local ok, forbidden = pcall(widget.IsForbidden, widget)
    return (not ok) or forbidden
end

--------------------------------------------------------------------------------
-- Keystone
--
-- C_MythicPlus has two lookalike accessors and they are not interchangeable:
-- GetOwnedKeystoneMapID returns the zone's uiMapID (a four-digit number),
-- while GetOwnedKeystoneChallengeMapID returns the challenge map ID that
-- C_ChallengeMode.GetMapUIInfo and GetActiveChallengeMapID speak in. Passing
-- the first to the second gets you nil and a message reading "+10 map 2859",
-- so every caller goes through here instead of picking one by hand.
--------------------------------------------------------------------------------

-- The one place that reads the client's season map table. Feature-detected and
-- pcall'd the way Roster/Model.lua does it, and deliberately not cached: the
-- table is empty until the first CHALLENGE_MODE_MAPS_UPDATE after login, so an
-- empty answer is "not yet", not "no dungeons", and holding on to one would
-- leave anything built from it blank for the rest of the session.
local function challengeMaps()
    if not (C_ChallengeMode and C_ChallengeMode.GetMapTable) then return {} end
    local ok, maps = pcall(C_ChallengeMode.GetMapTable)
    if not ok or type(maps) ~= "table" then return {} end
    return maps
end

local function isChallengeMap(mapID)
    for _, id in ipairs(challengeMaps()) do
        if id == mapID then return true end
    end
    return false
end

-- Returns challengeMapID, level for the keystone in our bags, or nil.
function ns.OwnedKeystone()
    if not C_MythicPlus then return nil end

    local mapID
    if C_MythicPlus.GetOwnedKeystoneChallengeMapID then
        mapID = C_MythicPlus.GetOwnedKeystoneChallengeMapID()
    elseif C_MythicPlus.GetOwnedKeystoneMapID then
        -- Only reachable if the challenge-map accessor is renamed out from under
        -- us. Trust this one only when what it returns really is a challenge map.
        local candidate = C_MythicPlus.GetOwnedKeystoneMapID()
        if candidate and isChallengeMap(candidate) then mapID = candidate end
    end

    if not mapID or mapID == 0 then return nil end
    local level = C_MythicPlus.GetOwnedKeystoneLevel and C_MythicPlus.GetOwnedKeystoneLevel()
    return mapID, level
end

-- Dungeon name for a challenge map ID, or nil. Callers decide what an unnamed
-- dungeon should read as; nobody should be inventing "map 2859" locally.
function ns.DungeonName(mapID)
    if not (mapID and C_ChallengeMode and C_ChallengeMode.GetMapUIInfo) then return nil end
    return (C_ChallengeMode.GetMapUIInfo(mapID))
end

-- This season's Mythic+ dungeons as an ordered { { id =, name = }, ... } list,
-- sorted by name so a menu built from it does not reshuffle between sessions.
-- Maps the client has not named yet are left out rather than shown as an ID --
-- an unnamed entry in a dropdown is unpickable in practice.
--
-- Returns an empty list before the map table loads; callers show their own
-- "not loaded yet" rather than an empty menu that looks like a bug.
function ns.SeasonDungeons()
    local out = {}
    for _, id in ipairs(challengeMaps()) do
        local name = ns.DungeonName(id)
        if name then out[#out + 1] = { id = id, name = name } end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- "Name-Realm" from name/realm parts. The realm is always included so
-- cross-realm groupmates stay distinguishable in display strings.
function ns.FullName(name, realm)
    if not name or name == "" then return nil end
    if name:find("-", 1, true) then return name end
    if realm and realm ~= "" then return name .. "-" .. realm end
    local home = GetNormalizedRealmName and GetNormalizedRealmName() or GetRealmName()
    return name .. "-" .. ((home or ""):gsub("%s+", ""))
end

-- "Landairsea|cff7f7f7f-Area52|r". Two people called Landairsea on different
-- realms are a normal thing to have in a pug roster, so the realm is part of the
-- identity, not decoration -- but it is dimmed so the name still reads first.
-- `color` tints the character half only. The realm carries its own escape code,
-- so it has to sit outside the colourised part: nesting them closes the first
-- colour early and the rest of the line loses it.
-- A clickable player name for chat output.
--
-- The client turns |Hplayer:Name-Realm|h into the same link the chat frame makes
-- for anyone speaking, so clicking it opens a whisper -- which is the point: a
-- notification that you messaged someone is most useful when it is also the way
-- to message them again.
function ns.PlayerLink(fullName, display)
    if not fullName or fullName == "" or ns.IsSecret(fullName) then
        return display or "?"
    end
    return string.format("|Hplayer:%s|h|cff9b7fd6[%s]|r|h",
        fullName, display or ns.ShortName(fullName))
end

function ns.NameWithRealm(full, color)
    if not full or full == "" then return "?" end
    local name, realm = full:match("^([^-]+)-(.+)$")
    name = name or full
    local shown = color and ns.Colorize(name, color) or name
    if realm then shown = shown .. "|cff7f7f7f-" .. realm .. "|r" end
    return shown
end

function ns.ShortName(full)
    if not full then return "?" end
    return (full:match("^([^-]+)") or full)
end

-- The client calls it DAMAGER. Nobody else does.
local ROLE_LABEL = { TANK = "tank", HEALER = "healer", DAMAGER = "DPS" }

function ns.RoleLabel(role)
    if not role or role == "" or role == "NONE" then return "-" end
    return ROLE_LABEL[role] or role:lower()
end

function ns.ClassColor(classFile)
    local c = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
    return c or { r = 0.8, g = 0.8, b = 0.8 }
end

function ns.Colorize(text, color)
    if not color then return text end
    return string.format("|cff%02x%02x%02x%s|r", color.r * 255, color.g * 255, color.b * 255, text)
end

function ns.TierText(tier)
    tier = tier or "Neutral"
    return ns.Colorize(tier, ns.TIER_COLOR[tier])
end

-- Big numbers in the unit that reads naturally.
--
-- The unit is chosen so the figure stays a real number rather than a decimal:
-- 4,787,000 is 4787K, not 4.787M, while 141,000,000 is 141M rather than
-- 141000K. The rule is simply "step up a unit once you have at least ten of
-- them", which is how people say these numbers out loud.
function ns.FormatCount(value)
    local n = math.floor(tonumber(value) or 0)
    local sign = n < 0 and "-" or ""
    n = math.abs(n)

    if n >= 10000000000 then return sign .. math.floor(n / 1000000000) .. "B" end
    if n >= 10000000    then return sign .. math.floor(n / 1000000) .. "M" end
    if n >= 10000       then return sign .. math.floor(n / 1000) .. "K" end
    return sign .. n
end

-- How many bytes this table will cost in SavedVariables.
--
-- Measured, not guessed. The previous version multiplied a row count by a
-- constant, which is fine for a readout and useless as a budget -- the error
-- compounds with chat lines, names and tag tables, and a ceiling has to be built
-- on a number that is actually true.
--
-- The client writes SavedVariables as Lua source, so an entry's cost is knowable:
-- a tab per depth, the key as `["name"] = ` or `[12] = `, the value, then a comma
-- and a newline. Walking it is cheap because nothing is concatenated -- only the
-- lengths are added up.
local function measure(value, depth, seen)
    local kind = type(value)
    if kind == "number" then return #tostring(value) end
    if kind == "boolean" then return value and 4 or 5 end
    if kind == "string" then return #value + 2 end
    if kind ~= "table" then return 0 end

    -- Cycles are not expected in the database, but a walker that can hang on one
    -- is not worth writing.
    if seen[value] then return 0 end
    seen[value] = true

    local bytes = 4                      -- the braces and their newlines
    local indent = depth + 1
    for k, v in pairs(value) do
        bytes = bytes + indent           -- one tab per level
        if type(k) == "string" then
            bytes = bytes + #k + 7       -- ["k"] = 
        else
            bytes = bytes + #tostring(k) + 5
        end
        bytes = bytes + measure(v, depth + 1, seen) + 2   -- value, comma, newline
    end

    seen[value] = nil
    return bytes
end

function ns.MeasureBytes(value)
    return measure(value, 0, {})
end

-- Size of the whole database, plus the counts worth showing beside it.
function ns.MeasureDB()
    local records = #(ns.db.runs or {}) + #(ns.db.fights or {})
    return {
        records = records,
        characters = ns.Roster.CountCharacters(),
        bytes = ns.MeasureBytes(ns.db),
    }
end

-- Per-second rate over the time actually spent fighting.
--
-- Combat time, not `elapsed`: a key's elapsed is wall clock, and the minutes
-- spent running between packs are not minutes anyone was doing damage in.
-- Records captured before combat time was tracked fall back to elapsed, which
-- understates a key and is exactly right for a fight.
function ns.PerSecond(amount, record)
    amount = tonumber(amount) or 0
    if amount <= 0 or not record then return 0 end
    local seconds = tonumber(record.combatTime) or tonumber(record.elapsed) or 0
    if seconds <= 0 then return 0 end
    return amount / seconds
end

function ns.FormatDuration(seconds)
    seconds = math.max(0, math.floor(seconds or 0))
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

function ns.FormatSigned(seconds)
    local sign = seconds < 0 and "-" or "+"
    return sign .. ns.FormatDuration(math.abs(seconds))
end

function ns.FormatDate(ts)
    if not ts then return "-" end
    return date("%Y-%m-%d %H:%M", ts)
end

function ns.Now()
    return time()
end

-- Coarse "45m" / "3h" / "2d" for a span of seconds. Callers add their own
-- "ago"/"left"; the span itself carries no direction.
function ns.Span(seconds)
    local d = math.max(0, seconds or 0)
    if d < 60 then return math.max(1, math.floor(d)) .. "s" end
    if d < 3600 then return math.floor(d / 60) .. "m" end
    if d < 86400 then return math.floor(d / 3600) .. "h" end
    return math.floor(d / 86400) .. "d"
end

function ns.TimeAgo(ts)
    if not ts then return "never" end
    return ns.Span(ns.Now() - ts) .. " ago"
end

-- Sorted key list, so UI iteration order is stable between frames.
function ns.SortedKeys(t, cmp)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, cmp)
    return keys
end

--------------------------------------------------------------------------------
-- Event dispatch
--
-- One frame, many handlers per event. Modules register inside their own file so
-- load order stays free of cross-module wiring.
--------------------------------------------------------------------------------

local handlers = {}
local frame = CreateFrame("Frame", "PugRosterEventFrame")
ns.eventFrame = frame

function ns.RegisterEvent(event, fn)
    if not handlers[event] then
        handlers[event] = {}
        frame:RegisterEvent(event)
    end
    table.insert(handlers[event], fn)
end

-- Fire handlers by hand. The debug event simulator uses this so a synthetic run
-- travels the exact same code path a real key does.
function ns.FireEvent(event, ...)
    local list = handlers[event]
    if not list then return false end
    ns.Trace("event:" .. event)
    for _, fn in ipairs(list) do
        local ok, err = pcall(fn, ...)
        if not ok then ns.Print("|cffff5555error|r in", event, "handler:", err) end
    end
    return true
end

frame:SetScript("OnEvent", function(_, event, ...)
    ns.FireEvent(event, ...)
end)

--------------------------------------------------------------------------------
-- Saved variables
--------------------------------------------------------------------------------

local DB_VERSION = 1

local function initDB()
    PugRosterDB = PugRosterDB or {}
    local db = PugRosterDB

    db.version      = db.version or DB_VERSION
    db.settings     = db.settings or {}
    db.runs         = db.runs or {}         -- array, oldest first
    -- Everything that is not a Mythic+ key. Kept apart from db.runs on purpose:
    -- Rating reads db.runs, and a raid boss or a target dummy must never move
    -- somebody's Mythic+ tier.
    db.fights       = db.fights or {}
    db.persons      = db.persons or {}      -- [personId] = person
    db.characters   = db.characters or {}   -- [guid] = character
    db.tags         = db.tags or {}         -- [tagName] = { category = ... }
    db.templates    = db.templates or {}
    db.sentLog      = db.sentLog or {}
    db.savedGroups  = db.savedGroups or {}  -- [name] = filter spec
    db.nextPersonId = db.nextPersonId or 1
    db.nextRunId    = db.nextRunId or 1
    db.nextFightId  = db.nextFightId or 1
    -- db.activeRun is left nil unless a key is genuinely in progress; it is the
    -- /reload-safe scratch record RunTracker resumes from.

    -- The message cooldown used to be expressed in hours, which was far coarser
    -- than the guard needs to be. A value someone actually chose is carried
    -- across as seconds; one that is merely a shipped default is dropped, so an
    -- untouched database picks up the new default instead of inheriting a
    -- half-day lockout nobody asked for.
    local oldHours = db.settings.messageCooldownHours
    if oldHours then
        if oldHours ~= 12 and oldHours ~= 4 and not db.settings.messageCooldownSeconds then
            db.settings.messageCooldownSeconds = oldHours * 3600
        end
        db.settings.messageCooldownHours = nil
    end

    copyDefaults(db.settings, ns.DEFAULTS.settings)

    if not next(db.tags) then
        for _, t in ipairs(ns.DEFAULT_TAGS) do
            db.tags[t.name] = { category = t.category }
        end
    end

    if #db.templates == 0 then
        db.templates = {
            { name = "LFM my key", text = "Hey {name}, running my {mykeylevel} {dungeon} -- want in?" },
            { name = "Key swap",   text = "{name}! Got a {key} going, need one more. Interested?" },
            { name = "Ping",       text = "Hey {name}, you around for keys tonight?" },
        }
    end

    ns.db = db
    ns.settings = db.settings
end

--------------------------------------------------------------------------------
-- Bootstrap
--------------------------------------------------------------------------------

ns.modules = {}

-- Modules add an init function here; they all run once, after saved variables
-- exist, in registration (= .toc load) order.
--
-- One shared stack, and taint is a property of the stack: whatever one
-- initialiser picks up, every initialiser after it inherits. So nothing here may
-- make a protected call -- see Capture/CombatLog.lua, which registers its event
-- at file scope for exactly this reason.
function ns.OnInit(fn)
    table.insert(ns.modules, fn)
end

local booted = false
local function boot()
    if booted then return end
    booted = true
    initDB()
    for _, fn in ipairs(ns.modules) do
        local ok, err = pcall(fn)
        if not ok then ns.Print("|cffff5555init error|r:", err) end
    end
end

ns.RegisterEvent("ADDON_LOADED", function(name)
    if name == ADDON then boot() end
end)

--------------------------------------------------------------------------------
-- Forbidden-action reporting
--
-- "PugRoster has been blocked from an action only available to the Blizzard UI"
-- is a popup with no detail in it. ADDON_ACTION_FORBIDDEN carries the name of
-- the refused function, which is the one fact worth having -- but an addon
-- cannot register for that event. Trying to is itself a forbidden action, so a
-- reporter written that way reports nothing except its own registration, on
-- every load, forever. Do not put those two event names in RegisterEvent.
--
-- What is allowed is watching the popup: UIParent answers the event by calling
-- StaticPopup_Show with the addon and function names, and hooksecurefunc onto a
-- Blizzard global is ordinary. Same two facts, no forbidden call.
--
-- Only our own refusals are recorded; another addon's taint is not our business.
--------------------------------------------------------------------------------

local FORBIDDEN_LOG_SIZE = 10
local forbidden = {}

-- Newest first: { func, trace, when }.
function ns.ForbiddenLog()
    return forbidden
end

local function reportForbidden(which, addonName, func)
    if which ~= "ADDON_ACTION_FORBIDDEN" or addonName ~= ADDON then return end

    local crumbs = {}
    for i, entry in ipairs(ns.TraceLog()) do
        if i > 8 then break end
        crumbs[#crumbs + 1] = string.format("      %6.3fs ago  %s", entry.ago, entry.tag)
    end

    table.insert(forbidden, 1, {
        func  = tostring(func),
        trace = #crumbs > 0 and table.concat(crumbs, "\n") or "      (nothing traced)",
        when  = ns.Now(),
    })
    while #forbidden > FORBIDDEN_LOG_SIZE do table.remove(forbidden) end

    ns.Print("|cffff5555forbidden|r", tostring(func), "-- refused. See the Debug tab,"
        .. " or |cffffff00/console taintLog 2|r then Logs/taint.log.")
end

if type(_G.StaticPopup_Show) == "function" then
    pcall(hooksecurefunc, "StaticPopup_Show", function(which, arg1, arg2)
        pcall(reportForbidden, which, arg1, arg2)
    end)
end

--------------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------------

SLASH_PUGROSTER1 = "/pugroster"
SLASH_PUGROSTER2 = "/pr"
SlashCmdList.PUGROSTER = function(msg)
    local cmd, rest = (msg or ""):match("^(%S*)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()

    if cmd == "" or cmd == "show" or cmd == "roster" then
        ns.UI.Toggle("Roster")
    elseif cmd == "history" then
        ns.UI.Toggle("History")
    elseif cmd == "send" then
        ns.UI.Toggle("Send")
    elseif cmd == "options" or cmd == "config" then
        ns.UI.Toggle("Options")
    elseif cmd == "rate" then
        local n = ns.Rating.RecomputeAll()
        ns.Print("recomputed provisional tiers for", n, "characters.")
    elseif cmd == "note" then
        local who, note = rest:match("^(%S+)%s*(.-)$")
        if not who or who == "" then
            ns.Print("usage: /pugroster note <name> <text>")
        else
            local ok = ns.Roster.SetNoteByName(who, note)
            ns.Print(ok and ("note saved for " .. who) or ("no one known named " .. who))
        end
    else
        ns.Print("commands: |cffffff00show|r, |cffffff00history|r, |cffffff00send|r, |cffffff00options|r, |cffffff00rate|r, |cffffff00note <name> <text>|r")
    end
end
