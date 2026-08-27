-- Housekeeping.lua -- the ceiling on how much of your disk this addon takes.
--
-- SavedVariables is read and written whole at every login and logout, so the size
-- of this database is a login delay and, past a point, a file that fails to write.
-- The per-record caps in RunTracker and FightTracker bound the *shape* of the
-- data; this bounds its size, which is the only thing that actually guarantees
-- anything.
--
-- It lives in one file rather than split across the two trackers because the
-- decision is between them: which store gives something up is the whole question.
--
-- With pull-by-pull detail no longer saved this should essentially never fire.
-- That is the point of a backstop.

local ADDON, ns = ...

local Housekeeping = {}
ns.Housekeeping = Housekeeping

local MB = 1048576

--------------------------------------------------------------------------------
-- What may be given up, in order
--
-- Never: an unexported key (the in-game store is a capture buffer -- losing one
-- loses it for good), the roster, tags, templates and saved groups. Those are
-- small, and they are the point of the addon.
--------------------------------------------------------------------------------

local steps = {
    {
        name = "captured chat",
        -- Mostly unreadable on this client anyway; see Capture/ChatLog.lua.
        run = function(deficit)
            local freed, touched = 0, 0
            for _, store in ipairs({ ns.db.runs, ns.db.fights }) do
                for _, record in ipairs(store or {}) do
                    if freed >= deficit then break end
                    if record.chat and #record.chat > 0 then
                        freed = freed + ns.MeasureBytes(record.chat)
                        record.chat = nil
                        record.chatDropped = true
                        touched = touched + 1
                    end
                end
            end
            return freed, touched > 0 and (touched .. " chat logs") or nil
        end,
    },
    {
        name = "old fights",
        run = function(deficit)
            local freed, removed = 0, 0
            local fights = ns.db.fights or {}
            while #fights > 0 and freed < deficit do
                freed = freed + ns.MeasureBytes(fights[1])
                table.remove(fights, 1)
                removed = removed + 1
            end
            return freed, removed > 0 and (removed .. " old fights") or nil
        end,
    },
    {
        name = "old exported keys",
        run = function(deficit)
            local freed, removed = 0, 0
            local runs = ns.db.runs or {}
            while #runs > 0 and freed < deficit do
                -- Stop at the first key the companion has not seen. Everything
                -- older than it has already been exported, so nothing beyond this
                -- point is safe to drop either.
                if not runs[1].exported then break end
                freed = freed + ns.MeasureBytes(runs[1])
                table.remove(runs, 1)
                removed = removed + 1
            end
            return freed, removed > 0 and (removed .. " old keys") or nil
        end,
    },
}

--------------------------------------------------------------------------------

function Housekeeping.Budget()
    return math.floor((tonumber(ns.settings.maxStorageMB) or 5) * MB)
end

-- Bring the database under budget. Returns the bytes freed, or 0.
function Housekeeping.Enforce()
    local budget = Housekeeping.Budget()
    if budget <= 0 then return 0 end

    local before = ns.MeasureBytes(ns.db)
    if before <= budget then return 0 end

    -- Each candidate is costed on its own subtree, so the ladder sheds until the
    -- deficit is covered rather than re-walking the whole database per item.
    local deficit = before - budget
    local freed, gave = 0, {}

    for _, step in ipairs(steps) do
        if freed >= deficit then break end
        local ok, stepFreed, what = pcall(step.run, deficit - freed)
        if ok and stepFreed then
            freed = freed + stepFreed
            if what then gave[#gave + 1] = what end
        end
    end

    if freed <= 0 then return 0 end

    local after = ns.MeasureBytes(ns.db)
    ns.Print(string.format(
        "over the %d MB limit -- dropped %s (now %.1f MB).",
        math.floor(budget / MB),
        #gave > 0 and table.concat(gave, " and ") or "old records",
        after / MB))

    if after > budget then
        ns.Print("|cffd9a441still over the limit|r -- what is left is protected"
            .. " (unexported keys and the roster). Raise the limit in Options, or"
            .. " delete records from History.")
    end

    if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
    return freed
end

ns.OnInit(function()
    -- Once at login, for a database that grew under older settings.
    C_Timer.After(10, function() pcall(Housekeeping.Enforce) end)
end)
