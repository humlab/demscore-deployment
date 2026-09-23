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
  --hex-size N           hex_size WMS parameter (default: the world stop of the
                         app's ladder, 200000 in either projection)
  --palette LIST         Comma-separated palette filter (default: all app
                         palettes: default,indigo_amber,viridis,cividis)
  --latest-year-only     Warm only each variable's latest available year
  --dataset LIST         Comma-separated dataset filter (e.g. qog,repdem)
  --max-requests N       Stop after N requests (for smoke testing)
  --clear                Empty the server tile cache before warming it, so the
                         run renders every tile again instead of re-reading the
                         copies the proxy already holds
  --dry-run              Print what would be requested without curl fetches
  -h, --help             Show this help

Environment knobs:
  MAPCACHE_BASE_URL      Default: http://127.0.0.1:<DEMSCORE_ROUTER_PORT or 8090>/mapserver?map=/etc/mapserver/mapserver.map
  PGUSER                 Default: demscore
  PGDATABASE             Default: demscore

If node is available, variable polarity is resolved from
webapp/config/variable_polarity.json to match the browser's WMS URLs. Without
node, the script warms all three polarity URLs for each variable/year.
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
PALETTE_FILTER="default,indigo_amber,viridis,cividis"
LATEST_YEAR_ONLY=0
DATASET_FILTER=""
MAX_REQUESTS=0
CLEAR_CACHE=0
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
    --palette)
      PALETTE_FILTER="$2"; shift 2 ;;
    --projection)
      PROJECTION="$2"; shift 2 ;;
    --latest-year-only)
      LATEST_YEAR_ONLY=1; shift ;;
    --dataset)
      DATASET_FILTER="$2"; shift 2 ;;
    --max-requests)
      MAX_REQUESTS="$2"; shift 2 ;;
    --clear)
      CLEAR_CACHE=1; shift ;;
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

MAPCACHE_BASE_URL="${MAPCACHE_BASE_URL:-http://127.0.0.1:${DEMSCORE_ROUTER_PORT:-8090}/mapserver?map=/etc/mapserver/mapserver.map}"
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
    LAYER_NAMES="hex_variable,hex_inset,hex_outline"
    # The coarsest stop in the web app's ladder -- see HEX_ZOOM_THRESHOLDS in
    # webapp/src/core/projection.js. Warming any other size warms tiles the app
    # does not ask for at the world view.
    DEFAULT_HEX_SIZE=200000
    ;;
  mercator)
    WORLD_HALF_X=20037508.342789244
    WORLD_HALF_Y=20037508.342789244
    WORLD_SRS="EPSG:3857"
    LAYER_NAMES="hex_variable_mercator,hex_inset_mercator,hex_outline_mercator"
    # The same stop as Equal Earth, deliberately: both projections count in the
    # same resolution ladder, so an equal size is an equal grain on screen --
    # see hexResolutionStops in webapp/src/core/projection.js.
    DEFAULT_HEX_SIZE=200000
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

IFS=',' read -r -a PALETTES <<< "$PALETTE_FILTER"
VALIDATED_PALETTES=()
for palette in "${PALETTES[@]}"; do
  palette="$(printf '%s' "$palette" | awk '{gsub(/^ +| +$/, "", $0); print}')"
  [[ -n "$palette" ]] || continue
  case "$palette" in
    default|indigo_amber|viridis|cividis)
      VALIDATED_PALETTES+=("$palette")
      ;;
    *)
      echo "Unknown palette: $palette (expected default, indigo_amber, viridis or cividis)" >&2
      exit 1
      ;;
  esac
done

