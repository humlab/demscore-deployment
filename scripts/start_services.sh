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

is_truthy() {
  case "${1,,}" in
    1|true|yes|on)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

services=(db mapserver web-backend web mapcache router)
if is_truthy "${DEMSCORE_ENABLE_MAPCACHE:-1}"; then
  echo "Starting services with WMS tile caching enabled (DEMSCORE_ENABLE_MAPCACHE=1)..."
else
  echo "Starting services with WMS tile caching disabled..."
fi

"${ROOT_DIR}/scripts/build_webapp.sh"

# The backend's image carries server.js and its dependencies, so it is rebuilt
# on every start; an unchanged build is answered from the layer cache.
echo "Building the web backend image (web-backend/Containerfile)..."
podman compose build web-backend

# Remove any stopped containers that would block recreation (e.g. stale named containers).
podman compose rm -f "${services[@]}" 2>/dev/null || true

podman compose up -d "${services[@]}"

# A newer postgis image leaves the extensions and the collation version in the
# volume as they were under the old one until they are brought up to it.
"${ROOT_DIR}/scripts/upgrade_db_volume.sh"

# POSTGRES_PASSWORD only initialises the superuser on the volume's first boot,
# and demscore_reader -- what mapserver and web-backend connect as -- has to
# exist and carry DEMSCORE_READER_PASSWORD before either can read anything.
# Reconcile both on each start.
"${ROOT_DIR}/scripts/sync_db_roles.sh"
