# Data Correctness Review

This note records the main data-correctness findings from an audit of the
Demscore import, database preparation, WMS rendering, backend API, and web UI
presentation paths.

## Summary

This review originally found two user-facing correctness problems. Both are now
fixed:

1. Unmatched source observations are no longer silently deleted, and they are no
   longer merely audited either. QoG and REPDEM map fully; V-Dem maps 99.74% of
   its loaded values, and the 8,308 that remain (0.26%, all South Yemen before
   1967) are covered by an explicit `intentionally_unsupported` policy row.
   Setup fails on any unmapped observation that is not.
2. The old `ntile(7)` classing bug has been fixed. `demscore.country_scores()`
   now classes distinct values, so equal values receive the same class. A live
   scan across visible variable-years found zero split value groups.

Other reviewed areas were broadly consistent: the CSV melt excludes identifier
columns, filters Demscore's `-11111` missing marker, metadata matching is
complete in the live database, map colors and legend colors match, and the
legend/table read from the same `country_scores()` function used by WMS.

## Finding 1: Every Source Observation Now Has an Explicit Outcome

Severity: Resolved

The original review found that rows still lacking `country_id` after matching
were deleted outright:

```sql
DELETE FROM demscore.dataset_values
WHERE country_id IS NULL;
```

A first fix replaced the delete with `demscore.dataset_value_unmapped_audit`.
That stopped the data loss but left 145,045 V-Dem values (4.55%) audited and
undrawable, with no record of whether that was a decision or an oversight.

Both halves are now closed. `sql/historical_geometry.sql` adds a curated
historical geometry registry and a resolution policy, and
`scripts/check_country_resolution.sh` fails setup unless every unmapped
observation is covered by a policy row that says why.

### Live result

| Dataset | Loaded values | Mapped | Intentionally unsupported | Unresolved |
| --- | ---: | ---: | ---: | ---: |
| QoG | 55,611 | 55,611 (100.00%) | 0 | 0 |
| REPDEM | 30,311 | 30,311 (100.00%) | 0 | 0 |
| V-Dem | 3,189,614 | 3,181,306 (99.74%) | 8,308 | 0 |

The 145,045 previously undrawable V-Dem values resolved as follows, counted by
the `geometry_source_dataset` each one is now drawn on:

| Resolution | Values | Confidence | Geometry |
| --- | ---: | --- | --- |
| `cshapes_europe` | 68,641 | high | 17 pre-unification German and Italian states, on their own border-change periods |
| `cshapes_europe_extended` | 22,804 | medium / low | The same polygons carried back to 1789 and forward to the 1871 unification year |
| `cshapes_2.0_extended` | 15,804 | high / low | Zanzibar before 1890 and after 1964; Gaza, the West Bank and the British Mandate outside CShapes' own spans |
| `historical_basemaps` | 14,493 | low | Bavaria before 1806, Saxony before 1815, and Hanover, Hamburg and Tuscany, which CShapes-Europe does not carry separately |
| `natural_earth_50m` | 9,912 | medium | V-Dem's Republic of Vietnam before the 1954 partition |
| `cshapes_2.0_derived` | 5,083 | high | The West Bank and Gaza as one polygon, for the years V-Dem's unit covers both |
| Intentionally unsupported | 8,308 | — | South Yemen before 1967 |

Of the 136,737 values that changed from undrawable to drawn, 63.9% sit on a
period-aware boundary the source says was in force that year (`high`), 16.4% on
such a boundary carried across years the coding-unit history documents as
unchanged (`medium`), and 19.7% on a snapshot or a knowingly wrong extent
(`low`). Every `low` row records in `notes` what it is getting wrong.

### What the fix is made of

- `demscore.historical_country_geometries_src` — one row per (entity, year span,
  polygon) with `source_dataset`, `source_license`, `source_url`,
  `source_citation`, `source_snapshot_year`, `confidence` and `notes`. An
  exclusion constraint refuses two overlapping periods for one entity, a
  snapshot row cannot be graded above `low`, and a `low` row must state in
  `notes` what it is getting wrong.
- `demscore.country_resolution_policy` — replaces `demscore.country_aliases`.
  One row per (dataset, source entity, year window) with a status of
  `natural_earth`, `cshapes`, `historical_registry` or
  `intentionally_unsupported`. The last is what the alias table could not
  express.
- Matching now runs policy first and the source's own ISO3 and name afterwards,
  and an `intentionally_unsupported` row clears any `country_id` a later pass
  set, so a refusal is enforced rather than hoped for.
- `demscore.source_coverage()` and `/api/source-coverage` report what the source
  measured against what the map can draw, so "the source never measured this"
  and "this deployment cannot draw it" stop being the same answer.
- `/api/map-data` rows now carry `historical`, `validFromYear`/`validToYear`,
  `geometrySource` and `geometryConfidence`.

### Three coding units that needed period-aware handling

Reading V-Dem's own country coding units document changed the answer in three
places where a single polygon per entity would have been wrong:

- **Palestine/West Bank** covers the West Bank *and* Gaza from 1968 to 2006, and
  the West Bank alone for 1948-1967 and from 2007. The registry holds all three
  periods, the middle one as a union of the two CShapes polygons.
