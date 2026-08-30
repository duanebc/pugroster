# Plan: repairing roster identity

**Status:** proposed, awaiting approval. Nothing changed yet.
**Backup taken:** `wow/backups/pugroster-20260830-025700/` (SavedVariables + `.bak`).

---

## The finding

`bnetAccountID` is **not stable between sessions**, and the roster used it as a
person's identity.

The proof is in the data. The same character name appears under two *adjacent*
account IDs, which can only happen if one real account was handed a different
number in a different session:

| Character | Account IDs |
|---|---|
| Drakowolf | 690 and 364 |
| Chinahunter, Chinamage | 254 and 253 |
| Averelle | 111 and 112 |
| Shadowplay | 80 and 81 |
| Romalove | 138 and 139 |
| Gluwudel | 135 and 136 |
| Kayyllynt | 183 and 184 |
| Brinalockz | 292 and 294 |
| Chumps | 372 and 374 |

Supporting: the ID values are small dense handles (8–690, 146 distinct across 435
characters), not the large opaque numbers a durable account ID uses. The large
groups were stamped across 2–4 distinct days, i.e. several sessions.

### Two consequences, one root cause

1. **Splitting** — one real person's alts land in several person records. This is
   observed above.
2. **Merging strangers** — a released ID is reused by a different account, and two
   unrelated people become one. This is **not** observed: zero persons hold two
   conflicting BattleTags, and zero hold two characters that appeared in the same
   run together. Only the small amount of stable evidence available so far
   separates us from it.

The second is why this is worth fixing now rather than after it bites.

---

## What is actually at stake

| | |
|---|---|
| Person records holding more than one character | 92 |
| ...pure friends-list alts, zero runs | 82 |
| ...groups with real run history | 10 |
| Notes / tags / tier overrides on any of them | **0 / 0 / 0** |

Nothing hand-authored exists to lose. Run counts, item level and auto-tier live
on the **character**, not the person, so splitting a group preserves all of it.
What changes is the "these are the same person" claim, and the numbers derived
from it — "N runs together" and the per-person rating aggregate.

---

## Decisions taken

- **Ungroup everything** not backed by a matching BattleTag, including the 10
  groups with run history.
- **Future auto-grouping only on BattleTag.**
- **Identity work ships before v1.0.6**, with the other nine commits.

---

## Order of work

Hardening lands **before** the repair, and this is not negotiable: `SyncBNetLinks`
runs on login and would re-merge everything within seconds of a repair done the
other way round.

### 1. Harden the identity (`Roster/Model.lua`)

- **`SyncBNetLinks` stops linking on `bnetAccountID`.** It links only when two
  characters carry the same non-empty `battleTag`.
- **Backfill the tag.** Every friends-list character records `battleTag` when the
  client offers one. Today 58 of 435 have it, because the field was only added
  yesterday; the rest fill in as those friends come online.
- **A merge guard.** `LinkCharacters` refuses when both sides have a BattleTag and
  they disagree — the one thing that can prove a merge wrong, checked before it
  happens rather than found afterwards.
- **`linkedBy` on the person**: `"battletag"` or `"manual"`. There is no such
  marker today, which is why the existing repair says outright that manual links
  are lost. Recording it means the *next* repair never has to.

`bnetAccountID` is kept, because two of its uses are correct — both are
session-scoped, which is what the value actually is:

- the online index (`Roster.OnlineIndex`), rebuilt every call;
- matching an incoming Battle.net whisper to a character (`Messaging/Replies.lua`).

It stops being written to the character record as an identity.

### 2. Replace the repair (`/pr unmerge`)

`Roster.RebuildPersonsFromAccounts` rebuilds person records **from the account
IDs** — the very thing now known to be unreliable. Running it today would
entrench the damage. It is replaced by `/pr ungroup`:

- **Dry run by default.** Prints what would change and touches nothing.
  `/pr ungroup confirm` applies it.
- Splits every multi-character person **not** justified by a shared BattleTag or
  a `linkedBy = "manual"` link.
- Each character becomes its own person, named after itself, keeping its runs,
  item level, tier and history.
- Person-level notes, tags and tier overrides go to the character with the most
  runs. There are none today, but the code must not assume that.

### 3. Verify

Re-run the three checks that produced this document, against the repaired data:

1. No person holds two conflicting BattleTags.
2. No person holds two characters seen in the same run.
3. No character name appears under two person records that a BattleTag says
   should be one.

Plus: the roster count, total runs, and every run record's observations are
unchanged — the repair must move people between person records and touch nothing
else.

### 4. Rollback

Close the game, restore `PugRoster.lua` from the backup above, reopen. The repair
is a one-command re-run if it needs doing again after a code fix.

---

## What this will visibly change

- The roster gains person records — currently 92 groups collapse into roughly 250
  individual entries. The roster gets **longer**, not shorter.
- "N runs together" drops for the 10 groups that had history, because a person's
  runs are now one character's runs. Sanlanesh's 16 runs across 5 characters
  becomes five entries.
- Per-person rating recomputes on the smaller aggregate.
- Grouping returns over time, correctly, as BattleTags are learned.

Worth being plain about: **for someone with genuine alts, this is a step
backwards until their BattleTag is known.** The trade is that every grouping that
remains is one the client actually vouched for.

---

## Open question, deliberately unresolved

I have not proven the ID is unstable across a *logout* specifically — the
comparison available (`PugRoster.lua` vs `.lua.bak`) turned out to be two saves
from the same play session, where 433 of 433 IDs matched and told us nothing. The
adjacent-ID evidence is strong and comes from real sessions days apart, so the
conclusion stands on that. A logout-and-compare would settle it outright and
costs one relog if you want the certainty before I touch anything.
