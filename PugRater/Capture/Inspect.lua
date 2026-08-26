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
local pending, pendingSince
local ticker

local function unitForGUID(guid)
    if UnitGUID("player") == guid then return "player" end
    for i = 1, 4 do
        local unit = "party" .. i
        if UnitExists(unit) and UnitGUID(unit) == guid then return unit end
    end
    return nil
end

function Inspect.Queue(guid)
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
        pending = nil  -- request went unanswered; move on
    end

    local guid = table.remove(queue, 1)
    if not guid then return end
    queued[guid] = nil

    local unit = unitForGUID(guid)
    if not unit or not CanInspect(unit) or not CheckInteractDistance(unit, 1) then
        -- Out of range or not inspectable right now. Re-queue once at the back
        -- so a groupmate who was across the room gets picked up later.
        if not queued[guid] then
            queued[guid] = true
            table.insert(queue, guid)
        end
        return
    end

    pending, pendingSince = guid, GetTime()
    NotifyInspect(unit)
end

function Inspect.Start()
    if ticker then return end
    ticker = C_Timer.NewTicker(INTERVAL, drain)
end

function Inspect.Stop()
    if ticker then ticker:Cancel(); ticker = nil end
    pending = nil
    wipe(queue)
    wipe(queued)
end

ns.OnInit(function()
    ns.RegisterEvent("INSPECT_READY", function(guid)
        if guid and guid == pending then pending = nil end
        local unit = unitForGUID(guid)
        if unit then Inspect.Capture(guid, unit) end
        if ClearInspectPlayer then ClearInspectPlayer() end
    end)
end)
