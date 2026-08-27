# Listing copy

Paste-ready text for the CurseForge, Wago and WoWInterface project pages. Keep
it in step with `README.md` and `CHANGELOG.md`; the packager uploads the
changelog as each release's notes, but the description below is set once on the
project page and only changes when the addon does.

Project avatar: `images/pugrater/pugrater-logo-400.png`.

---

## Summary (one line)

Rate the players you run Mythic+ with, organise them into a tagged roster, and
message them by tag.

## Summary (short paragraph)

PugRater remembers who you had a good key with. It records every Mythic+ run you
do, rates the four people you ran it with on what actually happened, files them
into a roster you can tag and filter, and lets you whisper a whole group of them
at once when you are looking to fill. The point is to build your own list of
players worth running with, from your own runs, rather than inviting off a score
somebody else computed.

## Description (project page body)

**PugRater remembers who you had a good key with.**

Mythic+ throws you together with four strangers, and by next week you have
forgotten which of them you would take again. PugRater does not: it records every
run, rates everyone in it, and keeps them in a roster you can search when you
need to fill a group.

### Captures every key

From the moment the key starts to the moment it completes, PugRater records the
dungeon, level, affixes, timer result and upgrade level, plus a per-player
observation for all five of you -- deaths, wipes, interrupts, dispels, crowd
control, damage, healing, item level, spec, role, and whether anyone left early.
Party chat is logged alongside the run. Abandons, disbands and key resets are all
handled, and the in-progress run is saved as it goes, so a `/reload` mid-key
loses nothing.

It records everything else too -- raids, heroics, delves, PvP, open-world pulls,
target dummies -- as a browsable history with per-pull detail, filterable by
content type. Those are kept apart from your keys, so a raid boss can never move
somebody's Mythic+ rating.

### Rates them on what happened

Outcome dominates: timed, upgrade level, completion. Individual stats adjust
within that band, scaled by key level and weighted by role -- a tank or healer
death costs more than a DPS death. Previous seasons decay, and a handful of runs
is never enough to leave Neutral.

Every rating is explainable. The roster shows the per-run breakdown, and
`/pugdebug tier <name>` prints the whole calculation weight by weight. You are
never left wondering why somebody is rated the way they are.

### Organises them into a roster

Characters link under a person, so an alt you meet is the same player you already
know. Battle.net friends link themselves where the friends list allows it, and
anyone else can be linked by hand. Your existing friends list is imported and
tagged, because the people you already know are exactly the ones worth bringing
along.

Tag people however you think about them -- relationship, play style,
availability, voice, or any category you invent. Role, spec, item level bracket,
Raider.IO bracket and computed tier are derived automatically and stay current.
Then filter across both: `role = healer AND ilvl >= 640 AND tag = push`. Save any
filter as a named group.

### Messages them by group

Pick a group, preview the exact message every recipient will get, untick anyone
you have changed your mind about, and send with a configurable stagger. Templates
expand `{name} {key} {dungeon} {mykeylevel} {tier} {runs} {me}`. Battle.net
whisper when the account is known, character whisper otherwise. Per-person
cooldowns and a `do-not-message` tag are enforced in the send path itself, so a
manual whisper from the roster obeys them too. Replies come back verbatim next to
each name, with a one-click invite.

Nothing goes out by accident: nothing is selected until you select it, and echo
mode -- which prints messages locally instead of sending them -- is loud about
being on.

### Where you need it

Tier, tags, note, item level and Raider.IO score on player tooltips. A colour
badge on group-finder applicants, drawn as an overlay that never touches a
Blizzard frame. A dismissible toast when someone you have rated joins your group.

### Notes

- No external libraries. No Ace3, no LibStub, nothing embedded.
- On Midnight (interface 120000+) the combat log is closed to addons. Damage and
  healing come from Blizzard's own server-side meter, with Details as a fallback;
  deaths, interrupts, dispels and crowd control are unavailable there, and
  outcome-based rating is unaffected. The options panel tells you which is in
  effect on your client.
- `/pugrater` or `/pr` to open it. `/pr history`, `/pr send`, `/pr options`.
- Source, issues and full documentation: https://github.com/duanebc/pugrater

## Tags / keywords

mythic+, mythic plus, keystone, group finder, lfg, roster, rating, pug, whisper,
friends, guild, raider.io
