#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ENV_FILE="$ROOT_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

usage() {
  cat <<'USAGE'
Usage: ./scripts/preload_mapcache_tiles.sh [options]

Preload mapcache with WMS GetMap tile requests for demscore hex layers.

Options:
  --projection NAME      equalearth (default) or mercator. Each has a mesh and a
                         tile grid of its own, so each needs its own warm-up run
  --zoom-min N           Minimum zoom level to warm (default: 1)
  --zoom-max N           Maximum zoom level to warm (default: 4)
  --tile-size N          WMS tile WIDTH/HEIGHT in pixels (default: 512)
  --hex-size N           hex_size WMS parameter (default: the projection's world
                         stop, 200000 in Equal Earth and 400000 in Mercator)
  --latest-year-only     Warm only each variable's latest available year
  --dataset LIST         Comma-separated dataset filter (e.g. qog,repdem)
  --max-requests N       Stop after N requests (for smoke testing)
  --dry-run              Print what would be requested without curl fetches
  -h, --help             Show this help

Environment knobs:
  MAPCACHE_BASE_URL      Default: http://127.0.0.1:8090/mapserver?map=/etc/mapserver/mapserver.map
  PGUSER                 Default: demscore
  PGDATABASE             Default: demscore
USAGE
}

is_truthy() {
  case "${1,,}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

ZOOM_MIN=1
ZOOM_MAX=4
TILE_SIZE=512
PROJECTION=equalearth
HEX_SIZE=""
LATEST_YEAR_ONLY=0
DATASET_FILTER=""
MAX_REQUESTS=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --zoom-min)
      ZOOM_MIN="$2"; shift 2 ;;
    --zoom-max)
      ZOOM_MAX="$2"; shift 2 ;;
    --tile-size)
      TILE_SIZE="$2"; shift 2 ;;
    --hex-size)
      HEX_SIZE="$2"; shift 2 ;;
    --projection)
      PROJECTION="$2"; shift 2 ;;
    --latest-year-only)
      LATEST_YEAR_ONLY=1; shift ;;
    --dataset)
      DATASET_FILTER="$2"; shift 2 ;;
    --max-requests)
      MAX_REQUESTS="$2"; shift 2 ;;
    --dry-run)
      DRY_RUN=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1 ;;
  esac
done

if ! [[ "$ZOOM_MIN" =~ ^[0-9]+$ && "$ZOOM_MAX" =~ ^[0-9]+$ && "$TILE_SIZE" =~ ^[0-9]+$ && "$MAX_REQUESTS" =~ ^[0-9]+$ ]]; then
  echo "Numeric options must be non-negative integers." >&2
  exit 1
fi

if (( ZOOM_MIN < 1 )); then
  echo "--zoom-min must be >= 1 (Leaflet zoom levels in this app start at 1)." >&2
  exit 1
fi

if (( ZOOM_MAX < ZOOM_MIN )); then
  echo "--zoom-max must be >= --zoom-min." >&2
  exit 1
fi

if ! command -v podman >/dev/null 2>&1; then
  echo "podman is required but not found on PATH." >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required but not found on PATH." >&2
  exit 1
fi

if [[ "${DEMSCORE_ENABLE_MAPCACHE:-0}" != "" ]] && ! is_truthy "${DEMSCORE_ENABLE_MAPCACHE:-0}"; then
  echo "DEMSCORE_ENABLE_MAPCACHE is not enabled in .env."
  echo "Enable it first (DEMSCORE_ENABLE_MAPCACHE=1), then run ./scripts/dev_up.sh."
  exit 1
fi

if ! podman compose ps --format '{{.Service}}\t{{.State}}' 2>/dev/null | awk -F'\t' '$1=="mapcache" && $2=="running" {found=1} END{exit found?0:1}'; then
  echo "mapcache service is not running. Start services with ./scripts/dev_up.sh first." >&2
  exit 1
fi

MAPCACHE_BASE_URL="${MAPCACHE_BASE_URL:-http://127.0.0.1:8090/mapserver?map=/etc/mapserver/mapserver.map}"
PGUSER="${PGUSER:-demscore}"
PGDATABASE="${PGDATABASE:-demscore}"

if [[ "$MAPCACHE_BASE_URL" != *"?"* ]]; then
  if [[ "$MAPCACHE_BASE_URL" == *"="* || "$MAPCACHE_BASE_URL" == *"&"* ]]; then
    MAPCACHE_BASE_URL+="&"
  else
    MAPCACHE_BASE_URL+="?"
  fi
