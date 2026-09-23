# Country polygon considerations

What the country geometry on this map is, where it is approximate, and which of
those approximations matter. Everything here is a known, bounded property of the
current build — not a bug list.

Companion documents: `data/reference/README.md` for the licence and citation
register, `AGENTS.md` for how the pipeline fits together,
`old_country_polygon_completion_problem_and_task.md` for why the historical
layer exists at all.

---

## 1. What the map is made of

Four boundary sources, resolved in this order by
`demscore.country_resolution_policy`:

| Source | Role | Licence |
| --- | --- | --- |
| Natural Earth 50m | Present-day countries | Public domain |
| CShapes 2.0 | Period-aware world boundaries, 1886–2019 | CC BY-NC-SA 4.0 |
| CShapes-Europe | Period-aware European boundaries from 1816 | CC BY-NC-SA 4.0 |
| historical-basemaps | World snapshots at 1783, 1800, 1815 | GPL-3.0 |

Every historical polygon is one row in
`demscore.historical_country_geometries_src`, carrying its source, licence,
citation, snapshot year (if it came from one), validity years, a confidence
grade and a note. 67 rows, 24 entities.

Confidence means:

- **high** — a period-aware source used inside its own validity period.
- **medium** — such a polygon carried across years the V-Dem coding-unit
  history documents as territorially unchanged.
- **low** — a snapshot reconstruction, or a polygon known to draw a different
  extent than the coding unit held. The table refuses a `low` row with empty
  notes, so every one of them says what it is getting wrong.

---

## 2. Confidence is not a warning label

**The hexagons already absorb most of what `low` is warning about, and that is
by design.** A hexagon means "this country's score around here", not a parcel
boundary. At the three sizes the app offers — 200 km, 100 km, 50 km — a cell
covers about 104 000, 26 000 and 6 500 km². Most of these states are smaller
than one cell.

Measured, for all eleven `low`-confidence country-periods:

| Entity | Period | km² | Hexagons at 200/100/50 km |
| --- | --- | ---: | --- |
| Baden | 1789–1815 | 15 852 | 1 / 1 / 1 |
| Bavaria | 1789–1805 | 121 024 | 2 / 5 / 18 |
| Hamburg | 1789–1867 | 269 | 1 / 1 / 1 |
| Hanover | 1789–1837 | 40 583 | 1 / 1 / 4 |
| Hesse-Darmstadt | 1789–1815 | 8 342 | 1 / 1 / 1 |
| Piedmont-Sardinia | 1789–1815 | 74 491 | 1 / 3 / 11 |
| Saxony | 1789–1814 | 39 699 | 1 / 2 / 5 |
| Tuscany | 1789–1861 | 24 286 | 1 / 1 / 4 |
| Two Sicilies | 1789–1815 | 103 298 | 1 / 2 / 17 |
| Württemberg | 1789–1815 | 18 723 | 1 / 1 / 4 |
| Zanzibar | 1856–1889 | 2 591 | 1 / 1 / 1 |

Baden is the clearest case. The registry draws it at 15 852 km² where the 1789
Margraviate held roughly a fifth of that — a 5× overstatement, and on the map it
is one hexagon either way, at every size. The correct polygon would also be one
hexagon. The grade describes a difference the map cannot express.

That is true for six of the eleven at every size the app offers.

### The part that is not fuzziness

Two of the `low` rows are not imprecise borders. They draw **land the polity did
not hold**, which is a different kind of claim and one the hex grid does not
absorb:

- **Two Sicilies, 1789–1815.** V-Dem codes the mainland Kingdom of Naples alone
  until it united with Sicily in 1816. The polygon includes Sicily throughout.
  At 50 km that is **6 of its 17 hexagons** showing Naples' score over an island
  Naples did not govern. At 100 km it happens to be 0 of 2; the exposure is
  zoom-dependent, not constant.
- **Piedmont-Sardinia, 1789–1815.** Includes Savoy and Nice, French between 1793
  and 1814, and Piedmont itself was French territory from 1802 to 1814.

Both are documented in the row's `notes`. Neither is worth a client-side
annotation — 27 years of a 236-year series, at one zoom level — but both are
worth knowing before quoting the map on the Italian peninsula around 1800.

The generalisation: `confidence` in this registry conflates *imprecise border*
(absorbed by the grid) with *wrong territory* (not absorbed). If the grading is
ever refined, that is the axis to split on, not the tightening of a tolerance.

---

## 3. Coding units that move under you

V-Dem's country coding units are not stable territories with stable names.
Reading `countryunit_v15.pdf` changed the right answer in four places. All four
are implemented; they are listed here because anyone reasoning about a time
series over these entities needs to know.

- **Palestine/West Bank (V-Dem 128)** means the West Bank **and Gaza** from 1968
  to 2006, and the West Bank alone for 1948–1967 and from 2007. Three periods,
  the middle one drawn as a union of two CShapes polygons. V-Dem codes it for
  1948–1950 and 1967– only; 1951–1966 is genuinely absent, not lost.
- **Republic of Vietnam (V-Dem 35)** is the whole of Vietnam from 1802 — the
  Nguyễn empire, then Tonkin, Annam and Cochinchina inside French Indochina —
  and South Vietnam only from 1955. It is drawn as a country row of its own on
  Natural Earth's Vietnam outline, **not** as an alias onto modern Vietnam,
  because V-Dem codes a separate northern unit from 1945 and
  `demscore.country_scores()` would otherwise average the two together.
- **Zanzibar (V-Dem 236)** is coded from 1856 and continues after the 1964 union
  with Tanganyika, on both sides of CShapes' 1890–1964 span. V-Dem's unit also
  covers the East African coastal strip until 1895; the map draws Unguja and
  Pemba alone throughout, because CShapes already does so from 1890 and one
  footprint across the series beats two.
