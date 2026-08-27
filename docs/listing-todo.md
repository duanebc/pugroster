# CurseForge listing -- what is still outstanding

Checked against the live project on 2026-08-27 via the CurseForge API
(`GET /v1/mods/1670548`). Project 1670548, slug `pugroster`.

Dashboard: https://wow.curseforge.com/projects/1670548
Public page: https://www.curseforge.com/wow/addons/pugroster
(the author UI usually redirects to `legacy.curseforge.com/project/1670548`)

## Already done -- do not redo

- **Description** is set and current. It contains the roster search box, the
  `2 +3` session count and the `{keydungeon}`/`{keyname}` copy, so it matches
  what shipped in v1.0.0.
- **It rendered as real HTML** -- headings, the commands table and the code
  blocks all came through, with no literal `##` anywhere. The Markdown tab was
  used correctly.
- **Avatar** is the right logo at 400x400.
- **One screenshot** is up: the Roster tab, populated, tiers and tags visible.
- **v1.0.0 is uploaded.** The packager reported success against project 1670548.

## Blocking nothing, but worth doing first

**Categories are wrong.** Currently:

    Chat & Communication, Development Tools, Data Broker, Miscellaneous

`Development Tools` and `Data Broker` are simply not what this addon is. The
`.toc` declares `## X-Category: Group Finder`, which is the right answer;
`Chat & Communication` is defensible alongside it for the whisper side. Wrong
categories are the kind of thing a moderator stops on, so this one is worth two
minutes now rather than later -- it works against getting through review, which
is the whole point of being in the queue.

Settings -> Categories on the dashboard.

## The rest, whenever

- [ ] **Source and Issues links.** Both are empty. Set both to
      `https://github.com/duanebc/pugroster`. CurseForge renders them as buttons,
      and an open-source addon with no source link reads as odd.

- [ ] **Four more screenshots.** One is up; the listing converts badly without
      the others. In order of how much they help:
      1. The Send tab mid-preview -- the expanded per-recipient messages are the
         feature nobody expects and the one that sells it.
      2. A run history record expanded, showing the per-player breakdown.
      3. The filter builder with a real filter in it.
      4. A player tooltip with the tier block.

      Capture with the game otherwise quiet: no damage meter over the window,
      chat cleared, nothing overlapping the frame.

- [ ] **Retake or crop the existing screenshot.** Its title bar reads
      `@project-version@`, because the junctioned dev install reads the .toc
      before the packager substitutes the tag. A build installed from the release
      zip shows `v1.0.0`. Cropping the title bar works just as well.

- [ ] **Reconcile the summary.** The live summary is better than the one in
      `curseforge-listing.md` -- it mentions whispering a whole group, which the
      repo copy leaves out. Update the repo doc to match the live text, so the
      repo stays the source of truth rather than drifting behind it.

## Status, and what it means for testing

The project is **status 1 -- New, awaiting moderator review**. Its public file
list is empty, and will stay empty until it clears: uploaded files are not
downloadable by anyone else while a project is in the queue.

So friends **cannot install from CurseForge yet**, however long the queue takes.
Until it clears, send them the GitHub release instead -- byte-for-byte the same
zip the packager uploaded:

    https://github.com/duanebc/pugroster/releases/tag/v1.0.0

They unpack `PugRoster/` into `World of Warcraft/_retail_/Interface/AddOns/`.
