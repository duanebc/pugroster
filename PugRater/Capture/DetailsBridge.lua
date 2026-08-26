-- Capture/DetailsBridge.lua -- optional enrichment from Details! Damage Meter.
--
-- Details is never required. Every call is feature-detected *per function*
-- rather than per addon (see Open risk 3 in the plan): Details reshuffles its
-- API between expansions, and a missing method must degrade to our own numbers
-- rather than error out mid-run.

local ADDON, ns = ...

local Bridge = {}
ns.DetailsBridge = Bridge

local function details()
    if not ns.settings or not ns.settings.useDetails then return nil end
    local d = _G.Details
    return type(d) == "table" and d or nil
end

function Bridge.IsAvailable()
    local d = details()
    return d ~= nil and type(d.GetCurrentCombat) == "function"
end

-- Returns { [name] = { damage = n, healing = n } } for the combat segment that
-- covers the current run, or nil when Details cannot answer.
--
-- Details keys its actor containers by name, not GUID, so the caller has to map
-- back onto our GUID-keyed observations.
function Bridge.GetSegmentTotals()
    local d = details()
    if not d or type(d.GetCurrentCombat) ~= "function" then return nil end

    local ok, combat = pcall(d.GetCurrentCombat, d)
    if not ok or not combat or type(combat.GetContainer) ~= "function" then return nil end

    local out = {}

    local function harvest(containerId, field)
        local ok2, container = pcall(combat.GetContainer, combat, containerId)
        if not ok2 or not container then return end
        -- Details containers expose an array of actors at [1..n]; iterate
        -- defensively in case the internal shape moved.
        for _, actor in ipairs(container._ActorTable or container) do
            if type(actor) == "table" and actor.nome and actor.grupo then
                local rec = out[actor.nome] or { damage = 0, healing = 0 }
                rec[field] = tonumber(actor.total) or 0
                out[actor.nome] = rec
            end
        end
    end

    -- 1 = damage, 2 = healing in every Details version that has shipped so far;
    -- prefer the named constants when they exist.
    local damageId  = d.atributo_damage or 1
    local healingId = d.atributo_heal or 2
    harvest(damageId, "damage")
    harvest(healingId, "healing")

    if not next(out) then return nil end
    return out
end

-- Fold Details totals into a run's observations. Our own combat-log tallies
-- stay as the fallback; Details only overwrites when it has a number for that
-- player, and we record which source won so the history panel can say so.
function Bridge.Enrich(run)
    if not run or not run.observations then return false end
    local totals = Bridge.GetSegmentTotals()
    if not totals then return false end

    local applied = false
    for _, obs in pairs(run.observations) do
        local short = ns.ShortName(obs.name)
        local rec = totals[obs.name] or totals[short]
        if rec then
            if rec.damage and rec.damage > 0 then obs.damage = rec.damage end
            if rec.healing and rec.healing > 0 then obs.healing = rec.healing end
            obs.statSource = "details"
            applied = true
        end
    end
    if applied then run.detailsEnriched = true end
    return applied
end
