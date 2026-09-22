# Data Correctness Review

This note records the main data-correctness findings from an audit of the
Demscore import, database preparation, WMS rendering, backend API, and web UI
presentation paths.

## Summary

Two user-facing correctness problems were found:

1. Source observations for countries that do not match the Natural Earth 110m
   country table are silently deleted during map setup. The UI then reports the
   reduced Natural Earth universe as if it were the source data universe.
2. The map uses `ntile(7)` over country values, which can split identical source
   values across different color classes. This makes countries with the same
   value appear different on the map.

Other reviewed areas were broadly consistent: the CSV melt excludes identifier
columns, filters Demscore's `-11111` missing marker, metadata matching is
complete in the live database, map colors and legend colors match, and the
legend/table read from the same `country_scores()` function used by WMS.

## Finding 1: Unmatched Source Countries Are Dropped

Severity: High

The CSV import initially keeps source values with country names and, where
available, ISO-style identifiers. During map setup, `sql/mapserver_hex_setup.sql`
maps those rows to `demscore.countries` using:

- ISO3 match against `demscore.countries.iso_a3`
- exact lowercased name match against `demscore.countries.name`

Rows that still have no `country_id` are then deleted:

```sql
DELETE FROM demscore.dataset_values
WHERE country_id IS NULL;
```

This means country observations can disappear from the database because they do
not exist in, or do not exactly match, the Natural Earth 110m country layer. The
loss is not limited to historical states. It includes current/recent small
states and naming mismatches.

Measured impact against the current source files:

| Dataset | User-facing/source scope | Values dropped | Countries affected |
| --- | ---: | ---: | ---: |
| QoG | visible numeric values, excluding intended OECD duplicate side | 5,136 / 55,611 (9.2%) | 32 |
| REPDEM | visible variables | 328 / 17,976 (1.8%) | 1 |
| REPDEM | all numeric values, including hidden WECEE side | 624 / 30,311 (2.1%) | 1 |
| V-Dem | all loaded numeric values | 343,443 / 3,189,614 (10.8%) | 37 |

Examples of dropped current/recent countries:

- QoG: Singapore, Malta, Bahrain, Barbados, Mauritius, Maldives, Cabo Verde,
  Saint Lucia, Samoa, San Marino, Tonga, Tuvalu.
- V-Dem: Singapore, Hong Kong, Barbados, Cape Verde, Malta, Maldives, Mauritius,
  Bahrain, Palestine/Gaza, Palestine/West Bank.
- REPDEM: Czechia. Natural Earth has `ADM0_A3 = CZE`, but its `NAME_LONG` is
  `Czech Republic`; the source name is `Czechia`, and REPDEM has no ISO column in
  the loader.

Why this misrepresents the data:

- The map/table universe is `demscore.countries`, not the source dataset's
  country universe.
- Backend totals come from `count(*) FROM demscore.countries`.
- The UI says countries without a value are drawn as plain land, but dropped
  source countries are not counted as no-data countries. They are absent from
  the map/table universe entirely.

Recommended fixes:

1. Do not delete unmatched observations silently. Keep them with an
   `unmapped_reason` or move them to an audit table.
2. Add a required setup report that lists unmatched countries, years, variables,
   and value counts by dataset.
3. Add explicit aliases for naming mismatches such as `Czechia -> Czech Republic`.
4. Add geometry support for small states missing from Natural Earth 110m, for
   example point/inset geometries or a higher-resolution country source.
5. Expose source-country coverage separately from map-country coverage in the UI
   until all source countries can be represented.

## Finding 2: `ntile(7)` Splits Equal Values Across Classes

Severity: High

`demscore.country_scores()` computes color classes with:

```sql
ntile(7) OVER (ORDER BY cv.value) AS class_idx
```

`ntile` distributes rows into seven buckets. It does not preserve ties. If many
countries share the same value, the same value can appear in multiple classes
and therefore multiple colors.

Concrete live example:

For `repdem_basic_govtype` in 2020:

- value `1` is assigned to classes 1, 2, and 3.
- value `3` is assigned to classes 3, 4, and 5.
- value `4` is assigned to classes 6 and 7.

This is especially misleading for categorical and low-cardinality variables.
`repdem_basic_govtype` is documented as categories:

- `1`: minority cabinet
- `2`: single-party majority cabinet
- `3`: minimal winning coalition
- `4`: surplus majority coalition
- `5`: non-partisan cabinet

The map currently makes countries with the same category appear different.

The issue is user-facing beyond this one variable. In the current offered
variable set, split ties were found in variables including:

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
- With split ties, class membership can reflect row position rather than value.
  Equal values no longer mean equal visual treatment.

Recommended fixes:

1. Replace `ntile(7)` with a classing method that preserves equal values.
2. If preserving ties results in fewer populated classes, show fewer populated
   classes rather than forcing seven.
3. Render categorical variables with category-aware colors and labels instead of
   numeric quantiles.
4. Add tests/assertions that no `(dataset, variable, year, value)` appears in
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

- Add a setup-time SQL or script check for unmatched country observations, and
  fail CI/setup unless the unmatched set is explicitly approved.
- Add a setup-time check for split ties across rendered classes.
- Add a source-vs-map coverage endpoint so the UI can distinguish "source has no
  value" from "source value exists but cannot be mapped".
- Add per-variable rendering metadata for categorical variables.
