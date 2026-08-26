-- Core.lua -- addon namespace, saved variables, event dispatch, shared helpers.
--
-- Everything else in PugRater hangs off the `ns` table created here, which is
-- also published as the global `PugRater` so the optional Debug/ folder (and
-- anyone poking at it from /run) can feature-detect against it.

local ADDON, ns = ...
_G.PugRater = ns

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
        messageCooldownHours = 12,
        preferBNet           = true,
        -- Housekeeping
        maxRunsInGame        = 400,   -- oldest exported runs trimmed past this
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
    DEFAULT_CHAT_FRAME:AddMessage("|cff8f5fd6PugRater|r " .. table.concat(parts, " "))
end

function ns.Round(v, places)
    local m = 10 ^ (places or 0)
    return math.floor((v or 0) * m + 0.5) / m
end

function ns.Clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi else return v end
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

function ns.ShortName(full)
    if not full then return "?" end
    return (full:match("^([^-]+)") or full)
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

function ns.TimeAgo(ts)
    if not ts then return "never" end
    local d = ns.Now() - ts
    if d < 3600 then return math.max(1, math.floor(d / 60)) .. "m ago" end
    if d < 86400 then return math.floor(d / 3600) .. "h ago" end
    return math.floor(d / 86400) .. "d ago"
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
local frame = CreateFrame("Frame", "PugRaterEventFrame")
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
    PugRaterDB = PugRaterDB or {}
    local db = PugRaterDB

    db.version      = db.version or DB_VERSION
    db.settings     = db.settings or {}
    db.runs         = db.runs or {}         -- array, oldest first
    db.persons      = db.persons or {}      -- [personId] = person
    db.characters   = db.characters or {}   -- [guid] = character
    db.tags         = db.tags or {}         -- [tagName] = { category = ... }
    db.templates    = db.templates or {}
    db.sentLog      = db.sentLog or {}
    db.savedGroups  = db.savedGroups or {}  -- [name] = filter spec
    db.nextPersonId = db.nextPersonId or 1
    db.nextRunId    = db.nextRunId or 1
    -- db.activeRun is left nil unless a key is genuinely in progress; it is the
    -- /reload-safe scratch record RunTracker resumes from.

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
-- Slash commands
--------------------------------------------------------------------------------

SLASH_PUGRATER1 = "/pugrater"
SLASH_PUGRATER2 = "/pr"
SlashCmdList.PUGRATER = function(msg)
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
            ns.Print("usage: /pugrater note <name> <text>")
        else
            local ok = ns.Roster.SetNoteByName(who, note)
            ns.Print(ok and ("note saved for " .. who) or ("no one known named " .. who))
        end
    else
        ns.Print("commands: |cffffff00show|r, |cffffff00history|r, |cffffff00send|r, |cffffff00options|r, |cffffff00rate|r, |cffffff00note <name> <text>|r")
    end
end
