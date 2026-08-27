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
    -- A character target is a real name, so it gets a clickable link like the
    -- live path does. A bnet target is an account id and cannot be linked.
    local who = channel == "bnet" and ("|cff9b7fd6" .. tostring(target) .. "|r")
        or ns.PlayerLink(tostring(target))
    ns.Print(string.format("|cffd9a441[echo %s]|r %s: %s",
        channel == "bnet" and "bnet" or "whisper", who, text))
    return true
end

local function echoInvite(name)
    ns.Print(string.format("|cffd9a441[echo invite]|r would invite |cff9b7fd6%s|r", tostring(name)))
    return true
end

function EchoSender.SetEnabled(on)
    if ns.db then ns.db.debugEcho = on and true or false end
    -- The master switch wins. Otherwise turning echo back on would re-arm the
    -- send seam while the addon is meant to be behaving like a released build.
    if on and not ns.Debug.IsEnabled() then
        ns.Debug.Print("debug mode is off -- echo stays off.")
        on = false
    end
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
    -- Off unless you asked for it, and remembered across sessions.
    --
    -- This used to default on, which made sense when the addon was only ever
    -- driven by simulations: nothing could reach a real player by accident. It
    -- stopped making sense the moment it was used for real -- a messaging addon
    -- whose default is "do not actually message anyone" is a messaging addon that
    -- silently does nothing, and it took a recipient saying so to notice.
    EchoSender.SetEnabled(ns.db.debugEcho == true)
end)
