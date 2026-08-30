# Why per-player defensive tracking is not possible in Mythic+

**Status:** closed, not fixable from the addon side.
**Date:** 29 August 2026. Client: Midnight, interface 120000+.
**Outcome:** the `def` column was replaced by `avoid` (avoidable damage taken).

---

## The short version

Counting who pressed a defensive requires reading party members' auras. In
Mythic+, the client refuses that read outright:

```
GetAuraDataByIndex(): Auras cannot be accessed when secret
while tainted by 'PugRoster'
```

The same call, on the same units, in a timewalking dungeon, returns every aura.
Nothing in the addon can change which of those two situations it is in.

---

## How it was established

Four hypotheses were tested and three were disproved by measurement rather than
reasoning. They are listed because the wrong ones cost the most time, and each
was disproved by data already sitting in SavedVariables.

### 1. "The event never fires" — disproved

Counters were added at every point a count could be dropped, distinguishing *the
event never arrived* from *it arrived and was filtered*. One key produced:

| counter | meaning | value |
|---|---|---|
| `raw` | `UNIT_AURA` reached the handler | **108,752** |
| `notGroup` | not the player or a partymate | 73,857 |
| `noRecord` | nothing open to record against | 555 |
| `updates` | passed both guards, scan attempted | **34,340** |
| `examined` | aura ids actually read | **0** |
| `secretIds` | ids withheld as secret | **0** |

The event fires constantly and the guards pass tens of thousands of times. The
scan itself returns nothing, and `secretIds = 0` rules out secrecy of the ids as
the mechanism — nothing is being withheld, nothing is being seen.

### 2. "The spell list is wrong" — disproved

The diagnostic probe captured the aura ids actually present on groupmates during
a key. Of 27 distinct ids sampled, three were real defensives and **all three
were already in the curated list**:

- `102558` Incarnation: Guardian of Ursoc
- `108416` Dark Pact
- `11426` Ice Barrier

The other 24 were raid buffs, food, flasks and passives (Mark of the Wild, Power
Word: Fortitude, Prayer of Mending, Soul Leech…), correctly excluded. The list
was never the problem.

### 3. "Aura reads are refused inside the event handler" — disproved

This one looked convincing and was wrong. A scan from inside the `UNIT_AURA`
handler failed, while the identical call from a slash command seconds later
returned everything. That suggested the *execution context* was the gate, and
the scan was moved onto a `C_Timer` ticker to escape it.

It made no difference. The next key ran the ticker — `updates = 16,397` proves
the scan was called that many times — and every read was still refused.

The apparent contradiction was an artifact of **where each test was run**: every
successful probe happened standing in a city, every failure inside a key.

### 4. "The restriction is the gate" — confirmed

The disproof of (3) was already in the database. Comparing content types:

| Content | Result |
|---|---|
| The Forge of Souls (timewalking) | `defensives = 4` counted |
| Every keystone run | `0`, with the taint error |

Same code, same session, same day. Aura reads succeed in normal content and are
refused inside a key. When the refusal was instrumented to name the active
restrictions, it reported `Combat+ChallengeMode`.

This is the same wall that already makes groupmate spell IDs secret to addons in
restricted content, and it is deliberate on Blizzard's part.

---

## What was ruled out as a workaround

- **`COMBAT_LOG_EVENT_UNFILTERED`** — a protected action on 120000+. Registering
  it raises the blocked-action popup, which is not catchable and not a Lua error.
- **`UNIT_SPELLCAST_SUCCEEDED`** — fires for party members, but every spell id is
  secret. Measured across one key: 2,086 readable for the player, **0 readable
  and 1,111 secret across party1–4**. Resolving a secret id returns a name that
  is itself secret.
- **Scanning from a different execution context** — tested and disproved above.
- **Reading `updateInfo` from the aura payload** — a dead end for a separate
  reason: it arrives in only ~0.6% of updates (24 of 3,867), which is why the
  capture scans and diffs instead.

---

## What replaced it

`AvoidableDamageTaken`, from the server-side damage meter (`C_DamageMeter`).

The meter is the sanctioned data source in restricted content and already
supplies damage, healing, interrupts, dispels and deaths **inside keys** — which
is why those columns were always populated while `def` was not. Avoidable damage
taken answers a closely related question, arguably better: not "did you press
your button" but "did you take damage you should not have".

It is read as an amount rather than a count, so it truncates like damage instead
of rounding a per-second rate to zero — the bug that once made the interrupts
column read zero.

Meter types exposed by `Enum.DamageMeterType` but still unused:
`Dps`, `Hps`, `Absorbs`, `DamageTaken`, `EnemyDamageTaken`.

---

## What still works, and what was kept

Aura-based defensive counting **does** work outside keys, and the capture is
still in place for normal, heroic and timewalking dungeons. Two things guard it:

- A **five-second backoff** after a refused read. A refusal stands as long as the
  restriction holds, and retrying four times a second cost 16,400 failed reads in
  a single key for no information. Measured on a simulated 23-minute key: 276
  calls instead of ~16,400, recovering the moment the restriction lifts.
- A **`defensivesBlocked` flag** on the record. Three different claims can live
  in that cell — *predates the feature*, *tracked and nobody pressed anything*,
  and *never allowed to look* — and only one of them is a number. A key was
  printing the second when it meant the third.

One thing is still open: in the timewalking dungeon only the player's own
defensives were counted; the four groupmates read zero. That is trivial content
where they may genuinely have pressed nothing, so it does not yet distinguish
"groupmate auras are readable outside keys" from "only your own ever are". The
next non-key dungeon with real damage settles it.

---

## Lessons worth keeping

1. **A silent `pcall` costs more than it saves.** The taint error existed from
   the first attempt and was swallowed by `pcall` for three sessions. It was
   found within minutes of being printed. The same pattern hid a tooltip bug that
   was breaking every mouseover.
2. **Instrument the failures, not the successes.** Counters that only counted
   successes could not distinguish six causes; one counter per drop point named
   the cause in a single line.
3. **Test in the content the feature is for.** Three sessions of diagnosis were
   spent on probes run in a city, for a feature that only ever fails in a key.
4. **The database usually already holds the disproof.** The Forge of Souls record
   had been sitting in SavedVariables the whole time.
