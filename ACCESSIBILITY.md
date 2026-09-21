# Accessibility

What the map offers to someone who cannot see it, cannot use a mouse, or cannot tell two
colours apart — how it is built, and how to check it still works.

The hard part of this application is that the map is a WMS image. There is no feature under
the pointer to interrogate, no DOM inside the tiles, nothing an assistive technology can be
asked about. Everything below follows from that: the map's contents have to be served a
second time, as text, from the same numbers the picture was drawn from.

## What exists

### The map as text

Three things, all in `webapp/src/controllers/MapDataController.js`, all fed from
`/api/class-breaks` and `/api/map-data` — which read `demscore.country_scores()`, the same
function the WMS layer classes on. That shared source is the only thing keeping the picture
and the text in step; there is no assertion that they agree.

| | what it is | when it speaks |
|---|---|---|
| `#mapSummary` | dataset, variable, year, projection, how the colours run, how much of the world carries a value, and each class's span | never — a `region`, read on demand |
| `#mapAnnouncer` | one sentence naming the variable and its coverage | once the selection has stopped moving; never during autoplay |
| `#mapDataDialog` | every country on the map as a sortable row, plus a CSV of the same | on request, from the **Data table** button in the legend |

The summary is deliberately not a live region. It is several sentences plus seven list items
and it is rewritten on every frame of an animation; a polite region carrying that would talk
over everything else on the page. The announcer is the live one and holds a sentence.

The data table is the whole country table, not only the countries with values. "Somalia is
not shown for 2020" is as much a reading of the data as a number is.

### Colour

Two ramps, written twice — `mapserver/hex_classes.inc` paints the hexagons and
`LEGEND_COLORS_*` in `webapp/src/controllers/MapController.js` paints the legend bar that is
the key to them. `scripts/check_palette_contrast.mjs` reads both files, fails if they
disagree, and measures every adjacent pair in greyscale and under simulated protanopia,
deuteranopia and tritanopia.

- **Neutral** is viridis, trimmed to 0.15–0.85. It replaced a seven-step emerald ramp whose
  two lightest classes were ΔE 6 apart under protanopia and deuteranopia — indistinguishable
  — and whose lightest shade sat ΔE 17 from the cream no-data land, so "no value" read as
  "bottom of the scale". Viridis is monotonic in lightness, so it also orders correctly in
  greyscale and on a projector.
- **Diverging** is ColorBrewer RdYlBu, and it stays. Every adjacent pair clears the
  thresholds, but it is *not* monotonic in lightness: classes 2 and 7 print as the same grey.
  That is inherent to a diverging scheme, and it is the price of keeping polarity direction
  in the colour — blue at one end, red at the other. The script reports the collision as a
  note on every run so it stays a known trade.

What answers the grey collision is that colour is not the only channel:

- the equal-colour **area outlines** are on by default, and their toggle is on screen beside
  the projection radios rather than behind the Shift+D developer extras, because a control
  that carries this much is not a developer affordance;
- every legend swatch's accessible name carries its class number, value span and country
  count in full, so it does not depend on the hover card;
- the data table gives the exact value and class per country.

### Everything else

- Focus: `:focus-visible` at the top of `styles.css` is the floor. The transparent range
  input, the OpenLayers zoom buttons, the playback row, the projection radios and the legend
  swatches all draw a visible ring now; the range input's ring is drawn on the marker,
  because the input itself is invisible and covers the whole timeline.
- Tab order follows the visible layout: sidebar → timeline (top of the map) → map controls →
  legend (foot of the map). `#timeline-overlay` sits before `<main id="map">` in the source
  for that reason, though it is painted over it.
- The variable info card is a non-modal `dialog` when it is opened by a click — with a name,
  a close button, a focus moved into it and a focus given back — and a `tooltip` when it is
  shown by a hover.
- The phone picker is a grouped list of buttons rather than a listbox it never implemented.
- Coverage ranges are in every row's accessible description, not only in a `title`.
- The loading spinner has a spoken counterpart, but only past 1.5s and never during autoplay.
- `prefers-reduced-motion: reduce` stops the spinner, the boot placeholders and the preload
  fill.

## Before a release

There is no automated accessibility check (see the gap below), so this list is the check.

