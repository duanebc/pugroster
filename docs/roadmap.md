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

## 7. Roster growth: bound the count, not just the bytes

**Open. Raised 2026-09-01, after the friends-list sync turned out to be the
Mythic+ frame drops.**

`Housekeeping.lua` caps the database at 5 MB and sheds captured chat, then old
records, when it goes over. On this account it has never fired: the file is
1.27 MB. Housekeeping was watching the wrong axis.

What actually bit was **count**. The roster holds **1,087 characters**, and two
friend-list passes walked all of them on every `BN_FRIEND_INFO_CHANGED` -- 28.9 ms
a call, twenty-nine calls inside one pull. Nothing was near a size limit, and
nothing a byte budget does would have prevented it. Bytes are a disk and
login-time concern; count is a per-event cost, and they are not the same problem.

That is worth confronting now rather than after the next report, because the
roster is on the "never shed" list in `Housekeeping.lua` and therefore grows
without bound, and because the growth is not mostly runs:

| | count |
|---|---|
| characters stored | 1,087 |
| of those, from the friend list | 605 |
| with a battletag recorded | 272 |
| runs recorded | 180 |

**605 of 1,087 came from the friends list**, not from anyone you have run with.
They are stubs created so a name resolves; most will never appear in a record.
About six new characters arrive per run, so this grows steadily for anyone who
pugs, and every account eventually reaches the size where an O(n) scan per event
becomes a frame drop. This account got there first because it has the history.

The indexing fix removed the immediate cost, so nothing here is urgent. The
question is whether unbounded growth is acceptable at all, and it splits three
ways:

- **Leave it and keep indexing.** The data is small in bytes and the roster is
  the point of the addon. Every hot path must then be index-first, and the next
  linear scan someone adds reintroduces the bug quietly. That is a standing
  discipline rather than a fix.
- **Retire stubs.** A `fromFriendList` character with no record, not seen in
  N months, is a name that resolved once. Dropping those halves the roster today
  and touches nothing anyone has run with. Needs a `lastSeen` that is actually
  maintained on stubs, which should be checked before relying on it.
- **Roll over the file.** Split history from roster so the working set stays
  small, or archive records past a cutoff into a second saved variable loaded on
  demand. The most work by a distance, and only worth it if bytes become a real
  problem -- at 1.27 MB against a 5 MB budget they are not.

The middle one looks right, but this is a question rather than a plan: it decides
what the addon promises about people you met once, and that is not a decision to
take from a profiler reading.

Worth doing either way: a `/pugdebug size` that reports counts alongside bytes.
The byte budget was measured and reported all along; nobody was counting rows.

## Not yet: the Python companion

The largest missing piece on paper -- it would resolve alts for players who are
not Battle.net friends, which is the one grouping the client cannot give us. But
automatic linking has just been shown to do real damage when it guesses wrong,
and the companion is a second guesser working from less information. Worth having
the naming rule bedded in and a few weeks of stable data first.
