# Demscore feedback updates, round 1

Changes made in response to the client's notes on the prototype, plus the follow-up
decisions taken while reviewing them. Dated 2026-10-12.

**Where it is:** merged into `main` (merge commit `9cdc40a`; the work itself is `8831560`
and `ca937a5`, with webapp commit `d1759f1`). It was built in a separate worktree running
at <http://localhost:8091> beside the original on 8090 for comparison; that worktree, its
branch and its deployment have been removed, and the 8090 deployment now runs the merged
version.

## Summary by client request

| Client request | Status | What was done |
|---|---|---|
| Toggle off the bottom box and the timeline | Done | Hide buttons on the timeline, the bottom panel and the side panel, plus a fullscreen "map only" mode. All panels also scale down on smaller screens. |
| Thin the border lines | Done | Area outlines 1.6 px → 1.0 px. |
| Move the selected-variable note off the US | Done (removed) | The title over the map is gone; the selected row in the variable list is made much more prominent instead. |
| Remove the Mercator option | Done | Removed from the View switch (Map / Table remain). Server side left in place. |
| White space around country edges | Done | Countries with no value are drawn as grey hexagons; the cream land basemap is off. |
| Brown-blue default; keep red; remove red-green and blue-yellow | Done | Brown – Blue is the default, Red – Blue the alternative; Viridis and Cividis withdrawn. |
| Narrow the timeline bar | Done | Its gap to the map edges doubled (24 → 48 px each side); the play/speed controls take far less width. |
| Remove "Animate", leave only play | Done | Icon-only play button. |
| Timeline numbers darker and larger | Done | |
| Year label above the timeline smaller | Done | |
| Speed option under/beside play, maybe a slider | Done (as a dropdown) | Redesigned to the mockup: a play square and a speed square; the speed square opens a list of speeds. |
| Hover card: add number of countries with data | Done | One bar per year; the card shows the year and its country count. |
| Hover card: remove "Map Tiles Ready" and bar-height note | Done | |
| Grey out topics/datasets that don't apply | Done | Faded chips stay clickable and clear the conflicting filter. |
| Toggle for the left panel | Done | Hide button; hovering the remaining strip brings it back. |
| Download images and short animations | Deferred | Agreed to do on a separate feature branch (PNG + WebM, watermarked with Demscore and InfraVis logos; needs the InfraVis logo). |

## The map

### No-data countries and the "white space"

The white fringe was the cream land basemap showing wherever a hexagon's edge and the
coastline disagree — a hex grid cannot follow a coastline. Present-day countries with no
value for the selected variable-year are now drawn as **grey hexagons** (`#808080`), and the
land basemap is switched off, so the map is hexagons edge to edge.

- Mid grey rather than light grey: every light grey tested read as the middle class of the
  Brown – Blue ramp.
- Historical units (the Soviet Union, the pre-1871 German and Italian states, …) are still
  drawn only in years they have a value; the grey never sits under or over them.
- Antarctica is not drawn: it is in no dataset, and grey would say "not measured".
- Small island states without data now show as grey dots in the oceans — correct, but a
  visible change.
- The land basemap is kept as a developer switch (Shift+D → "Landmasses").

### Outlines

Area outlines are 1.0 px (were 1.6 px). The switch is labelled **"Outline equal values"**
(was "Equal-colour areas"). On screens narrower than 520 px, where its label no longer fits,
the switch is hidden rather than shown without a label.

### Map projection

Mercator is no longer offered; the View switch is **Map | Table**. Its server-side mesh and
layers are left in place, so offering it again is a one-line change.

### Colour schemes

For variables with a direction (e.g. democracy indices):

- **Brown – Blue** — the default for everyone, including returning visitors.
- **Red – Blue** — the previous default, kept as an option.
- Viridis and Cividis (the "red-green" and "blue-yellow" options) are withdrawn from the
  picker. Note: these were the only schemes that work in greyscale or for readers who cannot
  use hue at all; that trade-off was accepted.

For neutral variables (no better or worse end, e.g. cabinet composition, tax revenue), each
scheme has its own neutral ramp:

- Under Brown – Blue: **Purple – Magenta** (replaces an indigo-to-yellow ramp whose dark end
  used the same indigos as the "favourable" end of Brown – Blue).
- Under Red – Blue: **Green** (replaces black-to-yellow, which had no natural reading).

Scheme descriptions (the tooltips in the colour dropdown) were rewritten. They no longer
call either end "unfavourable" — neutral variables were previously described that way — and
developer notes such as colour-blindness remarks were removed from them. All colour ramps
pass the repository's contrast checks (adjacent classes, greyscale, three types of colour
blindness, distance from the no-data grey).

