# PugRoster — M+ Player Rating, Roster & Messaging Addon (Plan Spec)

WoW Midnight addon + Python companion app. Records every Mythic+ run you do, rates the players you ran with, organizes them into a taggable roster, and lets you message groups of them by tag. Goal: recommend good players early in a season based on your own positive experiences.

This is a plan handoff document. All design decisions below are settled; "Open risks" lists the only items requiring live-client verification before implementation.

---

## 1. Architecture Overview

Two components, same hybrid pattern as KeyGrid:

1. **In-game addon (Lua)** — captures run data from events and combat log, computes provisional ratings, renders all UI, persists everything to SavedVariables.
2. **Companion app (Python CLI + SQLite)** — reads SavedVariables, enriches with Blizzard API + Raider.IO API, archives/prunes old data, recomputes refined ratings, and writes a Lua lookup file back into the addon folder that the addon loads on next reload.

Data flow:

```
In-game events ──► SavedVariables (PugRosterDB.lua)
                        │
                        ▼ (companion run, out of game)
              Python CLI ──► SQLite (canonical store)
                        │        ▲
                        │        └── Blizzard API, Raider.IO API
                        ▼
              PugRoster_Lookup.lua (generated data file)
                        │
                        ▼ (next /reload or login)
              Addon loads refined tiers + RIO scores
```

Dev environment: Windows 11, Git Bash, Python for the companion. Addon dev against the live Midnight client (12.1, Season 2).

## 2. Scope

- **M+ only.** Run boundary = `CHALLENGE_MODE_START` → `CHALLENGE_MODE_COMPLETED` (or group disband/leave detection for abandoned runs). No raid tracking.
- Single-account data now. Schema and companion must be designed so a **shared friend-group pool** can be added later (export/import via companion, not in-game) without migration pain — include an `origin` field on runs/observations from day one.

## 3. Data Capture (per run)

### 3.1 Run record
- Dungeon (map ID + name), key level, affix IDs, season ID, timestamp
- Timed yes/no, completion time vs. par (margin in seconds), upgrade level (+1/+2/+3), depleted/over-time completion, abandoned/disband flag
- Key holder (who owned the key)
- Full group composition (all five GUIDs)
- Origin field (`self` now; future values for shared-pool imports)

### 3.2 Per-player observation (one per groupmate per run)
- GUID (primary key), Name-Realm (display), class, spec, role, item level at run time
- Deaths (count), wipes participated in (party-wide death events)
- Interrupts, dispels, CC casts (from combat log)
- Left-early flag (left group before run ended)
- Damage/healing totals — from own tracking; if **Details** is installed, enrich with its per-player numbers via its Lua API (optional dependency, feature-detect at runtime, never hard-require)
- Avoidable damage: **deferred to v2.** Deaths + interrupts + dispels serve as the proxy in v1.

### 3.3 Chat capture
- Log **all** `CHAT_MSG_PARTY`, `CHAT_MSG_PARTY_LEADER`, and `CHAT_MSG_INSTANCE_CHAT` lines during an active run, attributed by sender GUID, attached to the run record
- Whispers to/from groupmates during the run: capture as well (`CHAT_MSG_WHISPER` / `CHAT_MSG_WHISPER_INFORM`), flagged as whispers
- Companion app is responsible for pruning/archiving chat to keep SavedVariables bounded (see §8)

### 3.4 Events (verify names against live client)
- `CHALLENGE_MODE_START`, `CHALLENGE_MODE_COMPLETED`, `CHALLENGE_MODE_RESET`
- `COMBAT_LOG_EVENT_UNFILTERED` — deaths (`UNIT_DIED` for party GUIDs), interrupts (`SPELL_INTERRUPT`), dispels (`SPELL_DISPEL`), CC (curated aura list or `SPELL_AURA_APPLIED` with CC flag)
- `GROUP_ROSTER_UPDATE` — join/leave detection, left-early flags
- `PLAYER_ENTERING_WORLD` — state recovery after /reload mid-run (persist in-progress run state)
- `C_ChallengeMode.GetActiveKeystoneInfo()`, `C_ChallengeMode.GetCompletionInfo()` for run metadata
- Inspect API (`NotifyInspect` queue) for spec/ilvl of groupmates — throttled, best-effort

## 4. Rating Model

### 4.1 Tiers
Auto-computed tier per player: **Great / Good / Neutral / Avoid**, plus:
- Free-text notes (per person)
- Manual tier override (sticky; never silently overwritten by auto-computation — show both "auto" and "override" values)

