#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

ENV_FILE="${ROOT_DIR}/.env"
ENV_EXAMPLE="${ROOT_DIR}/.env.example"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

usage() {
  echo "Usage: $0 <command>"
  echo ""
  echo "Commands:"
  echo "  install   Generate credentials, start services, and load all data"
  echo "  import-data [--yes] [--preload N | --no-preload] [--verbose]"
  echo "            Replace the data with the files in data/Demscore_Module_Vars,"
  echo "            rebuild the map, print a summary, and offer to preload tiles"
  echo "  start     Start services (reads existing .env)"
  echo "  stop      Stop all services"
  echo "  status    Show service status"
  echo "  preload N Preload mapcache zoom levels 1..N"
  echo "            Pass --clear to empty the tile cache before warming it"
  echo "  clear-map-tile-cache"
  echo "            Empty the server-side WMS tile cache and reload nginx"
  echo ""
  echo "The install/start commands build webapp/dist before starting nginx."
  echo ""
  echo "Shortcuts:"
  echo "  --preload N  Same as: preload N"
  exit 1
}

generate_password() {
  # Prefer openssl; fall back to /dev/urandom
  if command -v openssl &>/dev/null; then
    openssl rand -base64 32 | tr -d '=/+\n' | head -c 32
  else
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32
  fi
}

set_env_var() {
  local key="$1"
  local value="$2"
  if grep -q "^${key}=" "$ENV_FILE"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
  else
    # A file that does not end in a newline would take the new key onto the
    # end of its last line.
    if [[ -s "$ENV_FILE" && -n "$(tail -c1 "$ENV_FILE")" ]]; then
      echo >> "$ENV_FILE"
    fi
    echo "${key}=${value}" >> "$ENV_FILE"
  fi
}

# Creates .env from .env.example if there is none, and generates each database
# password it lacks (or still has as the placeholder). Run by start as well as
# install, so a .env written before DEMSCORE_READER_PASSWORD existed gets one;
# scripts/sync_db_roles.sh then gives the roles whatever .env says.
ensure_env() {
  local key current
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "Creating .env from .env.example..."
    cp "$ENV_EXAMPLE" "$ENV_FILE"
  fi
  chmod 600 "$ENV_FILE"
  for key in POSTGRES_PASSWORD DEMSCORE_READER_PASSWORD; do
    current="$(grep "^${key}=" "$ENV_FILE" | cut -d'=' -f2- || true)"
    if [[ -z "$current" || "$current" == "change_me" ]]; then
      set_env_var "$key" "$(generate_password)"
      echo "Generated ${key} and saved to .env"
    fi
  done
}

# The host needs bash, curl and podman. Everything else -- Python, pdftotext,
# Node, GDAL, psql -- runs in containers.
check_deps() {
  local missing=()
  for cmd in podman curl; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: Missing required dependencies: ${missing[*]}" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_install() {
  check_deps

  ensure_env

  echo ""
  echo "Starting services..."
  ./scripts/start_services.sh

  # The same import `./deploy.sh import-data` runs, without asking first: on a
  # first install there is no earlier data to replace.
  echo ""
  ./scripts/import_data.sh --yes "$@"

  router_port="$(grep '^DEMSCORE_ROUTER_PORT=' "$ENV_FILE" | cut -d'=' -f2- || true)"
  router_port="${router_port:-8090}"

  echo ""
  echo "Install complete."
  echo "  Web app:   http://127.0.0.1:${router_port}"
  echo "  MapServer: http://127.0.0.1:${router_port}/mapserver?map=/etc/mapserver/mapserver.map"
}

cmd_import_data() {
  check_deps
  ./scripts/import_data.sh "$@"
}

cmd_start() {
  check_deps
  ensure_env
  ./scripts/start_services.sh
}

cmd_stop() {
  podman compose down
}

cmd_status() {
  podman compose ps
}

cmd_preload() {
  local levels="${1:-}"

  if [[ -z "$levels" ]]; then
    echo "ERROR: preload requires a zoom level count, e.g. ./deploy.sh --preload 2" >&2
    exit 1
  fi

  if ! [[ "$levels" =~ ^[0-9]+$ ]] || (( levels < 1 )); then
    echo "ERROR: preload level count must be a positive integer." >&2
    exit 1
  fi

  shift
  check_deps
  ./scripts/preload_mapcache_tiles.sh --zoom-min 1 --zoom-max "$levels" "$@"
}

cmd_clear_map_tile_cache() {
  check_deps
  ./scripts/clear_map_tile_cache.sh "$@"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

case "${1:-}" in
  install) shift; cmd_install "$@" ;;
  import-data) shift; cmd_import_data "$@" ;;
  start)   cmd_start ;;
  stop)    cmd_stop ;;
  status)  cmd_status ;;
  preload) shift; cmd_preload "$@" ;;
  --preload) shift; cmd_preload "$@" ;;
  clear-map-tile-cache) shift; cmd_clear_map_tile_cache "$@" ;;
  *)       usage ;;
esac
