#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v pdftotext >/dev/null 2>&1; then
  echo "pdftotext is required but not found on PATH." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required but not found on PATH." >&2
  exit 1
fi

if [[ ! -x "${ROOT_DIR}/scripts/extract_variable_metadata.py" ]]; then
  chmod +x "${ROOT_DIR}/scripts/extract_variable_metadata.py"
fi

PDFS=(
  "${ROOT_DIR}/data/Demscore_Module_Vars/QoG/codebook.pdf"
  "${ROOT_DIR}/data/Demscore_Module_Vars/REPDEM/codebook.pdf"
  "${ROOT_DIR}/data/Demscore_Module_Vars/V-Dem/codebook.pdf"
)

for pdf in "${PDFS[@]}"; do
  if [[ ! -f "$pdf" ]]; then
    echo "Missing codebook PDF: $pdf" >&2
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

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

qog_txt="${tmp_dir}/qog_codebook.txt"
repdem_txt="${tmp_dir}/repdem_codebook.txt"
vdem_txt="${tmp_dir}/vdem_codebook.txt"
raw_csv="${tmp_dir}/variable_metadata_raw.csv"

echo "Extracting PDF text..."
pdftotext -layout "${ROOT_DIR}/data/Demscore_Module_Vars/QoG/codebook.pdf" "$qog_txt"
pdftotext -layout "${ROOT_DIR}/data/Demscore_Module_Vars/REPDEM/codebook.pdf" "$repdem_txt"
pdftotext -layout "${ROOT_DIR}/data/Demscore_Module_Vars/V-Dem/codebook.pdf" "$vdem_txt"

echo "Parsing codebook entries..."
python3 "${ROOT_DIR}/scripts/extract_variable_metadata.py" \
  --output-csv "$raw_csv" \
  --input "${qog_txt}::${ROOT_DIR}/data/Demscore_Module_Vars/QoG/codebook.pdf" \
  --input "${repdem_txt}::${ROOT_DIR}/data/Demscore_Module_Vars/REPDEM/codebook.pdf" \
  --input "${vdem_txt}::${ROOT_DIR}/data/Demscore_Module_Vars/V-Dem/codebook.pdf"

echo "Copying parsed metadata into DB container..."
podman cp "$raw_csv" demscore-postgis:/tmp/variable_metadata_raw.csv

echo "Loading variable metadata into PostgreSQL..."
podman compose exec -T db psql -U demscore -d demscore -v ON_ERROR_STOP=1 -f - <<'SQL'
BEGIN;

DO $$
BEGIN
  IF to_regclass('demscore.variables') IS NULL THEN
    RAISE EXCEPTION 'Missing table demscore.variables. Run scripts/load_demscore_module_vars.sh first.';
  END IF;
END;
$$;

DROP TABLE IF EXISTS demscore.variable_metadata_raw;
CREATE TABLE demscore.variable_metadata_raw (
  dataset TEXT,
  source_pdf TEXT,
  dataset_tag TEXT,
  heading_raw TEXT,
  title TEXT,
  long_tag TEXT,
  original_tag TEXT,
  dataset_citation TEXT,
  variable_citation TEXT,
  description TEXT,
  description_full TEXT,
  raw_block_text TEXT,
  additional_versions TEXT,
  question TEXT,
  clarification TEXT,
  scale TEXT,
  sources TEXT,
  data_release TEXT,
  aggregation TEXT,
  cross_coder_aggregation TEXT,
  country_year_aggregation TEXT
);

COPY demscore.variable_metadata_raw
FROM '/tmp/variable_metadata_raw.csv'
WITH (FORMAT csv, HEADER true);

