#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BASE_DIR="${ROOT_DIR}/data/Demscore_Module_Vars"
DATASETS=("QoG" "REPDEM" "V-Dem")

# Demscore writes -11111 wherever an observation is lost in the translation to the
# requested unit of analysis ("missing due to the translation/merge", REPDEM
# codebook s2.4) — a missing marker, not a measurement. Loading it as a value put
# 8402 rows of it into REPDEM, where ntile() read them as the lowest quantile and
# AVG() folded them into the hex average, pulling the legend floor to -11111 and
# squeezing every real value into the top class. Columns whose real values are text
# (cabinet names, election dates, party lists) do not survive the numeric melt at
# all, so the marker was all they had left: filtering it here empties them, and the
# variables insert reads the same filtered rows, so they are never registered.
#
# -22222 is the codebooks' other Demscore code: no observation could be translated
# to this unit, although the original data has one elsewhere. Equally a marker,
# not a measurement. No export in data/ carries it yet; one that did would map it
# as a real value of -22222, which is the failure -11111 was filtered for.
MISSING_CODES="-11111, -22222"

# Spellings of "no value" other than an empty cell. Demscore's exports leave the
# cell empty, but one written out through R or Stata says NA or ".", and since a
# single text cell drops its whole column (see not_numeric below), one such
# export would take every indicator off the map. Compared case-insensitively,
# after trimming; how many were seen is in the column report.
NA_TOKENS="'na', 'nan', 'n/a', '.'"

for dataset in "${DATASETS[@]}"; do
  csv_path="${BASE_DIR}/${dataset}/data.csv"
  if [[ ! -f "$csv_path" ]]; then
    echo "Missing required dataset file: $csv_path" >&2
    exit 1
  fi
done

echo "Starting database service..."
podman compose up -d db

echo "Waiting for database readiness..."
for _ in {1..30}; do
  if podman compose exec -T db pg_isready -U demscore -d demscore >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

if ! podman compose exec -T db pg_isready -U demscore -d demscore >/dev/null 2>&1; then
  echo "Database is not ready after timeout." >&2
  exit 1
fi

tmp_sql="$(mktemp)"
trap 'rm -f "$tmp_sql"' EXIT

