-- Messaging/Replies.lua -- reply tracking for a send batch.
--
-- Deliberately dumb, per §6 of the plan: no intent classification. We watch for
-- whispers from people we just messaged, show the text verbatim next to their
-- name, and let the human mark it yes/no and hit invite. Guessing at "is this a
-- yes?" is exactly the kind of cleverness that invites the wrong person.

local ADDON, ns = ...

local Replies = {}
ns.Replies = Replies

-- Only whispers arriving within this window of our message are treated as a
-- reply to it.
local WATCH_WINDOW = 30 * 60

-- [personId] = { since = ts, reply = { text, t }, marked = "yes"|"no"|nil }
local watching = {}

function Replies.Watch(person)
    if not person then return end
    watching[person.id] = watching[person.id] or {}
    watching[person.id].since = ns.Now()
end

function Replies.WatchBatch(entries)
    for _, entry in ipairs(entries or {}) do
        if entry.selected and not entry.blocked then Replies.Watch(entry.person) end
    end
end

function Replies.Clear()
    wipe(watching)
end

function Replies.Get(person)
    return person and watching[person.id] or nil
end

function Replies.Mark(person, verdict)
    if not person then return end
    watching[person.id] = watching[person.id] or { since = ns.Now() }
    watching[person.id].marked = verdict
    if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
end

-- Everyone we are currently watching, newest reply first.
function Replies.Active()
    local out = {}
    local now = ns.Now()
    for personId, state in pairs(watching) do
        if now - (state.since or 0) <= WATCH_WINDOW then
            local person = ns.Roster.GetPerson(personId)
            if person then out[#out + 1] = { person = person, state = state } end
        end
    end
    table.sort(out, function(a, b)
        local ta = a.state.reply and a.state.reply.t or 0
        local tb = b.state.reply and b.state.reply.t or 0
        if ta ~= tb then return ta > tb end
        return (a.person.name or "") < (b.person.name or "")
    end)
    return out
end

--------------------------------------------------------------------------------
-- Capture
--------------------------------------------------------------------------------

local function attribute(person, text)
    if not person then return false end
    local state = watching[person.id]
    if not state then return false end
    if ns.Now() - (state.since or 0) > WATCH_WINDOW then return false end

    state.reply = { text = text, t = ns.Now() }
    if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
    return true
end

-- Exposed so the debug reply simulator drives the identical path.
function Replies.Inject(personOrName, text)
    local person = personOrName
    if type(personOrName) == "string" then
        local char = ns.Roster.FindCharacterByName(personOrName)
        person = char and ns.Roster.GetPerson(char.personId)
    end
    return attribute(person, text)
end

local function onWhisper(text, senderName, _, _, _, _, _, _, _, _, _, senderGUID)
    local person
    if senderGUID then person = ns.Roster.PersonForGUID(senderGUID) end
    if not person and senderName then
        local char = ns.Roster.FindCharacterByName(senderName)
        person = char and ns.Roster.GetPerson(char.personId)
    end
    attribute(person, text)
end

local function onBNetWhisper(text, _, _, _, _, _, _, _, _, _, _, _, bnSenderID)
    if not bnSenderID then return end
    for _, char in pairs(ns.db.characters) do
        if char.bnetAccountID == bnSenderID then
            if attribute(ns.Roster.GetPerson(char.personId), text) then return end
        end
    end
end

--------------------------------------------------------------------------------
-- Invite
--------------------------------------------------------------------------------

-- `char` overrides which character is invited. The history menu needs it: you
-- are looking at one specific character in one specific run, and inviting their
-- main instead would invite somebody who is not the person on your screen -- or
-- nobody at all, since a pug you have never filed has no person to have a main.
function Replies.Invite(person, char)
    char = char or ns.Roster.MainCharacter(person)
    if not char or not char.name then return false end

    if ns.Debug and ns.Debug.EchoInvite then
        return ns.Debug.EchoInvite(char.name)
    end

    -- Outside the echo sandbox a seeded name is not a person who can be invited.
    if (person and person.debug) or char.debug then
        ns.Print(string.format("|cffff8080%s is simulated -- no invite sent.|r",
            ns.ShortName(char.name)))
        return false
    end

    if C_PartyInfo and C_PartyInfo.InviteUnit then
        C_PartyInfo.InviteUnit(char.name)
    else
        InviteUnit(char.name)
    end
    return true
end

ns.OnInit(function()
    ns.RegisterEvent("CHAT_MSG_WHISPER", onWhisper)
    ns.RegisterEvent("CHAT_MSG_BN_WHISPER", onBNetWhisper)
end)