elif [[ "$MAPCACHE_BASE_URL" != *"&" && "$MAPCACHE_BASE_URL" != *"?" ]]; then
  MAPCACHE_BASE_URL+="&"
fi

if [[ "$MAPCACHE_BASE_URL" != *"?"* ]] && [[ "$MAPCACHE_BASE_URL" != *"&"* ]]; then
  MAPCACHE_BASE_URL+="?"
fi

if [[ "$MAPCACHE_BASE_URL" == *"?" ]]; then
  QUERY_JOIN=""
elif [[ "$MAPCACHE_BASE_URL" == *"&" ]]; then
  QUERY_JOIN=""
else
  QUERY_JOIN="&"
fi

# One world box, one mesh and one set of layers per projection, because the two
# meshes are cut in different planes and share no tile.
#
# Equal Earth's world is not a square the way Web Mercator's is: it is widest on
# the equator at +/-17243959.06 and reaches only +/-8392927.60 north-south, a
# 2.055:1 box. Tile rows and columns are therefore counted separately from the
# world's real size rather than assumed to be 2^z of each -- which is also why
# this works unchanged for the square one.
case "$PROJECTION" in
  equalearth)
    WORLD_HALF_X=17243959.06221695
    WORLD_HALF_Y=8392927.598466456
    WORLD_SRS="EPSG:8857"
    FILL_LAYER="hex_variable"
    # The coarsest stop in the web app's ladder -- see HEX_ZOOM_THRESHOLDS in
    # webapp/src/core/projection.js. Warming any other size warms tiles the app
    # does not ask for at the world view.
    DEFAULT_HEX_SIZE=200000
    ;;
  mercator)
    WORLD_HALF_X=20037508.342789244
    WORLD_HALF_Y=20037508.342789244
    WORLD_SRS="EPSG:3857"
    FILL_LAYER="hex_variable_mercator"
    # Twice the Equal Earth stop, which is what makes the two the same grain --
    # see sql/mapserver_hex_mercator.sql.
    DEFAULT_HEX_SIZE=400000
    ;;
  *)
    echo "Unknown projection: $PROJECTION (expected equalearth or mercator)" >&2
    exit 1 ;;
esac
HEX_SIZE="${HEX_SIZE:-$DEFAULT_HEX_SIZE}"
if ! [[ "$HEX_SIZE" =~ ^[0-9]+$ ]]; then
  echo "--hex-size must be a non-negative integer." >&2
  exit 1
fi
# The Web Mercator resolution ladder, which both projections use: the web app
# pins its zoom to these same metres-per-pixel so a zoom level means one scale
# whichever world is underneath it.
ZOOM_ZERO_RESOLUTION=156543.03392804097

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TILES_FILE="$TMP_DIR/tiles.tsv"
COMBOS_FILE="$TMP_DIR/combos.tsv"
FAILURES_FILE="$TMP_DIR/failures.tsv"

build_tiles() {
  : > "$TILES_FILE"
  local z
  for (( z=ZOOM_MIN; z<=ZOOM_MAX; z++ )); do
    awk -v hx="$WORLD_HALF_X" -v hy="$WORLD_HALF_Y" \
        -v r0="$ZOOM_ZERO_RESOLUTION" -v ts="$TILE_SIZE" -v z="$z" 'BEGIN {
      span = (r0 / (2 ^ z)) * ts;          # metres covered by one tile edge
      nx = int((2 * hx) / span); if (nx * span < 2 * hx) nx++;
      ny = int((2 * hy) / span); if (ny * span < 2 * hy) ny++;
      for (x = 0; x < nx; x++) {
        for (y = 0; y < ny; y++) {
          xmin = -hx + (x * span);
          ymax =  hy - (y * span);
          printf "%d\t%d\t%d\t%.8f\t%.8f\t%.8f\t%.8f\n", \
            z, x, y, xmin, ymax - span, xmin + span, ymax;
        }
      }
    }' >> "$TILES_FILE"
  done
}

