-- Rating/Provisional.lua -- the in-game tier computation.
--
-- Cheap, pure-Lua, local-data-only. Recomputed after every run and on demand.
-- The companion app does the same job with the full SQLite history plus RIO
-- data and ships a refined tier back; Roster.EffectiveTier prefers that when it
-- exists. Everything here must stay explainable -- /pugdebug tier <name> and the
-- roster tooltip both render the breakdown this file produces.
--
-- Shape of the model, per §4 of the plan:
--   * outcome dominates (timed / upgrade level / completion),
--   * per-player stats adjust within the outcome band,
--   * contribution scales with key level,
--   * deaths weigh heavier on tank/healer, damage share matters more for DPS,
--   * older seasons decay,
--   * a small sample cannot leave Neutral.

local ADDON, ns = ...

local Rating = {}
ns.Rating = Rating

--------------------------------------------------------------------------------
-- Tunables. Deliberately named and grouped so they can be lifted into settings
-- (or matched by the companion) without hunting through the math.
--------------------------------------------------------------------------------

local OUTCOME = {
    upgrade3    =  1.60,
    upgrade2    =  1.25,
    upgrade1    =  0.90,
    timed       =  0.80,  -- timed but no upgrade level reported
    overtime    =  0.15,  -- completed, depleted
    abandoned   = -0.90,  -- run ended without completion
    disband     = -0.40,  -- group-wide disband: everyone shares the blame
}

local LEFT_EARLY_PENALTY = -1.40

local ROLE_DEATH_WEIGHT = { TANK = 1.4, HEALER = 1.4, DAMAGER = 1.0 }

local ADJUST = {
    deathPerExcess   = -0.12,  -- per death above the group average
    deathCap         =  0.45,  -- absolute cap on the death adjustment
    interruptPer     =  0.06,
    interruptCap     =  0.30,
    dispelPer        =  0.05,
    dispelCap        =  0.20,
    damageShareScale =  0.60,  -- applied to (share - fair share) / fair share
    damageShareCap   =  0.30,
    healShareScale   =  0.30,
    healShareCap     =  0.15,
}

local TIER_CUT = {
    great   =  0.95,
    good    =  0.45,
    avoid   = -0.35,
}

-- A single very bad run (left early on a high key) can land someone in Avoid
-- before the normal sample gate is met.
local AVOID_IMMEDIATE = -0.80

--------------------------------------------------------------------------------
-- Season handling
--------------------------------------------------------------------------------

function Rating.CurrentSeason()
    if C_MythicPlus and C_MythicPlus.GetCurrentSeason then
        local s = C_MythicPlus.GetCurrentSeason()
        if s and s > 0 then return s end
    end
    return ns.db and ns.db.lastKnownSeason or 0
end

local function seasonDecay(run)
    local current = Rating.CurrentSeason()
    local season = run.seasonID or current
    if current <= 0 or season >= current then return 1.0 end
    if season == current - 1 then return ns.settings.seasonDecay end
    return ns.settings.olderDecay
end

-- Key level relative to a "meaningful range": a +2 barely counts, a +20 counts
-- double. Linear between, clamped at both ends.
local function keyScale(level)
    return ns.Clamp(0.4 + (level or 0) / 20, 0.4, 2.0)
end

--------------------------------------------------------------------------------
-- Per-run scoring
--------------------------------------------------------------------------------

local function outcomeScore(run)
    if run.disband then return OUTCOME.disband end
    if run.abandoned or not run.completed then return OUTCOME.abandoned end
    if not run.timed then return OUTCOME.overtime end
    local up = run.upgrade or 1
    if up >= 3 then return OUTCOME.upgrade3 end
    if up == 2 then return OUTCOME.upgrade2 end
    if up == 1 then return OUTCOME.upgrade1 end
    return OUTCOME.timed
end

