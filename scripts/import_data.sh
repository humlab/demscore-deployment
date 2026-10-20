#!/usr/bin/env bash
#
# Replaces the indicator data with the exports in data/Demscore_Module_Vars and
# rebuilds everything derived from it. This is what `./deploy.sh import-data`
# runs, and the second half of `./deploy.sh install`.
#
#   1. check     read the files before anything is touched
#                (scripts/import_data_report.py preflight)
#   2. back up   the current data tables, so a failed import can be undone
#   3. load      the CSVs (scripts/load_demscore_module_vars.sh), one transaction
#   4. metadata  titles and descriptions from the codebooks
#                (scripts/load_variable_metadata.sh)
#   5. map       country matching, hex mesh, coverage strips, credits and
#                smoke tests (scripts/setup_mapserver_hex_service.sh)
#   6. summary   what was found, what was imported, what needs attention --
#                then the offer to warm the tile cache for the new data
#
# A failure before step 3 commits changes nothing. A failure in step 5 leaves
# new data in the tables but the map unfinished, so the previous data is
# restored from step 2's backup (after asking, when run from a terminal).
# Every run keeps its logs and summary under state/imports/<run id>/.
#
# The host needs bash, curl and podman. Python and pdftotext run in the tools
# container (scripts/lib/tools.sh), and the database is only ever reached
# through `podman compose exec db`.
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

PG_USER="${PG_USER:-demscore}"
PG_DB="${PG_DB:-demscore}"
STATE_DIR="${ROOT_DIR}/state"
IMPORTS_DIR="${STATE_DIR}/imports"
# shellcheck source=scripts/lib/tools.sh
source "${ROOT_DIR}/scripts/lib/tools.sh"
# Run in the tools container, so repository-relative.
REPORT="scripts/import_data_report.py"
# Run directories kept; older ones are pruned at the start of a run.
KEEP_RUNS=10
DEFAULT_PRELOAD_LEVELS=2

usage() {
  cat <<'USAGE'
Usage: ./deploy.sh import-data [options]

Replace the indicator data with the files in data/Demscore_Module_Vars/
(QoG, REPDEM and V-Dem, each a data.csv and a codebook.pdf), rebuild the map,
and print a summary of what was found and imported.

Options:
  --yes, -y      Do not ask before replacing the data. Required when not run
                 from a terminal
  --preload N    Warm the tile cache for zoom levels 1..N afterwards, without
                 asking
  --no-preload   Do not offer to warm the tile cache
  --verbose      Show every step's output, not only the summary
  -h, --help     Show this help

Exit status: 0 imported, 2 imported but the codebook metadata did not load,
1 failed (the summary says whether the previous data was kept or restored).
USAGE
}

