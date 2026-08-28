# Changelog

## v1.0.1 -- unreleased

- **The roster names people, not their alts.** A row was labelled by whichever
  character you had seen most recently, so a friend with seven alts appeared
  under whichever one he last logged in on -- and searching for the name you
  actually call him found a row that did not look like him. Rows now lead with
  the person and name the character second: `Sanlanesh as Nnkidu`. People with
  one character are unaffected, and a person with only a placeholder name still
  shows the character, because "Person 24 as Amycus" helps nobody.
- **The "Same person as..." picker has a search.** It listed every person you had
  ever met in one column -- 3,500 pixels of menu at 179 people, clamped to the
  screen, so it stopped somewhere in the Gs and there was no way to reach anyone
  further down the alphabet. Type a name to narrow it; past thirty matches it
  says how many it is not showing rather than drawing a menu you cannot use.
- **A main-RIO column.** The highest Raider.IO score anywhere on the account,
  across every linked character and both this season and last, whichever is
  higher. The per-character score answers how good a character is; this answers
  who you are actually talking to when somebody brings an alt.

## v1.0.0 -- 2026-08-27

First public release.

- **Every Mythic+ key is recorded.** From `CHALLENGE_MODE_START` to
  `CHALLENGE_MODE_COMPLETED`: dungeon, key level, affixes, timer result and
  upgrade level, plus a per-player observation for all five of you -- deaths,
  wipes, interrupts, dispels, crowd control, damage, healing, item level, spec,
  role and whether anyone left early. Abandon, disband and key-reset are handled,
  and the in-progress run lives in SavedVariables so a `/reload` mid-key resumes
  rather than losing it.
- **Every other fight is recorded too** -- raids, heroics, delves, PvP, open-world
  pulls and target dummies -- anything lasting more than five seconds, classified
  by content type. A dungeon visit is one history row with each combat as a
  segment inside it, named by its boss or marked as trash, the way a damage meter
  paginates. Fights are stored apart from keys, so a raid boss or a training
  dummy can never move somebody's Mythic+ tier.
- **Ratings that explain themselves.** Outcome dominates -- timed, upgrade level,
  completion -- and per-player stats adjust within that band. Contribution scales
  with key level, a tank or healer death weighs heavier than a DPS death, previous
  seasons decay, and a small sample cannot leave Neutral. The roster panel shows
  the per-run breakdown and `/pugdebug tier <name>` prints the arithmetic weight
  by weight.
- **A roster of people, not characters.** Characters link under a person;
  Battle.net friends auto-link where the friends list exposes the mapping and
  anyone else can be linked by hand. Your whole friends list is imported and
  tagged `existing_friend`, because the people you already know are exactly the
  ones worth bringing along. Manual tags (relationship, play style, availability,
  voice, plus anything you invent) sit on the person; auto-tags for role, spec,
  item level bracket, Raider.IO bracket and tier are derived and always current.
  Names carry their realm everywhere they are shown.
- **A filter builder over both kinds of tag** -- `role = healer AND ilvl >= 640
  AND tag = push` -- saveable as a named group, and usable from the Send tab
  without saving it first. Plus a search box for when you just want one person by
  name, matching their alts as well as the name you filed them under.
- **Every session together is counted, but only keys are rated.** The Runs column
  reads `2 +3`: two keystone runs, and three other times you grouped up --
  normal dungeons, delves, raids. Only the first number can move a tier, because
  a raid boss has no business rating a Mythic+ player. Open-world pulls and
  target dummies are not company and do not count.
- **Messaging by group.** Pick a saved group or a live filter, preview the exact
  expanded message for every recipient, uncheck anyone, and send with a
  configurable stagger. Templates support `{name} {key} {dungeon} {mykeylevel}
  {tier} {runs} {me}`, and can carry a key they are recruiting *for* -- pick a
  dungeon and level and write `{keylevel} {keydungeon}`, which stays distinct
  from the keystone actually in your bags. Battle.net whisper when the account is known, character
  whisper otherwise. A per-person cooldown, a `do-not-message` tag and a sent log
  are enforced in the send path rather than the UI. Replies are tracked verbatim
  with manual yes/no marking and one-click invite.
- **Nothing is sent by accident.** Echo mode is off by default; nothing is
  selected in the Send tab until you select it; and when echo mode is on the
  summary says ECHO MODE, the button reads "Echo to N" and completion reports
  that nothing was really sent. Every send prints a clickable player name in
  chat, so the moment you most want to whisper someone you can.
- **The send list knows who is actually available.** It offers the whole roster
  rather than only the people whose online status is visible -- a cross-realm pug
  is neither a friend nor a guildmate, and the old rule hid exactly the players
  the roster exists for. Anyone in a dungeon, raid or battleground is left out;
  an empty list says how many were considered, how many were dropped and why,
  and names the setting that changes each.
- **Run history with dps and hps computed over combat time**, not wall clock,
  since the minutes spent running between packs are not minutes anyone was doing
  damage in. Filterable by content type, with a per-record Delete and a "Pull
  from Details" for a run captured before enrichment worked.
- **Mythic+ scores from the RaiderIO addon** when it is installed, with a second
  column for last season in RaiderIO's own previous-season colour, since the two
  seasons are not on the same scale.
- **Tooltips and a group-finder badge.** Tier, runs together, tags, note, item
  level and both scores on player tooltips; a colour badge on group-finder
  applicants, drawn as an addon-owned overlay so no widget, field or script hook
  is left on a Blizzard frame. A dismissible toast when a rated player joins your
  group.
- No external libraries -- pure Blizzard API, no Ace3, no LibStub.

### On Midnight (interface 120000+)

The combat log is closed to addons, so some of what PugRoster records comes from
elsewhere or not at all. Options reports which is in effect on your client.

- Damage and healing come from `C_DamageMeter`, Blizzard's server-side meter,
  with Details as the fallback -- both, rather than our own tallies.
- Deaths, interrupts, dispels and crowd control are unavailable. Outcome-based
  rating is unaffected.
- Other players' chat text is withheld, so a run whose every line was withheld
  says so once instead of listing blank rows. The capture is left in place, so it
  starts working again if Blizzard reopens it.
- Item level still works: inspect replies carry a secret GUID and are matched to
  the unit the request was made for.

### Not included in released builds

- The `Debug/` simulation suite -- fake runs driven through the real event
  handlers, seeded rosters and history, a messaging sandbox, tier and run
  inspectors and a taint capture. It registers its own tab, so a released build
  has four tabs and no debug UI at all.

### Not written yet

- The Python companion, which would refine tiers offline and fill in Raider.IO
  scores and same-person links. The generated `PugRoster_Lookup.lua` ships as an
  empty stub, so the addon behaves identically until it exists.
