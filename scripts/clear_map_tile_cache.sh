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
Usage: ./scripts/clear_map_tile_cache.sh [options]

Empty the server-side WMS tile cache and reload nginx, so the next request for
a tile is rendered again rather than served from the copy the proxy holds.

A tile carries the picture, not a reference to it, and nothing in the URL says
which mesh or which colours drew it. So anything that repaints a tile without
changing its URL -- a rebuilt hex mesh, a colour, a class boundary, the outline
rule -- leaves the cache serving the old map under the new code.

Options:
  --quiet     Print nothing on success
  -h, --help  Show this help

This reaches the server cache only. A reader's browser holds its own copy behind
the service worker, which is keyed by URL and shed only when the cache's name
changes: bump WMS_TILE_CACHE in webapp/sw.js for that, or hard-reload the page.
USAGE
}

QUIET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --quiet) QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1 ;;
  esac
done

say() {
  (( QUIET == 1 )) || echo "$@"
}

if ! command -v podman >/dev/null 2>&1; then
  echo "podman is required but not found on PATH." >&2
  exit 1
fi

# The cache lives in the mapcache_data volume, reachable only through the
# container, so a stopped stack cannot be cleared from here. Say which case this
# is rather than exiting quietly on a cache that is still full.
if ! podman container exists demscore-mapcache 2>/dev/null; then
  echo "The mapcache container does not exist, so there is no server tile cache to clear." >&2
  echo "If tiles are still held in the mapcache_data volume, start services with ./scripts/dev_up.sh and run this again." >&2
  exit 1
fi

if ! podman compose ps --format '{{.Service}}\t{{.State}}' 2>/dev/null | awk -F'\t' '$1=="mapcache" && $2=="running" {found=1} END{exit found?0:1}'; then
  echo "The mapcache container is not running. Start services with ./scripts/dev_up.sh first." >&2
  exit 1
fi

say "Clearing the server-side WMS tile cache..."
podman exec demscore-mapcache sh -c 'rm -rf /var/cache/nginx/* && nginx -s reload'
say "Cleared. Browsers keep their own copy: hard-reload the page, or bump WMS_TILE_CACHE in webapp/sw.js."
