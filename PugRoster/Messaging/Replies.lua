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

-- nil for anything the client withheld, the value itself otherwise. The same
-- idea as ns.SafeGUID, which is named for the one type it started with; every
-- value in a chat event's payload needs it, not just the GUID.
--
-- It has to run before the value is used at all. A secret tolerates a truthiness
-- test and raises on a comparison, so `if senderGUID then` passes and the lookup
-- underneath it does not -- which is exactly how the Battle.net handler below
-- shipped broken.
local function usable(value)
    if value == nil or ns.IsSecret(value) then return nil end
    return value
end

local function onWhisper(text, senderName, _, _, _, _, _, _, _, _, _, senderGUID)
    local guid, name = usable(senderGUID), usable(senderName)
    local person
    if guid then person = ns.Roster.PersonForGUID(guid) end
    if not person and name then
        local char = ns.Roster.FindCharacterByName(name)
        person = char and ns.Roster.GetPerson(char.personId)
    end
    attribute(person, text)
end

-- Runs on the *receiving* client, which is why this was never seen here: the
-- sender's client does not fire it. A user reported
--
--   Messaging/Replies.lua:104: Attempt to compare local 'bnSenderID'
--
-- once per Battle.net whisper they received. Both sides of the comparison are
-- now checked -- the id from the payload, and the one on each character, since
-- either can be withheld and it is the comparison that raises, not the read.
local function onBNetWhisper(text, _, _, _, _, _, _, _, _, _, _, _, bnSenderID)
    local sender = usable(bnSenderID)
    if not sender then return end
    for _, char in pairs(ns.db.characters) do
        local id = usable(char.bnetAccountID)
        if id and id == sender then
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
