# Changelog

## v1.0.11 -- 2026-09-03

- **Deaths are counted by when they happened, not by what the rows are labelled
  with.** A run where everyone died once filed one player with twelve. The
  server's Deaths meter lists every damage source that contributed to a killing
  blow, so one death arrives as several rows -- and counting distinct
  `deathRecapID` values, which fixed an earlier "seventeen deaths" report, turns
  out not to hold: those twelve rows carried twelve different ids.

  A death is a moment. The hits that caused it land within seconds of each other
  and two real deaths are separated by far more, so the timestamps are clustered
  instead and the id no longer decides anything. Ten seconds apart is the
  boundary. Where the server sends no timestamps at all, distinct ids are the
  next guess and the row count the last.

- `/pugdebug details deaths` now prints every row of the named meter with its
  recap id and timestamp, which is what settled this one.

## v1.0.10 -- 2026-09-02

- **A rate is no longer divided by a combat time too small to believe.** Every
  dps and hps figure is a total divided by the run's recorded combat time, and
  one run in a hundred recorded 707 seconds of combat across a 2,012 second run
  -- it was abandoned and re-formed, so the segments banked covered eleven
  minutes of a thirty-three minute run while the server meter's totals still
  covered all of it. Everything on that record read nearly three times too high,
  and a healer held the all-time best at 214k in a run nobody finished. The
  honest figure is 75k.

  Across the other hundred runs the ratio sits between 0.68 and 0.95, so
  anything under half now falls back to wall clock. That understates a rate,
  since wall clock counts the running between packs -- which is the safe
  direction to be wrong in.

- **Those rates are marked with a `~`.** The totals are real; what they were
  divided by is not, and a number you cannot compare should not look like one
  you can.

## v1.0.9 -- 2026-09-01

- **The frame drops in Mythic+ were this addon, and they are gone.** Measured
  rather than guessed: the client's own profiler put PugRoster at 447 ms of the
  501 ms spent by every addon across a single pull -- 89% of it, against 24 ms
  for Details and 4 for DBM. Its own per-event timing then named the handler.
  `BN_FRIEND_INFO_CHANGED` was costing **28.9 ms a call, 29 times in one pull**;
  a frame at 60fps is 16.7 ms, so each one dropped nearly two.

  Two handlers sat on that event and both walked the whole roster. With 1,087
  characters stored and fifty friends, one compared every character against
  every friend while the other looked up each friend with a full scan that
  lowercased and shortened all 1,087 names.

  Nothing there is time-critical -- who is online matters when you look at the
  roster and not at all mid-pull -- so both are now behind a fifteen-minute
  cache that never runs in combat and refreshes the moment the window opens.
  The lookup is indexed rather than scanned. Same event, same run: **0.0021 ms a
  call.**

- **Deaths are counted by recap rather than by row.** A hunter who died once was
  filed with seventeen deaths. A death recap lists every damage source that
  contributed to the killing blow, and each was being counted as a death. Runs
  already recorded keep their numbers; *Pull from Details* re-reads one.

- **A latent merge bug went with the rewrite.** The old friend-matching compared
  a withheld name against every character with `nil == nil`, which matched every
  stub at once.

- `/pugdebug profile on` times this addon's own event handlers, in case it is
  ever the suspect again.

## v1.0.8 -- 2026-08-30

- **No more "PugRoster has been blocked from an action only available to the
  Blizzard UI" during a pull.** The inspect queue called
  `CheckInteractDistance`, which is protected in combat, and its ticker runs
  every two seconds regardless of what is happening -- so a long fight produced
  that popup every two seconds. A blocked action is not a Lua error and cannot be
  caught after the fact; the only fix is not to make the call, so inspects now
  wait for combat to drop. Nothing is lost: the queue keeps its place, and a
  groupmate is likelier to be in range once the fight is over anyway.
  `taint.log` had recorded 180 of these from the one line.

## v1.0.7 -- 2026-08-30

- **A Battle.net whisper no longer prints an error at whoever receives it.**
  `CHAT_MSG_BN_WHISPER` fires on the *receiving* client, so this was invisible
  from the sending side and had to be reported by a friend:
  `Replies.lua:104: Attempt to compare local 'bnSenderID'`, once per whisper.
  The sender id can come back secret, and a secret tolerates a truthiness test
  while raising on a comparison -- so the `if not bnSenderID` guard above it
  passed and the comparison underneath it did not. Both sides of that comparison
  are now checked, and the ordinary whisper handler beside it, which had the same
  shape on the sender's GUID and name, is checked too.

## v1.0.6 -- 2026-08-30