if (( ${#VALIDATED_PALETTES[@]} == 0 )); then
  echo "--palette was provided but no valid palette values were parsed." >&2
  exit 1
fi
# The Web Mercator resolution ladder, which both projections use: the web app
# pins its zoom to these same metres-per-pixel so a zoom level means one scale
# whichever world is underneath it.
ZOOM_ZERO_RESOLUTION=156543.03392804097

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TILES_FILE="$TMP_DIR/tiles.tsv"
RAW_COMBOS_FILE="$TMP_DIR/combos_raw.tsv"
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

annotate_polarities() {
  local polarity_file="$ROOT_DIR/webapp/config/variable_polarity.json"

  if command -v node >/dev/null 2>&1 && [[ -f "$polarity_file" ]]; then
    node --input-type=module - "$RAW_COMBOS_FILE" "$polarity_file" > "$COMBOS_FILE" <<'NODE'
import fs from "node:fs";

const [, , combosPath, polarityPath] = process.argv;
const rawCombos = fs.readFileSync(combosPath, "utf8").trimEnd();
const polarityMeta = JSON.parse(fs.readFileSync(polarityPath, "utf8"));
const values = new Set(["positive", "negative", "neutral"]);

const valid = (value) => values.has(value);
const defaultPolarity = valid(polarityMeta?.defaults?.polarity)
  ? polarityMeta.defaults.polarity
  : "negative";
const datasetDefaults = polarityMeta?.dataset_defaults && typeof polarityMeta.dataset_defaults === "object"
  ? polarityMeta.dataset_defaults
  : {};
const variableOverrides = polarityMeta?.variable_overrides && typeof polarityMeta.variable_overrides === "object"
  ? polarityMeta.variable_overrides
  : {};
const rules = Array.isArray(polarityMeta?.rules)
  ? polarityMeta.rules
      .map((rule) => {
        try {
          return {
            dataset: rule.dataset,
            polarity: rule.polarity,
            regex: typeof rule.match === "string" && rule.match ? new RegExp(rule.match) : null,
          };
        } catch {
          return null;
        }
      })
      .filter((rule) => rule?.regex && valid(rule.polarity))
  : [];

function resolvePolarity(dataset, variable) {
  const override = variableOverrides?.[dataset]?.[variable];
  if (valid(override)) return override;

  const matchingRule = rules.find((rule) => {
    const datasetMatches = !rule.dataset || rule.dataset === dataset;
    return datasetMatches && rule.regex.test(variable);
  });
  if (matchingRule) return matchingRule.polarity;

  const datasetDefault = datasetDefaults?.[dataset];
  if (valid(datasetDefault)) return datasetDefault;

  return defaultPolarity;
}

if (rawCombos.length > 0) {
  for (const line of rawCombos.split("\n")) {
    const [dataset, variable, year] = line.split("\t");
    if (!dataset || !variable || !year) continue;
    console.log([dataset, variable, year, resolvePolarity(dataset, variable)].join("\t"));
  }
}
NODE
  else
    echo "node or webapp/config/variable_polarity.json not available; warming all polarity URLs." >&2
    awk -F'\t' 'BEGIN { OFS="\t" } NF >= 3 { print $1, $2, $3, "negative"; print $1, $2, $3, "positive"; print $1, $2, $3, "neutral" }' "$RAW_COMBOS_FILE" > "$COMBOS_FILE"
  fi
}

build_tiles

SQL_QUERY="$(build_sql)"
podman compose exec -T db psql -U "$PGUSER" -d "$PGDATABASE" -At -F $'\t' -c "$SQL_QUERY" > "$RAW_COMBOS_FILE"
annotate_polarities

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

palette_count=${#VALIDATED_PALETTES[@]}
total_requests=$((combo_count * tile_count * palette_count))
if (( MAX_REQUESTS > 0 && MAX_REQUESTS < total_requests )); then
  planned_requests=$MAX_REQUESTS
else
  planned_requests=$total_requests
fi

echo "Preloading mapcache tiles"
echo "- zoom range: ${ZOOM_MIN}-${ZOOM_MAX}"
echo "- tile size: ${TILE_SIZE}x${TILE_SIZE}"
echo "- hex_size: ${HEX_SIZE}"
echo "- layers: ${LAYER_NAMES}"
echo "- palettes: ${VALIDATED_PALETTES[*]}"
echo "- combos (dataset/variable/year/polarity): ${combo_count}"
echo "- tiles per combo: ${tile_count}"
echo "- planned requests: ${planned_requests}"
if (( DRY_RUN == 1 )); then
  echo "- mode: dry-run (no HTTP requests)"
fi

# Clearing belongs before the warm-up, not after: a preload only asks for tiles,
# and a URL the proxy already holds is answered from the cache, so a warm-up over
# a stale cache keeps the stale tiles and adds nothing.
if (( CLEAR_CACHE == 1 )); then
  if (( DRY_RUN == 1 )); then
    echo "- would clear the server tile cache first (skipped in dry-run)"
  else
    "$ROOT_DIR/scripts/clear_map_tile_cache.sh"
  fi
fi

request_idx=0
success_count=0
fail_count=0

while IFS=$'\t' read -r dataset variable year polarity; do
  for palette in "${VALIDATED_PALETTES[@]}"; do
    palette_param=""
    if [[ "$palette" != "default" || "$polarity" == "neutral" ]]; then
      palette_param="&palette=${palette}"
    fi
    while IFS=$'\t' read -r z x y xmin ymin xmax ymax; do
      if (( MAX_REQUESTS > 0 && request_idx >= MAX_REQUESTS )); then
        break 3
      fi
      request_idx=$((request_idx + 1))

      url="${MAPCACHE_BASE_URL}${QUERY_JOIN}SERVICE=WMS&VERSION=1.1.1&REQUEST=GetMap&LAYERS=${LAYER_NAMES}&STYLES=&FORMAT=image/png&TRANSPARENT=true&SRS=${WORLD_SRS}&BBOX=${xmin},${ymin},${xmax},${ymax}&WIDTH=${TILE_SIZE}&HEIGHT=${TILE_SIZE}&dataset=${dataset}&variable=${variable}&polarity=${polarity}&year=${year}&hex_size=${HEX_SIZE}${palette_param}"

      if (( DRY_RUN == 1 )); then
        if (( request_idx <= 20 )); then
          echo "[dry-run ${request_idx}] ${dataset}.${variable} year=${year} polarity=${polarity} palette=${palette} z=${z} x=${x} y=${y}"
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
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$dataset" "$variable" "$year" "$polarity" "$palette" "$z" "$x" "$y" >> "$FAILURES_FILE"
      fi

      if (( request_idx % 500 == 0 )) || (( request_idx == planned_requests )); then
        echo "Progress: ${request_idx}/${planned_requests} (ok=${success_count}, failed=${fail_count})"
      fi
    done < "$TILES_FILE"
  done
done < "$COMBOS_FILE"

echo "Done."
echo "- attempted: ${request_idx}"
echo "- successful: ${success_count}"
echo "- failed: ${fail_count}"

if (( fail_count > 0 )); then
  echo "Failure samples (dataset, variable, year, polarity, palette, z, x, y):"
  head -n 20 "$FAILURES_FILE"
  exit 2
fi
