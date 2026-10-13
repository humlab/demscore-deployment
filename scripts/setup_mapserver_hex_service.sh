#!/usr/bin/env bash
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
ROUTER_PORT="${DEMSCORE_ROUTER_PORT:-8090}"

# Country identity (names, ISO codes) and the web-backend land basemap.
COUNTRIES_FILE="${ROOT_DIR}/data/reference/ne_50m_admin_0_countries.geojson"
COUNTRIES_URL="https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_50m_admin_0_countries.geojson"
# The same sovereigns split into geographic units, so sql/mapserver_hex_setup.sql
# can drop overseas territories such as French Guiana from the hex geometry.
MAP_UNITS_FILE="${ROOT_DIR}/data/reference/ne_50m_admin_0_map_units.geojson"
MAP_UNITS_URL="https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_50m_admin_0_map_units.geojson"
# Historical country and dependent-territory boundaries for source observations
# whose country-year unit no longer exists in Natural Earth's current-country set.
CSHAPES_FILE="${ROOT_DIR}/data/reference/CShapes-2.0.geojson"
# CShapes 2.0 starts in 1886. CShapes-Europe is the same project's European
# series from 1816, and is what supplies the German and Italian states V-Dem
# codes through unification. Same licence, same period-aware model.
CSHAPES_EUROPE_FILE="${ROOT_DIR}/data/reference/CShapes-Europe.geojson"
CSHAPES_EUROPE_URL="https://icr.ethz.ch/data/cshapes/CShapes-Europe.geojson"
# World snapshots for the years before any period-aware source reaches, and for
# the two states CShapes-Europe carries no entry for at all. Snapshot-based and
# map-scale, so sql/historical_geometry.sql grades everything taken from here
# `low` and records which snapshot each polygon came from.
HISTORICAL_BASEMAPS_DIR="${ROOT_DIR}/data/reference/historical_basemaps"
HISTORICAL_BASEMAPS_YEARS=(1783 1800 1815)
HISTORICAL_BASEMAPS_URL_BASE="https://raw.githubusercontent.com/aourednik/historical-basemaps/master/geojson"
# Project-local approximate geometries. These are deliberately separate from
# upstream reference files, which are vendored verbatim.
CUSTOM_HISTORICAL_FILE="${ROOT_DIR}/data/reference/custom/v_dem_south_yemen_aden_approx.geojson"
PG_HOST="${PG_HOST:-127.0.0.1}"
PG_PORT="${PG_PORT:-${DEMSCORE_DB_PORT:-5532}}"
PG_DB="${PG_DB:-demscore}"
PG_USER="${PG_USER:-demscore}"

for spec in "$COUNTRIES_FILE|$COUNTRIES_URL" "$MAP_UNITS_FILE|$MAP_UNITS_URL"; do
  ref_file="${spec%%|*}"
  ref_url="${spec##*|}"
  if [[ ! -f "$ref_file" ]]; then
    echo "Reference geometry file not found. Downloading to ${ref_file}..."
    mkdir -p "$(dirname "$ref_file")"
    curl -L --fail --show-error --output "$ref_file" "$ref_url"
  fi
done

if [[ ! -f "$CSHAPES_FILE" ]]; then
  echo "Missing required historical geometry file: ${CSHAPES_FILE}" >&2
  exit 1
fi

if [[ ! -f "$CSHAPES_EUROPE_FILE" ]]; then
  echo "CShapes-Europe not found. Downloading to ${CSHAPES_EUROPE_FILE}..."
  curl -L --fail --show-error --output "$CSHAPES_EUROPE_FILE" "$CSHAPES_EUROPE_URL"
fi

mkdir -p "$HISTORICAL_BASEMAPS_DIR"
for snapshot_year in "${HISTORICAL_BASEMAPS_YEARS[@]}"; do
  snapshot_file="${HISTORICAL_BASEMAPS_DIR}/world_${snapshot_year}.geojson"
  if [[ ! -f "$snapshot_file" ]]; then
    echo "Historical basemap snapshot ${snapshot_year} not found. Downloading to ${snapshot_file}..."
    curl -L --fail --show-error --output "$snapshot_file" \
      "${HISTORICAL_BASEMAPS_URL_BASE}/world_${snapshot_year}.geojson"
  fi
done

if [[ ! -f "$CUSTOM_HISTORICAL_FILE" ]]; then
  echo "Missing required custom historical geometry file: ${CUSTOM_HISTORICAL_FILE}" >&2
  exit 1
fi

echo "Starting services for local dev..."
"${ROOT_DIR}/scripts/start_services.sh"

echo "Waiting for database readiness..."
for _ in {1..30}; do
  if podman compose exec -T db pg_isready -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

if ! podman compose exec -T db pg_isready -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1; then
  echo "Database is not ready after timeout." >&2
  exit 1
fi

