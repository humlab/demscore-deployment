#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

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
PG_HOST="${PG_HOST:-127.0.0.1}"
PG_PORT="${PG_PORT:-5532}"
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

echo "Starting services for local dev..."
"${ROOT_DIR}/scripts/dev_up.sh"

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

echo "Creating normalized map tables, precomputed hex meshes, and map function..."
echo "This step expects dataset values to be loaded first via scripts/load_demscore_module_vars.sh"
podman compose exec -T db psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 -f - < "${ROOT_DIR}/sql/mapserver_hex_setup.sql"

# The second mesh, cut in Web Mercator, for the projection toggle. A hexagon is
# only a hexagon in the plane it was cut in, so the comparison view cannot reuse
# the Equal Earth mesh -- see the note at the top of the file.
echo "Building the Web Mercator hex mesh for the projection toggle..."
podman compose exec -T db psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 -f - < "${ROOT_DIR}/sql/mapserver_hex_mercator.sql"

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

echo "Validating WMS GetCapabilities..."
curl -sS "http://127.0.0.1:8090/mapserver?map=/etc/mapserver/mapserver.map&SERVICE=WMS&REQUEST=GetCapabilities" \
  | head -n 20

# Requested exactly the way the web app requests it -- WMS 1.1.1, SRS rather
# than CRS, and the full Equal Earth world box -- so a mapfile that only renders
# under some other projection or axis order fails here rather than in a browser.
echo "Validating WMS GetMap (EPSG:8857)..."
map_response="$(curl -sS -o /tmp/demscore_hex_test.png -w '%{http_code} %{content_type} %{size_download}' 'http://127.0.0.1:8090/mapserver?map=/etc/mapserver/mapserver.map&SERVICE=WMS&VERSION=1.1.1&REQUEST=GetMap&LAYERS=hex_variable,hex_outline&STYLES=&SRS=EPSG:8857&BBOX=-17243960,-8392928,17243960,8392928&WIDTH=1200&HEIGHT=584&FORMAT=image/png&dataset=v_dem&variable=v2x_polyarchy&year=2020&hex_size=100000')"
echo "$map_response"
case "$map_response" in
  200\ image/png*) ;;
  *) echo "GetMap did not return a PNG -- the mapfile or the hex mesh is not serving Equal Earth." >&2; exit 1 ;;
esac

echo
cat <<'EOF'
Setup complete.

Example GetMap request:
http://127.0.0.1:8090/mapserver?map=/etc/mapserver/mapserver.map&SERVICE=WMS&VERSION=1.1.1&REQUEST=GetMap&LAYERS=hex_variable,hex_outline&STYLES=&SRS=EPSG:8857&BBOX=-17243960,-8392928,17243960,8392928&WIDTH=1200&HEIGHT=584&FORMAT=image/png&dataset=v_dem&variable=v2x_polyarchy&year=2020&hex_size=100000

Web app:
http://127.0.0.1:8090/

WMS tile caching:
Set DEMSCORE_ENABLE_MAPCACHE=1 in .env, then run this script.
WMS via app route: http://127.0.0.1:8090/mapserver?map=/etc/mapserver/mapserver.map
Web app: http://127.0.0.1:8090/
EOF
