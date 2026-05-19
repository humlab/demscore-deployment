#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

COUNTRIES_FILE="${ROOT_DIR}/data/reference/ne_110m_admin_0_countries.geojson"
COUNTRIES_URL="https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_110m_admin_0_countries.geojson"
PG_HOST="${PG_HOST:-127.0.0.1}"
PG_PORT="${PG_PORT:-5532}"
PG_DB="${PG_DB:-demscore}"
PG_USER="${PG_USER:-demscore}"
PG_PASSWORD="${PG_PASSWORD:-demscore}"

if ! command -v ogr2ogr >/dev/null 2>&1; then
  echo "ogr2ogr is required but not found on PATH." >&2
  exit 1
fi

if [[ ! -f "$COUNTRIES_FILE" ]]; then
  echo "Country geometry file not found. Downloading to ${COUNTRIES_FILE}..."
  mkdir -p "$(dirname "$COUNTRIES_FILE")"
  curl -L --fail --show-error --output "$COUNTRIES_FILE" "$COUNTRIES_URL"
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
export PGPASSWORD="$PG_PASSWORD"
ogr2ogr \
  -f PostgreSQL \
  "PG:host=${PG_HOST} port=${PG_PORT} dbname=${PG_DB} user=${PG_USER} password=${PG_PASSWORD}" \
  "$COUNTRIES_FILE" \
  -nln demscore.countries_src \
  -overwrite \
  -nlt PROMOTE_TO_MULTI \
  -lco GEOMETRY_NAME=geom \
  -lco FID=id

echo "Creating normalized map tables, precomputed hex meshes, and map function..."
echo "This step expects dataset values to be loaded first via scripts/load_demscore_module_vars.sh"
podman compose exec -T db psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 -f - < "${ROOT_DIR}/sql/mapserver_hex_setup.sql"

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

echo "Validating WMS GetCapabilities..."
curl -sS "http://127.0.0.1:8090/mapserver?map=/etc/mapserver/mapserver.map&SERVICE=WMS&REQUEST=GetCapabilities" \
  | head -n 20

echo "Validating WMS GetMap..."
map_response="$(curl -sS -o /tmp/demscore_hex_test.png -w '%{http_code} %{content_type} %{size_download}' 'http://127.0.0.1:8090/mapserver?map=/etc/mapserver/mapserver.map&SERVICE=WMS&VERSION=1.3.0&REQUEST=GetMap&LAYERS=hex_variable&STYLES=&CRS=EPSG:4326&BBOX=-60,-180,85,180&WIDTH=1200&HEIGHT=700&FORMAT=image/png&dataset=v_dem&variable=v2x_polyarchy&year=2020&hex_size=200000')"
echo "$map_response"

echo
cat <<'EOF'
Setup complete.

Example GetMap request:
http://127.0.0.1:8088/?map=/etc/mapserver/mapserver.map&SERVICE=WMS&VERSION=1.3.0&REQUEST=GetMap&LAYERS=hex_variable&STYLES=&CRS=EPSG:4326&BBOX=-60,-180,85,180&WIDTH=1200&HEIGHT=700&FORMAT=image/png&dataset=v_dem&variable=v2x_polyarchy&year=2020&hex_size=200000

Web app:
http://127.0.0.1:8090/

Optional cache proxy:
Set DEMSCORE_ENABLE_MAPCACHE=1 in .env, then run this script.
WMS via cache: http://127.0.0.1:8089/?map=/etc/mapserver/mapserver.map
Web app (uses cache automatically when enabled): http://127.0.0.1:8090/
EOF
