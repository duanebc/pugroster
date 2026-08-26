-- Debug/EchoSender.lua -- the messaging sandbox.
--
-- With echo on (the default in a dev build), Sender.dispatch routes here instead
-- of SendChatMessage/BNSendWhisper: messages print locally with the template
-- fully expanded, and the cooldown, sent-log, stagger and reply-tracking paths
-- all run exactly as they would for a real send. Nobody gets whispered.
--
-- `/pugdebug echo off` removes the interception if you deliberately want to
-- test against a real character.

local ADDON, ns = ...

local EchoSender = {}
ns.EchoSender = EchoSender

local enabled = false

local function echoSend(channel, target, text)
    ns.Print(string.format("|cffd9a441[echo %s]|r |cff9b7fd6%s|r: %s",
        channel == "bnet" and "bnet" or "whisper", tostring(target), text))
    return true
end

local function echoInvite(name)
    ns.Print(string.format("|cffd9a441[echo invite]|r would invite |cff9b7fd6%s|r", tostring(name)))
    return true
end

function EchoSender.SetEnabled(on)
    enabled = on and true or false
    -- Production code feature-detects these two functions, so removing them is
    -- what actually restores the real send path.
    ns.Debug.EchoSend   = enabled and echoSend or nil
    ns.Debug.EchoInvite = enabled and echoInvite or nil
    ns.Debug.Print("message echo", enabled and "|cff5fd68fon|r (nothing is really sent)"
                                            or "|cffff6666off|r -- sends go to real players")
end

function EchoSender.IsEnabled()
    return enabled
end

--------------------------------------------------------------------------------
-- Simulated replies
--------------------------------------------------------------------------------

function EchoSender.SimulateReply(name, text)
    if ns.Replies.Inject(name, text) then
        ns.Debug.Print(string.format("reply from %s: %s", name, text))
    else
        ns.Debug.Print(string.format(
            "%s is not being watched for replies -- send them something from the Send tab first.", name))
    end
end

ns.OnInit(function()
    EchoSender.SetEnabled(true)
end)