{
  cat <<'SQL'
BEGIN;

CREATE SCHEMA IF NOT EXISTS demscore;

-- Cleanup legacy objects from the previous wide-table pipeline.
DROP VIEW IF EXISTS demscore.dataset_rows CASCADE;
DROP FUNCTION IF EXISTS demscore.hex_variable(TEXT, TEXT, INTEGER, INTEGER);
DROP FUNCTION IF EXISTS demscore.country_scores(TEXT, TEXT, INTEGER);

-- Metadata tables depend on demscore.variables; clear them before rebuilding
-- the canonical variables/value tables.
DROP TABLE IF EXISTS demscore.variable_metadata;
DROP TABLE IF EXISTS demscore.variable_metadata_raw;

DROP TABLE IF EXISTS demscore.dataset_values;
DROP TABLE IF EXISTS demscore.variables;
DROP TABLE IF EXISTS demscore.qog CASCADE;
DROP TABLE IF EXISTS demscore.repdem CASCADE;
DROP TABLE IF EXISTS demscore.v_dem CASCADE;

CREATE TABLE demscore.variables (
  id BIGSERIAL PRIMARY KEY,
  dataset TEXT NOT NULL,
  variable TEXT NOT NULL,
  -- Kept in the database and renderable by direct WMS request, but left out of the
  -- variable list the web client offers. See the superseded-variant step below.
  hidden BOOLEAN NOT NULL DEFAULT FALSE,
  UNIQUE (dataset, variable)
);

CREATE TABLE demscore.dataset_values (
  id BIGSERIAL PRIMARY KEY,
  variable_id BIGINT NOT NULL REFERENCES demscore.variables(id) ON DELETE CASCADE,
  year INTEGER NOT NULL,
  iso3 TEXT,
  country_name TEXT,
  value DOUBLE PRECISION NOT NULL,
  country_id BIGINT
);

-- What the load found and what it did with it, for the summary
-- scripts/import_data.sh prints. Rebuilt by every load, so it always describes
-- the data that is in the tables beside it.
DROP TABLE IF EXISTS demscore.import_source_report;
CREATE TABLE demscore.import_source_report (
  dataset TEXT PRIMARY KEY,
  csv_rows BIGINT NOT NULL,
  csv_columns INTEGER NOT NULL,
  identifier_columns INTEGER NOT NULL,
  rows_without_year BIGINT NOT NULL,
  year_min INTEGER,
  year_max INTEGER,
  source_countries BIGINT NOT NULL
);

-- One row per CSV column. outcome is one of
--   identifier          a u_ column: country, year or a country code
--   imported            an indicator, now in demscore.variables
--   dropped_not_numeric holds at least one value that is not a number
--   dropped_no_values   nothing left once empty cells and missing codes go
--   dropped_redundant   an exact copy of a twin that was kept
--   hidden_superseded   kept, but left out of the variable list
DROP TABLE IF EXISTS demscore.import_column_report;
CREATE TABLE demscore.import_column_report (
  dataset TEXT NOT NULL,
  column_name TEXT NOT NULL,
  column_position INTEGER NOT NULL,
  outcome TEXT NOT NULL,
  value_count BIGINT NOT NULL DEFAULT 0,
  missing_code_cells BIGINT NOT NULL DEFAULT 0,
  na_token_cells BIGINT NOT NULL DEFAULT 0,
  detail TEXT,
  PRIMARY KEY (dataset, column_name)
);
SQL

  for dataset in "${DATASETS[@]}"; do
    csv_path="${BASE_DIR}/${dataset}/data.csv"
    stage_name="stg_$(echo "$dataset" | tr '[:upper:]' '[:lower:]' | tr '-' '_')"

    # A UTF-8 byte-order mark would otherwise become part of the first column's
    # name, which then no longer starts with u_ and no longer matches the name
    # the required-column check looks for. COPY skips the header line itself.
    header="$(head -n 1 "$csv_path" | tr -d '\r' | sed $'1s/^\xEF\xBB\xBF//')"
    IFS=',' read -r -a columns <<< "$header"
    # Names are plain identifiers (scripts/import_data_report.py checks that
    # before a load), but a writer may still have quoted every one of them.
    for i in "${!columns[@]}"; do
      col="${columns[$i]}"
      col="${col#\"}"
      columns[$i]="${col%\"}"
    done
    if [[ ${#columns[@]} -eq 0 ]]; then
      echo "No columns found in $csv_path" >&2
      exit 1
    fi

    case "$dataset" in
      "QoG")
        dataset_key="qog"
        iso_col="u_qog_country_year_ccodealp"
        country_col="u_qog_country_year_country"
        year_col="u_qog_country_year_year"
        ;;
      "REPDEM")
        dataset_key="repdem"
        iso_col=""
        country_col="u_repdem_country_year_country"
        year_col="u_repdem_country_year_year"
        ;;
      "V-Dem")
        dataset_key="v_dem"
        iso_col="u_vdem_country_year_country_text_id"
        country_col="u_vdem_country_year_country"
        year_col="u_vdem_country_year_year"
        ;;
      *)
        echo "Unknown dataset: $dataset" >&2
        exit 1
        ;;
    esac

    echo "DROP TABLE IF EXISTS demscore.${stage_name};"
    echo "CREATE UNLOGGED TABLE demscore.${stage_name} ("

    for i in "${!columns[@]}"; do
      col="${columns[$i]}"
      col="${col//\"/\"\"}"
      suffix=","
      if [[ $i -eq $((${#columns[@]} - 1)) ]]; then
        suffix=""
      fi
      echo "  \"${col}\" TEXT${suffix}"
    done

    echo ");"
    echo "COPY demscore.${stage_name} FROM '/datasets/${dataset}/data.csv' WITH (FORMAT csv, HEADER true);"

    # Demscore prefixes every unit/identifier column with `u_` (country name,
    # year, and the various country code systems). Excluding only the three the
    # load reads by name let the rest — e.g. u_vdem_country_year_country_id —
    # melt into demscore.variables as if they were indicators: numeric, so they
    # carry values and map, but with no codebook entry, so the web client can
    # only show their raw key. Drop the whole prefix instead.
    excluded_cols=()
    for col in "${columns[@]}"; do
      if [[ "$col" == u_* ]]; then
        excluded_cols+=("$col")
      fi
    done

    for required_col in "$country_col" "$year_col" ${iso_col:+"$iso_col"}; do
      if [[ ! " ${excluded_cols[*]} " == *" ${required_col} "* ]]; then
        echo "Column ${required_col} is missing from ${csv_path}" >&2
        exit 1
      fi
    done
    echo "${dataset}: excluding ${#excluded_cols[@]} identifier columns: ${excluded_cols[*]}" >&2

    # "2020.0" as well as "2020": a writer that went through a float column
    # spells the year that way, and rejecting it would drop every row.
    year_expr="CASE WHEN TRIM(s.\"${year_col}\") ~ '^[0-9]{1,4}(\\.0+)?\$' THEN TRIM(s.\"${year_col}\")::NUMERIC::INT ELSE NULL END"
    if [[ -n "$iso_col" ]]; then
      iso_expr="NULLIF(TRIM(s.\"${iso_col}\"), '')"
    else
      iso_expr="NULL::TEXT"
    fi

    exclude_sql=""
    for ec in "${excluded_cols[@]}"; do
      [[ -z "$ec" ]] && continue
      if [[ -n "$exclude_sql" ]]; then
        exclude_sql+=" ,"
      fi
      exclude_sql+="'${ec}'"
    done

    cat <<SQL
-- What the export holds, before anything is filtered out of it.
INSERT INTO demscore.import_source_report (
  dataset, csv_rows, csv_columns, identifier_columns, rows_without_year,
  year_min, year_max, source_countries
)
SELECT
  '${dataset_key}',
  count(*),
  ${#columns[@]},
  ${#excluded_cols[@]},
  count(*) FILTER (WHERE (${year_expr}) IS NULL),
  min(${year_expr}),
  max(${year_expr}),
  count(DISTINCT NULLIF(TRIM(s."${country_col}"), ''))
FROM demscore.${stage_name} s;

-- The melt, once: one row per (country-year, column) cell. Every step below
-- reads this table rather than melting the staging table again.
CREATE TEMP TABLE import_cells AS
SELECT
  ${iso_expr} AS iso3,
  NULLIF(TRIM(s."${country_col}"), '') AS country_name,
  ${year_expr} AS year,
  kv.key AS variable,
  c.raw_value,
  CASE
    WHEN c.raw_value ~ '^[+-]?[0-9]*\\.?[0-9]+([eE][+-]?[0-9]+)?$' THEN c.raw_value::DOUBLE PRECISION
    ELSE NULL
  END AS value,
  COALESCE(lower(c.raw_value) IN (${NA_TOKENS}), FALSE) AS is_na_token
FROM demscore.${stage_name} s
CROSS JOIN LATERAL jsonb_each_text(to_jsonb(s) - ARRAY[${exclude_sql}]) kv
CROSS JOIN LATERAL (SELECT NULLIF(btrim(kv.value), '') AS raw_value) c;

-- A column is an indicator only if every value it has is a number. Casting
-- cell by cell let REPDEM's cab_composition2 through: a list of party IDs,
-- where a coalition ("10005,10004,10001") failed the cast and was dropped
-- while a single-party cabinet ("10005") passed as the number 10005. The
-- map then drew coalitions as no data and ranked party IDs into classes.
CREATE TEMP TABLE import_column_stats AS
SELECT
  variable,
  count(*) FILTER (WHERE raw_value IS NOT NULL AND value IS NULL AND NOT is_na_token) AS text_cells,
  min(raw_value) FILTER (WHERE raw_value IS NOT NULL AND value IS NULL AND NOT is_na_token) AS text_example,
  count(*) FILTER (WHERE is_na_token) AS na_token_cells,
  count(*) FILTER (WHERE value IN (${MISSING_CODES})) AS missing_code_cells,
  count(*) FILTER (
    WHERE value IS NOT NULL AND value NOT IN (${MISSING_CODES}) AND year IS NOT NULL
  ) AS usable_cells
FROM import_cells
GROUP BY variable;

INSERT INTO demscore.variables (dataset, variable)
SELECT '${dataset_key}', variable
FROM import_column_stats
WHERE text_cells = 0
  AND usable_cells > 0
ORDER BY variable
ON CONFLICT (dataset, variable) DO NOTHING;

INSERT INTO demscore.dataset_values (variable_id, year, iso3, country_name, value, country_id)
SELECT
  v.id,
  c.year,
  c.iso3,
  c.country_name,
  c.value,
  NULL
FROM import_cells c
JOIN demscore.variables v
  ON v.dataset = '${dataset_key}'
 AND v.variable = c.variable
WHERE c.year IS NOT NULL
  AND c.value IS NOT NULL
  AND c.value NOT IN (${MISSING_CODES});

INSERT INTO demscore.import_column_report (
  dataset, column_name, column_position, outcome,
  value_count, missing_code_cells, na_token_cells, detail
)
SELECT
  '${dataset_key}',
  c.column_name,
  c.ordinal_position::INTEGER,
  CASE
    WHEN c.column_name LIKE 'u\\_%' THEN 'identifier'
    WHEN st.text_cells > 0 THEN 'dropped_not_numeric'
    WHEN v.id IS NOT NULL THEN 'imported'
    ELSE 'dropped_no_values'
  END,
  COALESCE(st.usable_cells, 0),
  COALESCE(st.missing_code_cells, 0),
  COALESCE(st.na_token_cells, 0),
  CASE
    WHEN c.column_name LIKE 'u\\_%' THEN NULL
    WHEN st.text_cells > 0
      THEN format('%s text value(s), e.g. "%s"', st.text_cells, left(st.text_example, 40))
    WHEN v.id IS NULL AND COALESCE(st.missing_code_cells, 0) > 0
      THEN format('only missing codes (%s cell(s))', st.missing_code_cells)
    WHEN v.id IS NULL THEN 'no values'
  END
FROM information_schema.columns c
LEFT JOIN import_column_stats st
  ON st.variable = c.column_name
LEFT JOIN demscore.variables v
  ON v.dataset = '${dataset_key}'
 AND v.variable = c.column_name
WHERE c.table_schema = 'demscore'
  AND c.table_name = '${stage_name}';

-- Name the melted columns that were not registered, so a column left out for
-- holding text or emptied by MISSING_CODES shows up in the load log instead of
-- just going absent from the variable list.
DO \$\$
DECLARE
  empty_cols TEXT;
BEGIN
  SELECT string_agg(column_name, ', ' ORDER BY column_name)
    INTO empty_cols
  FROM demscore.import_column_report
  WHERE dataset = '${dataset_key}'
    AND outcome LIKE 'dropped\\_%';
  IF empty_cols IS NOT NULL THEN
    RAISE NOTICE '%: dropped column(s) that are not wholly numeric or hold only missing codes: %', '${dataset_key}', empty_cols;
  END IF;
END
\$\$;

DROP TABLE import_cells, import_column_stats;
DROP TABLE demscore.${stage_name};
SQL
  done

  cat <<'SQL'
CREATE INDEX dataset_values_var_year_idx ON demscore.dataset_values (variable_id, year);
CREATE INDEX dataset_values_country_var_year_idx ON demscore.dataset_values (country_id, variable_id, year);
CREATE INDEX dataset_values_iso3_idx ON demscore.dataset_values (iso3);
CREATE INDEX dataset_values_country_name_lc_idx ON demscore.dataset_values (lower(country_name));

ANALYZE demscore.variables;
ANALYZE demscore.dataset_values;

-- QoG ships twelve of its thirteen indicators twice: once from the QoG Standard
-- Dataset Time-Series (global) and once from the QoG OECD Dataset Time-Series
-- (OECD members only). For this variable selection the OECD column is an exact
-- subset of its Standard twin — same country, same year, same value, and not one
-- row of its own — so it reached the variable list as a second row carrying the
-- codebook's identical title, with nothing but a shorter coverage strip to tell
-- the two apart. Drop the redundant side, but prove the redundancy per variable
-- first: if a later export revises one product and not the other, the twin stops
-- being a duplicate, and the load says so rather than discarding the difference.
-- Runs after the indexes exist, since the proof probes one twin per row of the
-- other. REPDEM's basic/wecee pair is deliberately not listed here — those two
-- disagree on real values, so both belong in the list (see the title
-- disambiguation in scripts/load_variable_metadata.sh).
DO $$
DECLARE
  rule RECORD;
  twin RECORD;
  extra BIGINT;
  dropped INT;
BEGIN
  FOR rule IN
    SELECT *
    FROM (VALUES ('qog', 'qog_oecd_ts_', 'qog_std_ts_')) AS r(dataset, drop_prefix, keep_prefix)
  LOOP
    dropped := 0;

    FOR twin IN
      SELECT
        d.id       AS drop_id,
        d.variable AS drop_variable,
        k.id       AS keep_id,
        k.variable AS keep_variable
      FROM demscore.variables d
      JOIN demscore.variables k
        ON k.dataset = d.dataset
       AND k.variable = rule.keep_prefix || substring(d.variable FROM length(rule.drop_prefix) + 1)
      WHERE d.dataset = rule.dataset
        AND starts_with(d.variable, rule.drop_prefix)
      ORDER BY d.variable
    LOOP
      SELECT count(*) INTO extra
      FROM demscore.dataset_values a
      WHERE a.variable_id = twin.drop_id
        AND NOT EXISTS (
          SELECT 1
          FROM demscore.dataset_values b
          WHERE b.variable_id = twin.keep_id
            AND b.year = a.year
            AND b.iso3 IS NOT DISTINCT FROM a.iso3
            AND b.country_name IS NOT DISTINCT FROM a.country_name
            AND b.value = a.value
        );

      IF extra = 0 THEN
        -- Cascades to dataset_values.
        DELETE FROM demscore.variables WHERE id = twin.drop_id;
        UPDATE demscore.import_column_report
           SET outcome = 'dropped_redundant',
               detail = format('exact copy of rows in %s', twin.keep_variable)
         WHERE dataset = rule.dataset
           AND column_name = twin.drop_variable;
        dropped := dropped + 1;
      ELSE
        RAISE WARNING '%: keeping % — % row(s) of it are not in %',
          rule.dataset, twin.drop_variable, extra, twin.keep_variable;
        UPDATE demscore.import_column_report
           SET detail = format('kept beside its twin %s: %s row(s) differ', twin.keep_variable, extra)
         WHERE dataset = rule.dataset
           AND column_name = twin.drop_variable;
      END IF;
    END LOOP;

    RAISE NOTICE '%: dropped % redundant %* variable(s)',
      rule.dataset, dropped, rule.drop_prefix;
  END LOOP;
END
$$;

-- REPDEM ships each of its ten indicators twice, as REPDEM Basic (PAGED Basic) and
-- as REPDEM PAGED Western, Central and Eastern Europe. Unlike QoG's OECD twins
-- these are not identical — basic revises wecee's figures and disagrees
-- substantively on up to 16% of shared country-years — so this marks rather than
-- deletes. The rows stay in the table, a direct WMS request still renders them,
-- and only the variable list the web client offers loses them.
--
-- The codebook is explicit that basic supersedes wecee: basic is "updated in-house
-- to cover additional years, additional countries (vetted by county experts), and
-- additional variables" through late-2025, while wecee stops at 2019 for Western
-- Europe and 2021 for Central and Eastern Europe. Basic carries every country
-- wecee has and six more (Australia, Canada, Israel, Japan, New Zealand,
-- Luxembourg), and no indicator is unique to wecee.
--
-- It is not a clean superset, though. Pooled over all years wecee adds no country,
-- but the map draws one year at a time, and in a given year a country can sit in
-- wecee and be absent from basic — Finland in 1958 for seats_total, a year basic
-- skips between 1957 and 1959. Eight such cells exist in total, so the load
-- prints the number it is hiding instead of pretending the twin adds nothing.
DO $$
DECLARE
  rule RECORD;
  twin RECORD;
  orphans BIGINT;
  hidden_vars INT;
  hidden_cells BIGINT;
BEGIN
  FOR rule IN
    SELECT *
    FROM (VALUES ('repdem', 'repdem_wecee_', 'repdem_basic_')) AS r(dataset, hide_prefix, keep_prefix)
  LOOP
    hidden_vars := 0;
    hidden_cells := 0;

    FOR twin IN
      SELECT
        h.id       AS hide_id,
        h.variable AS hide_variable,
        k.id       AS keep_id,
        k.variable AS keep_variable
      FROM demscore.variables h
      JOIN demscore.variables k
        ON k.dataset = h.dataset
       AND k.variable = rule.keep_prefix || substring(h.variable FROM length(rule.hide_prefix) + 1)
      WHERE h.dataset = rule.dataset
        AND starts_with(h.variable, rule.hide_prefix)
      ORDER BY h.variable
    LOOP
      SELECT count(*) INTO orphans
      FROM demscore.dataset_values a
      WHERE a.variable_id = twin.hide_id
        AND NOT EXISTS (
          SELECT 1
          FROM demscore.dataset_values b
          WHERE b.variable_id = twin.keep_id
            AND b.year = a.year
            AND b.country_id IS NOT DISTINCT FROM a.country_id
            AND b.country_name IS NOT DISTINCT FROM a.country_name
        );

      UPDATE demscore.variables SET hidden = TRUE WHERE id = twin.hide_id;
      UPDATE demscore.import_column_report
         SET outcome = 'hidden_superseded',
             detail = format('superseded by %s; %s country-year cell(s) only here', twin.keep_variable, orphans)
       WHERE dataset = rule.dataset
         AND column_name = twin.hide_variable;
      hidden_vars := hidden_vars + 1;
      hidden_cells := hidden_cells + orphans;
    END LOOP;

    RAISE NOTICE '%: hid % variable(s) superseded by %* — % country-year cell(s) exist only in the hidden side',
      rule.dataset, hidden_vars, rule.keep_prefix, hidden_cells;
  END LOOP;
END
$$;

-- A dataset with nothing left in its variable list would reach the web client
-- as a chip that opens onto no variables, and the map would have nothing to
-- draw for it. That is an export gone wrong (a different delimiter, every
-- column turned to text), not a selection anybody made, so the whole load
-- rolls back and the previous data stays where it is.
DO $$
DECLARE
  empty_datasets TEXT;
BEGIN
  SELECT string_agg(r.dataset, ', ' ORDER BY r.dataset)
    INTO empty_datasets
  FROM demscore.import_source_report r
  WHERE NOT EXISTS (
    SELECT 1 FROM demscore.variables v
    WHERE v.dataset = r.dataset AND NOT v.hidden
  );
  IF empty_datasets IS NOT NULL THEN
    RAISE EXCEPTION 'No indicator column survived the load for: %. Nothing was changed; the column outcomes are in the notices above.', empty_datasets;
  END IF;
END
$$;

ANALYZE demscore.variables;
ANALYZE demscore.dataset_values;
ANALYZE demscore.import_column_report;

COMMIT;
SQL
} > "$tmp_sql"

podman compose exec -T db psql -U demscore -d demscore -v ON_ERROR_STOP=1 -f - < "$tmp_sql"

podman compose exec -T db psql -U demscore -d demscore -v ON_ERROR_STOP=1 -c "
SELECT
  v.dataset,
  count(DISTINCT v.variable) AS variable_count,
  count(dv.*) AS value_count
FROM demscore.variables v
LEFT JOIN demscore.dataset_values dv
  ON dv.variable_id = v.id
GROUP BY v.dataset
ORDER BY v.dataset;"
