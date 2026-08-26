-- Debug/FakeRoster.lua -- seeded persons, tags, links, saved groups and a fake
-- friends list.
--
-- Phase 4 of the plan (roster and tagging) is untestable without a populated
-- roster, and phase 6 (messaging) is untestable without someone online. This
-- provides both without touching a real player.

local ADDON, ns = ...

local FakeRoster = {}
ns.FakeRoster = FakeRoster

local NOTES = {
    "great kicks, always brings food",
    "chill, happy to run alt keys",
    "knows every route, ask before pulling",
    "pushed 3k last season",
    "went afk twice, keep an eye out",
    "learning the tank role, patient group needed",
    "voice on Discord, quick to invite",
    "left mid-key once, gave a reason",
}

local MANUAL_TAGS = { "push", "chill", "learning", "weeknights", "weekends", "voice", "Discord", "guild", "met-in-pug", "IRL friend" }

--------------------------------------------------------------------------------
-- Seeding
--------------------------------------------------------------------------------

function FakeRoster.Seed(count)
    count = math.min(math.max(count or 12, 1), 40)
    local poolChars = ns.FakeRun.Pool(24)
    local tagged, linked = 0, 0

    for i = 1, math.min(count, #poolChars) do
        local c = poolChars[i]
        ns.Roster.TouchCharacter(c.guid, {
            name = c.name, class = c.class, classFile = c.classFile,
            role = c.role, spec = c.spec, specName = c.specName,
            ilvl = c.ilvl, debug = true,
        })

        local person = ns.Roster.PersonForGUID(c.guid)
        if person then
            -- One to three manual tags each, plus a note on roughly half.
            for _ = 1, math.random(1, 3) do
                ns.Roster.AddTag(person, MANUAL_TAGS[math.random(#MANUAL_TAGS)])
                tagged = tagged + 1
            end
            if math.random() < 0.5 then
                ns.Roster.SetNote(person, NOTES[math.random(#NOTES)])
            end
            -- A couple of manual tier overrides, so the "override" source shows
            -- up in the UI alongside auto and refined.
            if math.random() < 0.12 then
                ns.Roster.SetTierOverride(person, ns.TIERS[math.random(#ns.TIERS)])
            end
            if math.random() < 0.08 then
                ns.Roster.AddTag(person, ns.DO_NOT_MESSAGE_TAG)
            end
        end
    end

    -- Give two or three people an alt, so the person/character split and the
    -- "same person as..." linking have something to act on.
    for _ = 1, 3 do
        local a = poolChars[math.random(#poolChars)]
        local b = poolChars[math.random(#poolChars)]
        if a and b and a.guid ~= b.guid then
            ns.Roster.TouchCharacter(b.guid, { name = b.name, classFile = b.classFile, debug = true })
            if ns.Roster.LinkCharacters(a.guid, b.guid) then linked = linked + 1 end
        end
    end

    -- Saved groups worth having on a fresh test database.
    ns.Filters.SaveGroup("High Key Roster", {
        match = "all",
        conditions = {
            { field = "tag",  op = "has", value = "push" },
            { field = "runs", op = ">=",  value = 2 },
        },
    })
    ns.Filters.SaveGroup("Healers I trust", {
        match = "all",
        conditions = {
            { field = "role", op = "is", value = "HEALER" },
            { field = "tier", op = "is", value = "Good" },
        },
    })
    ns.Filters.SaveGroup("Weeknight crew", {
        match = "any",
        conditions = {
            { field = "tag", op = "has", value = "weeknights" },
            { field = "tag", op = "has", value = "Discord" },
        },
    })

    ns.Rating.RecomputeAll()
    ns.Debug.Print(string.format("seeded %d people, %d tags, %d links and 3 saved groups.",
        math.min(count, #poolChars), tagged, linked))

    if not ns.Debug._onlineIndex then
        FakeRoster.SetOnline(true)
    end
end

--------------------------------------------------------------------------------
-- Fake friends list
--------------------------------------------------------------------------------

-- Marks roughly two thirds of the known simulated characters as online, half of
-- those as Battle.net friends so both send channels get exercised.
function FakeRoster.SetOnline(enabled)
    if not enabled then
        ns.Debug._onlineIndex = nil
        ns.Debug.Print("fake friends list off -- the Send tab reads the real one again.")
        if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
        return
    end

    local index = {}
    local n, bnet = 0, 0
    local accountId = 90000

    for guid, char in pairs(ns.db.characters) do
        if char.debug and char.name and math.random() < 0.66 then
            accountId = accountId + 1
            local isBNet = math.random() < 0.5
            index[char.name] = {
                online    = true,
                bnet      = isBNet and accountId or nil,
                battleTag = isBNet and (ns.ShortName(char.name) .. "#1234") or nil,
            }
            n = n + 1
            if isBNet then bnet = bnet + 1 end
        end
    end

    ns.Debug._onlineIndex = index
    ns.Debug.Print(string.format("fake friends list on: %d online (%d via Battle.net).", n, bnet))
    if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
end
