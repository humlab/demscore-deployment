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

echo "Building web app bundle in ${NODE_IMAGE}..."
# `npm ci`, not `npm install`: the lockfile is committed, and a server build
# should install exactly what it says rather than quietly updating it.
podman run --rm \
  -v "${WEBAPP_DIR}:/app" \
  -w /app \
  "$NODE_IMAGE" \
  sh -c "npm ci --no-audit --no-fund && npm run build"