- **South Yemen (V-Dem 23)** codes the city of Aden and its surroundings until
  1963, then the Federation of South Arabia without its eastern protectorate.
  See §5.

---

## 4. Two entities can occupy the same ground

The historical rows are an **overlay**, not a second partition. Where two
coding units the source measures separately sit on the same land, both are
drawn, and which one lands on top is not defined.

- **Pre-partition Vietnam and Vietnam, 1945–1953.** V-Dem codes the northern
  unit from 1945 while the Republic of Vietnam unit still runs to 1975. Nine
  years of overlap, in the source rather than in the mapping.
- **Soviet Union over Russia and its neighbours**, and the German Democratic
  Republic over Germany. Pre-existing, and the reason the border tables were
  built to allow an edge with more than two sides.
- **The pre-unification German and Italian states over Germany and Italy.**
  V-Dem codes Germany from 1789, so in 1800 the map shows a modern German
  outline *and* Bavaria, Saxony, Hanover and the rest on top of it.

This is worth saying plainly because it looks like a rendering fault and is not.

---

## 5. The one thing the map refuses to draw

**V-Dem's South Yemen before 1967.** 8 308 values, in
`demscore.dataset_value_unmapped_audit` with
`resolution_status = 'intentionally_unsupported'`.

V-Dem codes only the city of Aden (192 km²) until 1963, and then the Federation
of South Arabia without its eastern protectorate. No vendored source carries
either outline. The only available polygon is the People's Democratic Republic
that CShapes 2.0 supplies from 1967, at about 287 000 km² — drawing it would put
one city's score across the whole of southern Arabia.

OpenHistoricalMap carries dated Aden Colony relations under CC0 and is the
obvious source if this is ever picked up.

Everything else resolves: QoG and REPDEM at 100%, V-Dem at 99.74%.

---

## 6. Operational traps

### A rebuilt mesh invalidates every cached tile, and nothing in the URL says so

The tiles carry the geometry, not a reference to it. A setup run that moves a
hexagon leaves the cache serving the old map under an unchanged URL — the same
trap a colour change sets. `scripts/setup_mapserver_hex_service.sh` now clears
the server cache when `DEMSCORE_ENABLE_MAPCACHE=1`. The browser's service worker
holds its own copy and needs a hard reload.

### A new dataset export can fail setup, on purpose

`scripts/check_country_resolution.sh` exits non-zero if any source observation is
unmapped without a policy row saying why. That is the intended behaviour: the
map's universe must not silently differ from the source's. The fix is a registry
entry plus a `historical_registry` policy row, or an `intentionally_unsupported`
row with a reason. The check prints each entity with its years and value count.

### Coverage strips go stale silently

`webapp/config/variable_coverage.json` is derived from `country_id`, so anything
that changes what maps changes it. Rerun `scripts/build_variable_coverage.sh`.
V-Dem's busiest year moved from 165 countries to 179 when the historical
registry landed.

### A historical country borrows a hexagon, it never takes one

The mesh builder's fallback passes hand a cell from one country to another when
the owner can spare it. That is right for a partition among countries on the map
at once; it is wrong for an overlay, because the cell would be gone from the
present-day country in *every* year. Germany fell from 11 hexagons to 6 at
100 km before this was caught, and Ukraine had already lost four to the Soviet
Union. Eviction is now conditional on both sides being `natural_earth`. If you
touch those passes, the check is: zero cells lost by a present-day country to a
historical one.

### Four Natural Earth dependencies miss some hexagon sizes

Sint Maarten, Saint-Barthélemy, Saint-Martin and Montserrat — all under 100 km²,
all in no dataset. More of them in Mercator, whose size ladder starts twice as
coarse. Nothing draws them, so nothing shows it. The invariant that holds is
*every country that carries data has a hexagon at every size*.

---

## 7. Licence consequences

Two of the four sources carry conditions that reach the derived data — and the
hex meshes and rendered tiles are derived data.

- **CC BY-NC-SA 4.0** (CShapes 2.0 and CShapes-Europe): non-commercial use only,
  and a derivative distributed onward must carry the same licence.
- **GPL-3.0** (historical-basemaps): copyleft. Five polygons come from it —
  Bavaria before 1806, Saxony before 1815, Hanover, Hamburg and Tuscany. The
  complete list at any time is
  `SELECT * FROM demscore.historical_country_geometries_src WHERE source_dataset = 'historical_basemaps'`.

Nothing here is public-domain-only, so a deployment needing unencumbered
geometry cannot simply drop a file: `sql/historical_geometry.sql` would have to
be reduced to its Natural Earth rows, and every pre-1886 country would go with
it.

---

## 8. Where the metadata is actually useful

Not as a warning on the map. `geometry_confidence` and `geometry_source_dataset`
earn their place in three other ways:

1. **Auditing the registry.** `scripts/check_country_resolution.sh` prints the
   geometry the map is drawn on, grouped by source, licence and confidence. A
   new `low` row that nobody intended shows up there.
2. **Answering a specific question.** `/api/source-coverage` reports, for one
   variable-year, how many drawn countries rest on each grade — 1800 is 41 high,
   4 medium, 8 low; 1840 is 73 high, 1 medium, 1 low; 1950 is 153 high, 1 medium,
   0 low, with South Yemen named as unrepresented. That is the right granularity
   for a methods note.
3. **Separating "no value" from "cannot draw it".** This is the one that is
   genuinely invisible without the API. A country the source measured but this
   deployment cannot represent looks exactly like a country the source never
   measured, and those are opposite facts. `/api/source-coverage` distinguishes
   them; the picture cannot.
