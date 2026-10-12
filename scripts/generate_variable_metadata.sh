#!/usr/bin/env bash
# Queries the database variable_metadata table and writes
# webapp/config/variable_metadata.json for use by the web client.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PG_HOST="${PG_HOST:-127.0.0.1}"
PG_PORT="${PG_PORT:-${DEMSCORE_DB_PORT:-5532}}"
PG_DB="${PG_DB:-demscore}"
PG_USER="${PG_USER:-demscore}"
export PGPASSWORD="${PG_PASSWORD:-demscore}"

OUT_FILE="${ROOT_DIR}/webapp/config/variable_metadata.json"

echo "Generating ${OUT_FILE} from database..."

psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -At <<'SQL' > "$OUT_FILE"
SELECT jsonb_pretty(
  jsonb_object_agg(
    dataset_key,
    jsonb_build_object(
      'citation',  citation,
      'variables', vars
    )
  )
)
FROM (
  SELECT
    dataset                                                    AS dataset_key,
    -- One citation per dataset (use first non-null value)
    (array_agg(dataset_citation ORDER BY variable)
       FILTER (WHERE dataset_citation IS NOT NULL))[1]        AS citation,
    jsonb_object_agg(
      variable,
      jsonb_strip_nulls(
        jsonb_build_object(
          'title', COALESCE(NULLIF(trim(title), ''), variable),
          'dataset_tag', NULLIF(trim(dataset_tag), ''),
          'heading_raw', NULLIF(trim(heading_raw), ''),
          'source_long_tag', NULLIF(trim(source_long_tag), ''),
          'source_pdf', NULLIF(trim(source_pdf), ''),
          'original_tag', NULLIF(trim(original_tag), ''),
          'dataset_citation', NULLIF(trim(dataset_citation), ''),
          'variable_citation', NULLIF(trim(variable_citation), ''),
          'description', NULLIF(trim(description), ''),
          'description_full', NULLIF(trim(description_full), ''),
          'raw_block_text', NULLIF(trim(raw_block_text), ''),
          'additional_versions', NULLIF(trim(additional_versions), ''),
          'question', NULLIF(trim(question), ''),
          'clarification', NULLIF(trim(clarification), ''),
          'scale', NULLIF(trim(scale), ''),
          'sources', NULLIF(trim(sources), ''),
          'data_release', NULLIF(trim(data_release), ''),
          'aggregation', NULLIF(trim(aggregation), ''),
          'cross_coder_aggregation', NULLIF(trim(cross_coder_aggregation), ''),
          'country_year_aggregation', NULLIF(trim(country_year_aggregation), ''),
          'matched_by', NULLIF(trim(matched_by), '')
        )
      )
      ORDER BY variable
    )                                                          AS vars
  FROM demscore.variable_metadata
  GROUP BY dataset
) sub;
SQL

echo "Done: ${OUT_FILE}"