-- Group means, computed once per run rather than once per observation.
local function groupStats(run)
    local n, deaths, interrupts, dispels, damage, healing = 0, 0, 0, 0, 0, 0
    local dpsCount = 0
    for _, obs in pairs(run.observations or {}) do
        n = n + 1
        deaths     = deaths + (obs.deaths or 0)
        interrupts = interrupts + (obs.interrupts or 0)
        dispels    = dispels + (obs.dispels or 0)
        damage     = damage + (obs.damage or 0)
        healing    = healing + (obs.healing or 0)
        if (obs.role or "DAMAGER") == "DAMAGER" then dpsCount = dpsCount + 1 end
    end
    if n == 0 then return nil end
    return {
        count       = n,
        avgDeaths   = deaths / n,
        avgKicks    = interrupts / n,
        avgDispels  = dispels / n,
        totalDamage = damage,
        totalHealing = healing,
        dpsCount    = math.max(1, dpsCount),
    }
end

local function capped(value, cap)
    return ns.Clamp(value, -cap, cap)
end

-- Returns score plus the list of contributions, so the UI can show its work.
function Rating.ScoreObservation(run, obs, stats)
    stats = stats or groupStats(run)
    local parts = {}
    local base = outcomeScore(run)

    local label
    if run.disband then label = "group disbanded"
    elseif run.abandoned or not run.completed then label = "run abandoned"
    elseif not run.timed then label = "completed over time"
    else label = string.format("timed +%d", run.upgrade or 1) end
    parts[#parts + 1] = { label = label, value = base }

    local total = base

    if obs.leftEarly and not run.disband then
        total = total + LEFT_EARLY_PENALTY
        parts[#parts + 1] = { label = "left early", value = LEFT_EARLY_PENALTY }
    end

    if stats then
        local role = obs.role or "DAMAGER"

        local excess = (obs.deaths or 0) - stats.avgDeaths
        local deathAdj = capped(excess * ADJUST.deathPerExcess * (ROLE_DEATH_WEIGHT[role] or 1.0), ADJUST.deathCap)
        if math.abs(deathAdj) > 0.005 then
            total = total + deathAdj
            parts[#parts + 1] = { label = string.format("deaths %d (group avg %.1f)", obs.deaths or 0, stats.avgDeaths), value = deathAdj }
        end

        local kickAdj = capped(((obs.interrupts or 0) - stats.avgKicks) * ADJUST.interruptPer, ADJUST.interruptCap)
        if math.abs(kickAdj) > 0.005 then
            total = total + kickAdj
            parts[#parts + 1] = { label = string.format("interrupts %d (group avg %.1f)", obs.interrupts or 0, stats.avgKicks), value = kickAdj }
        end

        local dispelAdj = capped(((obs.dispels or 0) - stats.avgDispels) * ADJUST.dispelPer, ADJUST.dispelCap)
        if math.abs(dispelAdj) > 0.005 then
            total = total + dispelAdj
            parts[#parts + 1] = { label = string.format("dispels %d", obs.dispels or 0), value = dispelAdj }
        end

        if role == "DAMAGER" and stats.totalDamage > 0 and (obs.damage or 0) > 0 then
            local fair = 1 / stats.dpsCount
            local share = obs.damage / stats.totalDamage
            local adj = capped(((share - fair) / fair) * ADJUST.damageShareScale, ADJUST.damageShareCap)
            total = total + adj
            parts[#parts + 1] = { label = string.format("damage share %.0f%% (fair %.0f%%)", share * 100, fair * 100), value = adj }
        elseif role == "HEALER" and stats.totalHealing > 0 and (obs.healing or 0) > 0 then
            local share = obs.healing / stats.totalHealing
            local adj = capped((share - 0.8) * ADJUST.healShareScale, ADJUST.healShareCap)
            total = total + adj
            parts[#parts + 1] = { label = string.format("healing share %.0f%%", share * 100), value = adj }
        end
    end

    return total, parts
end

--------------------------------------------------------------------------------
-- Aggregation
--------------------------------------------------------------------------------

-- Walks every run once and returns { [guid] = aggregate }.
local function aggregate()
    local out = {}

    for _, run in ipairs(ns.db.runs) do
        local stats = groupStats(run)
        local weightBase = keyScale(run.keyLevel) * seasonDecay(run)

        for guid, obs in pairs(run.observations or {}) do
            local agg = out[guid]
            if not agg then
                agg = {
                    guid = guid, runs = 0, weighted = 0, weight = 0,
                    deaths = 0, interrupts = 0, dispels = 0, cc = 0,
                    timed = 0, abandoned = 0, leftEarly = 0,
                    bestKey = 0, lastSeen = 0,
                }
                out[guid] = agg
            end

            local score = Rating.ScoreObservation(run, obs, stats)
            agg.runs       = agg.runs + 1
            agg.weighted   = agg.weighted + score * weightBase
            agg.weight     = agg.weight + weightBase
            agg.deaths     = agg.deaths + (obs.deaths or 0)
            agg.interrupts = agg.interrupts + (obs.interrupts or 0)
            agg.dispels    = agg.dispels + (obs.dispels or 0)
            agg.cc         = agg.cc + (obs.ccCasts or 0)
            if run.timed then agg.timed = agg.timed + 1 end
            if run.abandoned or run.disband then agg.abandoned = agg.abandoned + 1 end
            if obs.leftEarly then agg.leftEarly = agg.leftEarly + 1 end
            if (run.keyLevel or 0) > agg.bestKey then agg.bestKey = run.keyLevel end
            if (run.endedAt or run.startedAt or 0) > agg.lastSeen then
                agg.lastSeen = run.endedAt or run.startedAt
            end
        end
    end

    for _, agg in pairs(out) do
        agg.score = agg.weight > 0 and (agg.weighted / agg.weight) or 0
    end
    return out
end

function Rating.TierForScore(score, runs)
    local minRuns = ns.settings.minRunsForTier or 2

    if score <= AVOID_IMMEDIATE then return "Avoid" end
    if runs < minRuns then return "Neutral" end

    if score >= TIER_CUT.great and runs >= minRuns + 1 then return "Great" end
    if score >= TIER_CUT.good then return "Good" end
    if score <= TIER_CUT.avoid then return "Avoid" end
    return "Neutral"
end

-- Recompute every character's provisional tier from the local run history.
-- Returns the number of characters touched.
function Rating.RecomputeAll()
    local aggs = aggregate()
    local touched = 0

    for guid, agg in pairs(aggs) do
        local char = ns.Roster.EnsureCharacter(guid)
        if char then
            char.runs     = agg.runs
            char.score    = ns.Round(agg.score, 3)
            char.autoTier = Rating.TierForScore(agg.score, agg.runs)
            char.agg      = {
                deaths = agg.deaths, interrupts = agg.interrupts, dispels = agg.dispels,
                cc = agg.cc, timed = agg.timed, abandoned = agg.abandoned,
                leftEarly = agg.leftEarly, bestKey = agg.bestKey,
            }
            -- Trust the runs over the stored value. Existing databases carry a
            -- lastSeen that the old rating pass flattened to "now" on every
            -- recompute, so raising-only would preserve the wrong number for
            -- good; the newest run a character appears in is the honest answer.
            if agg.lastSeen and agg.lastSeen > 0 then
                char.lastSeen = agg.lastSeen
            end
            touched = touched + 1
        end
    end

    ns.db.lastRated = ns.Now()
    if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
    return touched
end

--------------------------------------------------------------------------------
-- Explainability
--------------------------------------------------------------------------------

-- Per-run breakdown for one character: what each run contributed and why.
-- Returns { score, runs, lines = { {text, value} } }.
function Rating.Breakdown(guid)
    local result = { score = 0, runs = 0, lines = {} }
    local totalWeighted, totalWeight = 0, 0

    for _, run in ipairs(ns.db.runs) do
        local obs = run.observations and run.observations[guid]
        if obs then
            local stats = groupStats(run)
            local score, parts = Rating.ScoreObservation(run, obs, stats)
            local decay = seasonDecay(run)
            local weight = keyScale(run.keyLevel) * decay

            totalWeighted = totalWeighted + score * weight
            totalWeight = totalWeight + weight
            result.runs = result.runs + 1

            table.insert(result.lines, {
                header = string.format("%s +%d  (%s)", run.dungeon or "?", run.keyLevel or 0, ns.FormatDate(run.endedAt or run.startedAt)),
                value  = score,
                weight = weight,
                decay  = decay,
                parts  = parts,
            })
        end
    end

    result.score = totalWeight > 0 and (totalWeighted / totalWeight) or 0
    result.tier = Rating.TierForScore(result.score, result.runs)
    result.weight = totalWeight
    return result
end
