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
| the **table view** | every country on the map as a sortable row, plus a CSV of the same | on request, from **Table** in the View switch |

The summary is deliberately not a live region. It is several sentences plus seven list items
and it is rewritten on every frame of an animation; a polite region carrying that would talk
over everything else on the page. The announcer is the live one and holds a sentence.

The table view is the whole country table, not only the countries with values. "Somalia is
not shown for 2020" is as much a reading of the data as a number is. It replaced a modal of
the same rows opened from a **Data table** button on the legend; a view that stays on while
the year moves is what a modal could not be.

### Colour

**The reader picks the scheme.** Which colours work is not one question with one answer —
about one man in twelve cannot use the red-green channel, a diverging ramp always has two
classes that print as the same grey, and a projector flattens saturation — so *Colours* in
the bottom-left map controls offers four, and the choice is kept in a cookie.

| scheme | kind | what it is for |
|---|---|---|
| **Default** | diverging | Blue to red. Today's map: colour carries *which end is bad*, via `polarity`. |
| **Indigo–amber** | diverging | Keeps that same reading, but separates roughly half again as far under simulated red-green deficiency (worst adjacent pair ΔE 18.1 against the default's 12.8). |
| **Viridis** | sequential | One ramp for everything, dark purple to light green, always low to high. Monotonic in lightness, so it survives greyscale and a projector too. |
| **Cividis** | sequential | One ramp for everything, dark blue to yellow. Built so protan and deutan viewers see very nearly what everyone else does. |

The two sequential schemes cannot encode valence — one ramp, no second end to put anything
at — so they run low-to-high always and ignore `polarity`. That is a real loss and it is the
trade the reader makes: the "which end is bad" cue moves entirely into the legend's end
labels, which are words. The legend bar, the legend note and the map's spoken summary all
follow the chosen scheme, so none of them ever describes colours that are not on screen.

Every colour is written once, in `webapp/src/core/palettes.js`;
`scripts/build_hex_classes.mjs` generates the MapServer side from it, and
`scripts/check_palette_contrast.mjs` reads both files, fails if they disagree, and measures
every adjacent pair in every scheme in greyscale and under simulated protanopia,
deuteranopia and tritanopia.

Two things that shaped the menu, both found by running that script rather than by eye:

- **Every classic ColorBrewer diverging ramp is unusable here.** RdBu, PuOr and BrBG all
  centre on a near-white class that sits ΔE 5–12 from the cream no-data land, so "no value"
  would read as the middle of the scale. Indigo–amber is centred on a mid-tone for that
  reason.
- **True greyscale is impossible at seven classes.** It cannot hold ΔE 9 between neighbours
  *and* clear the cream. A print/monochrome scheme would need the no-data colour moved off
  `#fffaf0` as well, which changes how "no data" reads in every scheme — a separate decision,
  not a fifth option.

The neutral ramp used to be seven steps of emerald, and failed twice over: its two lightest
classes were ΔE 6 apart under protanopia and deuteranopia — indistinguishable — and its
lightest shade sat ΔE 17 from the cream, so "no value" read as "bottom of the scale".

Colour is still not the only channel, which matters most in the two diverging schemes:

- the equal-colour **area outlines** are on by default, and their toggle is on screen beside
  the View switch and the colour picker rather than behind the Shift+D developer extras,
  because a control that carries this much is not a developer affordance;
- every legend swatch's accessible name carries its class number, value span and country
  count in full, so it does not depend on the hover card;
- the table view gives the exact value and class per country.

### Everything else

- Focus: `:focus-visible` at the top of `styles.css` is the floor. The transparent range
  input, the OpenLayers zoom buttons, the playback row, the View switch and the legend
  swatches all draw a visible ring now; the range input's ring is drawn on the marker,
  because the input itself is invisible and covers the whole timeline.
- Tab order follows the visible layout: sidebar → timeline (top of the map) → the map's own
  controls → the dashboard at the foot of it, which holds the View switch, the colour
  picker, the outline toggle and the legend. `#timeline-overlay` sits before
  `<main id="map">` in the source for that reason, though it is painted over it.
- The variable info card is a non-modal `dialog` when it is opened by a click — with a name,
  a close button, a focus moved into it and a focus given back — and a `tooltip` when it is
  shown by a hover.
- The phone picker is a grouped list of buttons rather than a listbox it never implemented.
- Coverage ranges are in every row's accessible description, not only in a `title`. The
  coverage strips themselves — the one under each row, and the height of the timeline's
  read-ahead marks — are `aria-hidden`: they carry no fact the row's description, the
  slider's `aria-valuetext` and the map summary do not already say in words. The years
  printed under a row's strip are `aria-hidden` for the same reason, and because the row
  is a `<label>` wrapping a radio, where visible text would join the radio's name.
- The loading spinner has a spoken counterpart, but only past 1.5s and never during autoplay.
- `prefers-reduced-motion: reduce` stops the spinner, the boot placeholders and the preload
  fill.

## Before a release

There is no automated accessibility check (see the gap below), so this list is the check.

### Keyboard, desktop

Tab from the address bar and do not touch the mouse.

- [ ] Every stop shows a focus ring you can find without looking for it.
- [ ] The order runs: search box → topic chips → dataset chips → variable list → Animate →
      speed − / + → year slider → variable info → zoom + / − → attribution → **View**
      (one stop) → the seven legend swatches → **Colours** (one stop) → outline toggle.
      The legend and the picker are both inside the Colours panel, the middle of the three
      in the dashboard, with the legend above the picker — so the order is the visible
      layout, left to right and then top to bottom.
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
- [ ] Arrow keys move between the three **View** options and each one takes effect: the two
      projections redraw the map, **Table** replaces it. The group is one tab stop, the
      arrows wrap at both ends, and picking a projection while the table is on screen sets
      it *and* brings the map back.
- [ ] The *Colours* picker is reachable, operable from the keyboard alone, and announces
      itself by its visible "Colours" label. Each of the four repaints the hexagons and the
      legend bar together, and the legend note describes the scheme actually on screen.
- [ ] **Each scheme announces its name.** The name is not painted on the button any more —
      the four buttons are swatch strips, and the strips are `aria-hidden` — so the name is
      a `visually-hidden` span inside each button and the tooltip carries it too. A button
      that reads as "button" rather than as "Viridis" means that span has been removed.
- [ ] Space on the outline toggle removes and restores the black class boundaries.
- [ ] Each legend swatch announces its class number, its value span and its country count
      without the hover card being involved.
- [ ] In the table view, Enter on a column header sorts it, the header reports the
      direction, and focus stays on that header. No-data rows sort to the end either way.
- [ ] The table's rows are **one** tab stop, not 245. Arrow Up/Down move between them,
      Home/End reach the ends, Enter follows the row the focus is on, and Escape clears
      every mark. A followed row reads its name followed by "followed, blue" — the
      highlight is not the only way that state is carried, and the colour is named
      because it is what tells one mark from another.
- [ ] **Deselect all (n)** appears in the head with the first mark and carries the count.
      Enter on it clears every mark and moves focus to the rows, not to the body — the
      button removes itself, and focus left on a hidden element is focus lost.
- [ ] Step a year with a row focused and the focus stays on that row. The FLIP pass takes
      every row out of the document for the length of one statement, which blurs whatever
      was focused — `renderRows` notes it and puts it back, and this is the check that it
      still does.
- [ ] Enter on **About** opens the dialog. It is one dialog covering both what the map is
      and what it is made of; there is no second modal to reach the licences.
- [ ] Inside it, every section heading is a disclosure reachable by Tab and operable with
      Enter or Space, and each says how many sources or which licence it holds before it is
      opened. *Indicator data*, *Map boundaries* and *Using this map* are **open** when the
      dialog appears; only *Software and images* is closed.
- [ ] Tab reaches **Sources & licences** inside the attribution line under the map — the
      credit line is a tab stop, not a mouse target, because it is where the CC BY-NC-SA and
      GPL-3.0 attribution is discharged. Enter opens the About dialog scrolled to *Map
      boundaries*, traps focus, and Escape closes it and returns focus to that button.
- [ ] The table view's **Boundary** column sorts, and a historical row reads its source with
      the years that outline is claimed for.
- [ ] The **±** column reads as words, not as a shape: "Up 3 places from 2018", "Same
      position as 2018", "Not in the 2018 table". Its header announces "Change in position
      since the previous year" rather than "plus or minus".
- [ ] Up and down are told apart with the colour off. The two inks are at the same
      lightness on purpose — they are indistinguishable in greyscale and to the commonest
      colour blindness — so the triangle's direction is what has to carry it.

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
- [ ] The table view reads country by country with the country name as each row's header.
- [ ] The attribution line under the map is read as part of the page, not skipped: it names
      the boundary sources and their licences on **every** year, including present-day ones.
- [ ] Each boundary entry reads its title and its licence. The per-source "Modified:"
      sentence sits behind that entry's disclosure; the always-visible credit line under the
      map is what carries the indication of modification unconditionally, so check that line
      still ends "Modified." on every year.

### Colour

- [ ] `node scripts/build_hex_classes.mjs --check` passes — the generated mapfile classes are
      in step with `webapp/src/core/palettes.js`.
- [ ] `node scripts/check_palette_contrast.mjs` passes, for every scheme. Run with
      `--verbose` for the numbers.
- [ ] Check a real `GetMap` response per scheme, not only the CSS legend — the colours live
      in two files and the script is what says they agree.
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
5. the table view on, and again after sorting
6. the phone picker open
7. each of the four colour schemes (the legend bar's contrast against the dashboard changes
   with it, and nothing else does)

Two things axe cannot answer, and which stay manual: whether the text equivalent of the map
actually says what the map shows, and whether the ramps are usable. The first has no check
but reading it; the second is `scripts/check_palette_contrast.mjs`.