echo "Importing country boundaries into PostGIS..."
podman compose --profile setup run --rm gdal ogr2ogr \
  -f PostgreSQL \
  "PG:host=db port=5432 dbname=${PG_DB} user=${PG_USER}" \
  /data/ne_50m_admin_0_countries.geojson \
  -nln demscore.countries_src \
  -overwrite \
  -nlt PROMOTE_TO_MULTI \
  -lco GEOMETRY_NAME=geom \
  -lco FID=id

echo "Importing country map units into PostGIS..."
podman compose --profile setup run --rm gdal ogr2ogr \
  -f PostgreSQL \
  "PG:host=db port=5432 dbname=${PG_DB} user=${PG_USER}" \
  /data/ne_50m_admin_0_map_units.geojson \
  -nln demscore.country_units_src \
  -overwrite \
  -nlt PROMOTE_TO_MULTI \
  -lco GEOMETRY_NAME=geom \
  -lco FID=id

echo "Importing historical country boundaries into PostGIS..."
podman compose --profile setup run --rm gdal ogr2ogr \
  -f PostgreSQL \
  "PG:host=db port=5432 dbname=${PG_DB} user=${PG_USER}" \
  /data/CShapes-2.0.geojson \
  -nln demscore.cshapes_src \
  -overwrite \
  -nlt PROMOTE_TO_MULTI \
  -lco GEOMETRY_NAME=geom \
  -lco FID=id

# ogr2ogr maps a source field called "Id" onto the FID column, and CShapes-Europe
# reuses a Gleditsch-Ward code across every period of one country, so the default
# -lco FID=id collides on the second period of the first country. Renaming the
# columns on the way in also lines them up with demscore.cshapes_src, which is
# what lets sql/historical_geometry.sql read the two the same way.
echo "Importing CShapes-Europe boundaries into PostGIS..."
podman compose --profile setup run --rm gdal ogr2ogr \
  -f PostgreSQL \
  "PG:host=db port=5432 dbname=${PG_DB} user=${PG_USER}" \
  /data/CShapes-Europe.geojson \
  -nln demscore.cshapes_europe_src \
  -overwrite \
  -nlt PROMOTE_TO_MULTI \
  -lco GEOMETRY_NAME=geom \
  -lco FID=feature_id \
  -sql 'SELECT "Id" AS gwcode, "Holder" AS holder, "Name" AS cntry_name, "Status" AS status, "From" AS gwsyear, "To" AS gweyear FROM "CShapes-Europe"'

# The three snapshots land in one table, with the snapshot year carried as a
# column: a polygon from a world snapshot is only meaningful next to the year it
# is a snapshot of.
for snapshot_year in "${HISTORICAL_BASEMAPS_YEARS[@]}"; do
  if [[ "$snapshot_year" == "${HISTORICAL_BASEMAPS_YEARS[0]}" ]]; then
    import_mode="-overwrite"
  else
    import_mode="-append"
  fi
  echo "Importing historical basemap snapshot ${snapshot_year} into PostGIS..."
  podman compose --profile setup run --rm gdal ogr2ogr \
    -f PostgreSQL \
    "PG:host=db port=5432 dbname=${PG_DB} user=${PG_USER}" \
    "/data/historical_basemaps/world_${snapshot_year}.geojson" \
    -nln demscore.historical_basemaps_src \
    $import_mode \
    -nlt PROMOTE_TO_MULTI \
    -lco GEOMETRY_NAME=geom \
    -lco FID=feature_id \
    -sql "SELECT ${snapshot_year} AS snapshot_year, \"NAME\" AS name, \"SUBJECTO\" AS subject_to, \"PARTOF\" AS part_of, \"BORDERPRECISION\" AS border_precision FROM world_${snapshot_year}"
done

echo "Importing custom historical approximations into PostGIS..."
podman compose --profile setup run --rm gdal ogr2ogr \
  -f PostgreSQL \
  "PG:host=db port=5432 dbname=${PG_DB} user=${PG_USER}" \
  /data/custom/v_dem_south_yemen_aden_approx.geojson \
  -nln demscore.custom_historical_geometries_src \
  -overwrite \
  -nlt PROMOTE_TO_MULTI \
  -lco GEOMETRY_NAME=geom \
  -lco FID=feature_id

echo "Building the curated historical geometry registry and the resolution policy..."
podman compose exec -T db psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 -f - < "${ROOT_DIR}/sql/historical_geometry.sql"

echo "Creating normalised map tables, precomputed hex meshes, and map function..."
echo "This step expects dataset values to be loaded first via scripts/load_demscore_module_vars.sh"
podman compose exec -T db psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 -f - < "${ROOT_DIR}/sql/mapserver_hex_setup.sql"

# The second mesh, cut in Web Mercator, for the projection toggle. A hexagon is
# only a hexagon in the plane it was cut in, so the comparison view cannot reuse
# the Equal Earth mesh -- see the note at the top of the file.
echo "Building the Web Mercator hex mesh for the projection toggle..."
podman compose exec -T db psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 -f - < "${ROOT_DIR}/sql/mapserver_hex_mercator.sql"