- **Player tooltips work again.** Mousing over anybody had silently stopped
  showing their tier, runs together and item level. The unit token this client
  hands a tooltip is a *secret* value, and passing one to `UnitIsPlayer` raises
  outright -- on every mouseover, swallowed by the `pcall` that is there so a
  tooltip can never break. The GUID is taken from the tooltip's own data now and
  the token is never touched. The swallowed error is also reported once in
  development builds, because three sessions were spent not seeing it.
- **A whisper goes to the person you clicked.** After whispering a Battle.net
  friend, every later whisper from the addon went to them instead. A whisper and
  a Battle.net whisper keep their targets in two different attributes on the chat
  box, and setting one without clearing the other leaves the box holding both.
  Both whisper actions now go through one place that sets the target explicitly
  and clears the other.

- **`avoid` -- avoidable damage taken -- replaces the `def` column.** Counting
  defensive cooldowns cannot work in Mythic+ and never could: reading a
  groupmate's auras is refused while the challenge-mode restriction holds, so the
  column read zero for all five players in exactly the content it was built for.
  It was measured four ways before being believed, and the write-up is in
  `docs/defensives-in-mythic-plus.md`. Avoidable damage comes from the server's
  own meter -- the one already supplying damage, healing, interrupts and deaths
  inside keys -- and answers a better question anyway: not "did you press your
  button" but "did you take damage you should not have".
- **The defensive-aura capture is gone**, along with the `def` column and the
  Battle.net friend button, which could not do what it promised either: a
  Battle.net request needs a BattleTag, and this client gives an addon a
  BattleTag only for people already on your friends list.

- **People are identified by BattleTag, not by a number that changes.**
  `bnetAccountID` is not stable between sessions, and it was a person's identity.
  The proof was in the database it produced: the same character sitting under two
  adjacent account IDs, which only happens if one real account was handed a
  different number on a different day. That splits one person across several
  entries and would eventually merge two people once a number is handed out
  again. Linking is on the BattleTag now, a merge is refused outright when two
  known BattleTags disagree, and persons record whether a grouping was yours or
  the client's.
- **`/pr ungroup` repairs a roster that guessed.** Dry run unless you type
  `confirm`. It dissolves every grouping nothing vouches for and keeps those
  backed by a shared BattleTag or made by you. Runs, item level and tier live on
  the character, so nothing is lost but the claim that two characters are one
  person. It replaces `/pr unmerge`, which regrouped by the very number now known
  to be unreliable.

- **A roster row names one character.** It used to name the person and a
  character together -- "Enkidu as Sanlanesh" -- so somebody with seven alts
  stayed findable. Every other column in that row describes a single character,
  though, so a second name made the row read as being about somebody it was not.
  Search still names the character that matched, now in that character's own
  class colour.
- **History says who a run count is pooled from, and why.** Filtering to a person
  with alts now shows their characters and the grounds for the grouping -- linked
  by you, the same Battle.net account, or an honest note that it predates the
  reason being recorded. A run count spanning five characters is misleading if
  you cannot see that it does.

- **A window with the group's numbers when a run is recorded.** Five players
  across seven columns is a table, and a table read as scrolling chat text is not
  a table -- particularly with a small chat frame. It opens when the record is
  actually enriched rather than at the completion screen, because the server
  withholds damage and healing until the key is behind you and a window at
  completion would faithfully report a row of zeroes. Ordinary dungeons get one
  too. Movable, closable, and switchable off in Options.
- **Faction and spec are recorded and shown.** Faction was never captured -- it is
  only knowable while somebody is standing beside you, and nothing recovers it
  afterwards -- so it is taken with the group snapshot from now on. Both appear as
  icons in a narrow column of their own, ahead of the name, in both the summary
  window and the history table. Their own cell rather than a prefix on the name,
  because either can be missing -- an old record has no faction, an uninspected
  pug has no spec -- and inside the name cell a missing one shifts that row out
  of line with all the others.

- **Less work per frame in a dungeon.** Watching auras put 108,752 events per key
  through the shared event dispatcher, each one allocating a string that existed
  only to be thrown away -- garbage made in combat, which is where collecting it
  is felt as a stutter. That watcher is gone with the feature; the dispatcher no
  longer builds a string per event; and the group-finder badge sweep stops
  running once there is nothing left to follow.

## v1.0.5 -- 2026-08-29

- **Inspecting somebody yourself no longer comes back empty.** The model loaded
  and every equipment slot was blank. The inspect API is a single global slot,
  and PugRoster's background item-level queue was taking it: it would request an
  inspect of a groupmate while your own inspect window was open, then call
  `ClearInspectPlayer` when the reply arrived, which releases the data your frame
  was drawing from. Worse, INSPECT_READY is broadcast to every listener, so the
  addon released the slot even for inspects it had not requested -- discarding
  what you had just asked for, before the frame had drawn it. The queue now
  pauses while that window is open, nobody is dropped from it, and the slot is
  only ever released for a request PugRoster actually made.

