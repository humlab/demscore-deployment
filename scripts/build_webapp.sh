#!/usr/bin/env bash
set -euo pipefail

# Builds webapp/dist, which the `web` nginx container serves.
#
# The build runs in a throwaway Node container rather than on the host, so a
# server needs nothing beyond podman: the same node:20-alpine image the
# web-backend service already runs in. The webapp directory is mounted in, so
# node_modules and dist land on the host where nginx's bind mount reads them.
# Nothing in the dependency tree compiles native code (fsevents, the only
# package with an install script, is macOS-only and optional), so that
# node_modules is equally usable by a host-side `npm run dev`.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WEBAPP_DIR="${ROOT_DIR}/webapp"
NODE_IMAGE="${DEMSCORE_NODE_IMAGE:-docker.io/library/node:20-alpine}"

if ! command -v podman >/dev/null 2>&1; then
  echo "ERROR: podman is required to build the web app." >&2
  exit 1
fi

if [[ ! -f "${WEBAPP_DIR}/package.json" ]]; then
  echo "ERROR: ${WEBAPP_DIR}/package.json not found (is the webapp submodule checked out? try: git submodule update --init)." >&2
  exit 1
fi

# Which map setup run drew the tiles (written by
# scripts/setup_mapserver_hex_service.sh). The build stamps it into the service
# worker's tile cache name, so a reader's browser drops tiles of the previous
# data or mesh instead of serving them under unchanged URLs forever. Absent
# before the first setup, and then the name is the bare version.
MAP_BUILD_ID=""
if [[ -f "${ROOT_DIR}/state/map_build_id" ]]; then
  MAP_BUILD_ID="$(tr -cd 'A-Za-z0-9-' < "${ROOT_DIR}/state/map_build_id")"
fi

echo "Building web app bundle in ${NODE_IMAGE}${MAP_BUILD_ID:+ (map build ${MAP_BUILD_ID})}..."
# `npm ci`, not `npm install`: the lockfile is committed, and a server build
# should install exactly what it says rather than quietly updating it.
podman run --rm \
  -v "${WEBAPP_DIR}:/app" \
  -w /app \
  -e DEMSCORE_MAP_BUILD_ID="$MAP_BUILD_ID" \
  "$NODE_IMAGE" \
  sh -c "npm ci --no-audit --no-fund && npm run build"
