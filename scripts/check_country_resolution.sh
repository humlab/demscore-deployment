#!/usr/bin/env bash
#
# Every source observation must be either drawn or explicitly refused.
#
# demscore.dataset_value_unmapped_audit records the observations that carry a
# value but have no geometry. This script reports them, and fails when any is
# `unresolved` -- that is, when nothing in demscore.country_resolution_policy
# names that entity and year. A country can leave the map only by somebody
# deciding it should and writing down why.
#
# It then runs regression assertions over the cases that are easy to get wrong:
# coding units whose territory changes under them (Palestine, Zanzibar,
# Vietnam), and the pre-1850 European states, where the right answer moves
# between three different geometry sources as the years advance.
#
# Run it on its own any time; scripts/setup_mapserver_hex_service.sh runs it
# after building the map tables.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ENV_FILE="${ROOT_DIR}/.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

PG_DB="${PG_DB:-demscore}"
PG_USER="${PG_USER:-demscore}"

psql_run() {
  podman compose exec -T db psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 -P pager=off "$@"
}

echo "=== Source coverage by dataset ==="
psql_run -c "
WITH loaded AS (
  SELECT v.dataset,
         count(*) AS loaded_values,
         count(*) FILTER (WHERE dv.country_id IS NULL) AS unmapped_values
  FROM demscore.dataset_values dv
  JOIN demscore.variables v ON v.id = dv.variable_id
  GROUP BY v.dataset
), audited AS (
  SELECT dataset,
         sum(value_count) FILTER (WHERE resolution_status = 'intentionally_unsupported') AS unsupported,
         sum(value_count) FILTER (WHERE resolution_status = 'unresolved') AS unresolved
  FROM demscore.dataset_value_unmapped_audit
  GROUP BY dataset
)
SELECT
  l.dataset,
  l.loaded_values,
  l.loaded_values - l.unmapped_values AS mapped_values,
  COALESCE(a.unsupported, 0) AS intentionally_unsupported,
  COALESCE(a.unresolved, 0) AS unresolved,
  round(100.0 * (l.loaded_values - l.unmapped_values) / NULLIF(l.loaded_values, 0), 2) AS pct_mapped
FROM loaded l
LEFT JOIN audited a ON a.dataset = l.dataset
ORDER BY l.dataset;"

echo
echo "=== Geometry the map is drawn on ==="
psql_run -c "
SELECT
  c.geometry_source_dataset AS source,
  c.geometry_source_license AS license,
  c.geometry_confidence AS confidence,
  count(*) AS countries
FROM demscore.countries c
GROUP BY 1, 2, 3
ORDER BY 1, 3 DESC;"

echo
echo "=== Intentionally unsupported source entities ==="
psql_run -c "
SELECT
  dataset,
  coalesce(iso3, '-') AS iso3,
  country_name,
  min(year) AS from_year,
  max(year) AS to_year,
  sum(value_count) AS values,
  left(reason, 90) || CASE WHEN length(reason) > 90 THEN '...' ELSE '' END AS reason
FROM demscore.dataset_value_unmapped_audit
WHERE resolution_status = 'intentionally_unsupported'
GROUP BY dataset, iso3, country_name, reason
ORDER BY sum(value_count) DESC;"

unresolved_count="$(psql_run -t -A -c "
  SELECT COALESCE(sum(value_count), 0)
  FROM demscore.dataset_value_unmapped_audit
  WHERE resolution_status = 'unresolved';")"

if [[ "$unresolved_count" != "0" ]]; then
  echo
  echo "=== UNRESOLVED source entities ===" >&2
  psql_run -c "
  SELECT
    dataset,
    coalesce(iso3, '-') AS iso3,
    country_name,
    min(year) AS from_year,
    max(year) AS to_year,
    sum(value_count) AS values,
    reason
  FROM demscore.dataset_value_unmapped_audit
  WHERE resolution_status = 'unresolved'
  GROUP BY dataset, iso3, country_name, reason
  ORDER BY sum(value_count) DESC;" >&2
  cat >&2 <<MSG

${unresolved_count} source values have no resolution policy.

Each entity above needs one of two things in sql/historical_geometry.sql:

  * geometry, as rows in demscore.historical_country_geometries_src plus a
    'historical_registry' row in demscore.country_resolution_policy; or
  * an 'intentionally_unsupported' policy row whose reason says why this
    deployment cannot represent it.

Setup fails rather than shipping a map whose universe silently differs from
the source's.
MSG
  exit 1
fi

echo
echo "=== Registry integrity ==="
psql_run -c "
SELECT
  'registry rows'                 AS check, count(*)::TEXT AS value FROM demscore.historical_country_geometries_src
