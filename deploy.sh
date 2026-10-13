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
    echo "${key}=${value}" >> "$ENV_FILE"
  fi
}

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

  # Create .env from example if it doesn't exist
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "Creating .env from .env.example..."
    cp "$ENV_EXAMPLE" "$ENV_FILE"
  fi

  # Generate POSTGRES_PASSWORD if it's still the placeholder or missing
  current_pw="$(grep '^POSTGRES_PASSWORD=' "$ENV_FILE" | cut -d'=' -f2- || true)"
  if [[ -z "$current_pw" || "$current_pw" == "change_me" ]]; then
    new_pw="$(generate_password)"
    set_env_var "POSTGRES_PASSWORD" "$new_pw"
    echo "Generated POSTGRES_PASSWORD and saved to .env"
  else
    echo "POSTGRES_PASSWORD already set, skipping generation"
  fi

  echo ""
  echo "Starting services..."
  ./scripts/start_services.sh

  echo ""
  echo "Loading datasets..."
  ./scripts/load_demscore_module_vars.sh

  echo ""
  echo "Setting up MapServer and hex service..."
  ./scripts/setup_mapserver_hex_service.sh

  router_port="$(grep '^DEMSCORE_ROUTER_PORT=' "$ENV_FILE" | cut -d'=' -f2- || true)"
  router_port="${router_port:-8090}"

  echo ""
  echo "Install complete."
  echo "  Web app:   http://127.0.0.1:${router_port}"
  echo "  MapServer: http://127.0.0.1:${router_port}/mapserver?map=/etc/mapserver/mapserver.map"
}

cmd_start() {
  check_deps
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
  install) cmd_install ;;
  start)   cmd_start ;;
  stop)    cmd_stop ;;
  status)  cmd_status ;;
  preload) shift; cmd_preload "$@" ;;
  --preload) shift; cmd_preload "$@" ;;
  clear-map-tile-cache) shift; cmd_clear_map_tile_cache "$@" ;;
  *)       usage ;;
esac
