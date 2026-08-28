# PugRoster

> **You timed a +12 on Tuesday with a warrior who kicked everything and a healer
> who never let the tank drop. By Thursday you cannot remember either name.**

PugRoster remembers. It records every Mythic+ run you do, rates the four people
you ran it with on what actually happened in the key, and files them into a
roster you can tag, filter and message. The next time you are short a healer, you
are inviting somebody *you* had a good run with -- not the highest number on a
list a website computed.

A roster built out of your own runs. That is the whole idea.

---

## Captures every key, automatically

You do not have to press anything. From the moment the key starts to the moment
it completes, PugRoster writes down:

- **The run** -- dungeon, key level, affixes, elapsed against par, timer result
  and upgrade level.
- **All five of you** -- deaths, wipes, interrupts, dispels, crowd control,
  damage, healing, item level, spec, role, and whether anyone left early.
- **The conversation** -- party, instance and whisper chat, kept with the run.

Abandons, disbands and key resets are recorded as their own outcomes rather than
lumped in as failures. The in-progress run is written to disk as it happens, so a
`/reload` in the middle of a key resumes exactly where it was.

**And everything else you do.** Raids, heroics, delves, PvP, open-world pulls,
target dummies -- anything lasting more than five seconds gets a history row,
classified by content type, with per-pull detail named by boss. Those live
separately from your keys, so a raid wipe or an afternoon on a training dummy can
never move somebody's Mythic+ rating.

---

## Rates them on what happened, and shows its working

Outcome dominates. Timed, upgrade level, completion -- that sets the band.
Individual performance adjusts *within* it, so nobody parses their way out of a
bricked key, and nobody is punished for a clean +2 that went slowly.

Inside that band the numbers are weighted the way the game actually works:

| The rating accounts for | Because |
| --- | --- |
| Key level | A death at +18 is not a death at +5 |
| Role | A tank or healer death costs the group more than a DPS death |
| Season age | Last season's form decays rather than counting forever |
| Sample size | Two runs together before anyone can leave **Neutral** |

Four tiers: **Great**, **Good**, **Neutral**, **Avoid**.

Every one of them is explainable. The roster panel breaks a tier down run by run,
and `/pugdebug tier <name>` prints the full arithmetic, weight by weight. You are
never left staring at a number wondering where it came from -- which is exactly
the problem with inviting off somebody else's score.

---

## A roster of people, not a list of names

**Characters link under a person.** The rogue you met last week and the alt he
brings tonight are the same player, and PugRoster knows it. Battle.net friends
link themselves wherever the friends list exposes the mapping; anyone else can be
linked by hand in two clicks.

**And unlinked when it gets it wrong.** **Unlink main** detaches a single
character. If a person has collected characters that are not theirs at all,
`/pr unmerge` splits every person back apart by Battle.net account -- that ID
comes from the server, so it is the one grouping that cannot be mistaken. It
discards hand-made links along with the bad ones, because after the fact there is
no way to tell them apart.

**Your friends list is already in there.** Everyone on it is imported and tagged
`existing_friend`, because the people you already know are precisely the ones
worth bringing along -- and a roster made only of strangers would have been
missing them.

**Tag people the way you actually think about them.** Relationship, play style,
availability, voice, or any category you invent. Alongside those, PugRoster
derives tags that stay current on their own: role, spec, item level bracket,
Raider.IO bracket, computed tier.

**Then search across all of it.** The filter builder combines both kinds:

```
role = healer  AND  ilvl >= 640  AND  tag = push
```

Save any filter as a named group and it is one click from then on. Or when you
just want one person, type their name in the search box -- it matches their alts
too, so you find them under whichever character you remember.

Names carry their realm everywhere they appear, because two pugs called
Landairsea on different realms is a normal thing to have in a roster.

**Every session together is counted, but only keys are rated.** The Runs column
reads `2 +3`: two keystone runs together, and three other times you grouped up --
normal dungeons, delves, raids. Only the first number can move somebody's tier,
because a heroic dungeon has no business rating a Mythic+ player. But somebody
you have run three dungeons with should not read as a stranger either, so both
numbers are there.

---

## Message the whole group at once

Pick a saved group -- or a filter you just built, without having to save it
first. PugRoster shows you **the exact message every single recipient will get**,
fully expanded, before anything is sent. Untick anyone you have changed your mind
about. Then send, with a configurable stagger between whispers.

Templates expand as you would expect:

