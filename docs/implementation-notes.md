# Implementation notes

The development log for PugRoster's first implementation, built from
`docs/pug-roster-plan.md`. It covers phases 1-6 of that plan; the Python
companion (phase 3's out-of-game half) is not written yet.

This is kept apart from `CHANGELOG.md`, which the packager ships as the release
notes and which stays user-facing. What follows is the reasoning behind the code
-- why a value is read from one API rather than another, what a fix was actually
fixing -- grouped by module rather than by release.

## v1.0.0

### Capture
- Values come from the source's `totalAmount`, which is the exact figure for every
  meter -- 34688769 damage, or 4 interrupts. `amountPerSecond` is that divided by
  the segment length, which is why damage looked right when multiplied back out
  while a count of 4 over 446 seconds rounded to zero. Interrupts, dispels and
  deaths were never missing; they were being read from the wrong field.
- Deaths are counted by entry, not read from a field. The server reports one
  source per death -- carrying `deathRecapID` and `deathTimeSeconds` -- and leaves
  `totalAmount` at 0, so reading the value returned zero no matter what else was
  right. Four deaths in a session is four entries.
- A record left without combat stats is retried at login. A /reload destroys the
  pending retries, so a run finished seconds earlier filed with nothing and could
  never recover -- but `C_DamageMeter` is the server's and its sessions survive a
  reload, unlike Details'. Bounded to the last quarter hour, since the Overall
  session resembles a record less the further back it is.
- The send list's status label tests for absence first. `entry.online` is nil for
  anyone whose status cannot be seen -- most of the roster -- so a branch ordered
  after a check that already passed on nil indexed it and took the tab down.
- Both battleground lookups are feature-detected. Checking `GetNumBattlegroundTypes`
  and then calling `GetBattlegroundInfo`, which does not exist on this client, took
  the Send tab down with "attempt to call a nil value"; the instance-name lookup is
  also wrapped now, since a convenience that decides whether to hide somebody from
  a list must never stop a panel drawing.
- Segment enrichment retries instead of taking one shot: the server publishes a
  finished session a moment after combat drops, and reading too early looks
  exactly like having no data.
- Sources are matched on `sourceGUID` rather than name. The server hands one back
  and observations are keyed by GUID, so the two line up exactly instead of being
  reconciled through realm suffixes.
- Automatic enrichment is no longer gated on the "Use Details" setting. The
  numbers come from Blizzard's meter; Details is only the fallback. It also says
  in chat when it succeeds, since silence and failure looked identical.
- **Combat stats are read from `C_DamageMeter` directly.** Blizzard's server-side
  meter has every session, source and number; Details' containers come back empty
  on this client, and it reads the same API anyway. Details is now the fallback
  rather than the source, which also removes the dependency on its internals
  surviving the next patch.

- Records group by zone with a 30-minute idle timeout rather than 60 seconds. An
  afternoon in one delve became nine separate history rows because a pause for a
  turn-in looked like a new outing.
- A real storage ceiling, `maxStorageMB`, default 5. Measured rather than
  estimated -- `ns.MeasureBytes` walks the database summing the bytes the
  SavedVariables writer will emit, because a limit is only a limit if the number
  beside it is true. Over budget it sheds captured chat, then old world and dummy
  fights, then old exported keys, and says what went. Unexported keys, the roster,
  tags, templates and saved groups are never touched.
- **Pull-by-pull detail is no longer saved.** Each pull is still read from the
  server as it happens and folded into the record's totals -- reading per pull is
  what keeps those totals accurate, since the server's Overall session spans
  everything since it was last reset rather than this dungeon -- but the breakdown
  is discarded. A record's totals are five rows; its pulls were up to 125, which
  put the worst case near 9 MB of SavedVariables for a breakdown only worth having
  while it is on screen. Worst case is now about 0.4 MB.
- A boss encounter still bounds a segment even when combat never drops, because
  that is what lets a key's pulls be read individually at all.
- The last pull of a key lands on the key. It finishes after
  CHALLENGE_MODE_COMPLETED, so there was no active run to attach it to and it
  filed a second, near-duplicate record for the same dungeon.
- Every pull is labelled by what it was: the boss's name from `ENCOUNTER_START`,
  or "Trash". A wipe is marked as one. Scanning a list of "Pull 7" for the fight
  you remember is not something anyone can do, so the segment picker names them
  and the detail header says which pull you are looking at.
- Mythic+ keys record their pulls too. Only non-key content did, so a key had no
  per-pull breakdown at all -- the segment dropdown had nothing to offer. A key's
  segments are for display only and are not accumulated: the run's totals come
  from one authoritative read of the whole key at completion, and adding segments
  to that would double-count.
- A dungeon visit is one history record, not one per pull. Six rows for a single
  Nexus run was useless: the entry is the visit, and each combat is a segment
  inside it. The detail pane shows the visit total and can page into any single
  pull, the way a damage meter paginates segments. Open-world combat has no visit
  to belong to, so it groups only while pulls keep coming.
- Segment numbers are read from the server's *Current* session, which is the
  combat that just ended; visit totals are the sum of their segments. The Overall
  session spans everything since the meter was last reset, which is not the same
  thing as this dungeon.
- Every fight is recorded, not only Mythic+ keys: raids, heroics, delves, PvP,
  open-world pulls and target dummies. Anything lasting more than five seconds
  gets a history row, classified by content type from `GetInstanceInfo`.
- Fights are stored in `db.fights`, deliberately apart from `db.runs`. Rating
  reads `db.runs` alone, so a raid boss or a target dummy can never move
  somebody's Mythic+ tier.
- A target dummy is the only content you can produce on demand, so recording them
  is also what makes the capture path testable without running a key.

- **Inspect works again.** `INSPECT_READY` answers with a secret GUID on
  Midnight, and the queue matched that GUID against the one it had requested -- a
  comparison that can never succeed, so every inspect timed out in silence and no
  groupmate ever got an item level. The reply is now matched to the unit the
  request was made for, since only one is ever in flight.
- The inspect queue runs whenever you are in a group, not only during a key, so a
  party member's item level is available on the tooltip anywhere.

- **The reason every Details read came back empty: the server withholds combat
  values while you are in combat.** `C_DamageMeter` has the sessions and their
  sources all along, but each `name` and `amountPerSecond` is a *secret* until the
  Combat restriction clears. Reads are now gated on that, and enrichment waits for
  the lock to drop before its first attempt rather than racing it -- the end of a
  key is exactly when you are still in combat.
- `/pugdebug details` probes `C_DamageMeter` -- Blizzard's own server-side meter,
  which is the source Details reads on Midnight now that the combat log is closed
  -- before it looks at Details at all. "The server recorded nothing" and "Details
  has nothing" are different problems, and only the report could tell them apart.
  It also prints `C_RestrictedActions` state, which is what withholds combat data
  during restricted content.
- Details enrichment retries at 5, 15, 30 and 60 seconds after a key rather than
  taking one shot. Details holds its segments in memory only, so a reload discards
  them and the run can never be enriched afterwards -- that window is the only
  chance there is, and how long Details takes to assemble its combined Mythic+
  segment is not ours to know.
- "Details has no combat data in this session" is now distinguished from a real
  failure, and says why: segments are cleared by a reload or logout.
- Segment selection picks the best candidate that actually has actors in it,
  rather than the best candidate that merely exists. Details' overall segment can
  be present and empty -- selection stopped there and reported no data while the
  run sat in another segment. `/pugdebug details` now lists every candidate with
  its actor count so the choice is visible.
- Details actors keyed on an empty `serial` no longer collapse into one shared
  record. Details leaves `serial` as "" on actors it built without a GUID (its
  own code guards for this), so keying on it merged every such actor together and
  the result matched nobody.
- `/pugdebug details` runs the whole harvest and prints what it found, then says
  which of your current group it would match. It needs no run record, so Details
  integration can be tested against a training dummy in seconds rather than by
  finishing a key.
- A run that cannot be read from Details now says so in chat instead of filing
  itself with every stat at zero and no explanation.
- A failed "Pull from Details" prints the full Details report on the spot instead
  of one line, so a failure names its own cause without a second command.
- The Chat section is hidden entirely when a run holds no readable lines. Midnight
  withholds other players' chat text, so a header over an empty box was worse
  than no section; Options carries the explanation.
- Details enrichment actually reads the containers now. It was calling
  `combat:GetContainer(Details.atributo_damage)` -- and `atributo_damage` is not
  an attribute id, it is the damage actor *class* metatable. `GetContainer` is
  `self[id]`, so indexing with a table returned nil and every pull reported "no
  data" while Details sat there full of it. The ids are the numeric
  `DETAILS_ATTRIBUTE_*` globals.
- Details is now the source for deaths, interrupts, dispels, damage and healing,
  not just damage and healing: with the combat log closed on Midnight it is the
  only source there is. The bridge reads Details' combined Mythic+ segment when
  it has built one, falling back to the overall then the current segment, and
  reports which it used.
- Runs already filed as "over time" that finished inside par are corrected on
  load. Finishing inside par is the definition of timed, so the flag was
  recoverable even though the API that reported it is gone. The upgrade level is
  derived from the par thresholds and marked with a `?`, because our elapsed can
  land a few seconds either side of a boundary.
- The Add friend button adds by "Name-Realm" and no longer claims cross-realm is
  the problem -- it is not; cross-realm friends are ordinary. It now checks the
  friends list afterwards and reports what actually happened, since the server
  refuses with "Player not found" for a character that is offline.
- Run completion reads `C_ChallengeMode.GetChallengeCompletionInfo`, falling back
  to the deprecated positional `GetCompletionInfo`. The old call still returns
  the map, level and time but no longer fills in `onTime` or
  `keystoneUpgradeLevels`, which filed a timed +2 as "over time" with the correct
  elapsed and par printed beside it.
- Details is re-read five seconds after a key ends, because it assembles its
  combined Mythic+ segment slightly after `CHALLENGE_MODE_COMPLETED`. History has
  a "Pull from Details" button for when even that is early, or to recover a run
  captured before any of this worked.
- **Party chat cannot be captured on Midnight.** Other players' chat text comes
  back as a secret value: passable, but not readable, storable, or serialisable.
  A run whose every line was withheld now says so once instead of listing blank
  rows, and Options reports it next to the combat-log line. The capture is left
  in place so it starts working again if Blizzard reopens it.
- Details actors are no longer filtered on Details' `grupo` flag. It means "was
  in my group", which looks like the right filter and is not -- it is set on
  Details' own actor-creation paths and does not survive into the merged overall
  segment, so every player was discarded and a full segment reported "no group
  actors". Matching on the run's own GUIDs is stricter anyway.
- Captured chat records whether a line was withheld rather than storing a blank.
  A row now reads "(hidden by the client)" or "(not captured)" instead of "?:",
  which are different problems and were indistinguishable before.
- Midnight returns some values "secret": usable, but not valid as a table key,
  and indexing with one throws. Chat sender GUIDs are secret, which took the
  History tab down when a chat line reached `Roster.GetCharacter`. Every GUID
  bound for a table lookup or SavedVariables now passes through `ns.SafeGUID`.

- Mythic+ run lifecycle from `CHALLENGE_MODE_START` to `CHALLENGE_MODE_COMPLETED`,
  with abandon, disband and key-reset paths.
- In-progress run state persisted to SavedVariables, so a `/reload` mid-key
  resumes instead of losing the run.
- Per-player observations: deaths, wipes, interrupts, dispels, crowd control,
  damage and healing, item level, spec, role, left-early flag.
- Party, instance and whisper chat logged per run, capped so one chatty key
  cannot bloat SavedVariables.
- Throttled inspect queue for groupmate spec and item level.
- Optional Details enrichment for damage and healing, feature-detected per
  function so a missing method degrades to our own tallies.

### Rating
- The rating pass no longer stamps every character as seen-just-now. It called
  `TouchCharacter(guid, {})` to fetch a record, and TouchCharacter treated any
  call as a sighting -- so the roster's "Last" column reported the time of the
  last recompute rather than when you played with anyone. Fetching now goes
  through `Roster.EnsureCharacter`, and the recompute takes `lastSeen` from the
  newest run a character appears in, which repairs databases the old behaviour
  flattened.

- Outcome-dominant provisional tiers, scaled by key level, weighted by role,
  decayed by season, gated on sample size.
- Per-run breakdown exposed in the roster panel and `/pugdebug tier`.
- Reader for the companion-generated `PugRoster_Lookup.lua`; refined tiers and
  Raider.IO scores are preferred when present, and its absence is a no-op.

### Roster
- Everyone on the friends list is imported into the roster and carries an
  `existing_friend` auto-tag. The roster recorded only people you had run with,
  which left out the ones you already know -- exactly the people worth bringing
  along. Imported without touching `lastSeen`, since being on a friends list is
  not an occasion of having played together.
- People already in a dungeon, raid or battleground are left out of the send list.
  Best effort: current-season Mythic+ dungeons and battlegrounds are enumerable,
  and everything else is inferred from the difficulty wording in rich presence, so
  it can miss someone busy but never invents one. Switchable under
  Options -> Messaging.

- Mythic+ scores come from the RaiderIO addon when it is installed, falling back
  to the companion snapshot. Previously the only source was `PugRoster_Lookup.lua`,
  which the unwritten companion produces -- so every RIO cell read "-".
- A second score column, LS-RIO, carrying last season's score in RaiderIO's own
  previous-season colour, since the two seasons are not on the same scale.
- The Send tab offers everyone in the roster, not only those we can see are
  online. Online status is only visible for Battle.net friends, character friends
  and guildmates -- a cross-realm pug is none of those, so the old rule hid
  exactly the players the roster exists for. Unverifiable ones are listed as
  "status unknown"; a whisper to someone offline fails harmlessly. Switchable
  under Options -> Messaging.
- Names carry their realm everywhere they are shown -- roster, send list, run
  history -- dimmed after the character name. Two pugs called Landairsea on
  different realms are a normal thing to have in a roster.
- An "Add friend" button on the roster detail pane, which is what makes someone's
  online status visible. Same realm group only; cross-realm needs a Battle.net
  request, which no addon can send for you.
- You no longer appear in your own roster. You are in your own runs, so you ended
  up rated against yourself.
- The window is 1000px wide rather than 920, for the realm names.
- The Send tab no longer offers your own characters. The guild roster and friends
  list both include the player, so on an account with nobody else online they
  were the only "recipients" it found.

- Person/character model with Battle.net auto-linking and manual "same person"
  linking.
- Manual tags with default categories, user-extensible; derived auto-tags for
  role, spec, item level bracket, Raider.IO bracket and tier.
- Filter builder over tags and numeric fields, saveable as named groups.
- Online suggestions from the friends list, Battle.net friends and guild roster.

### Messaging
- **Echo mode is off by default**, and the choice is remembered. It defaulted on,
  which made sense when the addon was only ever driven by simulations and nothing
  could reach a real player by accident -- and stopped making sense the moment it
  was used for real. A messaging addon whose default is "do not actually message
  anyone" silently does nothing, and it took a recipient saying so to notice.
  Turning debug mode back on no longer forces it on either.
- Nothing is selected in the Send tab by default. A send goes to real people, so
  the safe starting point is an empty selection you add to rather than a full one
  you have to remember to trim.
- A send prints a notification carrying a clickable player name, so clicking it
  opens a whisper. The moment you most want to whisper someone is right after you
  have just messaged them, and a send from the Send tab otherwise left no trace in
  chat at all. Echoed sends carry the same link and stay marked as echoes.
- "Recently sent" stays inside the addon. Its rows were anchored on one side only,
  so a long message drew at its natural width -- across the game, outside the
  window. Bounded both sides and clipped, with a horizontal scrollbar to read the
  rest of a line and the existing vertical one for the list.
- The sent log keeps the last 20 messages rather than 500, configurable as
  "messages kept in Recently sent". It is a view of what you just did, not an
  archive, and the same cap now applies per person as well as globally.
- Clicking a line in "Recently sent" opens a whisper to whoever it went to.

- Echo mode is impossible to mistake for a real send: the Send tab summary says
  ECHO MODE, the button reads "Echo to N" rather than "Send to N", and completion
  reports "echoed -- nothing was really sent". A message reported as sent that
  never arrived was echo mode doing its job invisibly.

- Templates with placeholder expansion, managed in the send panel.
- Recipient preview with per-person messages, staggered send queue, cancel.
- Per-person cooldown, `do-not-message` tag and sent log, enforced in the send
  path rather than the UI.
- Verbatim reply tracking with manual yes/no marking and one-click invite.

### Display
- A Delete button on each history record, next to Pull from Details, confirming
  on a second click. Deleting a key recomputes tiers; deleting a fight does not,
  since fights never fed them.
- The role filter offers DPS rather than DAMAGER. The stored value is still the
  client's `DAMAGER`, which is what every comparison is against -- only the label
  changed, in the filter menu and in saved-group descriptions.
- The Send tab can use the filter built on the Roster tab. It only ever offered
  saved groups, so a filter you had just built did nothing there until you saved
  it, which is not obvious from either tab.
- dps and hps columns in the run history, both computed over **combat time**
  rather than elapsed. A key's elapsed is wall clock, and the minutes spent running between
  packs are not minutes anyone was doing damage in -- dividing by it would report
  something well below what the group actually did. Combat time is accumulated
  per pull and shown beside elapsed when the two differ. Records captured before
  this fall back to elapsed, which understates a key and is exactly right for a
  fight.
- Numbers are shown in whichever unit reads naturally: 4787K rather than 4.787M,
  141M rather than 141000K. The rule is "step up a unit once you have at least ten
  of them", which is how people say these out loud.
- An empty Send tab says why it is empty -- how many people were considered, and
  how many were dropped as busy, as your own characters, or as not confirmed
  online -- with the setting that changes each.
- A busy player is now genuinely dropped from the send list. Nulling their info
  fell through to the unknown-status branch and put them straight back on it,
  which was the opposite of the point.
- A content filter on the History tab -- Mythic+, dungeons, raids, delves, PvP,
  target dummies, open world. It only offers types you actually have records for.

- Item level, current score and last season's score on the unit tooltip, all on
  plain mouseover. The full Raider.IO block is RaiderIO's own and is reached by
  turning off its "Enable Profile Modifier" setting -- PugRoster does not
  duplicate it.
- `DAMAGER` reads as `DPS` in the roster and run history, through one
  `ns.RoleLabel` so the two cannot drift.

- Tier, runs together, tags and note on player tooltips.
- Colour badge on group-finder applicants, feature-detected and taint-safe:
  the badge is an addon-owned overlay anchored to the row, so no widget,
  field or script hook is left on a Blizzard applicant frame.
- Main window closes on ESC without going through `UISpecialFrames`.
- `{dungeon}` and `{key}` resolve through `C_MythicPlus.GetOwnedKeystoneChallengeMapID`
  rather than `GetOwnedKeystoneMapID`, which returns a uiMapID and left messages
  reading "+10 map 2859". Key-holder detection compared the same two ID spaces
  and so never matched.
- Send tab: cooldown blocks read "messaged 4m ago, 45s left" rather than
  "messaged 4m ago ago", and Select all says so when every match is blocked
  instead of looking like a dead button. Durations under a minute now read in
  seconds rather than rounding up to "1m".
- Turning off "Tier on player tooltips" now short-circuits the whole tooltip
  hook rather than only the lines it adds. `GetUnit()` still ran with the feature
  off, so the setting could not be used to rule the hook out.
- Hooks that receive a Blizzard widget -- the unit-tooltip post-call and the
  group-finder applicant hook -- check `IsForbidden` before touching it. Calling
  any method on a forbidden widget, a getter included, raises
  `ADDON_ACTION_FORBIDDEN` and is what puts the "disable this addon" popup on
  screen.
- Message cooldown is configured in seconds rather than hours and defaults to
  300, and the Send tab has a "Clear cooldowns" button for the people currently
  listed. An existing database keeps a window its owner actually chose; one
  still on a shipped default picks up the new one. Editable under
  Options -> Messaging.
- Dismissible toast when a rated player joins the group.

### Development
- `Debug/` simulation suite: fake runs driven through the real event handlers,
  bulk history seeding, seeded roster and tags, fake friends list, message echo
  and simulated replies. Stripped from released packages by `.pkgmeta` and a
  `#@debug@` block.
- `ADDON_ACTION_BLOCKED`/`ADDON_ACTION_FORBIDDEN` are reported to chat with the
  refused function name, so a blocked-action popup names its own cause.
- The `debug` flag now covers everything a seed can write -- persons (derived
  from their characters), saved groups and sent-log entries, not just runs and
  characters -- and `/pugdebug wipe fake` collects all of it. Flagged records are
  blocked from real sends and invites, marked `[sim]` in the roster and send
  lists, and dropped on a fresh login so they never age into the database. The
  companion app must skip them on import.
- `/pugdebug popup on|off` silences the blocked-action popup while hunting a
  forbidden call; the refused function name still prints to chat.
- A **Debug tab** carrying every development affordance in one pane: generate all
  test data or seed each kind separately, simulate a key with its outcome flags,
  remove all generated data, the messaging sandbox, the tier and run inspectors,
  and a taint capture. It registers itself from `Debug/`, so a released build has
  four tabs and no debug UI at all.
- A master switch (`/pugdebug on|off`, or the checkbox on the Debug tab) that
  makes the addon behave as a released build: every seam production code
  feature-detects is cleared, and the other slash commands refuse. "Remove all
  test data" deliberately keeps working while it is off, so seeded records can
  always be cleared.
- Forbidden actions are captured with the refused function name and a breadcrumb
  trail of what PugRoster was doing just before, shown in a copyable box on the
  Debug tab. The popup names the addon and nothing else. A traceback would not
  help -- the event is dispatched at a frame boundary rather than inside the
  offending call -- so `ns.Trace` drops a marker at every point Blizzard enters
  the addon and `ns.TraceLog` reports them with ages.
- **The blocked-action popup is fixed, and it was open risk 1 from the plan.**
  Midnight (interface 120000+) makes `COMBAT_LOG_EVENT_UNFILTERED` off limits to
  addons: registering it is a protected action, the client refuses it, and that
  refusal is the popup, once per login. A blocked action is not a Lua error, so
  there is nothing to pcall -- the only fix is not to make the call. The
  registration is now gated on the interface build, the same check Details uses
  for its own parser.
- Combat capture degrades instead of erroring, as the plan specified: deaths,
  interrupts, dispels and CC are unavailable on Midnight, Details remains the
  damage and healing source, and outcome-based rating is unaffected. Options
  reports which of the two is in effect, because it changes what a run record
  contains.
- The combat log gets its own frame rather than going through `ns.RegisterEvent`,
  so thousands of events per pull no longer put a breadcrumb in `ns.Trace`.
- The capture hooks `StaticPopup_Show` rather than registering for
  `ADDON_ACTION_FORBIDDEN`. **An addon cannot register those two events**:
  attempting it is itself a forbidden action, so a reporter written that way
  raises the popup it exists to explain, on every load. Silencing the popup is
  one-way for the same reason -- re-registering it on `UIParent` would raise it
  again, so it comes back on `/reload`.
