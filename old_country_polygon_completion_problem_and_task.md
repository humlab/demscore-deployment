# Old Country Polygon Completion Problem and Task

## Problem

The remaining unmapped Demscore source observations are not ordinary current
country-name mismatches. They are mostly V-Dem observations for historical
states that existed somewhere in the 1789-1849 range, before the global CShapes
coverage used by this repository.

The current setup no longer deletes these rows silently. They remain in
`demscore.dataset_values` with `country_id IS NULL` and are summarized in
`demscore.dataset_value_unmapped_audit`. That fixes the silent data-loss part of
Finding 1, but it does not make the values drawable on the map.

To finish the problem, each remaining source entity needs one explicit outcome:

1. Map it to defensible historical polygon geometry.
2. Mark it as intentionally unsupported with a documented reason.

Anything in between is still a correctness gap: the source has a value, but the
map/table universe cannot represent it.

## Candidate Polygon Sources

### CShapes-Europe

Regular CShapes 2.0 covers 1886-2019. ETH documents a separate CShapes-Europe
dataset that covers Europe from 1816. This is the first source to check for
European leftovers after 1816.

Pros:

- Same family as the current CShapes source.
- Designed for country borders and historical state systems.
- Year-aware and closer to the existing import model than static snapshots.

Risks:

- License is CC BY-NC-SA 4.0, like CShapes 2.0, so redistribution and reuse
  constraints need to be acceptable for this deployment.
- It only helps from 1816 onward and only for Europe.
- It may still not include every V-Dem historical entity or every needed year.

### Historical Basemaps

Repository: `aourednik/historical-basemaps`.

This project provides world GeoJSON snapshots for historical countries and
cultural regions. It has relevant snapshots such as 1783, 1800, 1815 and 1880.
The 1800 snapshot includes names in the same problem space, including Baden,
Bavaria, Brunswick, Hanover, Mecklenburg-Schwerin, Oldenburg, Papal States,
Parma, Saxony, Tuscany, Wurttemberg and Zanzibar.

Pros:

- Covers the pre-1816 period where CShapes-Europe cannot help.
- World-scale rather than Europe-only.
- Direct GeoJSON source is easy to inspect and import.

Risks:

- License is GPL-3.0. That is usable, but it has strong copyleft implications
  if we redistribute derived polygon data.
- It is snapshot-based, not annual validity-period data.
- It mixes states, empires, dependencies, cultural regions and other mapped
  entities. Names and status must be vetted per source entity.
- Accuracy is suitable for map-scale reconstruction, not necessarily for
  authoritative year-by-year borders.

### OpenHistoricalMap

OpenHistoricalMap is a historical mapping project using an OpenStreetMap-like
data model. It supports `start_date` and `end_date` tags and historical boundary
relations. Its data is generally CC0/public domain unless individual features
carry a `license=*` tag.

Pros:

- The licensing model is attractive for a redistributable derived dataset.
- Time-aware boundary data can sometimes be queried directly.
- Individual features can carry provenance and date tags.

Risks:

- Completeness varies by region and period.
- Data quality depends on volunteered contributions.
- Extraction requires careful filtering and validation of boundary relations,
  dates, licenses and names.
- Some useful individual geometries may carry feature-level license tags.

### IPUMS Mosaic / MPIDR Historical GIS

The IPUMS Mosaic historical GIS datafiles include a German Union 1815-1870
shapefile series. That is relevant if the remaining unmapped set is dominated
by German Confederation states.

Pros:

- More systematic for German states than generic global basemap snapshots.
- Annual or time-series data is closer to what the Demscore loader needs.
- Credible academic source with citation information.

Risks:

- Use is described as free for non-commercial scientific purposes with
  registration and citation, not fully open public-domain data.
- German Union coverage excludes some entities such as Austria, Luxembourg and
  Limburg.
- It only helps a regional subset of the remaining problem.

### Euratlas

Euratlas has historical vector data for Europe, including 1800 sovereign and
dependent states.

Pros:

- Relevant period and region.
- Good reference material for historical Europe.

Risks:

- Access and licensing are restricted through many library portals.
- It is probably better as a validation/reference source than as a
  redistributable source for this repository.

## Recommended Approach

1. Export the current unmapped audit list.

   Use `demscore.dataset_value_unmapped_audit` grouped by `dataset`, `iso3`,
   `country_name`, `reason`, `min(year)`, `max(year)` and total value count.
   This becomes the working checklist.

2. Classify each source entity.

   Assign one of:

   - `cshapes_europe_candidate`
   - `historical_basemaps_candidate`
   - `openhistoricalmap_candidate`
   - `ipums_mosaic_candidate`
   - `needs_custom_geometry`
   - `intentionally_unsupported`

3. Prefer period-aware datasets over snapshots.

   Use CShapes-Europe or IPUMS-style time-series geometry where available.
   Use Historical Basemaps snapshots only when no period-aware source exists,
   and record the snapshot year used.

4. Add a new curated historical geometry layer.

   Do not overload `demscore.cshapes_src` with non-CShapes data. Add a separate
   source table such as `demscore.historical_country_geometries_src` with:

   - `source_dataset`
   - `source_license`
   - `source_url`
   - `source_snapshot_year`
   - `source_name`
   - `normalized_name`
   - `valid_from_year`
   - `valid_to_year`
   - `confidence`
   - `notes`
   - `geom`

5. Extend `demscore.country_aliases` or add a richer resolution table.

   The existing alias table can express some mappings, but the completion
   problem likely needs explicit source provenance and policy. A dedicated
   resolution table may be clearer:

   - source dataset and source identifier
   - source year range
   - target geometry source
   - target geometry key
   - resolution status
   - reason or notes

