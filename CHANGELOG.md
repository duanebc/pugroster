# Changelog

## [Unreleased]

First implementation, built from `docs/pug-rater-plan.md`. Covers phases 1-6 of
the plan; the Python companion (phase 3's out-of-game half) is not written yet.

### Capture
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
- Outcome-dominant provisional tiers, scaled by key level, weighted by role,
  decayed by season, gated on sample size.
- Per-run breakdown exposed in the roster panel and `/pugdebug tier`.
- Reader for the companion-generated `PugRater_Lookup.lua`; refined tiers and
  Raider.IO scores are preferred when present, and its absence is a no-op.

### Roster
- Person/character model with Battle.net auto-linking and manual "same person"
  linking.
- Manual tags with default categories, user-extensible; derived auto-tags for
  role, spec, item level bracket, Raider.IO bracket and tier.
- Filter builder over tags and numeric fields, saveable as named groups.
- Online suggestions from the friends list, Battle.net friends and guild roster.

### Messaging
- Templates with placeholder expansion, managed in the send panel.
- Recipient preview with per-person messages, staggered send queue, cancel.
- Per-person cooldown, `do-not-message` tag and sent log, enforced in the send
  path rather than the UI.
- Verbatim reply tracking with manual yes/no marking and one-click invite.

### Display
- Tier, runs together, tags and note on player tooltips.
- Colour badge on group-finder applicants, feature-detected and taint-safe.
- Dismissible toast when a rated player joins the group.

### Development
- `Debug/` simulation suite: fake runs driven through the real event handlers,
  bulk history seeding, seeded roster and tags, fake friends list, message echo
  and simulated replies. Stripped from released packages by `.pkgmeta` and a
  `#@debug@` block.
