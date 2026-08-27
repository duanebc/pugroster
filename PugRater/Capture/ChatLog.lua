-- Capture/ChatLog.lua -- party, instance and whisper capture during a run.
--
-- Every line is attributed by sender GUID and attached to the active run, so
-- the history panel can replay what was said alongside what happened. Whispers
-- to and from groupmates are captured too, flagged so they can be filtered or
-- pruned separately.
--
-- The companion is responsible for long-term pruning; the in-game cap here only
-- stops a single pathological run from bloating SavedVariables.

local ADDON, ns = ...

local ChatLog = {}
ns.ChatLog = ChatLog

-- Set the first time a line arrives with its text withheld. Midnight returns
-- other players' chat as a secret value: it can be passed around but not read,
-- not stored, and not written to SavedVariables. So party chat capture is simply
-- not possible on this client, and the honest thing is to say so once rather
-- than fill the history with blank rows.
--
-- Left as a runtime observation rather than a build check because the client
-- withholds some lines and not others (your own text comes through), and because
-- if Blizzard reopens it this starts working again with no code change.
ChatLog.textWithheld = false

local CHANNEL = {
    CHAT_MSG_PARTY          = "party",
    CHAT_MSG_PARTY_LEADER   = "party",
    CHAT_MSG_INSTANCE_CHAT  = "instance",
    CHAT_MSG_INSTANCE_CHAT_LEADER = "instance",
    CHAT_MSG_WHISPER        = "whisper-in",
    CHAT_MSG_WHISPER_INFORM = "whisper-out",
}

function ChatLog.Record(channel, text, senderName, senderGUID)
    local run = ns.RunTracker.Active()
    if not run or not ns.settings.captureChat then return end

    local isWhisper = channel:find("whisper", 1, true) ~= nil
    if isWhisper then
        if not ns.settings.captureWhispers then return end
        -- Only whispers with someone in the group are part of the run record.
        local safe = ns.SafeGUID(senderGUID)
        if not safe or not run.observations[safe] then return end
    end

    run.chat = run.chat or {}
    local cap = ns.settings.chatLinesPerRun or 400
    if #run.chat >= cap then
        -- Oldest-first truncation: the end of a run is usually the informative
        -- part ("sorry, have to go", "gg"), so keep the tail.
        table.remove(run.chat, 1)
        run.chatTruncated = true
    end

    if ns.IsSecret(text) then ChatLog.textWithheld = true end

    -- Midnight can hand back a secret value for any of these. A secret cannot be
    -- stored (it does not survive SavedVariables) or printed, so record the fact
    -- rather than an empty string: a line that reads "hidden by the client" is a
    -- different problem from one that was never captured, and the history panel
    -- should not have to guess which happened.
    table.insert(run.chat, {
        t       = ns.Now(),
        guid    = ns.SafeGUID(senderGUID),
        name    = ns.SafeGUID(senderName),
        channel = channel,
        text    = ns.SafeGUID(text),
        secret  = (ns.IsSecret(text) or ns.IsSecret(senderName)) or nil,
        whisper = isWhisper or nil,
    })
end

local function onChat(event, text, senderName, _, _, _, _, _, _, _, _, _, senderGUID)
    local channel = CHANNEL[event]
    if not channel then return end
    ChatLog.Record(channel, text, senderName, senderGUID)
end

-- Lines belonging to the currently-open run, newest last.
function ChatLog.ForRun(run)
    return run and run.chat or {}
end

ns.OnInit(function()
    for event in pairs(CHANNEL) do
        ns.RegisterEvent(event, function(...) onChat(event, ...) end)
    end
end)