UNION ALL SELECT 'registry entities',       count(DISTINCT registry_key)::TEXT FROM demscore.historical_country_geometries_src
UNION ALL SELECT 'policy rows',             count(*)::TEXT FROM demscore.country_resolution_policy
UNION ALL SELECT 'registry rows on the map', count(*)::TEXT FROM demscore.countries WHERE source = 'historical_registry'
ORDER BY 1;"

# A registry period that reached no observation was dropped by the
# unreferenced-country sweep in sql/mapserver_hex_setup.sql. That is correct for
# CShapes, which carries periods nobody asked for, but the registry is curated
# period by period, so a dropped one means a window was written for years the
# source does not actually carry -- worth knowing, not worth failing on.
echo
echo "=== Registry periods that reached no observation ==="
psql_run -c "
SELECT r.registry_key, r.valid_from_year, r.valid_to_year, r.source_dataset
FROM demscore.historical_country_geometries_src r
WHERE NOT EXISTS (
  SELECT 1 FROM demscore.countries c
  WHERE c.source = 'historical_registry'
    AND c.registry_key = r.registry_key
    AND c.valid_from_year = r.valid_from_year
)
ORDER BY 1, 2;"

echo
echo "=== Regression cases ==="
# A case whose entity-year the source does not carry is skipped, not failed:
# the cases are about where a coding unit is drawn, and a newer export that no
# longer reaches back to Bavaria in 1800 has not drawn Bavaria wrongly. Each
# skip is named, so a case that silently stopped testing anything is still
# visible -- and a coding unit V-Dem merely renamed would surface anyway, as an
# unresolved entity above. The import summary picks the skips up by their
# "Skipped regression case:" prefix.
regression_results="$(psql_run -t -A -c "
WITH expected(dataset, source_name, year, want_country, want_geometry_source) AS (VALUES
  -- Palestine: three coding units whose territory moves under them.
  ('v_dem', 'Palestine/British Mandate', 1918, 'Palestine/British Mandate',     'cshapes_2.0_extended'),
  ('v_dem', 'Palestine/British Mandate', 1930, 'Palestine',                     'cshapes_2.0'),
  ('v_dem', 'Palestine/Gaza',            1960, 'Gaza',                          'cshapes_2.0'),
  ('v_dem', 'Palestine/Gaza',            2020, 'Palestine/Gaza',                'cshapes_2.0_extended'),
  -- V-Dem codes the West Bank for 1948-1950 and again from 1967; 1960 has no data.
  ('v_dem', 'Palestine/West Bank',       1949, 'West Bank',                     'cshapes_2.0'),
  -- The years V-Dem's West Bank unit also covers Gaza.
  ('v_dem', 'Palestine/West Bank',       1990, 'Palestine/West Bank and Gaza',  'cshapes_2.0_derived'),
  ('v_dem', 'Palestine/West Bank',       2020, 'Palestine/West Bank',           'cshapes_2.0_extended'),
  -- Republic of Vietnam is the whole country before the 1954 partition and the
  -- southern state after it.
  ('v_dem', 'Republic of Vietnam',       1900, 'Vietnam (pre-partition)',       'natural_earth_50m'),
  ('v_dem', 'Republic of Vietnam',       1960, 'Vietnam, Republic of',          'cshapes_2.0'),
  -- Yemen/YEM is the North Yemen coding unit until unification, not the modern
  -- state outline that would overlap South Yemen.
  ('v_dem', 'Yemen',                     1970, 'Yemen (Arab Republic of Yemen)', 'cshapes_2.0'),
  ('v_dem', 'Yemen',                     1991, 'Yemen',                         'natural_earth_50m'),
  -- Zanzibar, before CShapes begins and after the union with Tanganyika.
  ('v_dem', 'Zanzibar',                  1860, 'Zanzibar',                      'cshapes_2.0_extended'),
  ('v_dem', 'Zanzibar',                  1900, 'Zanzibar',                      'cshapes_2.0'),
  ('v_dem', 'Zanzibar',                  2020, 'Zanzibar',                      'cshapes_2.0_extended'),
  -- Pre-1850 European states. Each of these moves between geometry sources as
  -- the years advance, which is the whole reason the registry is period-aware.
  ('v_dem', 'Bavaria',                   1800, 'Bavaria',                       'historical_basemaps'),
  ('v_dem', 'Bavaria',                   1810, 'Bavaria',                       'cshapes_europe_extended'),
  ('v_dem', 'Bavaria',                   1840, 'Bavaria',                       'cshapes_europe'),
  ('v_dem', 'Bavaria',                   1871, 'Bavaria',                       'cshapes_europe_extended'),
  ('v_dem', 'Saxony',                    1800, 'Saxony',                        'historical_basemaps'),
  ('v_dem', 'Saxony',                    1830, 'Saxony',                        'cshapes_europe'),
  ('v_dem', 'Hanover',                   1820, 'Hanover',                       'historical_basemaps'),
  ('v_dem', 'Hanover',                   1850, 'Hanover',                       'cshapes_europe'),
  ('v_dem', 'Hamburg',                   1830, 'Hamburg',                       'historical_basemaps'),
  ('v_dem', 'Tuscany',                   1830, 'Tuscany',                       'historical_basemaps'),
  ('v_dem', 'Papal States',              1800, 'Papal States',                  'cshapes_europe_extended'),
  ('v_dem', 'Papal States',              1840, 'Papal States',                  'cshapes_europe'),
  ('v_dem', 'Two Sicilies',              1840, 'Two Sicilies',                  'cshapes_europe'),
  ('v_dem', 'Piedmont-Sardinia',         1840, 'Piedmont-Sardinia',             'cshapes_europe'),
  ('v_dem', 'Würtemberg',                1871, 'Württemberg',                   'cshapes_europe_extended'),
  -- South Yemen before statehood is a low-confidence Aden marker; statehood
  -- years use the CShapes People's Democratic Republic polygon.
  ('v_dem', 'South Yemen',               1950, 'South Yemen (Aden approximation)', 'demscore_custom_aden_approx'),
  ('v_dem', 'South Yemen',               1980, 'Yemen, People''s Republic of',  'cshapes_2.0')
), actual AS (
  SELECT
    e.dataset, e.source_name, e.year, e.want_country, e.want_geometry_source,
    (SELECT count(*) FROM demscore.dataset_values dv
       JOIN demscore.variables v ON v.id = dv.variable_id
      WHERE v.dataset = e.dataset AND dv.country_name = e.source_name AND dv.year = e.year
    ) AS source_rows,
    (SELECT string_agg(DISTINCT c.name, ' + ') FROM demscore.dataset_values dv
       JOIN demscore.variables v ON v.id = dv.variable_id
       JOIN demscore.countries c ON c.id = dv.country_id
      WHERE v.dataset = e.dataset AND dv.country_name = e.source_name AND dv.year = e.year
    ) AS got_country,
    (SELECT string_agg(DISTINCT c.geometry_source_dataset, ' + ') FROM demscore.dataset_values dv
       JOIN demscore.variables v ON v.id = dv.variable_id
       JOIN demscore.countries c ON c.id = dv.country_id
      WHERE v.dataset = e.dataset AND dv.country_name = e.source_name AND dv.year = e.year
    ) AS got_geometry_source,
    (SELECT count(*) FROM demscore.dataset_value_unmapped_audit a
      WHERE a.dataset = e.dataset AND a.country_name = e.source_name AND a.year = e.year
        AND a.resolution_status = 'intentionally_unsupported'
    ) AS unsupported_rows
  FROM expected e
)
SELECT
  CASE WHEN source_rows = 0 THEN 'skip|' || source_name || ' ' || year || ': not in the source data'
  ELSE 'fail|' ||
  source_name || ' ' || year || ': expected ' ||
    COALESCE(want_country || ' on ' || want_geometry_source, want_geometry_source) ||
    ', got ' || COALESCE(COALESCE(got_country, '(nothing)') || ' on ' || COALESCE(got_geometry_source, '(nothing)'),
                         CASE WHEN unsupported_rows > 0 THEN 'intentionally_unsupported' ELSE '(nothing)' END)
  END
FROM actual
WHERE source_rows = 0
   OR (want_country IS NOT NULL AND (got_country IS DISTINCT FROM want_country
                                     OR got_geometry_source IS DISTINCT FROM want_geometry_source))
   OR (want_country IS NULL AND (got_country IS NOT NULL OR unsupported_rows = 0));")"

regression_skips="$(sed -n 's/^skip|//p' <<<"$regression_results")"
regression_failures="$(sed -n 's/^fail|//p' <<<"$regression_results")"

if [[ -n "$regression_skips" ]]; then
  sed 's/^/Skipped regression case: /' <<<"$regression_skips"
fi

if [[ -n "$regression_failures" ]]; then
  echo "FAILED:" >&2
  echo "$regression_failures" | sed 's/^/  /' >&2
  exit 1
fi

if [[ -n "$regression_skips" ]]; then
  echo "Every regression case the source still carries passes."
else
  echo "All regression cases pass."
fi
