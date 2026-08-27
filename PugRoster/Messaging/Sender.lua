-- Messaging/Sender.lua -- recipient resolution, guardrails and the send queue.
--
-- Nothing here ever sends without an explicit confirm from the send panel, and
-- every send is staggered: whispering five people in the same frame is exactly
-- what the server-side squelch is looking for.
--
-- Guardrails, all enforced here rather than in the UI so a manual send from the
-- roster panel obeys them too:
--   * the do-not-message tag blocks outright,
--   * a per-person cooldown blocks re-messaging within N seconds,
--   * offline people are not recipients (by design -- whispers need a target),
--   * in debug builds the whole send path is swapped for a local echo.

local ADDON, ns = ...

local Sender = {}
ns.Sender = Sender

--------------------------------------------------------------------------------
-- Guardrails
--------------------------------------------------------------------------------

function Sender.CooldownRemaining(person)
    if not person or not person.lastMessaged then return 0 end
    local window = ns.settings.messageCooldownSeconds or 300
    local remaining = (person.lastMessaged + window) - ns.Now()
    return remaining > 0 and remaining or 0
end

-- Returns blockedReason or nil.
function Sender.BlockReason(person)
    if not person then return "unknown person" end
    -- Seeded people are not real characters. Echo mode is the sandbox where
    -- messaging them is the whole point; anywhere else, refuse -- whispering or
    -- inviting a name that does not exist is the failure mode the flag exists
    -- to prevent. A release build has no way to create these, so this only ever
    -- fires on leftovers from a dev database.
    if person.debug and not (ns.Debug and ns.Debug.EchoSend) then
        return "simulated (test data)"
    end
    if ns.Roster.IsDoNotMessage(person) then return "do-not-message" end
    local cd = Sender.CooldownRemaining(person)
    if cd > 0 then
        -- Time remaining is the actionable half: "messaged 4m ago" alone reads
        -- like a note when it is actually a 12-hour lockout.
        return string.format("messaged %s, %s left",
            ns.TimeAgo(person.lastMessaged), ns.Span(cd))
    end
    return nil
end

-- Forget that we ever messaged someone. The cooldown is a courtesy guard, not a
-- rule, and the whole point of a guard is that you can lift it deliberately.
function Sender.ClearCooldown(person)
    if not person or not person.lastMessaged then return false end
    person.lastMessaged = nil
    return true
end

--------------------------------------------------------------------------------
-- Recipients
--
-- One entry per online person matching the filter:
--   { person, character, online, blocked, selected, message }
-- Blocked entries stay in the list, greyed out with their reason, rather than
-- vanishing -- silently dropping people is how you end up not understanding why
-- a send went to three of eight.
--------------------------------------------------------------------------------

function Sender.BuildRecipients(filter, templateText)
    local senderCtx = ns.Templates.SenderContext()
    local out = {}

    for _, match in ipairs(ns.Filters.OnlineMatches(filter)) do
        local person, char = match.person, match.character
        local blocked = Sender.BlockReason(person)
        out[#out + 1] = {
            person    = person,
            character = char,
            online    = match.online,
            blocked   = blocked,
            -- Nothing is selected by default. A send goes to real people, so
            -- the safe starting point is an empty selection you add to, not a
            -- full one you have to remember to trim.
            selected  = false,
            message   = ns.Templates.Expand(templateText or "",
                            ns.Templates.RecipientContext(person, char), senderCtx),
        }
    end

    return out
end

--------------------------------------------------------------------------------
-- Channel
--------------------------------------------------------------------------------

-- BNet whispers reach the person on any character or game, so they are the
-- better channel when we know the account.
local function chooseChannel(entry)
    local bnet = entry.online and entry.online.bnet
    if bnet and ns.settings.preferBNet then
        return "bnet", bnet
    end
    return "whisper", entry.character and entry.character.name or entry.person.name
end

local function dispatch(channel, target, text)
    -- Debug builds intercept here: EchoSender prints locally and can fake a
    -- reply, so the whole queue/cooldown/sent-log path is exercised without
    -- whispering a real player.
    if ns.Debug and ns.Debug.EchoSend then
        return ns.Debug.EchoSend(channel, target, text)
    end

    if channel == "bnet" then
        BNSendWhisper(target, text)
    else
        SendChatMessage(text, "WHISPER", nil, target)
    end
    return true
end