6. Fail setup on unresolved unmapped rows.

   Once the policy table exists, setup should fail if
   `dataset_value_unmapped_audit` contains rows that are neither mapped nor
   intentionally unsupported.

7. Expose source-vs-map coverage.

   The UI should be able to distinguish:

   - source has no value
   - source has a value and it maps to geometry
   - source has a value but this deployment cannot represent its geometry

## Acceptance Criteria

- No source observation is silently deleted.
- Every remaining `country_id IS NULL` row is covered by an explicit resolution
  policy.
- All mapped historical polygons have source, license, year coverage and
  confidence metadata.
- Setup reports unresolved entities and fails unless the unresolved set is
  empty.
- The web backend can report source coverage separately from map coverage.
- Regression checks cover named difficult cases such as Palestine/Gaza,
  Palestine/West Bank, Republic of Vietnam and selected pre-1850 European
  states.


---

## Outcome

Done. Every source observation now has an explicit outcome, and setup fails if
one does not.

| Dataset | Loaded | Mapped | Intentionally unsupported | Unresolved |
| --- | ---: | ---: | ---: | ---: |
| QoG | 55,611 | 100.00% | 0 | 0 |
| REPDEM | 30,311 | 100.00% | 0 | 0 |
| V-Dem | 3,189,614 | 99.74% | 8,308 | 0 |

### Against the acceptance criteria

- *No source observation is silently deleted.* Unchanged from the previous fix;
  `scripts/check_country_resolution.sh` now also reports the totals.
- *Every remaining `country_id IS NULL` row is covered by an explicit policy.*
  `demscore.country_resolution_policy`, with
  `demscore.dataset_value_unmapped_audit.resolution_status` recording which.
- *All mapped historical polygons have source, license, year coverage and
  confidence metadata.* `demscore.historical_country_geometries_src`. The table
  enforces the grading: a snapshot row cannot be graded above `low`, and a `low`
  row must say in `notes` what it is getting wrong.
- *Setup reports unresolved entities and fails unless the unresolved set is
  empty.* `scripts/check_country_resolution.sh`, run by
  `scripts/setup_mapserver_hex_service.sh`.
- *The web backend can report source coverage separately from map coverage.*
  `/api/source-coverage`, backed by `demscore.source_coverage()`.
  `/api/map-data` rows also carry `geometryConfidence`.
- *Regression checks cover the named difficult cases.* 29 assertions in the
  check script, covering all three Palestine units, Republic of Vietnam,
  Zanzibar, South Yemen and eleven pre-1850 European cases — each one pinned to
  the geometry source it should resolve to in that year.

### Sources used

Ordered as the recommendation asked, period-aware before snapshots:

1. **CShapes 2.0** where it covers the unit and the year.
2. **CShapes-Europe** (CC BY-NC-SA 4.0, the same licence as CShapes 2.0, which
   this repository already vendors). It carries 17 of the 19 pre-unification
   states with their border-change periods, and resolves 68,641 values on its
   own periods and another 22,804 carried just outside them.
3. **historical-basemaps** (GPL-3.0) for the five cases neither reaches:
   Bavaria before 1806, Saxony before 1815, and Hanover, Hamburg and Tuscany.

IPUMS Mosaic and Euratlas were not needed: CShapes-Europe covers the German
Union period more completely than either, without registration or portal access.
OpenHistoricalMap was not needed either, though it remains the obvious source
for the one refusal below.

### What was learned along the way

Reading V-Dem's own country coding units document changed three answers that a
one-polygon-per-entity model would have got wrong:

- **Palestine/West Bank** means the West Bank *and Gaza* from 1968 to 2006, and
  the West Bank alone otherwise. Three periods, the middle one a union.
- **Republic of Vietnam** is the whole country from 1802 and South Vietnam only
  from 1955. It is a country row of its own, not an alias onto modern Vietnam,
  because V-Dem codes a northern unit from 1945 and `country_scores()` would
  have averaged the two together.
- **Zanzibar** is coded from 1856 and continues after the 1964 union with
  Tanganyika — on both sides of CShapes' 1890-1964 span.

One entity is `intentionally_unsupported`: **V-Dem's South Yemen before 1967**,
which codes the city of Aden (192 km2) to 1963 and then the Federation of South
Arabia without its eastern protectorate. No vendored source carries either
outline, and the only available polygon is the whole People's Democratic
Republic at some 287,000 km2. OpenHistoricalMap has dated Aden Colony relations
under CC0 if this is picked up.

### One thing this exposed that was not in the brief

The mesh builder's fallback passes hand a cell from one country to another when
the owner can spare it. That is right for a partition of the present-day map,
but historical countries are an overlay, and a cell they took was gone from the
present-day country in *every* year. Germany dropped from 11 hexagons to 6 at
100 km once the pre-unification states arrived — and Ukraine had already lost
four to the Soviet Union before any of this work started. Eviction is now
conditional on both sides being present-day countries; a historical country
borrows the cell and the owner keeps it. Zero cells are now lost to a historical
country, and the 51 that still move are micro-states taking a spare from a large
neighbour, which is what that pass is for.

### Still open

19.7% of the newly resolved values sit on a snapshot or a knowingly wrong
extent. Reviewed and accepted: this is a hex map whose cells already blur exact
borders, and six of the eleven low-confidence country-periods are a single
hexagon at every size the app offers — Baden before 1816 is drawn five times too
large and is one hexagon either way. The grade describes a difference the map
cannot express.

Two of them are territorial rather than imprecise and do survive the argument:
Two Sicilies before 1816 includes Sicily (6 of its 17 hexagons at 50 km) and
Piedmont-Sardinia includes Savoy and Nice. Both are documented per row.

`country_polygon_considerations.md` carries the register, the measurements and
the rest of the operational caveats.