CREATE TABLE IF NOT EXISTS demscore.variable_metadata (
  variable_id BIGINT PRIMARY KEY REFERENCES demscore.variables(id) ON DELETE CASCADE,
  dataset TEXT NOT NULL,
  variable TEXT NOT NULL,
  source_long_tag TEXT NOT NULL,
  source_pdf TEXT NOT NULL,
  dataset_tag TEXT,
  heading_raw TEXT,
  original_tag TEXT,
  title TEXT,
  dataset_citation TEXT,
  variable_citation TEXT,
  description TEXT,
  description_full TEXT,
  raw_block_text TEXT,
  additional_versions TEXT,
  question TEXT,
  clarification TEXT,
  scale TEXT,
  sources TEXT,
  data_release TEXT,
  aggregation TEXT,
  cross_coder_aggregation TEXT,
  country_year_aggregation TEXT,
  matched_by TEXT NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE demscore.variable_metadata ADD COLUMN IF NOT EXISTS heading_raw TEXT;
ALTER TABLE demscore.variable_metadata ADD COLUMN IF NOT EXISTS description_full TEXT;
ALTER TABLE demscore.variable_metadata ADD COLUMN IF NOT EXISTS raw_block_text TEXT;
ALTER TABLE demscore.variable_metadata ADD COLUMN IF NOT EXISTS question TEXT;
ALTER TABLE demscore.variable_metadata ADD COLUMN IF NOT EXISTS clarification TEXT;
ALTER TABLE demscore.variable_metadata ADD COLUMN IF NOT EXISTS scale TEXT;
ALTER TABLE demscore.variable_metadata ADD COLUMN IF NOT EXISTS sources TEXT;
ALTER TABLE demscore.variable_metadata ADD COLUMN IF NOT EXISTS data_release TEXT;
ALTER TABLE demscore.variable_metadata ADD COLUMN IF NOT EXISTS aggregation TEXT;
ALTER TABLE demscore.variable_metadata ADD COLUMN IF NOT EXISTS cross_coder_aggregation TEXT;
ALTER TABLE demscore.variable_metadata ADD COLUMN IF NOT EXISTS country_year_aggregation TEXT;

TRUNCATE demscore.variable_metadata;

WITH raw_dedup AS (
  SELECT DISTINCT ON (dataset, long_tag, COALESCE(original_tag, ''))
    dataset,
    source_pdf,
    NULLIF(dataset_tag, '') AS dataset_tag,
    NULLIF(heading_raw, '') AS heading_raw,
    NULLIF(title, '') AS title,
    long_tag,
    NULLIF(original_tag, '') AS original_tag,
    NULLIF(dataset_citation, '') AS dataset_citation,
    NULLIF(variable_citation, '') AS variable_citation,
    NULLIF(description, '') AS description,
    NULLIF(description_full, '') AS description_full,
    NULLIF(raw_block_text, '') AS raw_block_text,
    NULLIF(additional_versions, '') AS additional_versions,
    NULLIF(question, '') AS question,
    NULLIF(clarification, '') AS clarification,
    NULLIF(scale, '') AS scale,
    NULLIF(sources, '') AS sources,
    NULLIF(data_release, '') AS data_release,
    NULLIF(aggregation, '') AS aggregation,
    NULLIF(cross_coder_aggregation, '') AS cross_coder_aggregation,
    NULLIF(country_year_aggregation, '') AS country_year_aggregation
  FROM demscore.variable_metadata_raw
  WHERE NULLIF(long_tag, '') IS NOT NULL
  ORDER BY dataset, long_tag, COALESCE(original_tag, ''), length(COALESCE(description, '')) DESC
)
INSERT INTO demscore.variable_metadata (
  variable_id,
  dataset,
  variable,
  source_long_tag,
  source_pdf,
  dataset_tag,
  heading_raw,
  original_tag,
  title,
  dataset_citation,
  variable_citation,
  description,
  description_full,
  raw_block_text,
  additional_versions,
  question,
  clarification,
  scale,
  sources,
  data_release,
  aggregation,
  cross_coder_aggregation,
  country_year_aggregation,
  matched_by
)
SELECT
  v.id,
  v.dataset,
  v.variable,
  rd.long_tag,
  rd.source_pdf,
  rd.dataset_tag,
  rd.heading_raw,
  rd.original_tag,
  COALESCE(rd.title, rd.original_tag, rd.long_tag),
  rd.dataset_citation,
  rd.variable_citation,
  rd.description,
  rd.description_full,
  rd.raw_block_text,
  rd.additional_versions,
  rd.question,
  rd.clarification,
  rd.scale,
  rd.sources,
  rd.data_release,
  rd.aggregation,
  rd.cross_coder_aggregation,
  rd.country_year_aggregation,
  'direct'
FROM raw_dedup rd
JOIN demscore.variables v
  ON v.dataset = rd.dataset
 AND v.variable = rd.long_tag
ON CONFLICT (variable_id) DO UPDATE SET
  dataset = EXCLUDED.dataset,
  variable = EXCLUDED.variable,
  source_long_tag = EXCLUDED.source_long_tag,
  source_pdf = EXCLUDED.source_pdf,
  dataset_tag = EXCLUDED.dataset_tag,
  heading_raw = EXCLUDED.heading_raw,
  original_tag = EXCLUDED.original_tag,
  title = EXCLUDED.title,
  dataset_citation = EXCLUDED.dataset_citation,
  variable_citation = EXCLUDED.variable_citation,
  description = EXCLUDED.description,
  description_full = EXCLUDED.description_full,
  raw_block_text = EXCLUDED.raw_block_text,
  additional_versions = EXCLUDED.additional_versions,
  question = EXCLUDED.question,
  clarification = EXCLUDED.clarification,
  scale = EXCLUDED.scale,
  sources = EXCLUDED.sources,
  data_release = EXCLUDED.data_release,
  aggregation = EXCLUDED.aggregation,
  cross_coder_aggregation = EXCLUDED.cross_coder_aggregation,
  country_year_aggregation = EXCLUDED.country_year_aggregation,
  matched_by = EXCLUDED.matched_by,
  updated_at = now();

WITH raw_dedup AS (
  SELECT DISTINCT ON (dataset, long_tag, COALESCE(original_tag, ''))
    dataset,
    source_pdf,
    NULLIF(dataset_tag, '') AS dataset_tag,
    NULLIF(heading_raw, '') AS heading_raw,
    NULLIF(title, '') AS title,
    long_tag,
    NULLIF(original_tag, '') AS original_tag,
    NULLIF(dataset_citation, '') AS dataset_citation,
    NULLIF(variable_citation, '') AS variable_citation,
    NULLIF(description, '') AS description,
    NULLIF(description_full, '') AS description_full,
    NULLIF(raw_block_text, '') AS raw_block_text,
    NULLIF(additional_versions, '') AS additional_versions,
    NULLIF(question, '') AS question,
    NULLIF(clarification, '') AS clarification,
    NULLIF(scale, '') AS scale,
    NULLIF(sources, '') AS sources,
    NULLIF(data_release, '') AS data_release,
    NULLIF(aggregation, '') AS aggregation,
    NULLIF(cross_coder_aggregation, '') AS cross_coder_aggregation,
    NULLIF(country_year_aggregation, '') AS country_year_aggregation
  FROM demscore.variable_metadata_raw
  WHERE NULLIF(long_tag, '') IS NOT NULL
  ORDER BY dataset, long_tag, COALESCE(original_tag, ''), length(COALESCE(description, '')) DESC
)
INSERT INTO demscore.variable_metadata (
  variable_id,
  dataset,
  variable,
  source_long_tag,
  source_pdf,
  dataset_tag,
  heading_raw,
  original_tag,
  title,
  dataset_citation,
  variable_citation,
  description,
  description_full,
  raw_block_text,
  additional_versions,
  question,
  clarification,
  scale,
  sources,
  data_release,
  aggregation,
  cross_coder_aggregation,
  country_year_aggregation,
  matched_by
)
SELECT
  v.id,
  v.dataset,
  v.variable,
  rd.long_tag,
  rd.source_pdf,
  rd.dataset_tag,
  rd.heading_raw,
  rd.original_tag,
  COALESCE(rd.title, rd.original_tag, rd.long_tag),
  rd.dataset_citation,
  rd.variable_citation,
  rd.description,
  rd.description_full,
  rd.raw_block_text,
  rd.additional_versions,
  rd.question,
  rd.clarification,
  rd.scale,
  rd.sources,
  rd.data_release,
  rd.aggregation,
  rd.cross_coder_aggregation,
  rd.country_year_aggregation,
  'vdem_prefix'
FROM raw_dedup rd
JOIN demscore.variables v
  ON v.dataset = 'v_dem'
 AND rd.dataset = 'v_dem'
 AND v.variable = regexp_replace(rd.long_tag, '^vdem_cy_', '')
ON CONFLICT (variable_id) DO UPDATE SET
  dataset = EXCLUDED.dataset,
  variable = EXCLUDED.variable,
  source_long_tag = EXCLUDED.source_long_tag,
  source_pdf = EXCLUDED.source_pdf,
  dataset_tag = EXCLUDED.dataset_tag,
  heading_raw = EXCLUDED.heading_raw,
  original_tag = EXCLUDED.original_tag,
  title = EXCLUDED.title,
  dataset_citation = EXCLUDED.dataset_citation,
  variable_citation = EXCLUDED.variable_citation,
  description = EXCLUDED.description,
  description_full = EXCLUDED.description_full,
  raw_block_text = EXCLUDED.raw_block_text,
  additional_versions = EXCLUDED.additional_versions,
  question = EXCLUDED.question,
  clarification = EXCLUDED.clarification,
  scale = EXCLUDED.scale,
  sources = EXCLUDED.sources,
  data_release = EXCLUDED.data_release,
  aggregation = EXCLUDED.aggregation,
  cross_coder_aggregation = EXCLUDED.cross_coder_aggregation,
  country_year_aggregation = EXCLUDED.country_year_aggregation,
  matched_by = EXCLUDED.matched_by,
  updated_at = now();

WITH raw_dedup AS (
  SELECT DISTINCT ON (dataset, long_tag, COALESCE(original_tag, ''))
    dataset,
    source_pdf,
    NULLIF(dataset_tag, '') AS dataset_tag,
    NULLIF(heading_raw, '') AS heading_raw,
    NULLIF(title, '') AS title,
    long_tag,
    NULLIF(original_tag, '') AS original_tag,
    NULLIF(dataset_citation, '') AS dataset_citation,
    NULLIF(variable_citation, '') AS variable_citation,
    NULLIF(description, '') AS description,
    NULLIF(description_full, '') AS description_full,
    NULLIF(raw_block_text, '') AS raw_block_text,
    NULLIF(additional_versions, '') AS additional_versions,
    NULLIF(question, '') AS question,
    NULLIF(clarification, '') AS clarification,
    NULLIF(scale, '') AS scale,
    NULLIF(sources, '') AS sources,
    NULLIF(data_release, '') AS data_release,
    NULLIF(aggregation, '') AS aggregation,
    NULLIF(cross_coder_aggregation, '') AS cross_coder_aggregation,
    NULLIF(country_year_aggregation, '') AS country_year_aggregation
  FROM demscore.variable_metadata_raw
  WHERE NULLIF(long_tag, '') IS NOT NULL
  ORDER BY dataset, long_tag, COALESCE(original_tag, ''), length(COALESCE(description, '')) DESC
),
vdem_variants AS (
  SELECT
    rd.*,
    regexp_replace(rd.long_tag, '^vdem_cy_', '') AS base_variable,
    lower(trim(suffix)) AS suffix,
    ordinality::int AS suffix_pos
  FROM raw_dedup rd
  CROSS JOIN LATERAL regexp_split_to_table(COALESCE(rd.additional_versions, ''), '\s*,\s*') WITH ORDINALITY AS t(suffix, ordinality)
  WHERE rd.dataset = 'v_dem'
    AND COALESCE(rd.additional_versions, '') <> ''
    AND lower(trim(suffix)) ~ '^[a-z0-9_]+$'
),
variant_candidates AS (
  SELECT
    vv.*,
    vv.base_variable || '_' || vv.suffix AS variant_variable,
    vv.suffix AS suffix_chain
  FROM vdem_variants vv
  UNION ALL
  SELECT
    a.dataset,
    a.source_pdf,
    a.dataset_tag,
    a.heading_raw,
    a.title,
    a.long_tag,
    a.original_tag,
    a.dataset_citation,
    a.variable_citation,
    a.description,
    a.description_full,
    a.raw_block_text,
    a.additional_versions,
    a.question,
    a.clarification,
    a.scale,
    a.sources,
    a.data_release,
    a.aggregation,
    a.cross_coder_aggregation,
    a.country_year_aggregation,
    a.base_variable,
    b.suffix,
    b.suffix_pos,
    a.base_variable || '_' || a.suffix || '_' || b.suffix AS variant_variable,
    a.suffix || ',' || b.suffix AS suffix_chain
  FROM vdem_variants a
  JOIN vdem_variants b
    ON a.long_tag = b.long_tag
   AND a.suffix_pos < b.suffix_pos
)
INSERT INTO demscore.variable_metadata (
  variable_id,
  dataset,
  variable,
  source_long_tag,
  source_pdf,
  dataset_tag,
  heading_raw,
  original_tag,
  title,
  dataset_citation,
  variable_citation,
  description,
  description_full,
  raw_block_text,
  additional_versions,
  question,
  clarification,
  scale,
  sources,
  data_release,
  aggregation,
  cross_coder_aggregation,
  country_year_aggregation,
  matched_by
)
SELECT
  v.id,
  v.dataset,
  v.variable,
  vc.long_tag,
  vc.source_pdf,
  vc.dataset_tag,
  vc.heading_raw,
  vc.original_tag,
  CASE vc.suffix_chain
    WHEN 'codelow' THEN COALESCE(vc.title, vc.original_tag, vc.long_tag) || ' (Code low)'
    WHEN 'codehigh' THEN COALESCE(vc.title, vc.original_tag, vc.long_tag) || ' (Code high)'
    WHEN 'sd' THEN COALESCE(vc.title, vc.original_tag, vc.long_tag) || ' (Standard deviation)'
    WHEN 'osp' THEN COALESCE(vc.title, vc.original_tag, vc.long_tag) || ' (OSP variant)'
    WHEN 'ord' THEN COALESCE(vc.title, vc.original_tag, vc.long_tag) || ' (ORD variant)'
    WHEN 'mean' THEN COALESCE(vc.title, vc.original_tag, vc.long_tag) || ' (Mean variant)'
    WHEN 'nr' THEN COALESCE(vc.title, vc.original_tag, vc.long_tag) || ' (NR variant)'
    ELSE COALESCE(vc.title, vc.original_tag, vc.long_tag) || ' (' || replace(upper(vc.suffix_chain), ',', ' + ') || ' variant)'
  END AS title,
  vc.dataset_citation,
  vc.variable_citation,
  concat_ws(
    E'\n\n',
    vc.description,
    'Derived metadata inherited from base variable via ADDITIONAL VERSIONS (' ||
      array_to_string(
        ARRAY(
          SELECT '*_' || x
          FROM regexp_split_to_table(vc.suffix_chain, '\s*,\s*') AS x
        ),
        ', '
      ) || ').'
  ) AS description,
  concat_ws(
    E'\n\n',
    vc.description_full,
    'Derived metadata inherited from base variable via ADDITIONAL VERSIONS (' ||
      array_to_string(
        ARRAY(
          SELECT '*_' || x
          FROM regexp_split_to_table(vc.suffix_chain, '\s*,\s*') AS x
        ),
        ', '
      ) || ').'
  ) AS description_full,
  vc.raw_block_text,
  vc.additional_versions,
  vc.question,
  vc.clarification,
  vc.scale,
  vc.sources,
  vc.data_release,
  vc.aggregation,
  vc.cross_coder_aggregation,
  vc.country_year_aggregation,
  CASE
    WHEN vc.suffix_chain LIKE '%,%' THEN 'vdem_additional_versions_combo'
    ELSE 'vdem_additional_versions'
  END
FROM variant_candidates vc
JOIN demscore.variables v
  ON v.dataset = 'v_dem'
 AND v.variable = vc.variant_variable
ON CONFLICT (variable_id) DO UPDATE SET
  dataset = EXCLUDED.dataset,
  variable = EXCLUDED.variable,
  source_long_tag = EXCLUDED.source_long_tag,
  source_pdf = EXCLUDED.source_pdf,
  dataset_tag = EXCLUDED.dataset_tag,
  heading_raw = EXCLUDED.heading_raw,
  original_tag = EXCLUDED.original_tag,
  title = EXCLUDED.title,
  dataset_citation = EXCLUDED.dataset_citation,
  variable_citation = EXCLUDED.variable_citation,
  description = EXCLUDED.description,
  description_full = EXCLUDED.description_full,
  raw_block_text = EXCLUDED.raw_block_text,
  additional_versions = EXCLUDED.additional_versions,
  question = EXCLUDED.question,
  clarification = EXCLUDED.clarification,
  scale = EXCLUDED.scale,
  sources = EXCLUDED.sources,
  data_release = EXCLUDED.data_release,
  aggregation = EXCLUDED.aggregation,
  cross_coder_aggregation = EXCLUDED.cross_coder_aggregation,
  country_year_aggregation = EXCLUDED.country_year_aggregation,
  matched_by = EXCLUDED.matched_by,
  updated_at = now();

ANALYZE demscore.variable_metadata;

COMMIT;

SELECT
  (SELECT count(*) FROM demscore.variables) AS variable_rows,
  (SELECT count(*) FROM demscore.variable_metadata) AS metadata_rows,
  (SELECT count(*) FROM demscore.variables v LEFT JOIN demscore.variable_metadata vm ON vm.variable_id = v.id WHERE vm.variable_id IS NULL) AS unmatched_rows;

SELECT
  v.dataset,
  v.variable
FROM demscore.variables v
LEFT JOIN demscore.variable_metadata vm
  ON vm.variable_id = v.id
WHERE vm.variable_id IS NULL
ORDER BY v.dataset, v.variable
LIMIT 40;
SQL

echo "Cleaning temporary file from DB container..."
podman compose exec -T db sh -lc "rm -f /tmp/variable_metadata_raw.csv"

echo "Variable metadata load complete."
