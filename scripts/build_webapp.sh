#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WEBAPP_DIR="${ROOT_DIR}/webapp"

if ! command -v npm >/dev/null 2>&1; then
  echo "ERROR: npm is required to build the web app." >&2
  exit 1
fi

if [[ ! -f "${WEBAPP_DIR}/package.json" ]]; then
  echo "ERROR: ${WEBAPP_DIR}/package.json not found." >&2
  exit 1
fi

echo "Building web app bundle..."
(
  cd "$WEBAPP_DIR"
  npm install --no-audit --no-fund
  npm run build
)