--------------------------------------------------------------------------------
-- Sent log
--------------------------------------------------------------------------------

local function echoingNow()
    return ns.Debug and ns.Debug.EchoSend and true or false
end

local function recordSend(entry, channel, target, text)
    local person = entry.person
    person.lastMessaged = ns.Now()
    person.sentLog = person.sentLog or {}

    local record = {
        t         = ns.Now(),
        personId  = person.id,
        guid      = entry.character and entry.character.guid,
        name      = entry.character and entry.character.name or person.name,
        channel   = channel,
        target    = tostring(target),
        text      = text,
        -- Test data, either because the recipient is seeded or because the send
        -- was echoed rather than actually sent. Either way the companion must
        -- not import it.
        debug     = (person.debug or (ns.Debug and ns.Debug.EchoSend)) and true or nil,
    }

    table.insert(person.sentLog, record)
    table.insert(ns.db.sentLog, record)

    -- Notify with a clickable name. A send from the Send tab otherwise leaves no
    -- trace in chat, and the moment you most want to whisper someone is right
    -- after you have just messaged them.
    ns.Print("messaged", ns.PlayerLink(record.name),
        echoingNow() and "|cffd9a441(echo -- not really sent)|r" or "")

    -- Both logs are a convenience view of what you just did, not an archive, so
    -- they are bounded by the same setting rather than a hardcoded 500.
    local keep = math.max(1, tonumber(ns.settings.maxSentLog) or 20)
    while #ns.db.sentLog > keep do table.remove(ns.db.sentLog, 1) end
    while #person.sentLog > keep do table.remove(person.sentLog, 1) end
end

function Sender.SentLog(person)
    if person then return person.sentLog or {} end
    return ns.db.sentLog
end

--------------------------------------------------------------------------------
-- Queue
--------------------------------------------------------------------------------

local queue = {}
local running = false
local onProgress

local function step()
    local entry = table.remove(queue, 1)
    if not entry then
        running = false
        if onProgress then onProgress("done", nil, 0) end
        if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
        return
    end

    -- Re-check at send time: a cooldown may have been set by an earlier entry in
    -- this very batch (two characters, same person).
    local blocked = Sender.BlockReason(entry.person)
    if blocked then
        if onProgress then onProgress("skipped", entry, #queue) end
    else
        local channel, target = chooseChannel(entry)
        local ok = dispatch(channel, target, entry.message)
        if ok then
            recordSend(entry, channel, target, entry.message)
            if onProgress then onProgress("sent", entry, #queue) end
        else
            if onProgress then onProgress("failed", entry, #queue) end
        end
    end

    if #queue > 0 then
        C_Timer.After(ns.settings.sendStagger or 1.5, step)
    else
        running = false
        if onProgress then onProgress("done", nil, 0) end
        if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
    end
end

function Sender.IsSending()
    return running
end

function Sender.Pending()
    return #queue
end

function Sender.Cancel()
    wipe(queue)
    running = false
end

-- Queue every selected, unblocked entry. Returns how many were queued.
function Sender.SendBatch(entries, progressCallback)
    if running then return 0, "a send is already in progress" end

    local queued = 0
    for _, entry in ipairs(entries or {}) do
        if entry.selected and not entry.blocked and (entry.message or "") ~= "" then
            table.insert(queue, entry)
            queued = queued + 1
        end
    end

    if queued == 0 then return 0, "no eligible recipients" end

    onProgress = progressCallback
    running = true
    ns.Replies.WatchBatch(entries)
    step()
    return queued
end

-- One-off send from the roster panel. Obeys the same guardrails.
function Sender.SendTo(person, text)
    if not person then return false, "unknown person" end
    local blocked = Sender.BlockReason(person)
    if blocked then return false, blocked end

    local index = ns.Roster.OnlineIndex()
    for guid in pairs(person.characters) do
        local char = ns.Roster.GetCharacter(guid)
        local info = char and char.name and index[char.name]
        if info then
            local entry = { person = person, character = char, online = info }
            local channel, target = chooseChannel(entry)
            local message = ns.Templates.Expand(text, ns.Templates.RecipientContext(person, char),
                                                ns.Templates.SenderContext())
            if dispatch(channel, target, message) then
                recordSend(entry, channel, target, message)
                ns.Replies.Watch(person)
                return true
            end
            return false, "send failed"
        end
    end
    return false, "offline"
end