ASSUME_YES=0
PRELOAD_LEVELS=""
NO_PRELOAD=0
VERBOSE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) ASSUME_YES=1; shift ;;
    --preload)
      PRELOAD_LEVELS="${2:-}"
      if ! [[ "$PRELOAD_LEVELS" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: --preload needs a positive number of zoom levels, e.g. --preload 2" >&2
        exit 1
      fi
      shift 2 ;;
    --no-preload) NO_PRELOAD=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

is_truthy() {
  case "${1,,}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

is_interactive() {
  [[ -t 0 && -t 1 ]]
}

# ask "question" y|n -- the second argument is the answer Enter gives.
ask() {
  local question="$1" default="$2" hint reply
  [[ "$default" == "y" ]] && hint="[Y/n]" || hint="[y/N]"
  if ! read -r -p "${question} ${hint} " reply; then
    echo
    return 1
  fi
  reply="${reply:-$default}"
  [[ "${reply,,}" == y || "${reply,,}" == yes ]]
}

psql_db() {
  podman compose exec -T db psql -U "$PG_USER" -d "$PG_DB" -X -v ON_ERROR_STOP=1 "$@"
}

fmt_seconds() {
  local s="$1"
  if (( s < 60 )); then
    printf '%ds' "$s"
  else
    printf '%dm%02ds' $((s / 60)) $((s % 60))
  fi
}

# ---------------------------------------------------------------------------
# Prerequisites, before a run directory exists
# ---------------------------------------------------------------------------

missing=()
for cmd in podman curl; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "ERROR: missing required command(s): ${missing[*]}" >&2
  exit 1
fi

if (( ! ASSUME_YES )) && ! is_interactive; then
  echo "ERROR: not running in a terminal, so there is no one to ask before the data is replaced." >&2
  echo "       Pass --yes to import without asking." >&2
  exit 1
fi

mkdir -p "$IMPORTS_DIR"

# One import at a time: two would interleave their drops and loads.
exec 9>"${STATE_DIR}/import.lock"
if command -v flock >/dev/null 2>&1 && ! flock -n 9; then
  echo "ERROR: another import is already running (lock: ${STATE_DIR#"$ROOT_DIR"/}/import.lock)." >&2
  exit 1
fi

# Prune old run directories, newest kept.
mapfile -t old_runs < <(find "$IMPORTS_DIR" -mindepth 1 -maxdepth 1 -type d -name '20*' | sort -r | tail -n +"$KEEP_RUNS")
for dir in "${old_runs[@]}"; do
  rm -rf -- "$dir"
done

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="${IMPORTS_DIR}/${RUN_ID}"
RUN_DIR_REL="${RUN_DIR#"$ROOT_DIR"/}"
mkdir -p "$RUN_DIR"
STARTED_EPOCH="$(date +%s)"
STAGES_FILE="${RUN_DIR}/stages.tsv"
BACKUP_FILE="${RUN_DIR}/backup.sql.gz"
HAVE_BACKUP=0
INTERRUPTED=0
: > "$STAGES_FILE"

on_interrupt() {
  if (( INTERRUPTED )); then
    echo
    echo "Interrupted again; stopping. Logs: ${RUN_DIR_REL}" >&2
    exit 130
  fi
  INTERRUPTED=1
  echo
  echo "Interrupted -- finishing the current step's cleanup..." >&2
}
trap on_interrupt INT TERM

# run_stage key "label" command... -- runs one step with its output in a log of
# its own, prints one line for it, and records it for the summary.
#
# Every step, and every tool call below that does not need input, reads
# /dev/null rather than the terminal: `podman compose exec -T` and `run -T`
# pass stdin through, and a step that held the terminal would swallow keys
# typed ahead -- or, piped, the answer meant for the next question.
run_stage() {
  local key="$1" label="$2"
  shift 2
  local log="${RUN_DIR}/${key}.log"
  local start rc elapsed status
  start="$(date +%s)"
  if (( VERBOSE )); then
    echo "---- ${label} ----"
    if "$@" < /dev/null > >(tee "$log") 2>&1; then rc=0; else rc=$?; fi
  else
    printf '  %-26s ' "$label"
    if "$@" < /dev/null > "$log" 2>&1; then rc=0; else rc=$?; fi
  fi
  elapsed=$(( $(date +%s) - start ))
  if (( rc == 0 )); then status=ok; else status=failed; fi
  (( INTERRUPTED )) && status=failed
  if (( VERBOSE )); then
    echo "---- ${label}: ${status} ($(fmt_seconds "$elapsed")) ----"
  else
    echo "${status} ($(fmt_seconds "$elapsed"))"
  fi
  if [[ "$status" == failed ]] && (( ! VERBOSE )); then
    echo "    last lines of ${log#"$ROOT_DIR"/}:"
    tail -n 25 "$log" | sed 's/^/    | /'
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$key" "$label" "$status" "$elapsed" "${log#"$ROOT_DIR"/}" >> "$STAGES_FILE"
  [[ "$status" == ok ]]
}

# Everything the summary needs from the database, as one JSON object, so the
# report script never connects to it. Each part is null when its table does
# not exist (a first install, or a step that never got that far).
collect_db_facts() {
  psql_db -q -At <<'SQL'
CREATE FUNCTION pg_temp.rows(query TEXT) RETURNS JSON LANGUAGE plpgsql AS $fn$
DECLARE
  result JSON;
BEGIN
  EXECUTE format('SELECT COALESCE(json_agg(q), ''[]''::json) FROM (%s) q', query) INTO result;
  RETURN result;
EXCEPTION WHEN undefined_table OR undefined_column THEN
  RETURN NULL;
END
$fn$;

SELECT json_build_object(
  'variables', pg_temp.rows($q$
    SELECT dataset, variable, hidden FROM demscore.variables ORDER BY 1, 2 $q$),
  'columns', pg_temp.rows($q$
    SELECT dataset, column_name, outcome, value_count, na_token_cells, detail
    FROM demscore.import_column_report ORDER BY dataset, column_position $q$),
  'counts', pg_temp.rows($q$
    SELECT v.dataset,
           count(dv.id) AS values,
           count(DISTINCT dv.country_id) AS countries,
           count(dv.id) FILTER (WHERE dv.country_id IS NULL) AS unmapped,
           min(dv.year) AS year_min,
           max(dv.year) AS year_max
    FROM demscore.variables v
    LEFT JOIN demscore.dataset_values dv ON dv.variable_id = v.id
    GROUP BY v.dataset $q$),
  'metadata_parsed', pg_temp.rows($q$
    SELECT dataset, count(*) AS entries FROM demscore.variable_metadata_raw GROUP BY 1 $q$),
  'metadata_matched', pg_temp.rows($q$
    SELECT v.dataset,
           count(*) AS visible,
           count(vm.variable_id) AS matched,
           COALESCE(json_agg(v.variable ORDER BY v.variable)
                    FILTER (WHERE vm.variable_id IS NULL), '[]') AS unmatched
    FROM demscore.variables v
    LEFT JOIN demscore.variable_metadata vm ON vm.variable_id = v.id
    WHERE NOT v.hidden
    GROUP BY v.dataset $q$),
  'audit', pg_temp.rows($q$
    SELECT dataset, resolution_status AS status,
           count(DISTINCT COALESCE(iso3, '') || '|' || COALESCE(country_name, '')) AS entities,
           sum(value_count) AS values
    FROM demscore.dataset_value_unmapped_audit GROUP BY 1, 2 $q$),
  'unresolved', pg_temp.rows($q$
    SELECT dataset, COALESCE(iso3, '-') AS iso3, country_name,
           min(year) AS from_year, max(year) AS to_year, sum(value_count) AS values
    FROM demscore.dataset_value_unmapped_audit
    WHERE resolution_status = 'unresolved'
    GROUP BY 1, 2, 3 ORDER BY sum(value_count) DESC $q$)
);
SQL
}

print_summary() {
  if ! collect_db_facts > "${RUN_DIR}/facts.json" 2> "${RUN_DIR}/facts.log"; then
    echo '{}' > "${RUN_DIR}/facts.json"
  fi
  run_tool python3 "$REPORT" summary --run-dir "$RUN_DIR_REL" --started "$STARTED_EPOCH" < /dev/null || \
    echo "(the summary could not be produced; the step logs are in ${RUN_DIR_REL})" >&2
}

# ---------------------------------------------------------------------------
# Steps. Each is called from run_stage, where `set -e` does not apply, so
# each checks its own commands.
# ---------------------------------------------------------------------------

start_database() {
  podman compose up -d db || return 1
  local _
  for _ in {1..30}; do
    if podman compose exec -T db pg_isready -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "The database did not become ready within 60 seconds." >&2
  return 1
}

# The tables the load replaces, and the metadata the codebook step would
# otherwise leave describing the new variables. Nothing else is touched by the
# import before step 5, and step 5 rebuilds everything else from these.
backup_current_data() {
  local tables
  tables="$(psql_db -At -c "
    SELECT string_agg('demscore.' || n, ' ')
    FROM (VALUES ('variables'), ('dataset_values'), ('variable_metadata'),
                 ('variable_metadata_raw'), ('import_source_report'),
                 ('import_column_report')) t(n)
    WHERE to_regclass('demscore.' || n) IS NOT NULL")" || return 1
  if [[ -z "$tables" || " $tables " != *" demscore.variables "* ]]; then
    echo "No indicator data in the database yet; nothing to back up."
    return 0
  fi
  local args=() table
  for table in $tables; do
    args+=(-t "$table")
  done
  echo "Backing up: ${tables}"
  # Compressed by pg_dump and checked by the db container's gzip, so the host
  # needs neither.
  podman compose exec -T db pg_dump -U "$PG_USER" -d "$PG_DB" --no-owner --no-privileges \
    --compress=1 "${args[@]}" > "$BACKUP_FILE" || return 1
  podman compose exec -T db gzip -t < "$BACKUP_FILE" || return 1
  echo "Wrote $(du -h "$BACKUP_FILE" | cut -f1) to ${BACKUP_FILE#"$ROOT_DIR"/}"
  HAVE_BACKUP=1
}

# One transaction: the backup goes back in whole or not at all.
restore_previous_data() {
  podman compose exec -T db sh -c '
    {
      echo "BEGIN;"
      # CASCADE for the foreign keys between them; the map step rebuilds
      # every other object that reads them.
      echo "DROP TABLE IF EXISTS demscore.variable_metadata, demscore.variable_metadata_raw,"
      echo "  demscore.import_column_report, demscore.import_source_report,"
      echo "  demscore.dataset_values, demscore.variables CASCADE;"
      gunzip -c
      echo "COMMIT;"
    } | psql -U "$1" -d "$2" -X -q -v ON_ERROR_STOP=1
  ' sh "$PG_USER" "$PG_DB" < "$BACKUP_FILE"
}

remove_backup() {
  rm -f -- "$BACKUP_FILE"
}

# ---------------------------------------------------------------------------
# Failure handling
# ---------------------------------------------------------------------------

# After step 3 has committed: the new data is in, the map may not be. Put the
# previous data back and rebuild the map from it.
offer_restore() {
  echo
  if (( ! HAVE_BACKUP )); then
    echo "There was no earlier data to restore. Fix the problem above and run ./deploy.sh import-data again."
    exit 1
  fi
  if is_interactive; then
    echo "The new data is loaded, but the map was not finished with it."
    if ! ask "Restore the data from before this import and rebuild the map from it?" y; then
      echo "Left as it is. Fix the problem above and run ./deploy.sh import-data again;"
      echo "the previous data is saved in ${BACKUP_FILE#"$ROOT_DIR"/} until the next successful import."
      exit 1
    fi
  else
    echo "Restoring the data from before this import (not running in a terminal, so not asking)."
  fi
  INTERRUPTED=0
  if run_stage restore "Restore previous data" restore_previous_data \
    && run_stage map_restore "Rebuild map (previous)" "${ROOT_DIR}/scripts/setup_mapserver_hex_service.sh"; then
    remove_backup
    echo
    echo "Import FAILED; the data and the map are back as they were before it."
  else
    echo
    echo "Import FAILED and so did the restore. The backup is kept in ${BACKUP_FILE#"$ROOT_DIR"/};"
    echo "the logs in ${RUN_DIR_REL} say what went wrong."
  fi
  exit 1
}

# ---------------------------------------------------------------------------
# Tile preload
# ---------------------------------------------------------------------------

offer_preload() {
  echo
  if (( NO_PRELOAD )); then
    return 0
  fi
  if ! is_truthy "${DEMSCORE_ENABLE_MAPCACHE:-0}"; then
    echo "The server tile cache is off (DEMSCORE_ENABLE_MAPCACHE=0 in .env), so there is nothing to preload."
    return 0
  fi
  local levels="$PRELOAD_LEVELS"
  if [[ -z "$levels" ]]; then
    if ! is_interactive; then
      echo "To warm the tile cache for the new data: ./deploy.sh preload ${DEFAULT_PRELOAD_LEVELS}"
      return 0
    fi
    echo "The server tile cache was emptied, so the map renders each tile on first view."
    if ! ask "Preload map tiles for the new data now?" n; then
      echo "Skipped. To do it later: ./deploy.sh preload ${DEFAULT_PRELOAD_LEVELS}"
      return 0
    fi
    while true; do
      read -r -p "Zoom levels to warm, 1..N (each level is about four times the work of the last) [${DEFAULT_PRELOAD_LEVELS}]: " levels || return 0
      levels="${levels:-$DEFAULT_PRELOAD_LEVELS}"
      [[ "$levels" =~ ^[1-9][0-9]*$ ]] && break
      echo "Please enter a positive whole number."
    done
  fi
  if ! "${ROOT_DIR}/scripts/preload_mapcache_tiles.sh" --zoom-min 1 --zoom-max "$levels" < /dev/null; then
    echo "WARNING: the preload did not finish. The import itself is done; run ./deploy.sh preload ${levels} to try again." >&2
  fi
}

# ---------------------------------------------------------------------------
# The import
# ---------------------------------------------------------------------------

echo "Demscore data import -- run ${RUN_ID}"
echo

printf '  %-26s ' "Start database"
if ! start_database < /dev/null > "${RUN_DIR}/database.log" 2>&1; then
  echo "failed"
  tail -n 15 "${RUN_DIR}/database.log" | sed 's/^/    | /'
  exit 1
fi
echo "ok"

printf '  %-26s ' "Prepare tools container"
if ! ensure_tools_image < /dev/null > "${RUN_DIR}/tools.log" 2>&1; then
  echo "failed"
  tail -n 15 "${RUN_DIR}/tools.log" | sed 's/^/    | /'
  exit 1
fi
echo "ok"

# What the database holds before the import, for the comparison afterwards.
if ! collect_db_facts > "${RUN_DIR}/previous.json" 2> "${RUN_DIR}/previous.log"; then
  echo '{}' > "${RUN_DIR}/previous.json"
fi

echo
echo "Checking the files in data/Demscore_Module_Vars"
check_start="$(date +%s)"
if run_tool python3 "$REPORT" preflight --out "${RUN_DIR_REL}/preflight.json" \
  --previous "${RUN_DIR_REL}/previous.json" < /dev/null 2>&1 | tee "${RUN_DIR}/check.log"; then
  check_status=ok
else
  check_status=failed
fi
printf '%s\t%s\t%s\t%s\t%s\n' check "Check files" "$check_status" $(( $(date +%s) - check_start )) \
  "${RUN_DIR_REL}/check.log" >> "$STAGES_FILE"
if [[ "$check_status" != ok ]]; then
  echo
  echo "Import stopped before changing anything: fix the errors above and run it again."
  echo "Logs: ${RUN_DIR_REL}"
  exit 1
fi

echo
if (( ! ASSUME_YES )); then
  echo "This replaces every indicator in the database with the files above and rebuilds"
  echo "the map. The map is unavailable while that runs, which takes several minutes."
  if ! ask "Continue?" n; then
    echo "Nothing was changed."
    rm -rf -- "$RUN_DIR"
    exit 0
  fi
  echo
fi

echo "Importing (each step's output is in ${RUN_DIR_REL}/)"

if ! run_stage backup "Back up current data" backup_current_data; then
  print_summary
  echo
  echo "Import stopped before changing anything: the current data could not be backed up."
  exit 1
fi

if ! run_stage load "Load CSV files" "${ROOT_DIR}/scripts/load_demscore_module_vars.sh"; then
  print_summary
  echo
  echo "The load is a single transaction, so the previous data is still in place."
  remove_backup
  exit 1
fi

metadata_ok=1
if ! run_stage metadata "Load codebook metadata" "${ROOT_DIR}/scripts/load_variable_metadata.sh"; then
  metadata_ok=0
  if (( INTERRUPTED )); then
    print_summary
    offer_restore
  fi
  echo "    (carrying on: the map does not need the codebooks)"
fi

(( VERBOSE )) || echo "    the map step takes several minutes; follow it with: tail -f ${RUN_DIR_REL}/map.log"
if ! run_stage map "Build map" "${ROOT_DIR}/scripts/setup_mapserver_hex_service.sh"; then
  print_summary
  offer_restore
fi

print_summary
remove_backup
trap - INT TERM

offer_preload

if (( ! metadata_ok )); then
  exit 2
fi
exit 0