### 4.2 Scoring principles
- **Outcome-heavy:** timed / upgrade level / completion are the dominant signals. Per-player stats (deaths, interrupts, relative damage/healing) adjust within the outcome band.
- **Key-level scaled:** a +10 performance outweighs a +5. Scale contribution by key level relative to the season's meaningful range.
- **Role-weighted:** tank and healer deaths weigh heavier than DPS deaths; DPS judged more on interrupts and damage relative to group.
- **Confidence:** number of runs together matters. One good run ≠ Great; require a minimum sample before leaving Neutral, and expose the run count in UI.
- **Season decay:** previous-season runs count at reduced weight (suggested: ×0.5 for last season, ×0.25 older; make constants configurable). Early-season recommendations lean on decayed history until current data accumulates.
- Left-early/disband events are strong negative signals unless the run record shows a group-wide disband.

### 4.3 Computation stages
1. **In-game provisional tier** — recomputed after each run from local data only. Cheap, pure-Lua.
2. **Refined tier** — companion app recomputes with the full SQLite history + RIO scores (this season and last season) + Blizzard API data, then ships results back in the lookup file. Addon prefers refined values when present and newer.

## 5. Roster & Tagging

### 5.1 Entity model
- **Person** is the top-level entity; **characters** link under a person.
  - BattleTag friends: auto-link characters via friends-list account info when observable (only resolvable while they're online — cache aggressively).
  - Non-friends/pug strangers: characters stand alone until manually linked in the roster UI ("mark as same person").
- **Person-level:** manual tags, notes, tier (aggregated across their characters), sent-log, do-not-message flag.
- **Character-level:** auto-tags — spec, role, ilvl bracket, RIO bracket, computed tier inputs.

### 5.2 Tags
- **Auto-tags** (maintained by addon/companion, read-only): role, spec, ilvl bracket, RIO score bracket, computed tier.
- **Manual tags**, shipped default categories, all user-extensible with fully custom tags:
  - Relationship: IRL friend / guild / met-in-pug
  - Play style: push / chill / learning
  - Availability: weeknights / weekends (free-form additions allowed)
  - Voice: yes / no / Discord
- Tag storage: normalized tag list + person↔tag mapping (both in SavedVariables and SQLite).

### 5.3 Roster UI
- Sortable table: name, role, spec, ilvl, RIO, tier, runs together, last-played-with; tag chips per row.
- Clicking a tag chip adds it to the active filter.
- **Filter builder:** conditions over tags and numeric fields (e.g. role = healer AND ilvl ≥ X AND tag = push). Filters saveable as **named groups** ("High Key Roster").
- **Online suggestions:** when forming a group, show currently-online friends matching the active filter/saved group (friends list + guild roster online status).

## 6. Tag Messaging

- Flow: pick saved group or ad-hoc filter → **preview recipient list** (online matches only) → uncheck anyone → **send-all with stagger** (~1–2 s between sends, configurable) to avoid spam throttling/squelch.
- **Templates with placeholders:** saved message templates; placeholders at minimum `{key}`, `{dungeon}`, `{mykeylevel}`, `{name}`. Template manager UI (add/edit/delete).
- **Channel:** `BNSendWhisper` when the person is a BNet friend (reaches any character/game), else `SendChatMessage("WHISPER")` to Name-Realm. Recipients are online-only by design.
- **Guardrails:**
  - Per-person cooldown (default: don't re-message within N hours; configurable) — cooldown-blocked people shown greyed-out in preview with reason
  - Sent-log: who, what, when, via which channel — visible per person and globally
  - `do-not-message` tag honored everywhere, including manual sends from the panel
- **Reply tracking:** watch `CHAT_MSG_WHISPER` / BNet whisper events from recent recipients; show reply text next to each name in the send panel. **No automated intent classification** — display the reply verbatim with manual ✓/✗ marking and a one-click party invite button per replier.

## 7. Display Surfaces

1. **Tooltip injection** — tier, runs together, top tags, note preview on player unit/LFG tooltips.
2. **LFG applicant badge** — color/icon on applicants in the group finder applicant list (see Open risks).
3. **Popup on join** — when a rated (non-Neutral or noted) player joins your group: small dismissible toast with tier + note. Include an "off" toggle in options since it can get noisy.
4. **History panel** — browsable run history: per run (details, group, chat log) and per person (all shared runs, stat aggregates, tier evolution).
5. **Roster panel** — §5.3.

## 8. Storage

### 8.1 SavedVariables (addon)
- `PugRosterDB`: runs (with observations + chat), persons, characters, tags, templates, sent-log, settings, refined-lookup cache metadata.
- Keys: **GUID primary**, Name-Realm display. Accept drift on renames/transfers; GUID survives both for the same character.
- **Keep everything in-game**; the companion archives. If SavedVariables size becomes a problem before a companion run, degrade gracefully (oldest chat logs truncate first — never lose run/observation rows in-game before the companion has exported them; track an `exported` flag per run).

### 8.2 Companion (Python CLI + SQLite)
- Commands (suggested): `sync` (parse SavedVariables → SQLite, mark exported), `enrich` (Blizzard API: character profile/ilvl/spec validation; Raider.IO API: current + previous season scores), `rate` (refined tier computation), `emit` (write `PugRoster_Lookup.lua`), `prune` (archive old-season chat/runs out of the SavedVariables side on next emit), `report` (quick CLI views). `all` runs the pipeline.
- SQLite is the canonical long-term store. SavedVariables is a rolling capture buffer + current-season working set.
- Config file for API credentials (Blizzard client ID/secret via OAuth client-credentials flow; Raider.IO is keyless for basic endpoints), region/realm defaults, addon folder path.
- Rate-limit and cache all external API calls; RIO lookups are per character, batch politely.
- Future: `export-pool` / `import-pool` commands for the shared friend-group dataset (schema carries `origin` already).

### 8.3 Generated lookup file
- `PugRoster_Lookup.lua` written into the addon folder, loaded via .toc. Contains refined tiers, RIO scores (this + last season), person-links discovered offline. Addon treats it as read-only enrichment; absence of the file must never break the addon.

## 9. Project Layout (suggested)

```
PugRoster/
  PugRoster.toc
  Core.lua            -- init, saved vars, event frame
  Capture/
    RunTracker.lua    -- challenge mode lifecycle, run records
    CombatLog.lua     -- deaths, interrupts, dispels, CC
    ChatLog.lua       -- party/instance/whisper capture
    Inspect.lua       -- spec/ilvl inspection queue
    DetailsBridge.lua -- optional Details enrichment (feature-detected)
  Rating/
    Provisional.lua   -- in-game tier computation
  Roster/
    Model.lua         -- persons, characters, tags, links
    Filters.lua       -- filter builder + saved groups
  Messaging/
    Sender.lua        -- staggered send queue, channels, cooldowns
    Templates.lua
    Replies.lua
  UI/
    RosterPanel.lua
    HistoryPanel.lua
    SendPanel.lua
    Tooltip.lua
    LFGBadge.lua
    JoinPopup.lua
    Options.lua
  Debug/              -- entire folder excluded from release packages (see §11)
    DebugCore.lua     -- flag, /pugdebug command router, guards
    FakeRun.lua       -- synthetic run/player/chat generator
    EventSim.lua      -- drives the addon's real handlers with fake events
    FakeRoster.lua    -- seeded persons/tags for roster & messaging tests
    EchoSender.lua    -- send-path interceptor + simulated replies
  PugRoster_Lookup.lua -- generated by companion (checked-in stub)
companion/
  pugroster/           -- python package
    cli.py, savedvars.py, db.py, blizzard.py, raiderio.py,
    rating.py, emit.py, prune.py
  pyproject.toml
  config.example.toml
```

## 10. Implementation Phases

1. **Capture core** — run lifecycle, combat-log stats, group roster, chat log, SavedVariables schema, /reload-safe in-progress state. *Exit: a completed key produces a full run record.*
2. **Provisional rating + history panel** — scoring v1, per-person aggregation, browsable history. *Exit: tiers visible and explainable from in-game data.*
3. **Companion pipeline** — savedvars parser, SQLite schema, enrich (Blizzard + RIO), refined rating, emit lookup, prune/archive. *Exit: round trip works; RIO scores appear in-game.*
4. **Roster & tagging** — person/character model, manual linking, tags, filter builder, saved groups, roster panel, online suggestions.
5. **Display surfaces** — tooltip, join popup, LFG badge (risk-gated).
6. **Messaging** — templates, send panel, stagger queue, cooldowns, sent-log, reply tracking, invite button.
7. **Polish/v2 candidates** — avoidable-damage via Details plugin or curated lists, shared friend-pool export/import, Details damage percentile vs. own history.

## 11. Debug / Dev Mode (development builds only)

Purpose: test every feature without running real dungeons. Iterating on capture, rating, and UI must not require a 30-minute key per attempt.

### 11.1 Gating
- Debug code lives entirely in `Debug/` plus a `DEBUG_MODE` flag file. The **release packager excludes the folder and flag** (CurseForge `.pkgmeta` `ignore` list, or the build script strips it), so debug code is physically absent from shipped zips — not merely toggled off.
- All hooks from production code into debug code are guarded feature-detections (`if PugRoster.Debug then ...`), so production files load cleanly when the folder is gone.
- In dev builds, `/pugdebug` is the command router; it does not exist in release builds.

### 11.2 Simulation capabilities
- **Fake-run generator** (`/pugdebug run [keylevel] [dungeon]`): creates a synthetic run — randomized-but-plausible groupmates (GUIDs, names, classes, specs, ilvls), deaths, interrupts, dispels, chat lines, timer outcome, upgrade level. Parameters overridable (e.g. force a disband, force a wipe-heavy run, force a left-early).
- **Event simulation** (`EventSim`): rather than writing records directly into the DB, the simulator **fires the addon's own event handlers** with synthetic payloads (`CHALLENGE_MODE_START`, combat-log subevents, roster updates, `CHALLENGE_MODE_COMPLETED`) so the real capture pipeline is exercised end-to-end. A direct-inject mode also exists for bulk data seeding (e.g. `/pugdebug seed 50` to generate 50 historical runs for rating/decay testing).
- **Seeded roster** (`/pugdebug roster`): populates fake persons with linked characters, tags across all default categories, varied tiers and run counts — makes filter builder, saved groups, sorting, and tag chips testable immediately.
- **Messaging sandbox**: with debug active, the send queue routes through `EchoSender` instead of `SendChatMessage`/`BNSendWhisper` — messages print locally with full template expansion, and simulated replies (`/pugdebug reply <name> <text>`) drive the reply-tracking panel, cooldown, and sent-log logic without whispering anyone real.
- **State tools**: `/pugdebug wipe` (reset DB with confirmation), `/pugdebug export` (dump current run state to chat/copyable frame), `/pugdebug tier <name>` (show rating-computation breakdown for a person — inputs, weights, decay applied).
- Fake data is flagged `debug = true` on every record; the companion app **skips or segregates** flagged records so test data never pollutes the SQLite canonical store, and `/pugdebug wipe fake` removes only flagged records.

### 11.3 Companion debug support
- `--debug` flag on the CLI: reads a fixture SavedVariables file instead of the live one, writes to a scratch SQLite DB, and emits the lookup to a test path. Fixture files generated from `/pugdebug seed` output.
- Mock mode for Blizzard/RIO API calls (canned JSON fixtures) so `enrich`/`rate`/`emit` are testable offline and in CI.

### 11.4 Testing note for implementation
Each phase in §10 should land with its debug counterpart in the same phase (e.g. Phase 1 ships `FakeRun` + `EventSim`; Phase 4 ships `FakeRoster`; Phase 6 ships `EchoSender`). Debug tooling is not a final phase — it is the enabler for every phase.

## 12. Open Risks (verify against live Midnight client before/while implementing)

1. **Secret Values / combat-log restrictions:** confirm `COMBAT_LOG_EVENT_UNFILTERED` still exposes other players' `UNIT_DIED`, `SPELL_INTERRUPT`, `SPELL_DISPEL` in M+ this season. If restricted, fall back to whatever Details can legally read via its bridge, and degrade stats per capability.
2. **LFG applicant frame hooking:** confirm the applicant list frames are hookable/taint-safe for badges. If not, drop to tooltip-only for applicants.
3. **Details API surface in Midnight:** verify `Details:GetCurrentCombat()` / segment APIs still exist as expected; bridge must feature-detect per function, not per addon.
4. **BNet account-info APIs:** confirm which friends-list functions expose account↔character mapping for auto-linking, and their online-only limitations.
5. **Chat send throttling:** verify current server-side whisper throttle behavior to tune the stagger interval.
6. **Season IDs / affix API:** confirm current-season constants and `C_MythicPlus` / `C_ChallengeMode` return shapes on 12.1.

## 13. Explicit Non-Goals (v1)

- Raid tracking
- Avoidable-damage measurement
- Automated reply-intent classification
- In-game cross-account data sharing (addon comms)
- Any web dashboard