## v1.0.4 -- 2026-08-29

- **Right-click anyone in a run's group list.** The History tab is where you form
  an opinion about somebody, and the row was a dead end. It now offers their
  history, a message, an Add friend, and Open in Roster -- with a whisper for a
  pug you have never filed. Left-click still prints their score, unchanged.
  Deliberately shallow: the roster's detail pane owns tier, tags and notes, and a
  second place to edit a person is a second place for the two to disagree.
  Nothing is created by clicking -- browsing history does not grow your roster,
  and a boss in a fight record says "not a player" rather than offering to
  befriend it.
- **Searching the roster names the character you searched for.** A person filed
  under one alt's name can contain the character you are looking for, so
  searching "san" returned a row labelled "Unbroken" -- which looks exactly like
  not finding them. Search results now lead with the matching character and dim
  the person behind it.
- **The join toast names whoever actually walked in.** It used the person record's
  name, so somebody with several alts was announced under whichever one happened
  to name the person -- a popup reading "Unbroken" when Sanlanesh joined.
- **The join toast no longer fires for people who were already there.** Its
  memory of who is in the group is empty after a login or a `/reload`, so the
  first scan treated everyone standing beside you as a new arrival. That is what
  the occasional unexplained popup was: not somebody joining, but the addon
  loading.

## v1.0.3 -- 2026-08-28

- **Mythic+ runs recorded every stat as zero, for real this time.** v1.0.2 fixed
  a restriction check that was genuinely wrong but was not the cause. The cause
  was one line in the guard written to keep withheld values out: it compared the
  value to `""` *before* asking whether it was secret, and comparing a secret
  raises rather than returning false. So the check meant to reject a withheld
  name threw on the first one it met, and a single withheld actor took down the
  whole read -- which is why an entire group's numbers vanished at once, and why
  ordinary dungeons, where nothing is withheld, kept working throughout. Secrecy
  is now tested before anything is compared, in all four places that take values
  from the client.
- **"Pull from Details" refused before it tried.** It checked whether the Details
  addon was loaded, but stats come from Blizzard's server meter and Details is
  only the fallback -- so it turned down the source that works on behalf of the
  one that does not, and did so most reliably after a reload, when Details has
  forgotten the run and the server has not.
- **Failures say what actually happened.** A thrown error, a withholding server
  and a clean no-match all printed "Details refused the read", naming a component
  that is usually not even involved. Each now reports itself, errors included.
- The Details fallback is sandboxed, so an error inside it can no longer discard
  a server result that had already been read successfully.

## v1.0.2 -- 2026-08-28

- **Mythic+ runs recorded every stat as zero.** Ordinary dungeons either side of
  them recorded all five players, which made it look like only your own data
  survived. The cause: the check for "is the server still withholding combat
  values" tested the Combat restriction alone, and a key runs under ChallengeMode
  as well -- which outlives the pull. When the key ended Combat had dropped and
  ChallengeMode had not, so the addon read a meter that was still withholding,
  got sources whose names and GUIDs were every one of them secret, matched
  nobody, and filed the run with zeroes. It now waits for Combat, ChallengeMode,
  Encounter and PvPMatch alike, and names which one is holding things up. Stats
  land once you leave the dungeon rather than at the completion screen.
- **The wait is ten minutes, not two.** Two expired while the group was still
  standing in the finished key, which is exactly when ChallengeMode is still on.
- **A run reads every session before giving up.** If the widest one matches
  nobody -- which is what a withheld session looks like from outside -- the
  narrower Current session is tried before falling back to Details.
- **Failures say what happened.** "5 sources but 5 have no readable name or GUID"
  and "no sources at all" were the same message, and they mean opposite things.

## v1.0.1 -- 2026-08-28

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
- **The detail pane stops running off the bottom of the window.** The character
  list was one label that grew with every alt, and the buttons, link row and tier
  breakdown were all anchored beneath it -- so somebody with nine characters
  pushed Message and History into Same-person-as, and the breakdown drew off the
  bottom of the screen where it could not be reached. Characters and the
  breakdown are now bounded lists that scroll, so the rest of the pane keeps its
  place whatever a person has.
- **Characters read as a table** -- name, item level and Raider.IO score in
  columns, class-coloured, realm dimmed. Duplicates are gone: a character the
  friends list knows about and a character a run recorded were two records for
  one person, and both were listed, half of them blank.

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
