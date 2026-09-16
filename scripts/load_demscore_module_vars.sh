#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BASE_DIR="${ROOT_DIR}/data/Demscore_Module_Vars"
DATASETS=("QoG" "REPDEM" "V-Dem")

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
SQL

  for dataset in "${DATASETS[@]}"; do
    csv_path="${BASE_DIR}/${dataset}/data.csv"
    stage_name="stg_$(echo "$dataset" | tr '[:upper:]' '[:lower:]' | tr '-' '_')"

    header="$(head -n 1 "$csv_path" | tr -d '\r')"
    IFS=',' read -r -a columns <<< "$header"
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

    year_expr="CASE WHEN NULLIF(TRIM(s.\"${year_col}\"), '') ~ '^[0-9]{1,4}$' THEN NULLIF(TRIM(s.\"${year_col}\"), '')::INT ELSE NULL END"
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
WITH extracted AS (
  SELECT
    '${dataset_key}'::TEXT AS dataset,
    ${iso_expr} AS iso3,
    NULLIF(TRIM(s."${country_col}"), '') AS country_name,
    ${year_expr} AS year,
    kv.key AS variable,
    CASE
      WHEN kv.value ~ '^[+-]?[0-9]*\\.?[0-9]+([eE][+-]?[0-9]+)?$' THEN kv.value::DOUBLE PRECISION
      ELSE NULL
    END AS value
  FROM demscore.${stage_name} s
  CROSS JOIN LATERAL (SELECT to_jsonb(s) AS row_json) src
  CROSS JOIN LATERAL jsonb_each_text(src.row_json - ARRAY[${exclude_sql}]) kv
), typed AS (
  SELECT dataset, iso3, country_name, year, variable, value
  FROM extracted
  WHERE year IS NOT NULL
    AND value IS NOT NULL
)
INSERT INTO demscore.variables (dataset, variable)
SELECT DISTINCT dataset, variable
FROM typed
ON CONFLICT (dataset, variable) DO NOTHING;

WITH extracted AS (
  SELECT
    '${dataset_key}'::TEXT AS dataset,
    ${iso_expr} AS iso3,
    NULLIF(TRIM(s."${country_col}"), '') AS country_name,
    ${year_expr} AS year,
    kv.key AS variable,
    CASE
      WHEN kv.value ~ '^[+-]?[0-9]*\\.?[0-9]+([eE][+-]?[0-9]+)?$' THEN kv.value::DOUBLE PRECISION
      ELSE NULL
    END AS value
  FROM demscore.${stage_name} s
  CROSS JOIN LATERAL (SELECT to_jsonb(s) AS row_json) src
  CROSS JOIN LATERAL jsonb_each_text(src.row_json - ARRAY[${exclude_sql}]) kv
), typed AS (
  SELECT dataset, iso3, country_name, year, variable, value
  FROM extracted
  WHERE year IS NOT NULL
    AND value IS NOT NULL
)
INSERT INTO demscore.dataset_values (variable_id, year, iso3, country_name, value, country_id)
SELECT
  v.id,
  t.year,
  t.iso3,
  t.country_name,
  t.value,
  NULL
FROM typed t
JOIN demscore.variables v
  ON v.dataset = t.dataset
 AND v.variable = t.variable;

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
