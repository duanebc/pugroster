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

## 4. Defensives, via auras -- open outside keys, closed inside them

> **Closed 2026-08-30, capture removed.** The conclusion below ("defensives are
> countable") holds in normal, heroic and timewalking dungeons and is **false in
> Mythic+**:
> the client refuses the aura read outright while the challenge-mode restriction
> holds. Built, measured, and closed -- see
> [defensives-in-mythic-plus.md](defensives-in-mythic-plus.md) for the evidence
> and the four hypotheses it took to get there. The `def` column was replaced by
> `avoid` (avoidable damage taken), which is section 5 below.

**Answered 2026-08-29 by the third probe run**, and the answer changed the plan:

- `secret-id lookup: resolves, but the name is secret too`. A secret spell id can
  be handed back to the API, and what comes back is secret as well. **The cast
  route is closed for good** -- no spell list, by id or by name.
- `groupmate auras ARE readable` -- 184 readable, **0 secret**, across 2179 group
  aura events. `UNIT_AURA` sees other players' buffs when `UNIT_SPELLCAST_SUCCEEDED`
  will not tell you what they cast.

So defensives are countable: watch `UNIT_AURA` on `party1-4`, match aura spell ids
against a curated defensive list, count each application. It measures a defensive
being *active* rather than a button being pressed, which for a cooldown is the
same event and for Ironfur is arguably the better one.

Still true from the earlier analysis: Ironfur at 102 casts beside Barkskin at 3
means one number cannot hold rotational mitigation and emergency cooldowns
together. Majors only was the call.

## 5. The three unused server meters

> **`AvoidableDamageTaken` shipped 2026-08-29**, for exactly the reason this
> section predicted: it is the realistic version of the defensives feature. It
> replaced the `def` column in both the run summary and the history group table.
> `Absorbs` and `DamageTaken` remain unused.


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

## 6. Smaller, still worth doing

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