### Keyboard, desktop

Tab from the address bar and do not touch the mouse.

- [ ] Every stop shows a focus ring you can find without looking for it.
- [ ] The order runs: search box → topic chips → dataset chips → variable list → Animate →
      speed − / + → year slider → variable info → zoom + / − → attribution → projection →
      outline toggle → **Data table** → the seven legend swatches.
- [ ] Type in the search box; the list narrows and the summary under the chips updates.
      Escape empties the box and restores the full list.
- [ ] Space on a topic chip and on a dataset chip toggles each; both stay announced as
      pressed. Toggling both off restores the list.
- [ ] The variable list is one tab stop. Arrow keys move through it, across dataset
      boundaries, and each row announces its title, its dataset and its coverage range.
      Selecting a row changes the map.
- [ ] Tab to the variable info button and press Enter: the card opens, focus lands in it,
      and it reads as a dialog. Tab reaches the close button and both footer links. Escape
      closes it and focus returns to the button. Enter again reopens; Enter again closes.
- [ ] On the year slider, Left/Right move the year and the announcement says how far it
      actually moved — a variable with gaps snaps, and says "nearest year with data".
      Home/End reach the ends.
- [ ] Enter on Animate starts and stops it; the button's own name changes with it, and the
      years going past are **not** announced one by one.
- [ ] Enter on the speed buttons changes the multiplier and the change is announced once.
- [ ] Arrow keys move between the projection radios and the map redraws.
- [ ] Space on the outline toggle removes and restores the black class boundaries.
- [ ] Each legend swatch announces its class number, its value span and its country count
      without the hover card being involved.
- [ ] Enter on **Data table** opens the dialog, traps focus, and Escape closes it and
      returns focus to the button. Enter on a column header sorts it, the header reports the
      direction, and focus stays on that header. No-data rows sort to the end either way.

### Keyboard, phone width (≤900px)

- [ ] Enter on the variable button opens the picker; focus lands in its search field and the
      dialog is announced by its heading.
- [ ] Typing narrows the list; the topic chips narrow it further.
- [ ] Options read as buttons in named groups, the one on the map reads as current, and each
      carries its coverage.
- [ ] Choosing one closes the dialog and returns focus to the button, which now names it.
- [ ] Escape closes without choosing, and focus returns.
- [ ] The **Info** button opens the variable card and reports itself as expanded.

### Screen reader

NVDA + Firefox, and VoiceOver + Safari where it is available.

- [ ] The page's landmarks read: the variable picker region, the map, its summary region and
      the legend group.
- [ ] Reading into the map's summary region gives the variable, the year, the projection,
      how the colours run, how many countries carry a value, and all seven class spans.
- [ ] Changing variable produces exactly one announcement, after the selection settles.
- [ ] Starting an animation does not produce one per year.
- [ ] A variable row reads as its title and dataset, with its coverage as a description —
      once, not twice.
- [ ] The data table reads country by country with the country name as each row's header.

### Colour

- [ ] `node scripts/check_palette_contrast.mjs` passes. Run with `--verbose` for the numbers.
- [ ] Check a real `GetMap` response, not only the CSS legend — the two lists are separate
      files and the script is what says they agree.
- [ ] **A palette change invalidates every cached tile.** Clear the server cache and
      hard-reload, or the old ramp is served under the new legend:
      `podman exec demscore-mapcache sh -c 'rm -rf /var/cache/nginx/* && nginx -s reload'`

## What is missing

An automated audit. The plan called for Playwright driving the desktop and phone states with
axe-core over each, and it is the one item not done: this repository has never carried a
front-end dependency tree, and adding Playwright plus a browser download is a decision about
the project rather than about accessibility. Nothing above depends on it, but it is what
would keep a regression from being found by a reader rather than by CI.

The states worth auditing, when it is added:

1. initial desktop view
2. the variable list with a topic chip and a search term applied
3. the variable info card open
4. a legend swatch focused
5. the data table dialog open, and again after sorting
6. the phone picker open

Two things axe cannot answer, and which stay manual: whether the text equivalent of the map
actually says what the map shows, and whether the ramps are usable. The first has no check
but reading it; the second is `scripts/check_palette_contrast.mjs`.