build_sql() {
  local sql
  if (( LATEST_YEAR_ONLY == 1 )); then
    sql="SELECT v.dataset, v.variable, MAX(dv.year)::int AS year
FROM demscore.variables v
JOIN demscore.dataset_values dv ON dv.variable_id = v.id
GROUP BY v.dataset, v.variable"
  else
    sql="SELECT v.dataset, v.variable, dv.year::int AS year
FROM demscore.variables v
JOIN demscore.dataset_values dv ON dv.variable_id = v.id
GROUP BY v.dataset, v.variable, dv.year"
  fi

  if [[ -n "$DATASET_FILTER" ]]; then
    local datasets_csv
    datasets_csv="$(echo "$DATASET_FILTER" | tr ',' '\n' | awk 'NF {gsub(/^ +| +$/, "", $0); printf "\047%s\047,", $0}' | sed 's/,$//')"
    if [[ -z "$datasets_csv" ]]; then
      echo "--dataset was provided but no valid dataset values were parsed." >&2
      exit 1
    fi
    sql+="\nHAVING v.dataset IN (${datasets_csv})"
  fi

  sql+="\nORDER BY 1, 2, 3;"
  printf '%b' "$sql"
}

build_tiles

SQL_QUERY="$(build_sql)"
podman compose exec -T db psql -U "$PGUSER" -d "$PGDATABASE" -At -F $'\t' -c "$SQL_QUERY" > "$COMBOS_FILE"

combo_count=$(wc -l < "$COMBOS_FILE" | tr -d ' ')
tile_count=$(wc -l < "$TILES_FILE" | tr -d ' ')

if (( combo_count == 0 )); then
  echo "No dataset/variable/year combinations were found. Did you load data with scripts/load_demscore_module_vars.sh?" >&2
  exit 1
fi

if (( tile_count == 0 )); then
  echo "No tiles were generated for the provided zoom range." >&2
  exit 1
fi

total_requests=$((combo_count * tile_count))
if (( MAX_REQUESTS > 0 && MAX_REQUESTS < total_requests )); then
  planned_requests=$MAX_REQUESTS
else
  planned_requests=$total_requests
fi

echo "Preloading mapcache tiles"
echo "- zoom range: ${ZOOM_MIN}-${ZOOM_MAX}"
echo "- tile size: ${TILE_SIZE}x${TILE_SIZE}"
echo "- hex_size: ${HEX_SIZE}"
echo "- combos (dataset/variable/year): ${combo_count}"
echo "- tiles per combo: ${tile_count}"
echo "- planned requests: ${planned_requests}"
if (( DRY_RUN == 1 )); then
  echo "- mode: dry-run (no HTTP requests)"
fi

request_idx=0
success_count=0
fail_count=0

while IFS=$'\t' read -r dataset variable year; do
  while IFS=$'\t' read -r z x y xmin ymin xmax ymax; do
    if (( MAX_REQUESTS > 0 && request_idx >= MAX_REQUESTS )); then
      break 2
    fi
    request_idx=$((request_idx + 1))

    url="${MAPCACHE_BASE_URL}${QUERY_JOIN}SERVICE=WMS&VERSION=1.1.1&REQUEST=GetMap&LAYERS=${FILL_LAYER}&STYLES=&FORMAT=image/png&TRANSPARENT=true&SRS=${WORLD_SRS}&BBOX=${xmin},${ymin},${xmax},${ymax}&WIDTH=${TILE_SIZE}&HEIGHT=${TILE_SIZE}&dataset=${dataset}&variable=${variable}&year=${year}&hex_size=${HEX_SIZE}"

    if (( DRY_RUN == 1 )); then
      if (( request_idx <= 20 )); then
        echo "[dry-run ${request_idx}] ${dataset}.${variable} year=${year} z=${z} x=${x} y=${y}"
      elif (( request_idx == 21 )); then
        echo "[dry-run] ... output truncated after 20 requests"
      fi
      success_count=$((success_count + 1))
      continue
    fi

    if curl -fsS --max-time 60 --output /dev/null "$url"; then
      success_count=$((success_count + 1))
    else
      fail_count=$((fail_count + 1))
      printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$dataset" "$variable" "$year" "$z" "$x" "$y" >> "$FAILURES_FILE"
    fi

    if (( request_idx % 500 == 0 )) || (( request_idx == planned_requests )); then
      echo "Progress: ${request_idx}/${planned_requests} (ok=${success_count}, failed=${fail_count})"
    fi
  done < "$TILES_FILE"
done < "$COMBOS_FILE"

echo "Done."
echo "- attempted: ${request_idx}"
echo "- successful: ${success_count}"
echo "- failed: ${fail_count}"

if (( fail_count > 0 )); then
  echo "Failure samples (dataset, variable, year, z, x, y):"
  head -n 20 "$FAILURES_FILE"
  exit 2
fi