Both neutral ramps run **pale = low, dark = high**, so darker means more — the way most
readers take a single-hue scale. (They first ran the other way, inherited from the old
black-to-yellow ramp.)

## The bottom panel

Rebuilt as a single row, following the mockup: **View** (Map | Table) · **legend** with the
no-data swatch beside it · **Colours** dropdown · **Outline equal values** switch · hide
button.

- The colour scheme is chosen from a dropdown that opens upwards and shows each scheme's
  name over its colour ramp, with a check mark on the selected one.
- The hide button folds the panel down to just the legend, which moves to the bottom-left
  corner of the map (clear of the credit line along the bottom right); the chevron beside
  it brings the panel back.
- On phones the panel is two rows: the legend on top, the controls below.

## The timeline

- **Play and speed:** two squares the height of the timeline card, as in the mockup — a navy
  play button with a filled triangle, and a speed square showing e.g. "4×" over "SPEED".
  The whole speed square is a button that opens a list of speeds (1×–8×).
- "Animate" text removed; numbers on the scale darker and larger; the year label smaller.
- 48 px gap between the timeline and the map edges on each side (was 24 px).
- **One bar per year**, always. The hover card shows the year and the number of countries
  with data, e.g. "1919 — 146 countries with data". "Map tiles ready" (a debugging leftover)
  and the bar-height explanation are gone.
- A hide button at the right end of the card (chevron with "HIDE" under it).

## The side panel

- **Selected variable:** stronger mid-blue background, and a wider left edge in the
  terracotta of the divider between the panel and the map.
- **Filter chips:** topics not covered by the selected datasets, and datasets with nothing
  under the selected topics, are faded. A faded chip is still clickable: clicking it clears
  the other filter group and turns the chip on, so the list is never emptied.
- A hide button in the header slides the panel away; a thin strip remains on the left edge,
  and hovering it brings the panel back.

## Hiding panels and fullscreen

- The side panel and the timeline slide off-screen and leave a thin strip; pointing at the
  strip brings the panel back while the pointer is on it, and the panel's own button pins it
  back. Tabbing into a hidden panel also brings it back.
- The bottom panel folds to its legend (see above).
- **Fullscreen** (bottom-right corner): requests browser fullscreen and shows only the map.
  The credit line stays visible — the map's licences require it to be always shown. Escape,
  or the same button, returns to normal.
- Hidden panels are not remembered between visits.
- Hiding the side panel and the timeline is desktop-only; on phones these sit outside the
  map area anyway.

## Smaller screens

On laptop-sized windows the side panel, timeline and bottom panel are drawn proportionally
smaller (to 0.8× at 1366×768, 0.74× at 1280×720), which frees a large part of the map.
Phones keep their own layout.

## Technical notes

- **New database table** `demscore.hex_mesh_overlaps` (built by
  `sql/mapserver_hex_setup.sql`): which hexagon cells are shared between countries, used to
  keep no-data grey away from historical units. It was built directly in the running
  database; the full setup script has not been rerun.
- **New backend route** `/api/year-counts?dataset=&variable=`: per-year country counts for
  the timeline.
- **MapServer:** the fill and outline queries draw no-data hexagons (class 99); the outline
  is 1.0 px. Colours are still generated from `webapp/src/core/palettes.js` into
  `mapserver/hex_classes.inc`.
- **Tile caches:** several changes repaint tiles under unchanged URLs. The browser tile cache
  was bumped to v17 (`webapp/sw.js`); open tabs need a hard reload. The local server tile
  cache was cleared after the merge; on any other server with the tile cache enabled, run
  `./deploy.sh clear-map-tile-cache` after deploying.
- **Cookies:** the colour-scheme cookie was renamed so every visitor starts on Brown – Blue.
- **Deployment parameters:** `compose.yml` and the scripts now take
  `DEMSCORE_CONTAINER_PREFIX` and `DEMSCORE_DB_PORT` (defaults unchanged), which is what lets
  the two deployments run side by side.
- **Docs updated:** `AGENTS.md`, `webapp/AGENTS.md`, `ACCESSIBILITY.md` (including the
  keyboard checklist and tab order).
- **Not yet done:** a screen-reader pass, testing in Firefox (panel scaling needs
  Firefox 126+), and a full rerun of `scripts/setup_mapserver_hex_service.sh`.

## Still open

1. Downloads (images and short animations) — separate feature branch; needs the InfraVis
   logo and placement from the client.
2. Phones: the bottom panel's hide button is not shown there yet (no free spot that does not
   cover the legend or the credit line).
