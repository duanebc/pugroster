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
        if not senderGUID or not run.observations[senderGUID] then return end
    end

    run.chat = run.chat or {}
    local cap = ns.settings.chatLinesPerRun or 400
    if #run.chat >= cap then
        -- Oldest-first truncation: the end of a run is usually the informative
        -- part ("sorry, have to go", "gg"), so keep the tail.
        table.remove(run.chat, 1)
        run.chatTruncated = true
    end

    table.insert(run.chat, {
        t       = ns.Now(),
        guid    = senderGUID,
        name    = senderName,
        channel = channel,
        text    = text,
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
