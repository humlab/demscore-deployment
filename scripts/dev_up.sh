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

services=(db mapserver web-backend web router)
if is_truthy "${DEMSCORE_ENABLE_MAPCACHE:-0}"; then
  services+=(mapcache)
  echo "Starting services with mapcache enabled (DEMSCORE_ENABLE_MAPCACHE=1)..."
else
  echo "Starting services with mapcache disabled..."
fi

# Remove any stopped containers that would block recreation (e.g. stale named containers).
podman compose rm -f "${services[@]}" 2>/dev/null || true

podman compose up -d "${services[@]}"
