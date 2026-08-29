# What to do next

Written 2026-08-29, from what a week of running the addon against a live Midnight
client actually turned up. Ordered by what unblocks the most.

## 1. Name a person after the character you know them by

**Status: done 2026-08-29.** See `Roster.RefreshPersonName`.

A person was named after whichever character happened to create the record and
was never renamed, so a five-alt player could be filed under the alt he last
logged in on. That produced four separate bug reports -- a roster row labelled
with a stranger's name, a search for "san" returning a row reading "Unbroken", a
join toast announcing somebody nobody recognised, and "why are all these
characters under Sanlanesh".

Each was patched at the display site. The cause was upstream, and the fix is one
rule: a person is named after the character you have run with most, recomputed
with the tiers. Placeholder names (`Person 24`) are replaced as soon as any named
character is attached.

## 2. Release v1.0.4

Everything below the fold in `CHANGELOG.md` is unreleased, including the person
merge fix and `/pr unmerge`. That repair matters to anyone else running this:
their database will have the same corruption and no way to know, and the command
that fixes it currently exists only on one machine.

## 3. Fix the CurseForge categories

Two minutes, and the highest-leverage thing outstanding. The project is approved
and browsable, filed under **Development Tools** and **Data Broker**, where
nobody looking for a Mythic+ addon will find it. The `.toc` already declares
Group Finder.

While in there: the live description predates the last three releases.
`docs/curseforge-description.md` is ready to paste, and `docs/listing-todo.md`
lists the rest (source and issues links, four more screenshots).

## 4. The three unused server meters

`Enum.DamageMeterType` exposes eleven meters and the addon consumes five. The
defensive-cooldown probe found `Absorbs`, `DamageTaken` and
`AvoidableDamageTaken` unused and **returning five sources in a real dungeon** --
server-authoritative, no secrets, no spell list to maintain.

This is the realistic version of the defensives feature. Counting cooldown presses
is a dead end: `UNIT_SPELLCAST_SUCCEEDED` fires for party members but every
groupmate spell ID comes back secret (246 of 246 in the recorded run), so a spell
list can only ever count your own. `AvoidableDamageTaken` arguably answers the
underlying question -- did this player look after themselves -- better than a
button count would.

They drop into the `METERS` table in `Capture/DetailsBridge.lua` beside the five
already there. See `docs/defensive-probe.html` for the evidence.

## 5. Smaller, still worth doing

- **Audit for the secret-comparison pattern.** `x == ""` evaluated before
  `ns.IsSecret(x)` raises rather than returning false, and it silently emptied
  every Mythic+ run for a day. Four sites were fixed by following one traceback;
  nobody has looked for the rest.
- **`ns.FullName` substitutes your own realm** when the friends list withholds a
  friend's. That was half of what caused the person merge. It is still used by
  `Roster.OnlineIndex`, where a bad match mislabels online status rather than
  merging records -- less harmful, still wrong.
- **One NPC person record** remains in the roster (`Valeera Sanguinar`), left
  over from before creature GUIDs were guarded out.
- **`Sender.SendTo` has no callers.** Either wire it up or delete it.

## Not yet: the Python companion

The largest missing piece on paper -- it would resolve alts for players who are
not Battle.net friends, which is the one grouping the client cannot give us. But
automatic linking has just been shown to do real damage when it guesses wrong,
and the companion is a second guesser working from less information. Worth having
the naming rule bedded in and a few weeks of stable data first.