# A rebuilt mesh changes what a tile shows without changing a single character of
# the URL it is cached under, so every tile the server already holds is now a
# picture of the old geometry. This is the same trap a colour change sets (see
# the colour notes in AGENTS.md); it is just that here the hexagons move rather
# than their fill. Browsers hold their own copy behind the service worker, so a
# reader who was on the page needs a hard reload as well.
if [[ "${DEMSCORE_ENABLE_MAPCACHE:-0}" == "1" ]] && podman container exists "${DEMSCORE_CONTAINER_PREFIX:-demscore}-mapcache" 2>/dev/null; then
  echo "Clearing the WMS tile cache, which still holds the previous geometry..."
  # Not fatal: the database work above is done either way, and the checks below
  # are what say whether it is right. Stopping here once skipped all of them.
  if ! "${ROOT_DIR}/scripts/clear_map_tile_cache.sh" --quiet; then
    echo "WARNING: the WMS tile cache was NOT cleared and may serve the old map." >&2
    echo "WARNING: run ./deploy.sh clear-map-tile-cache once the problem above is fixed." >&2
  fi
fi

# Every source observation must now be either drawn or explicitly refused. This
# runs before the smoke tests because an entity that quietly left the map is a
# data-correctness failure, not a rendering one, and it is cheaper to read here
# than to find later in a coverage strip.
echo "Checking that every source observation has a resolution..."
"${ROOT_DIR}/scripts/check_country_resolution.sh"

echo "Validating map function outputs..."
podman compose exec -T db psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 -c "
SELECT
  dataset,
  variable,
  year,
  count(*) AS hex_count,
  min(value) AS min_value,
  max(value) AS max_value
FROM demscore.hex_variable('v_dem','v2x_polyarchy',2020,200000)
GROUP BY dataset, variable, year;"

echo "Precomputing variable coverage strips for the variable list..."
"${ROOT_DIR}/scripts/build_variable_coverage.sh"

# Every boundary source now on the map must be one the credits can name. This
# fails on a geometry source with no entry in webapp/config/attribution_sources.json,
# for the same reason the resolution check above fails on an unmapped country: a
# source that reaches the tiles without reaching the attribution is a licence
# breach, and the only moment anyone would notice is this one.
echo "Rebuilding the sources and licences the map credits..."
"${ROOT_DIR}/scripts/build_attribution.sh"

echo "Validating WMS GetCapabilities..."
curl -sS "http://127.0.0.1:${ROUTER_PORT}/mapserver?map=/etc/mapserver/mapserver.map&SERVICE=WMS&REQUEST=GetCapabilities" \
  | head -n 20

# Requested exactly the way the web app requests it -- WMS 1.1.1, SRS rather
# than CRS, and the full Equal Earth world box -- so a mapfile that only renders
# under some other projection or axis order fails here rather than in a browser.
echo "Validating WMS GetMap (EPSG:8857)..."
map_response="$(curl -sS -o /tmp/demscore_hex_test.png -w '%{http_code} %{content_type} %{size_download}' "http://127.0.0.1:${ROUTER_PORT}/mapserver?map=/etc/mapserver/mapserver.map&SERVICE=WMS&VERSION=1.1.1&REQUEST=GetMap&LAYERS=hex_variable,hex_outline&STYLES=&SRS=EPSG:8857&BBOX=-17243960,-8392928,17243960,8392928&WIDTH=1200&HEIGHT=584&FORMAT=image/png&dataset=v_dem&variable=v2x_polyarchy&year=2020&hex_size=100000")"
echo "$map_response"
case "$map_response" in
  200\ image/png*) ;;
  *) echo "GetMap did not return a PNG -- the mapfile or the hex mesh is not serving Equal Earth." >&2; exit 1 ;;
esac

echo
cat <<EOF
Setup complete.

Example GetMap request:
http://127.0.0.1:${ROUTER_PORT}/mapserver?map=/etc/mapserver/mapserver.map&SERVICE=WMS&VERSION=1.1.1&REQUEST=GetMap&LAYERS=hex_variable,hex_outline&STYLES=&SRS=EPSG:8857&BBOX=-17243960,-8392928,17243960,8392928&WIDTH=1200&HEIGHT=584&FORMAT=image/png&dataset=v_dem&variable=v2x_polyarchy&year=2020&hex_size=100000

Web app:
http://127.0.0.1:${ROUTER_PORT}/

WMS tile caching:
Set DEMSCORE_ENABLE_MAPCACHE=1 in .env, then run this script.
WMS via app route: http://127.0.0.1:${ROUTER_PORT}/mapserver?map=/etc/mapserver/mapserver.map
Web app: http://127.0.0.1:${ROUTER_PORT}/
EOF
