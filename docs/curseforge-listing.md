# Filling in the project pages

Instructions only. **No text on this page gets pasted anywhere** -- it tells you
which file goes in which field. The description lives in its own file precisely
so it can be pasted whole, with nothing to trim off either end:

| Field | Paste from | How |
| --- | --- | --- |
| Description | `docs/curseforge-description.md` | select all, paste, **Markdown tab** |
| Summary | the 256-character block below | type it in, it is one paragraph |
| Avatar | `images/pugroster/pugroster-logo-400.png` | upload |

Release notes are **not** set here -- the packager uploads `CHANGELOG.md` as the
notes for each release automatically. Keep the description in step with
`README.md` when the addon changes.

## Where

The packager uploads to project **1670548**. The dashboard it names is:

    https://wow.curseforge.com/projects/1670548

From there the fields are under **Settings** in the left-hand nav:

- **Description** -- the long body. The editor has a rich-text tab and a
  **Markdown** tab; pick Markdown, or every `#` heading arrives as a literal
  hash character.
- **Summary** -- the one-paragraph blurb, hard-capped at 256 characters.
- **Avatar / project image** -- upload the 400px logo.
- **Categories** -- Group Finder (matches `## X-Category` in the .toc).

If that host redirects, the same project opens on the legacy site at
`https://legacy.curseforge.com/project/1670548`; the WoW author UI has lived on
the legacy domain for a while, so expect to land there.

Uploaded files appear under **Files**. The v1.0.0 zip is already there.

## Summary (256 character limit)

Paste this into the Summary field:

```
PugRoster remembers who you had a good key with. Every Mythic+ run you do builds
a roster of the players in it, rated on what actually happened, tagged and
filterable -- so you invite off your own runs, not somebody else's score.
```

That is 229 characters as one paragraph -- the line breaks above are for reading
here, not part of it.

## Tags / keywords

mythic+, mythic plus, keystone, group finder, lfg, roster, rating, pug, whisper,
friends, guild, raider.io

## Screenshots still needed

None of the images in the repo are usable for a listing yet, and the description
converts badly without them. Worth capturing, in this order:

1. The Roster tab, populated, with tiers and tags visible.
2. The Send tab mid-preview -- the expanded per-recipient messages are the
   feature nobody expects and the one that sells it.
3. A run history record expanded, showing the per-player breakdown.
4. The filter builder with a real filter in it.
5. A player tooltip with the tier block.

Take them with the game UI otherwise quiet: no damage meter overlaying the
window, chat cleared, and the PugRoster window not overlapping anything else.