```
{name} {key} {dungeon} {mykeylevel} {tier} {runs} {me}
```

A template can also carry the key it is recruiting *for* -- pick a dungeon and a
level, and write `{keylevel} {keydungeon}`. That stays separate from the keystone
actually sitting in your bags, so one line can say both:

```
I have {key}, want to run your {keyname}?
  ->  I have +12 Halls of Atonement, want to run your +15 Dawnbreaker?
```

Battle.net whisper when the account is known, character whisper otherwise. The
send prints a clickable name in chat, because the moment you most want to whisper
somebody is right after you have just messaged them.

### It will not embarrass you

A messaging addon has to be trustworthy before it is useful. So:

- **Nothing is selected by default.** You add recipients; you never have to
  remember to remove them.
- **Nothing sends on its own.** There is no automatic messaging in PugRoster. No
  auto-reply, no auto-invite, no background whispering. Every message is one you
  pressed a button for.
- **Cooldowns are enforced in the send path**, not in the UI -- so a manual
  whisper from the roster obeys them too. Five minutes by default, configurable,
  with a `do-not-message` tag for people who would rather you did not.
- **People who are busy are left out.** Anyone in a dungeon, raid or battleground
  is dropped from the list before you see it.
- **Echo mode is loud about being on.** It prints messages locally instead of
  sending them; while it is active the summary reads ECHO MODE, the button reads
  "Echo to 6" rather than "Send to 6", and the result says plainly that nothing
  was really sent. It is off by default.

Replies come back verbatim next to each name, with a one-click invite. No
guessing at who said yes.

---

## Where you need it

- **Player tooltips** carry tier, runs together, tags, note, item level, and both
  this season's and last season's Raider.IO score.
- **A colour badge on group-finder applicants**, so you know who is applying
  before you read the name. Drawn as an addon-owned overlay -- it does not hook,
  wrap or write to a single Blizzard frame.
- **A dismissible toast** when somebody you have rated joins your group.
- **Run history** with dps and hps computed over *combat time* rather than wall
  clock, because the minutes spent walking between packs were not minutes anyone
  was doing damage in.

---

## Commands

| Command | What it does |
| --- | --- |
| `/pugroster` or `/pr` | open the roster |
| `/pr history` | run history browser |
| `/pr send` | messaging panel |
| `/pr options` | settings, tags, data tools |
| `/pr rate` | recompute tiers now |
| `/pr note <name> <text>` | quick note without opening the UI |
| `/pr unmerge` | split persons back apart by Battle.net account, when linking has gone wrong |

---

## Questions you might reasonably have

**Does this replace Raider.IO?**
No, and it does not try to. Raider.IO tells you how somebody performs against the
whole playerbase. PugRoster tells you how they went *with you*. Run both --
PugRoster reads Raider.IO's scores when it is installed and shows them alongside
its own tiers, and it deliberately does not duplicate the Raider.IO tooltip.

**Does it work on Midnight?**
Yes, with one honest caveat. Interface 120000+ closed the combat log to addons.
Damage and healing come from Blizzard's own server-side meter, with Details as a
fallback -- but deaths, interrupts, dispels and crowd control are not available
to any addon there. Outcome-based rating is completely unaffected, and the
options panel tells you which source is in effect on your client rather than
leaving you to guess. If Blizzard reopens the combat log, the capture is still in
place and starts working again.

**Does it message anyone automatically?**
No. See above -- every message is one you pressed a button for.

**Does it need an account, a website, or a companion app?**
No. Everything runs in the addon, on your machine. An optional Python companion
for offline enrichment is planned but not written yet; the addon behaves
identically without it, and always will.

**What does it do to my SavedVariables?**
There is a real storage ceiling, 5 MB by default and configurable. It is
*measured* rather than estimated -- PugRoster sums the bytes the SavedVariables
writer will actually emit, because a limit is only a limit if the number beside
it is true. Over budget it sheds captured chat first, then old world and dummy
fights, then old exported keys, and tells you what went. Your roster, tags,
templates and saved groups are never touched.

**Any libraries?**
None. No Ace3, no LibStub, nothing embedded. Pure Blizzard API.

---

## Install

Through your addon manager, or download the zip and unpack it into
`World of Warcraft/_retail_/Interface/AddOns/`. Type `/pr` and run a key.

**Source, issues and full documentation:**
https://github.com/duanebc/pugroster

*MIT licensed.*