- **Republic of Vietnam** is the whole of Vietnam from 1802 — the Nguyen empire,
  then Tonkin, Annam and Cochinchina inside French Indochina — and only South
  Vietnam from 1955. Drawing the early years on the South Vietnam polygon would
  have put a value for the whole country on half of it. It is a country row of
  its own rather than an alias onto modern Vietnam, because V-Dem codes a
  northern unit from 1945 and `country_scores()` would have averaged the two.
- **Zanzibar** is coded from 1856 and continues after the 1964 union with
  Tanganyika, on either side of the 1890-1964 span CShapes covers.

### Remaining risk

Eleven of the 67 historical country-periods rest on a world snapshot standing in
for a span of years, or on a polygon known to be the wrong size. That is mostly
a difference a hex map cannot express: six of the eleven are a single hexagon at
every size the app offers, and Baden before 1816 is drawn five times too large
and is one hexagon either way. The two that do bite are territorial rather than
imprecise — Two Sicilies before 1816 includes Sicily and Piedmont-Sardinia
includes Savoy and Nice, neither of which those units held. Both are recorded in
the registry's `notes`; `country_polygon_considerations.md` has the register and
the measurements.

What the picture genuinely cannot carry is the difference between a country the
source never measured and one this deployment cannot draw. `/api/source-coverage`
answers that; no client consumes it yet.

## Finding 2: Equal Values Preserve Class Membership

Severity: Resolved

The original review found that `demscore.country_scores()` computed color
classes with:

```sql
ntile(7) OVER (ORDER BY cv.value) AS class_idx
```

`ntile` distributes rows into seven buckets. It does not preserve ties. If many
countries share the same value, the same value can appear in multiple classes
and therefore multiple colors.

That implementation is no longer present. Current `country_scores()` classes
distinct values: it selects the distinct value set, ranks those values with
`dense_rank()`, and joins the resulting class back to all countries with that
value. Equal values therefore receive the same `class_idx`.

Original concrete example:

For `repdem_basic_govtype` in 2020:

- value `1` is assigned to classes 1, 2, and 3.
- value `3` is assigned to classes 3, 4, and 5.
- value `4` is assigned to classes 6 and 7.

Verified current live result for the same variable-year:

- value `1` is assigned only to class 1.
- value `2` is assigned only to class 2.
- value `3` is assigned only to class 3.
- value `4` is assigned only to class 4.

This is especially misleading for categorical and low-cardinality variables.
`repdem_basic_govtype` is documented as categories:

- `1`: minority cabinet
- `2`: single-party majority cabinet
- `3`: minimal winning coalition
- `4`: surplus majority coalition
- `5`: non-partisan cabinet

The current map no longer makes countries with the same exact value appear in
different classes. A live scan across visible variable-year combinations found
zero `(dataset, variable, year, value)` groups assigned to more than one class.

The original issue was user-facing beyond this one variable. Split ties had
been found in variables including:

- `repdem_basic_govtype`
- `repdem_basic_cab_num_parties`
- `repdem_basic_num_parties`
- `qog_std_ts_fh_rol`
- `qog_std_ts_icrg_qog`
- `bti_su`
- `v2x_polyarchy`
- `v2x_libdem`
- `v2x_partipdem`
- `v2x_egaldem`

Why this misrepresents the data:

- The legend and data table describe seven quantile classes from low to high.
- The table says class 1 is the lowest seventh and class 7 is the highest.
- With split ties, class membership reflected row position rather than value.
  The current distinct-value classing removes that failure mode.

Remaining recommended fixes:

1. If preserving ties results in fewer populated classes, show fewer populated
   classes rather than forcing seven.
2. Render categorical variables with category-aware colors and labels instead of
   numeric quantiles.
3. Add tests/assertions that no `(dataset, variable, year, value)` appears in
   more than one rendered class for UI-offered variables.

## Reviewed Areas That Were Consistent

- The CSV loader excludes all `u_` identifier columns before melting indicators.
- Numeric parsing avoids importing text fields as values.
- Demscore's `-11111` missing marker is filtered before variables and values are
  registered.
- QoG OECD duplicate variables are removed only after checking exact redundancy
  against the global QoG Standard counterpart.
- REPDEM WECEE twins are hidden rather than deleted, preserving direct
  queryability.
- Live metadata coverage was complete at review time: zero loaded variables were
  missing `demscore.variable_metadata`.
- No duplicate country/year rows were found in the live DB for the same
  dataset-variable-country-year, so the `AVG()` in `country_scores()` was not
  changing current values.
- The WMS layer, legend, spoken summary, and data table all read from
  `demscore.country_scores()`, which avoids separate class/value calculations.
- `node scripts/check_palette_contrast.mjs` passed and confirmed that mapfile
  classes match the frontend legend palettes.

## Suggested Follow-Up Checks

- Split `confidence` on the axis that matters: an imprecise border is absorbed
  by the hex grid, a polygon covering land the unit did not hold is not. The
  grade currently conflates them.
- Add a setup-time check for split ties across rendered classes to prevent a
  regression to row-position classing.
- Consume `/api/source-coverage` in the UI, so a reader can see that a country
  the source measured is missing from the map rather than missing from the data.
- Add per-variable rendering metadata for categorical variables.
