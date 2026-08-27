-- PugRoster_Lookup.lua -- GENERATED FILE. Do not edit by hand.
--
-- The Python companion (`pugroster emit`) overwrites this file with refined
-- tiers, Raider.IO scores and offline-discovered person links. This checked-in
-- stub is what a fresh install ships: an empty, well-formed table, so the addon
-- behaves identically whether or not the companion has ever run.

PugRosterLookup = {
    generated  = nil,   -- unix timestamp of the companion run
    season     = nil,   -- season ID the refined tiers were computed for
    characters = {},    -- [guid] = { tier, score, rioCurrent, rioPrevious }
    links      = {},    -- { { guidA, guidB }, ... } same-person links
}
