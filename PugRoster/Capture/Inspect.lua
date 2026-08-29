-- Capture/Inspect.lua -- throttled, best-effort spec/ilvl for groupmates.
--
-- The inspect API is a single global slot: one NotifyInspect at a time, answered
-- by INSPECT_READY, and hammering it gets the request dropped. So this is a
-- queue with a fixed drain interval, and every result is treated as a bonus --
-- a run record is perfectly valid with spec and ilvl missing.

local ADDON, ns = ...

local Inspect = {}
ns.Inspect = Inspect

local INTERVAL = 2.0     -- seconds between inspect requests
local RETRY_AFTER = 8.0  -- give up on a pending request after this long

local queue, queued = {}, {}
local pending, pendingSince, pendingUnit
local ticker

-- Is the player looking at Blizzard's inspect window right now?
--
-- InspectFrame is load-on-demand -- Blizzard_InspectUI does not exist until the
-- first inspect -- so a nil frame means nobody has opened one this session and
-- there is nothing to disturb.
local function userIsInspecting()
    return InspectFrame and InspectFrame:IsShown() and true or false
end

local function unitForGUID(guid)
    if UnitGUID("player") == guid then return "player" end
    for i = 1, 4 do
        local unit = "party" .. i
        if UnitExists(unit) and UnitGUID(unit) == guid then return unit end
    end
    return nil
end

function Inspect.Queue(guid)
    guid = ns.SafeGUID(guid)
    if not guid or queued[guid] then return end
    if not ns.settings.inspectGroupmates then return end
    queued[guid] = true
    table.insert(queue, guid)
end

function Inspect.QueueGroup()
    if UnitGUID("player") then Inspect.Capture(UnitGUID("player"), "player") end
    for i = 1, 4 do
        local unit = "party" .. i
        if UnitExists(unit) then Inspect.Queue(UnitGUID(unit)) end
    end
end

-- Read whatever the client will tell us about a unit right now. For the player
-- this is exact; for others it is only populated after INSPECT_READY.
function Inspect.Capture(guid, unit)
    if not guid or not unit or not UnitExists(unit) then return nil end

    local name, realm = UnitName(unit)
    local class, classFile = UnitClass(unit)
    local info = {
        name      = ns.FullName(name, realm),
        class     = class,
        classFile = classFile,
        role      = UnitGroupRolesAssigned(unit),
    }

    if unit == "player" then
        local _, avg = GetAverageItemLevel()
        info.ilvl = avg and math.floor(avg) or nil
        local specIndex = GetSpecialization and GetSpecialization()
        if specIndex then
            local specId, specName = GetSpecializationInfo(specIndex)
            info.spec, info.specName = specId, specName
        end
    else
        if C_PaperDollInfo and C_PaperDollInfo.GetInspectItemLevel then
            local ilvl = C_PaperDollInfo.GetInspectItemLevel(unit)
            if ilvl and ilvl > 0 then info.ilvl = math.floor(ilvl) end
        end
        local specId = GetInspectSpecialization and GetInspectSpecialization(unit)
        if specId and specId > 0 then
            local _, specName = GetSpecializationInfoByID(specId)
            info.spec, info.specName = specId, specName
            -- The assigned role can be blank in a freshly-formed group; the
            -- spec knows better.
            if not info.role or info.role == "NONE" then
                local _, _, _, _, roleFromSpec = GetSpecializationInfoByID(specId)
                info.role = roleFromSpec
            end
        end
    end

    if info.role == "NONE" then info.role = nil end

    ns.Roster.TouchCharacter(guid, info)
    ns.RunTracker.UpdateObservation(guid, info)
    return info
end

local function drain()
    if pending then
        if GetTime() - pendingSince < RETRY_AFTER then return end
        pending, pendingUnit = nil, nil  -- went unanswered; move on
    end

    local guid = table.remove(queue, 1)
    if not guid then return end
    queued[guid] = nil

    -- Never while the player has Blizzard's own inspect window open. The inspect
    -- API is a single global slot: our request takes it out from under theirs,
    -- and the ClearInspectPlayer that follows releases the data their frame is
    -- drawing from -- the model stays, every item slot empties. The queue is not
    -- dropped, just not drained; whoever is in it waits until the window closes.
    if userIsInspecting() then
        if not queued[guid] then
            queued[guid] = true
            table.insert(queue, guid)
        end
        return
    end

    local unit = unitForGUID(guid)
    ns.Trace("inspect:range")
    if not unit or not CanInspect(unit) or not CheckInteractDistance(unit, 1) then
        -- Out of range or not inspectable right now. Re-queue once at the back
        -- so a groupmate who was across the room gets picked up later.
        if not queued[guid] then
            queued[guid] = true
            table.insert(queue, guid)
        end
        return
    end

    -- The unit is remembered, not just the GUID: INSPECT_READY answers with a
    -- secret GUID on Midnight, so the reply cannot be matched back by identity.
    -- One request is ever in flight, so "the unit we asked about" is enough.
    pending, pendingSince, pendingUnit = guid, GetTime(), unit
    ns.Trace("inspect:notify")
    NotifyInspect(unit)
end

function Inspect.Start()
    if ticker then return end
    ticker = C_Timer.NewTicker(INTERVAL, drain)
end

function Inspect.Stop()
    if ticker then ticker:Cancel(); ticker = nil end
    pending, pendingUnit = nil, nil
    wipe(queue)
    wipe(queued)
end

ns.OnInit(function()
    -- The event's GUID is deliberately ignored.
    --
    -- Midnight answers INSPECT_READY with a *secret* GUID, and a secret cannot be
    -- compared -- so `guid == pending` never matched, the request never resolved,
    -- and every inspect timed out in silence. That is why no groupmate ever had
    -- an item level. Details hits the same wall and simply gives up on a secret
    -- GUID, which is why its item level column reads zero.
    --
    -- We do not need the identity: exactly one request is in flight, and drain()
    -- recorded which unit it asked about.
    ns.RegisterEvent("INSPECT_READY", function()
        local guid, unit = pending, pendingUnit
        pending, pendingUnit = nil, nil

        if guid and unit and UnitExists(unit) then
            Inspect.Capture(guid, unit)
        end

        -- Only ever release a request we made. INSPECT_READY is broadcast to
        -- every listener, so this fires for Blizzard's own inspect too -- and
        -- clearing then throws away the data the player just asked for, before
        -- their frame has drawn it.
        --
        -- Checking the frame is not enough on its own: Blizzard_InspectUI is
        -- load-on-demand, so on the first inspect of a session InspectFrame does
        -- not exist yet when the reply arrives, the guard sees nothing open, and
        -- the slot is cleared out from under a window that is about to appear.
        -- `guid` is nil for anybody else's request, which is the reliable test.
        if guid and ClearInspectPlayer and not userIsInspecting() then
            ClearInspectPlayer()
        end
    end)

    -- The queue used to run only while a key was in progress, so a party
    -- member's item level was unavailable anywhere else -- including on the
    -- tooltip, which is where you actually want it.
    ns.RegisterEvent("GROUP_ROSTER_UPDATE", function()
        if IsInGroup() then
            Inspect.Start()
            Inspect.QueueGroup()
        elseif not ns.RunTracker.IsActive() then
            Inspect.Stop()
        end
    end)

    ns.RegisterEvent("PLAYER_ENTERING_WORLD", function()
        if IsInGroup() then
            Inspect.Start()
            Inspect.QueueGroup()
        end
    end)
end)
